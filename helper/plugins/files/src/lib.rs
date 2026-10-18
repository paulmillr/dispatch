//! Complete source text; filesystem work runs through the shared IO interface.
//!
//! One module per operation family: `read.rs` (files.read), `branch.rs` (files.branch), `list.rs`
//! (files.list), `summary.rs` (files.summary), `write.rs` (files.write), `pack.rs` (files.pack,
//! files.pack.drop), `unpack.rs` (files.unpack.*) and `git.rs` (files.git); `transfer.rs` tracks the packs
//! and unpacks a client has open.

use dispatch_helper_core::api::{
    Chunk, Done, Error, Event, FileKind, Io, Job, Metadata, Output, Plugin, Read, Ui, Work,
    deferred,
};
use dispatch_helper_core::api::{FolderSummary, Listing};
use dispatch_helper_core::api::{Git, Packed, Progress, Transfer, Unpacked};
use std::{
    cell::RefCell,
    io,
    path::{Path, PathBuf},
    rc::Rc,
};

mod branch;
mod git;
mod list;
mod read;
mod summary;
#[cfg(test)]
#[path = "harness.test.rs"]
mod harness;
mod pack;
mod transfer;
mod unpack;
mod write;

const LIMIT: u64 = 2_000_000;
type Jobs = Rc<RefCell<Vec<(Work, Pending)>>>;

pub struct Files {
    checked: bool,
    jobs: Jobs,
    packs: pack::Shared,
    unpack: unpack::Shared,
    gate: transfer::Gate,
    git: git::Settings,
    /// Each repository's filters, read once (files.git turns them off).
    repositories: git::Repositories,
}

enum Stage {
    Metadata(PathBuf),
    Read,
}

struct Text {
    stage: Stage,
    done: Done<String>,
}

enum Pending {
    Text(Text),
    Read(read::State),
    Branch(branch::State),
    List(list::State),
    Summary(summary::State),
}

impl Pending {
    fn fail(self, io: &mut dyn Io, error: Error) {
        match self {
            Self::Text(text) => (text.done)(io, Err(error)),
            Self::Read(read) => (read.done)(io, Err(error)),
            Self::Branch(_) => unreachable!("branch completion handles unavailable metadata"),
            Self::List(list) => (list.done)(io, Err(error)),
            Self::Summary(summary) => (summary.done)(io, Err(error)),
        }
    }
}

fn error(code: &'static str) -> Error {
    Error {
        code,
        message: String::new(),
    }
}

fn native(value: io::Error) -> Error {
    let code = match value.kind() {
        io::ErrorKind::NotFound => "not_found",
        io::ErrorKind::PermissionDenied => "permission_denied",
        io::ErrorKind::InvalidInput => "invalid_request",
        io::ErrorKind::Interrupted => "interrupted",
        io::ErrorKind::TimedOut => "timeout",
        io::ErrorKind::WouldBlock => "busy",
        _ => "io",
    };
    Error {
        code,
        message: value.to_string(),
    }
}

impl Files {
    /// `checked` keeps the existing SSH policy; false keeps the local initial preview.
    pub fn new(checked: bool) -> Self {
        let gate = transfer::Gate::default();
        Self {
            checked,
            jobs: Rc::default(),
            packs: Rc::new(RefCell::new(pack::Packs::new(gate.clone()))),
            unpack: Rc::default(),
            gate,
            git: git::Settings::default(),
            repositories: git::Repositories::default(),
        }
    }

    fn submit(jobs: &Jobs, io: &mut dyn Io, job: Job, pending: Pending) {
        match io.submit(job) {
            Ok(work) => jobs.borrow_mut().push((work, pending)),
            Err(value) => pending.fail(io, native(value)),
        }
    }
}

impl Plugin for Files {
    fn name(&self) -> &str {
        "files"
    }

    fn read(
        &mut self,
        io: &mut dyn Io,
        read: &Read,
        limit: usize,
        chunk: Chunk,
        done: Done<Metadata>,
    ) {
        let done = deferred(done);
        if !read.path.is_absolute() || read.offset > i64::MAX as u64 || limit == 0 {
            done(io, Err(error("invalid_request")));
            return;
        }
        read::State {
            read: read.clone(),
            limit: limit as u64,
            chunk: Rc::new(RefCell::new(chunk)),
            done,
        }
        .submit(io, &self.jobs);
    }

    fn branch(&mut self, io: &mut dyn Io, path: &Path, done: Done<Option<String>>) {
        let done = deferred(done);
        if !path.is_absolute() {
            done(io, Ok(None));
            return;
        }
        branch::State::start(path, done, io, &self.jobs);
    }

    fn list(
        &mut self,
        io: &mut dyn Io,
        path: &Path,
        hidden: bool,
        limit: u64,
        // Accepted for the git tabs; marks stay None until they come.
        _git: bool,
        done: Done<Listing>,
    ) {
        let done = deferred(done);
        if !path.is_absolute() {
            done(io, Err(error("invalid_request")));
            return;
        }
        list::State::start(path, hidden, limit, done, io, &self.jobs);
    }

    fn summary(&mut self, io: &mut dyn Io, path: &Path, limit: u64, done: Done<FolderSummary>) {
        let done = deferred(done);
        if !path.is_absolute() {
            done(io, Err(error("invalid_request")));
            return;
        }
        summary::State::start(path, limit, done, io, &self.jobs);
    }

    fn text(&mut self, io: &mut dyn Io, path: &Path, done: Done<String>) {
        let done = deferred(done);
        if !path.is_absolute() {
            done(io, Err(error("invalid_request")));
            return;
        }
        let path = path.to_path_buf();
        let (job, stage) = if self.checked {
            (
                Job::Read {
                    path,
                    offset: 0,
                    length: LIMIT + 1,
                },
                Stage::Read,
            )
        } else {
            (
                Job::Stat {
                    path: path.clone(),
                    follow: false,
                },
                Stage::Metadata(path),
            )
        };
        Self::submit(&self.jobs, io, job, Pending::Text(Text { stage, done }));
    }

    fn write(
        &mut self,
        io: &mut dyn Io,
        path: &Path,
        bytes: Vec<u8>,
        mode: Option<u32>,
        replace: bool,
        done: Done<Metadata>,
    ) {
        write::write(io, path, bytes, mode, replace, deferred(done));
    }

    fn pack(
        &mut self,
        io: &mut dyn Io,
        transfer: &str,
        base: &Path,
        paths: &[PathBuf],
        limit: u64,
        done: Done<Packed>,
    ) {
        pack::pack(&self.packs, io, transfer, base, paths, limit, deferred(done));
    }

    fn pack_drop(&mut self, io: &mut dyn Io, transfer: &str, done: Done<()>) {
        pack::discard(&self.packs, io, transfer, deferred(done));
    }

    fn unpack_open(
        &mut self,
        io: &mut dyn Io,
        transfer: &str,
        target: &Path,
        policy: &str,
        names: &[String],
        done: Done<Transfer>,
    ) {
        unpack::open(&self.unpack, &self.gate, io, transfer, target, policy, names, deferred(done));
    }

    fn unpack_write(&mut self, io: &mut dyn Io, transfer: &str, bytes: Vec<u8>, done: Done<Progress>) {
        unpack::write(&self.unpack, io, transfer, bytes, deferred(done));
    }

    fn unpack_close(&mut self, io: &mut dyn Io, transfer: &str, commit: bool, done: Done<Unpacked>) {
        unpack::close(&self.unpack, io, transfer, commit, deferred(done));
    }

    fn git(&mut self, io: &mut dyn Io, path: &Path, args: &[String], limit: u64, done: Done<Git>) {
        git::git(io, &self.git, &self.repositories, path, args, limit, deferred(done));
    }

    /// The client that opened `transfer` left: its archive or staging folder goes, by the same paths as its own
    /// drop or uncommitted close would take.
    fn release(&mut self, io: &mut dyn Io, transfer: &str, unpack: bool, done: Done<()>) {
        let done = deferred(done);
        if unpack {
            unpack::close(&self.unpack, io, transfer, false, Box::new(move |io, _| done(io, Ok(()))));
        } else {
            pack::discard(&self.packs, io, transfer, Box::new(move |io, _| done(io, Ok(()))));
        }
    }

    fn event(&mut self, io: &mut dyn Io, _ui: &mut dyn Ui, event: Event) {
        let Event::Done { work, result } = event else {
            return;
        };
        let pending = {
            let mut jobs = self.jobs.borrow_mut();
            let Some(index) = jobs.iter().position(|(id, _)| *id == work) else {
                return;
            };
            jobs.swap_remove(index).1
        };
        let pending = match pending {
            Pending::Branch(branch) => {
                branch.event(io, &self.jobs, result);
                return;
            }
            Pending::List(list) => {
                list.event(io, result);
                return;
            }
            Pending::Summary(summary) => {
                summary.event(io, result);
                return;
            }
            pending => pending,
        };
        let output = match result {
            Ok(output) => output,
            Err(value) => {
                pending.fail(io, native(value));
                return;
            }
        };
        let pending = match pending {
            Pending::Branch(_) => unreachable!(),
            Pending::List(_) | Pending::Summary(_) => unreachable!(),
            Pending::Text(text) => text,
            Pending::Read(read) => {
                read.event(io, &self.jobs, output);
                return;
            }
        };
        match (pending.stage, output) {
            (Stage::Metadata(path), Output::Metadata(metadata))
                if metadata.kind == FileKind::File && metadata.size <= LIMIT =>
            {
                Self::submit(
                    &self.jobs,
                    io,
                    Job::Read {
                        path,
                        offset: 0,
                        length: LIMIT + 1,
                    },
                    Pending::Text(Text {
                        stage: Stage::Read,
                        done: pending.done,
                    }),
                );
            }
            (
                Stage::Read,
                Output::Read {
                    before,
                    after,
                    bytes,
                },
            ) => {
                let valid = !self.checked
                    || (before.kind == FileKind::File
                        && before.size <= LIMIT
                        && before == after
                        && bytes.len() as u64 == before.size);
                let text = if valid && bytes.len() as u64 <= LIMIT && !bytes.contains(&0) {
                    String::from_utf8(bytes).map_err(|_| error("unsupported"))
                } else {
                    Err(error("unsupported"))
                };
                (pending.done)(io, text);
            }
            (Stage::Metadata(_), Output::Metadata(_)) => {
                (pending.done)(io, Err(error("unsupported")))
            }
            _ => (pending.done)(io, Err(error("internal"))),
        }
    }
}

impl Default for Files {
    fn default() -> Self {
        Self::new(false)
    }
}

#[cfg(test)]
#[path = "transfer.test.rs"]
mod transfer_tests;
