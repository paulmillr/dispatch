//! `terminals.follow` (feature terminals.follow): a client holds the output of one of its attach subscriptions, a
//! chat tab whose terminal it does not show, and gets the screen back when it shows the terminal again.
//!
//! Only `terminal.output` and `terminal.stderr` of that subscription are held. Everything else goes on: input and its
//! windows, `terminal.exit`, topology, chat records, the prompt watcher and the helper's own screen reads (they read
//! the multiplexer, not this stream), and other observers of the terminal (the iPhone) get their output as before.
//! Held output is dropped, not buffered: following again asks the multiplexer for a whole repaint
//! (`Multiplexer::restore`) that reaches that subscription alone, queued in order with the terminal's output, and
//! until it arrives the subscription stays held, so nothing older reaches it after the repaint and nothing newer
//! before it. Only multiplexers that can repaint (`Multiplexer::restores`: tmux, herdr) let output be held. Tests:
//! helper/following.test.rs (they route updates as the reactor does).
use super::*;
use std::os::fd::RawFd;

/// The held subscriptions by (client, subscription): None while held, the token of the repaint coming while one is.
#[derive(Default)]
pub(crate) struct Holds {
    held: BTreeMap<(RawFd, u64), Option<u64>>,
    tokens: u64,
}
pub(crate) type Follows = Rc<RefCell<Holds>>;

impl Holds {
    /// Whether `observer`, a terminal subscription, gets `update`: a held one no Output or Stderr and only the
    /// repaint it waits for; a following one no repaint at all.
    pub(crate) fn admits(&self, observer: (RawFd, u64), update: &Update) -> bool {
        match update {
            Update::Output { .. } | Update::Stderr { .. } => !self.held.contains_key(&observer),
            Update::Restore { token, .. } => self.held.get(&observer) == Some(&Some(*token)),
            _ => true,
        }
    }
    /// The repaint reached `observer`: it follows again.
    pub(crate) fn restored(&mut self, observer: (RawFd, u64)) {
        self.held.remove(&observer);
    }
    /// Forget subscriptions that ended (`open` no longer names them).
    pub(crate) fn retain(&mut self, open: impl Fn((RawFd, u64)) -> bool) {
        self.held.retain(|observer, _| open(*observer));
    }
    pub(crate) fn is_empty(&self) -> bool {
        self.held.is_empty()
    }
}

impl Request<'_> {
    /// Protocol result: null (feature terminals.follow). `{terminal, following, subscription?}` addresses the
    /// client's own attach subscription of `terminal`, as terminals.input does. `following: false` holds its output
    /// (`unsupported` on a multiplexer that cannot repaint); `true` after that answers once the repaint is queued
    /// (an error leaves the output held: attach again). Either is a no-op when already so.
    pub(super) fn terminals_follow(&mut self, p: &Data<'_>) -> Result<(), Error> {
        let known = p
            .object()
            .ok_or_else(|| invalid("params"))?
            .all(|(key, _)| matches!(key, "terminal" | "following" | "subscription"));
        if !known {
            return Err(invalid("params"));
        }
        let following = p.get("following").and_then(Data::boolean).ok_or_else(|| invalid("following"))?;
        let (index, mux) = self.mux(p)?;
        let terminal = reference(index, local(number(p, "terminal")?));
        // terminals.attach's grant: backend.register (checked before an extension runs) and the multiplexer's.
        let grants: &[&str] = match mux.borrow().name() {
            "tmux" => &["tmux.pane"],
            "herdr" => &["herdr.rpc", "herdr.terminal"],
            _ => &[],
        };
        if grants.iter().any(|grant| !crate::helper::login::permits(&self.helper.permissions, grant)) {
            return Err(Error { code: "permission_denied", message: "This SSH feature is disabled".into() });
        }
        let observer = (self.fd, self.subscription(p, terminal)?);
        let follows = self.helper.follows.clone();
        let state = follows.borrow().held.get(&observer).copied();
        let done = self.done(None);
        match (following, state) {
            // Already so; a repaint already coming serves this one too.
            (false, Some(None)) | (true, None) | (true, Some(Some(_))) => deferred(done)(self.io, Ok(())),
            (false, _) => {
                if !mux.borrow().restores() {
                    return Err(Error {
                        code: "unsupported",
                        message: "This terminal's output cannot be held: its screen could not be restored".into(),
                    });
                }
                // A repaint still coming (shown and hidden again quickly) is not wanted now: none reaches it.
                follows.borrow_mut().held.insert(observer, None);
                deferred(done)(self.io, Ok(()));
            }
            (true, Some(None)) => {
                let token = {
                    let mut follows = follows.borrow_mut();
                    follows.tokens += 1;
                    let token = follows.tokens;
                    follows.held.insert(observer, Some(token));
                    token
                };
                mux.borrow_mut().restore(
                    self.io,
                    local(terminal),
                    token,
                    Box::new(move |io, result| {
                        if result.is_err() {
                            let mut follows = follows.borrow_mut();
                            if let Some(waiting) = follows.held.get_mut(&observer).filter(|w| **w == Some(token)) {
                                *waiting = None;
                            }
                        }
                        done(io, result);
                    }),
                );
            }
        }
        Ok(())
    }

    /// The client's attach subscription of `terminal`: `subscription` when it names one of them, else its only one.
    fn subscription(&self, p: &Data<'_>, terminal: Id) -> Result<u64, Error> {
        let windows = self.helper.windows.borrow();
        let mut streams = windows
            .iter()
            .filter(|((fd, _), (id, _))| *fd == self.fd && *id == terminal)
            .filter_map(|((_, stream), _)| *stream);
        match optional(p, "subscription") {
            Some(stream) => streams.find(|s| *s == stream).ok_or_else(|| invalid("subscription")),
            None => match (streams.next(), streams.next()) {
                (Some(stream), None) => Ok(stream),
                _ => Err(invalid("subscription")),
            },
        }
    }
}
