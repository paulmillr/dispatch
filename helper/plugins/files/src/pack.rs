//! files.pack and files.pack.drop: a selection packed by one worker job (Job::Pack) into
//! `<temporary directory>/dispatch-pack-<random>.tar.zst`, which the app then reads with files.read and drops.
//!
//! An archive is its connection's until that connection drops it or ends, or until it is left `idle` without a read.
//! What they all hold is bounded (Budget): archives per connection and per helper, running or kept, and their bytes
//! per connection and per helper. So a client with only the read grant can neither keep packing until the temporary
//! volume is down to its reserve nor crowd out the other clients, and the map holds at most `helper` ids of at most
//! TRANSFER bytes.
use super::*;
use dispatch_helper_core::api::{Expected, PackJob, Packed, Stop};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
use transfer::{Gate, failure, job, normal};

/// Entries one pack holds when the request names no limit.
const ENTRIES: u64 = 250_000;
/// A caller may lower the ordinary bound, never turn a copy into an unbounded filesystem walk.
const MAX_ENTRIES: u64 = 1_000_000;
const PREFIX: &str = "dispatch-pack-";
/// Archives this old were left by a helper that ended before their drop.
const AGE: Duration = Duration::from_secs(24 * 60 * 60);
/// The longest transfer id (packs and unpacks): the apps send a UUID's 36 characters.
pub(super) const TRANSFER: usize = 64;

/// What one helper's packs may hold, running or kept.
#[derive(Clone, Copy, Debug)]
pub(super) struct Budget {
    /// Archives per connection: one being read, one more being packed.
    pub client: usize,
    pub helper: usize,
    /// Archive bytes per connection: one copy at the 64 GiB content bound.
    pub client_bytes: u64,
    pub helper_bytes: u64,
    /// A kept archive nobody read for this long is removed, as its drop would.
    pub idle: Duration,
}

impl Default for Budget {
    fn default() -> Self {
        Self {
            client: 2,
            helper: 8,
            client_bytes: 64 << 30,
            helper_bytes: 128 << 30,
            idle: Duration::from_secs(10 * 60),
        }
    }
}

pub(super) struct Packs {
    /// The system temporary directory, from the first pack's sweep (never looked at during startup: every
    /// recording would change).
    temporary: Option<PathBuf>,
    packs: HashMap<String, State>,
    gate: Gate,
    pub(super) budget: Budget,
    /// Tells a kept archive from a later one under the same id, for its idle timer.
    serial: u64,
    /// The last archives removed for being left idle, to say so to a read that finds one gone.
    expired: std::collections::VecDeque<PathBuf>,
}

impl Packs {
    pub(super) fn new(gate: Gate) -> Self {
        Self {
            temporary: None,
            packs: HashMap::new(),
            gate,
            budget: Budget::default(),
            serial: 0,
            expired: std::collections::VecDeque::new(),
        }
    }

    /// When the kept archive `transfer` was packed or last read.
    #[cfg(test)]
    pub(super) fn used(&self, transfer: &str) -> Option<Instant> {
        self.packs.get(transfer).and_then(|state| state.used)
    }

    /// The archives `client` holds (None: everyone's), running or kept, and their bytes.
    fn held(&self, client: Option<u64>) -> (usize, u64) {
        let owned = self.packs.values().filter(|state| client.is_none_or(|client| state.client == client));
        owned.fold((0, 0), |(count, bytes), state| (count + 1, bytes.saturating_add(state.size)))
    }
}

struct State {
    /// The serial of the connection that packed it: only its own drop or departure ends it.
    client: u64,
    /// None while the pack runs.
    archive: Option<PathBuf>,
    /// The archive's size once packed.
    size: u64,
    /// When it was packed or last read.
    used: Option<Instant>,
    serial: u64,
    /// Dropped while running: the job stops before its next entry, and an archive it finished is removed.
    dropped: bool,
    stop: Stop,
}

pub(super) type Shared = Rc<RefCell<Packs>>;

struct Run {
    packs: Shared,
    transfer: String,
    base: PathBuf,
    paths: Vec<PathBuf>,
    limit: u64,
    budget: u64,
    done: Done<Packed>,
}

fn refused(code: &'static str, message: String) -> Error {
    Error { code, message }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn pack(
    packs: &Shared,
    io: &mut dyn Io,
    client: u64,
    transfer: &str,
    base: &Path,
    paths: &[PathBuf],
    limit: u64,
    done: Done<Packed>,
) {
    let named = !transfer.is_empty() && transfer.len() <= TRANSFER;
    let Some(base) = normal(base).filter(|_| named && !paths.is_empty()) else {
        return done(io, Err(error("invalid_request")));
    };
    let Some(paths) = paths
        .iter()
        .map(|path| normal(path).filter(|path| path.starts_with(&base) && *path != base))
        .collect::<Option<Vec<_>>>()
    else {
        return done(io, Err(error("invalid_request")));
    };
    let budget = {
        let mut packs = packs.borrow_mut();
        if packs.gate.get() {
            return done(io, Err(error("busy")));
        }
        if packs.packs.contains_key(transfer) {
            return done(io, Err(error("invalid_request")));
        }
        let limits = packs.budget;
        let ((count, bytes), (total, all)) = (packs.held(Some(client)), packs.held(None));
        if count >= limits.client {
            let message = format!("this connection already keeps {count} copy archives on the helper; wait for the current copy to finish");
            return done(io, Err(refused("limit", message)));
        }
        // Other clients' copies: they end, so this one may wait for them.
        if total >= limits.helper {
            let message = format!("the helper already keeps {total} copy archives for its clients");
            return done(io, Err(refused("busy", message)));
        }
        let budget = limits.client_bytes.saturating_sub(bytes).min(limits.helper_bytes.saturating_sub(all));
        if budget == 0 {
            let message = "the copy archives on the helper are at their size budget; wait for the current copy to finish".to_owned();
            return done(io, Err(refused("limit", message)));
        }
        packs.gate.set(true);
        packs.serial += 1;
        let serial = packs.serial;
        packs.packs.insert(
            transfer.to_owned(),
            State {
                client,
                archive: None,
                size: 0,
                used: None,
                serial,
                dropped: false,
                stop: Stop::default(),
            },
        );
        budget
    };
    let run = Run {
        packs: packs.clone(),
        transfer: transfer.to_owned(),
        base,
        paths,
        limit: if limit == 0 { ENTRIES } else { limit.min(MAX_ENTRIES) },
        budget,
        done,
    };
    let temporary = packs.borrow().temporary.clone();
    match temporary {
        Some(directory) => run.start(io, directory),
        None => {
            let sweep = Job::Sweep(PREFIX.into(), AGE);
            job(io, sweep, move |io, result| match result {
                Ok(Output::Swept(directory, _)) => {
                    run.packs.borrow_mut().temporary = Some(directory.clone());
                    run.start(io, directory);
                }
                Ok(_) => run.fail(io, error("internal")),
                Err(value) => run.fail(io, native(value)),
            });
        }
    }
}

impl Run {
    fn start(self, io: &mut dyn Io, directory: PathBuf) {
        let name = match transfer::random(io) {
            Ok(name) => name,
            Err(value) => return self.fail(io, native(value)),
        };
        let archive = directory.join(format!("{PREFIX}{name}.tar.zst"));
        // Dropped during the sweep: nothing to start.
        let stop = self.packs.borrow().packs.get(&self.transfer).filter(|state| !state.dropped).map(|state| state.stop.clone());
        let Some(stop) = stop else {
            return self.fail(io, error("cancelled"));
        };
        let work = Job::Pack(PackJob {
            base: self.base.clone(),
            paths: self.paths.clone(),
            archive: archive.clone(),
            limit: self.limit,
            budget: self.budget,
            stop,
        });
        job(io, work, move |io, result| match result {
            Ok(Output::Packed(packed)) => self.finish(io, archive, packed),
            Ok(_) => self.fail(io, error("internal")),
            Err(_) if self.dropped() => self.fail(io, error("cancelled")),
            Err(value) => self.fail(io, packing(value)),
        });
    }

    fn dropped(&self) -> bool {
        self.packs.borrow().packs.get(&self.transfer).is_none_or(|state| state.dropped)
    }

    fn finish(self, io: &mut dyn Io, archive: PathBuf, packed: Packed) {
        let kept = {
            let mut packs = self.packs.borrow_mut();
            packs.gate.set(false);
            match packs.packs.get_mut(&self.transfer) {
                Some(state) if !state.dropped => {
                    state.archive = Some(archive.clone());
                    state.size = packed.size;
                    Some(state.serial)
                }
                _ => {
                    packs.packs.remove(&self.transfer);
                    None
                }
            }
        };
        if let Some(serial) = kept {
            let now = io.now();
            let idle = {
                let mut packs = self.packs.borrow_mut();
                if let Some(state) = packs.packs.get_mut(&self.transfer) {
                    state.used = Some(now);
                }
                packs.budget.idle
            };
            expire(&self.packs, io, self.transfer.clone(), serial, now + idle);
            return (self.done)(io, Ok(packed));
        }
        job(io, Job::Remove { path: archive, expected: Expected::Any }, |_, _| {});
        (self.done)(io, Err(error("cancelled")));
    }

    fn fail(self, io: &mut dyn Io, error: Error) {
        let mut packs = self.packs.borrow_mut();
        packs.gate.set(false);
        packs.packs.remove(&self.transfer);
        drop(packs);
        (self.done)(io, Err(error));
    }
}

/// At `at`, the kept archive `transfer` (still the one numbered `serial`) is removed, unless it was read since: then
/// the wait starts again from that read.
fn expire(packs: &Shared, io: &mut dyn Io, transfer: String, serial: u64, at: Instant) {
    let shared = packs.clone();
    // An Io without timers keeps the archive until its drop.
    let _ = io.after(
        at,
        Box::new(move |io| {
            let due = {
                let packs = shared.borrow();
                let used = packs.packs.get(&transfer).filter(|state| state.serial == serial).and_then(|state| state.used);
                let Some(used) = used else { return };
                used + packs.budget.idle
            };
            if io.now() < due {
                return expire(&shared, io, transfer, serial, due);
            }
            {
                let mut packs = shared.borrow_mut();
                let archive = packs.packs.get(&transfer).and_then(|state| state.archive.clone());
                if let Some(archive) = archive {
                    if packs.expired.len() == EXPIRED {
                        packs.expired.pop_front();
                    }
                    packs.expired.push_back(archive);
                }
            }
            discard(&shared, io, By::Idle, &transfer, Box::new(|_, _| {}));
        }),
    );
}

/// Archives `expired` remembers.
const EXPIRED: usize = 8;

/// Whether `path` is a kept archive.
pub(super) fn kept(packs: &Shared, path: &Path) -> bool {
    packs.borrow().packs.values().any(|state| state.archive.as_deref() == Some(path))
}

/// Whether `path` was an archive removed for being left idle.
pub(super) fn expired(packs: &Shared, path: &Path) -> bool {
    packs.borrow().expired.iter().any(|expired| expired == path)
}

/// Each window files.read reads of a kept archive: an archive being read stays.
pub(super) fn touch(packs: &Shared, io: &mut dyn Io, path: &Path) {
    let mut packs = packs.borrow_mut();
    if let Some(state) = packs.packs.values_mut().find(|state| state.archive.as_deref() == Some(path)) {
        state.used = Some(io.now());
    }
}

/// `done` of a files.read of the kept (or expired) archive `path`: when the archive went for being left without a read
/// for longer than `idle`, the read says so instead of only that the file is gone.
pub(super) fn reading(packs: &Shared, path: &Path, done: Done<Metadata>) -> Done<Metadata> {
    let (packs, path) = (packs.clone(), path.to_path_buf());
    Box::new(move |io, result| {
        let result = match result {
            Err(error) if error.code == "not_found" && packs.borrow().expired.contains(&path) => {
                let minutes = packs.borrow().budget.idle.as_secs().div_ceil(60);
                let message = format!("the helper removed the copy archive after {minutes} minutes without a read; copy again");
                Err(refused("limit", message))
            }
            result => result,
        };
        done(io, result)
    })
}

/// Job::Pack's failures: only a file that changed under it (its identity or size) is `changed`; the encoder's own
/// failures are `io`, since the archive is the helper's, not anything the client sent.
pub(super) fn packing(value: io::Error) -> Error {
    let code = match (value.raw_os_error(), value.kind()) {
        (None, io::ErrorKind::StaleNetworkFileHandle) => "changed",
        (None, io::ErrorKind::InvalidData) => "io",
        _ => return failure(value),
    };
    Error {
        code,
        message: value.to_string(),
    }
}

/// Who ends a pack: its connection's drop (another connection's is refused), its connection's departure (another
/// connection's pack of that id is left alone), or the helper, for an archive left idle.
pub(super) enum By {
    Drop(u64),
    Departure(u64),
    Idle,
}

/// files.pack.drop, a departure's release, or an idle archive's end (By). An unknown transfer is already gone.
pub(super) fn discard(packs: &Shared, io: &mut dyn Io, by: By, transfer: &str, done: Done<()>) {
    let archive = {
        let mut packs = packs.borrow_mut();
        let owner = packs.packs.get(transfer).map(|state| state.client);
        match (by, owner) {
            (By::Drop(client), Some(owner)) if client != owner => {
                drop(packs);
                return done(io, Err(refused("invalid_request", "another connection's copy archive".into())));
            }
            (By::Departure(client), Some(owner)) if client != owner => {
                drop(packs);
                return done(io, Ok(()));
            }
            _ => {}
        }
        match packs.packs.get_mut(transfer) {
            None => None,
            Some(state) if state.archive.is_none() => {
                state.dropped = true;
                state.stop.set();
                None
            }
            Some(_) => packs.packs.remove(transfer).and_then(|state| state.archive),
        }
    };
    let Some(archive) = archive else {
        return done(io, Ok(()));
    };
    job(io, Job::Remove { path: archive, expected: Expected::Any }, move |io, result| match result {
        Err(value) if value.kind() != io::ErrorKind::NotFound => done(io, Err(native(value))),
        _ => done(io, Ok(())),
    });
}
