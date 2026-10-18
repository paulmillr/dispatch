//! files.list: one directory level through Job::Entries.
use super::*;
use dispatch_helper_core::api::{EntriesJob, Listing};

/// The most entries one listing returns; more only set `truncated`. The app shows them all as
/// rows, so the bound is what a view can hold, not what a directory can.
const ENTRIES: u64 = 10_000;

pub(super) struct State {
    path: String,
    pub done: Done<Listing>,
}

/// A folder operation's failure: a path that is not a directory has its own code.
pub(super) fn failure(value: io::Error) -> Error {
    if value.kind() == io::ErrorKind::NotADirectory {
        error("not_directory")
    } else {
        native(value)
    }
}

impl State {
    pub(super) fn start(
        path: &Path,
        hidden: bool,
        limit: u64,
        done: Done<Listing>,
        io: &mut dyn Io,
        jobs: &Jobs,
    ) {
        let job = Job::Entries(EntriesJob {
            path: path.to_path_buf(),
            hidden,
            limit: if limit == 0 {
                ENTRIES
            } else {
                limit.min(ENTRIES)
            },
        });
        let state = Self {
            path: path.to_string_lossy().into_owned(),
            done,
        };
        Files::submit(jobs, io, job, Pending::List(state));
    }

    pub(super) fn event(self, io: &mut dyn Io, result: io::Result<Output>) {
        let listing = match result {
            Ok(Output::Entries(entries, truncated)) => Ok(Listing {
                path: self.path,
                entries,
                truncated,
            }),
            Ok(_) => Err(error("internal")),
            Err(value) => Err(failure(value)),
        };
        (self.done)(io, listing);
    }
}

#[cfg(test)]
#[path = "list.test.rs"]
mod tests;
