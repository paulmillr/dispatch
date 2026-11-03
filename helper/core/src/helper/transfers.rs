//! Files transfers a client opened (files.pack, files.unpack.open) end with its connection: a pack's archive is
//! dropped and an open unpack is closed without commit, so no archive or staging directory outlives the copy.
//! What a client opened is known from its requests' completions, never from the requests alone: a refused
//! request (a transfer id another client holds) opens nothing, and a close ends a transfer only once it is done.
//! The ending goes through the plugin's `release`, which no capability check stands in front of.
use crate::{api::*, json::Data};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    os::fd::RawFd,
    rc::Rc,
    time::Duration,
};

/// How long a stdio helper whose client left waits for those removals before it exits anyway; a running commit
/// is always waited for, since exiting during its moves would leave the copy half in place.
pub(super) const ENDING: Duration = Duration::from_secs(30);

/// One transfer a client opened: (plugin, unpack rather than pack, transfer id).
type Opened = (String, bool, String);

/// Packs remembered per client, newest kept: the plugin keeps far fewer per client and removes one left idle by
/// itself, so an older id no longer names an archive, and a client never dropping its ids cannot grow the list.
const PACKS: usize = 16;

#[derive(Default)]
struct Client {
    /// Set when the client disconnects: a request of its that completes later ends what it opened at once.
    ended: Cell<bool>,
    /// The connection's own number, never reused (its fd is): what owns the packs it makes.
    serial: u64,
}

#[derive(Default)]
struct State {
    opened: BTreeMap<RawFd, Vec<Opened>>,
    /// Clients with transfer requests, until they disconnect (fd numbers are reused: each connection gets its own).
    clients: BTreeMap<RawFd, Rc<Client>>,
    /// Releases and requests of disconnected clients whose completion has not come back.
    running: usize,
    /// Commits (files.unpack.close with commit) in flight.
    committing: usize,
    /// The last client serial given.
    serial: u64,
}

impl State {
    fn client(&mut self, fd: RawFd) -> Rc<Client> {
        if let Some(client) = self.clients.get(&fd) {
            return client.clone();
        }
        self.serial += 1;
        let client = Rc::new(Client { ended: Cell::new(false), serial: self.serial });
        self.clients.insert(fd, client.clone());
        client
    }
}

#[derive(Default)]
pub(crate) struct Transfers {
    state: Rc<RefCell<State>>,
}

/// One running release: counted until its completion runs or is dropped unrun, so a lost callback cannot keep
/// a helper waiting.
struct Running(Rc<RefCell<State>>);
impl Drop for Running {
    fn drop(&mut self) {
        self.0.borrow_mut().running -= 1;
    }
}

/// One observed request in flight, likewise counted until its completion runs or is dropped.
struct Pending {
    state: Rc<RefCell<State>>,
    client: Rc<Client>,
    commit: bool,
}
impl Drop for Pending {
    fn drop(&mut self) {
        let mut state = self.state.borrow_mut();
        if self.commit {
            state.committing -= 1;
        }
        if self.client.ended.get() {
            state.running -= 1;
        }
    }
}

fn release(state: &Rc<RefCell<State>>, io: &mut dyn Io, plugin: Shared<dyn Plugin>, client: u64, unpack: bool, transfer: String) {
    state.borrow_mut().running += 1;
    let running = Running(state.clone());
    // Never inside the call that completed: the plugin may still be borrowed there.
    io.defer(Box::new(move |io| {
        let finished: Done<()> = Box::new(move |_, _| drop(running));
        plugin.borrow_mut().release(io, client, &transfer, unpack, finished);
    }));
}

impl Transfers {
    /// The serial of the connection on `fd`: the owner the plugin keeps for what it opens.
    pub(crate) fn client(&self, fd: RawFd) -> u64 {
        self.state.borrow_mut().client(fd).serial
    }

    /// `done` of request `method` (a plugin trait method) from `fd` to `plugin`, wrapped to learn what it opens and
    /// ends; any other method's comes back unchanged.
    pub(crate) fn observe<T: 'static>(
        &self,
        fd: RawFd,
        plugin: &Shared<dyn Plugin>,
        method: &str,
        params: &Data<'_>,
        done: Done<T>,
    ) -> Done<T> {
        let (unpack, opens) = match method {
            "pack" => (false, true),
            "pack_drop" => (false, false),
            "unpack_open" => (true, true),
            "unpack_close" => (true, false),
            _ => return done,
        };
        let Some(transfer) = params.get("transfer").and_then(Data::string).map(str::to_owned) else {
            return done;
        };
        let commit = method == "unpack_close" && params.get("commit").and_then(Data::boolean).unwrap_or(false);
        let name = plugin.borrow().name().to_owned();
        let client = self.state.borrow_mut().client(fd);
        // Pending's drop takes it back.
        if commit {
            self.state.borrow_mut().committing += 1;
        }
        let pending = Pending { state: self.state.clone(), client, commit };
        let plugin = plugin.clone();
        Box::new(move |io, result| {
            let opened = opens
                // A call the grants refused after the plugin took it may still have opened the transfer.
                && result.as_ref().err().is_none_or(|error| error.code == "permission_denied");
            let ended = pending.client.ended.get();
            if !ended {
                let mut state = pending.state.borrow_mut();
                let list = state.opened.entry(fd).or_default();
                // A refused open (an id already open) leaves the open one listed.
                if opened || !opens {
                    list.retain(|(plugin, kind, id)| !(*plugin == name && *kind == unpack && *id == transfer));
                }
                if opened {
                    list.push((name.clone(), unpack, transfer.clone()));
                    let packs = list.iter().filter(|(_, unpack, _)| !unpack).count();
                    let mut excess = packs.saturating_sub(PACKS);
                    list.retain(|(_, unpack, _)| *unpack || excess == 0 || {
                        excess -= 1;
                        false
                    });
                }
            } else if opened {
                release(&pending.state, io, plugin, pending.client.serial, unpack, transfer);
            }
            drop(pending);
            done(io, result);
        })
    }

    /// `fd` disconnected: end what it left open, and what its requests still running open.
    pub(super) fn end(&mut self, fd: RawFd, io: &mut dyn Io, plugins: &[Shared<dyn Plugin>]) {
        let (opened, client) = {
            let mut state = self.state.borrow_mut();
            (state.opened.remove(&fd).unwrap_or_default(), state.clients.remove(&fd))
        };
        let serial = client.as_ref().map_or(0, |client| client.serial);
        if let Some(client) = client {
            client.ended.set(true);
            // Each of its requests still in flight holds a count until it completes.
            self.state.borrow_mut().running += Rc::strong_count(&client) - 1;
        }
        for (name, unpack, transfer) in opened {
            let Some(plugin) = plugins.iter().find(|plugin| plugin.borrow().name() == name).cloned() else {
                continue;
            };
            release(&self.state, io, plugin, serial, unpack, transfer);
        }
    }

    /// The removals a disconnect started, or a commit, are still running.
    pub(super) fn running(&self) -> bool {
        let state = self.state.borrow();
        state.running > 0 || state.committing > 0
    }

    /// A stdio helper whose client left may exit: nothing runs, or the deadline passed and no commit runs.
    pub(super) fn may_exit(&self, past_deadline: bool) -> bool {
        !self.running() || (past_deadline && self.state.borrow().committing == 0)
    }
}

#[cfg(test)]
#[path = "transfers.test.rs"]
mod tests;
