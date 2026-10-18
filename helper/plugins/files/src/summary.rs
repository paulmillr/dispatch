//! files.summary: totals of a bounded walk through Job::Summary.
use super::*;
use dispatch_helper_core::api::{FolderSummary, SummaryJob};

/// Entries one summary visits when the caller names no bound.
const ENTRIES: u64 = 100_000;

pub(super) struct State {
    pub done: Done<FolderSummary>,
}

impl State {
    pub(super) fn start(
        path: &Path,
        limit: u64,
        done: Done<FolderSummary>,
        io: &mut dyn Io,
        jobs: &Jobs,
    ) {
        let job = Job::Summary(SummaryJob {
            path: path.to_path_buf(),
            limit: if limit == 0 { ENTRIES } else { limit },
        });
        Files::submit(jobs, io, job, Pending::Summary(Self { done }));
    }

    pub(super) fn event(self, io: &mut dyn Io, result: io::Result<Output>) {
        let totals = match result {
            Ok(Output::Summary(totals)) => Ok(totals),
            Ok(_) => Err(error("internal")),
            Err(value) => Err(list::failure(value)),
        };
        (self.done)(io, totals);
    }
}

#[cfg(test)]
#[path = "summary.test.rs"]
mod tests;
