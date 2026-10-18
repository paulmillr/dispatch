//! files.pack and files.pack.drop: a selection packed by one worker job (Job::Pack) into
//! `<temporary directory>/dispatch-pack-<random>.tar.zst`, which the app then reads with files.read and drops.
use super::*;
use dispatch_helper_core::api::{Expected, PackJob, Packed, Stop};
use std::{collections::HashMap, time::Duration};
use transfer::{Gate, failure, job, normal};

/// Entries one pack holds when the request names no limit.
const ENTRIES: u64 = 250_000;
const PREFIX: &str = "dispatch-pack-";
/// Archives this old were left by a helper that ended before their drop.
const AGE: Duration = Duration::from_secs(24 * 60 * 60);

pub(super) struct Packs {
    /// The system temporary directory, from the first pack's sweep (never looked at during startup: every
    /// recording would change).
    temporary: Option<PathBuf>,
    packs: HashMap<String, State>,
    gate: Gate,
}

impl Packs {
    pub(super) fn new(gate: Gate) -> Self {
        Self {
            temporary: None,
            packs: HashMap::new(),
            gate,
        }
    }
}

struct State {
    /// None while the pack runs.
    archive: Option<PathBuf>,
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
    done: Done<Packed>,
}

pub(super) fn pack(
    packs: &Shared,
    io: &mut dyn Io,
    transfer: &str,
    base: &Path,
    paths: &[PathBuf],
    limit: u64,
    done: Done<Packed>,
) {
    let Some(base) = normal(base).filter(|_| !transfer.is_empty() && !paths.is_empty()) else {
        return done(io, Err(error("invalid_request")));
    };
    let Some(paths) = paths
        .iter()
        .map(|path| normal(path).filter(|path| path.starts_with(&base) && *path != base))
        .collect::<Option<Vec<_>>>()
    else {
        return done(io, Err(error("invalid_request")));
    };
    {
        let mut packs = packs.borrow_mut();
        if packs.gate.get() {
            return done(io, Err(error("busy")));
        }
        if packs.packs.contains_key(transfer) {
            return done(io, Err(error("invalid_request")));
        }
        packs.gate.set(true);
        packs.packs.insert(
            transfer.to_owned(),
            State {
                archive: None,
                dropped: false,
                stop: Stop::default(),
            },
        );
    }
    let run = Run {
        packs: packs.clone(),
        transfer: transfer.to_owned(),
        base,
        paths,
        limit: if limit == 0 { ENTRIES } else { limit },
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
                    true
                }
                _ => {
                    packs.packs.remove(&self.transfer);
                    false
                }
            }
        };
        if kept {
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

/// files.pack.drop: an unknown transfer is already gone.
pub(super) fn discard(packs: &Shared, io: &mut dyn Io, transfer: &str, done: Done<()>) {
    let archive = {
        let mut packs = packs.borrow_mut();
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
