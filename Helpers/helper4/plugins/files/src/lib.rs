//! Complete source text; filesystem work runs through the shared IO interface.

use dispatch_helper4_core::api::{
    Chunk, Done, Error, Event, FileKind, Io, Job, Metadata, Output, Plugin, Read, Ui, Work,
    deferred,
};
use std::{
    cell::RefCell,
    io,
    path::{Path, PathBuf},
    rc::Rc,
};

mod branch;
mod read;

const LIMIT: u64 = 2_000_000;
type Jobs = Rc<RefCell<Vec<(Work, Pending)>>>;

pub struct Files {
    checked: bool,
    jobs: Jobs,
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
}

impl Pending {
    fn fail(self, io: &mut dyn Io, error: Error) {
        match self {
            Self::Text(text) => (text.done)(io, Err(error)),
            Self::Read(read) => (read.done)(io, Err(error)),
            Self::Branch(_) => unreachable!("branch completion handles unavailable metadata"),
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
        Self {
            checked,
            jobs: Rc::default(),
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
