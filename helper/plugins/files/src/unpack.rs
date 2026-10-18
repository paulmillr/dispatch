//! files.unpack.open, .write and .close: an incoming archive is staged in `<target>/.dispatch-copy-<random>/`
//! (0700) as `archive.tar.zst`, then one worker job (Job::Unpack) extracts it beside the target and moves it in,
//! or the staging directory is removed. One transfer is open per helper; the helper closes it uncommitted when
//! the client that opened it disconnects.
use super::*;
use dispatch_helper_core::api::{FileIdentity, Policy, Progress, Replacement, Staging, Stop, Transfer, UnpackJob, Unpacked};
use std::collections::{BTreeMap, BTreeSet};
use transfer::{Gate, failure, job, plain};

const ARCHIVE: &str = "archive.tar.zst";
const STAGING: &str = ".dispatch-copy-";
/// Top-level names one transfer may carry; a selection is far smaller.
const NAMES: usize = 100_000;

pub(super) struct Open {
    transfer: String,
    /// The staging folder once Job::Stage made it, with its and its target's identity: the transfer is ready.
    staging: Option<Staging>,
    policy: Policy,
    /// The top-level names the client packed; the archive may hold no others.
    names: BTreeSet<Vec<u8>>,
    replacements: BTreeMap<Vec<u8>, FileIdentity>,
    /// Archive bytes staged so far.
    staged: u64,
    /// A job for this transfer is running; writes wait for none, a close waits for it.
    working: bool,
    /// The running job is the commit, holding the long-job gate and exclusive file-publication access.
    committing: bool,
    closing: Option<(bool, Done<Unpacked>)>,
    /// Stops a running commit's extraction when an uncommitted close comes (its client leaving).
    stop: Stop,
    gate: Gate,
    access: transfer::SharedAccess,
}

pub(super) type Shared = Rc<RefCell<Option<Open>>>;

#[allow(clippy::too_many_arguments)]
pub(super) fn open(
    shared: &Shared,
    gate: &Gate,
    access: &transfer::SharedAccess,
    io: &mut dyn Io,
    transfer: &str,
    target: &Path,
    policy: &str,
    names: &[String],
    expected_parent: FileIdentity,
    replacements: &[Replacement],
    done: Done<Transfer>,
) {
    let policy = match policy {
        "replace" => Policy::Replace,
        "keep" => Policy::Keep,
        "skip" => Policy::Skip,
        _ => return done(io, Err(error("invalid_request"))),
    };
    // Each a single entry name, as the client's selection holds them: never a path, `.`, `..` or a staging name.
    let single = |name: &String| {
        !name.is_empty()
            && name != "."
            && name != ".."
            && !name.contains(['/', '\0'])
            && !name.starts_with(STAGING)
    };
    if names.is_empty() || names.len() > NAMES || !names.iter().all(single) {
        return done(io, Err(error("invalid_request")));
    }
    let names: BTreeSet<_> = names.iter().map(|name| name.as_bytes().to_vec()).collect();
    let replacement_count = replacements.len();
    let replacements: BTreeMap<_, _> = replacements
        .iter()
        .map(|replacement| (replacement.name.as_bytes().to_vec(), replacement.identity))
        .collect();
    let guarded = replacements.len() == replacement_count
        && replacements.keys().all(|name| names.contains(name));
    if !guarded
        || (policy != Policy::Replace && !replacements.is_empty())
    {
        return done(io, Err(error("invalid_request")));
    }
    if transfer.is_empty() || !plain(target) {
        return done(io, Err(error("invalid_request")));
    }
    if shared.borrow().is_some() {
        return done(io, Err(error("busy")));
    }
    let staging = match transfer::random(io) {
        Ok(name) => target.join(format!("{STAGING}{name}")),
        Err(value) => return done(io, Err(native(value))),
    };
    *shared.borrow_mut() = Some(Open {
        transfer: transfer.to_owned(),
        staging: None,
        policy,
        names,
        replacements,
        staged: 0,
        working: true,
        committing: false,
        closing: None,
        stop: Stop::default(),
        gate: gate.clone(),
        access: access.clone(),
    });
    let (shared, transfer, target) = (shared.clone(), transfer.to_owned(), target.to_owned());
    let stat = Job::Stat {
        path: target.clone(),
        follow: true,
    };
    job(io, stat, move |io, result| {
        let parent = match result {
            Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::Directory
                && metadata.device == expected_parent.device && metadata.inode == expected_parent.inode => identity(&metadata),
            Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::Directory => {
                return abandon(&shared, io, done, error("changed"));
            }
            Ok(Output::Metadata(_)) => return abandon(&shared, io, done, error("not_directory")),
            Ok(_) => return abandon(&shared, io, done, error("internal")),
            Err(value) => return abandon(&shared, io, done, native(value)),
        };
        // One job makes the folder and its archive, or nothing: a folder that exists already is never taken.
        job(io, Job::Stage(staging.clone(), expected_parent), move |io, result| {
            let folder = match result {
                Ok(Output::Metadata(metadata)) => identity(&metadata),
                Ok(_) => return abandon(&shared, io, done, error("internal")),
                Err(value) => return abandon(&shared, io, done, failure(value)),
            };
            if let Some(open) = shared.borrow_mut().as_mut() {
                open.staging = Some(Staging { path: staging.clone(), target, folder, parent });
                open.working = false;
            }
            let staging = staging.to_string_lossy().into_owned();
            done(io, Ok(Transfer { transfer, staging }));
            resume(&shared, io);
        });
    });
}

fn identity(metadata: &Metadata) -> FileIdentity {
    FileIdentity {
        device: metadata.device,
        inode: metadata.inode,
    }
}

/// An open that failed: the transfer is gone (Job::Stage left nothing behind), and a close the client already
/// sent finds nothing left to do.
fn abandon(shared: &Shared, io: &mut dyn Io, done: Done<Transfer>, error: Error) {
    let closing = shared.borrow_mut().take().and_then(|open| open.closing);
    done(io, Err(error));
    if let Some((_, close)) = closing {
        close(io, Ok(Unpacked::default()));
    }
}

pub(super) fn write(shared: &Shared, io: &mut dyn Io, transfer: &str, bytes: Vec<u8>, done: Done<Progress>) {
    if bytes.len() > write::LIMIT {
        return done(io, Err(error("limit")));
    }
    let path = {
        let mut open = shared.borrow_mut();
        let Some(open) = open.as_mut().filter(|open| open.transfer == transfer) else {
            return done(io, Err(error("invalid_request")));
        };
        // Appends in flight at once could land in either order.
        let Some(staging) = open.staging.as_ref().filter(|_| !open.working && open.closing.is_none()) else {
            return done(io, Err(error("busy")));
        };
        if bytes.is_empty() {
            return done(io, Ok(Progress { bytes: open.staged }));
        }
        let staging = staging.clone();
        open.working = true;
        staging
    };
    let shared = shared.clone();
    let append = Job::Append(path, bytes);
    job(io, append, move |io, result| {
        let result = match result {
            Ok(Output::Appended(total)) => Ok(Progress { bytes: total }),
            Ok(_) => Err(error("internal")),
            Err(value) => Err(failure(value)),
        };
        if let Some(open) = shared.borrow_mut().as_mut() {
            open.working = false;
            if let Ok(progress) = &result {
                open.staged = progress.bytes;
            }
        }
        done(io, result);
        resume(&shared, io);
    });
}

pub(super) fn close(shared: &Shared, io: &mut dyn Io, transfer: &str, commit: bool, done: Done<Unpacked>) {
    {
        let mut open = shared.borrow_mut();
        let Some(open) = open.as_mut().filter(|open| open.transfer == transfer) else {
            return done(io, Err(error("invalid_request")));
        };
        if open.closing.is_some() {
            return done(io, Err(error("busy")));
        }
        // After the running open or append: a close (a disconnecting client's too) is never refused for it. One
        // without commit during the commit stops its extraction, so nothing moves.
        if open.working {
            if open.committing && !commit {
                open.stop.set();
            }
            open.closing = Some((commit, done));
            return;
        }
    }
    finish(shared, io, commit, done);
}

/// A close the running job held back.
fn resume(shared: &Shared, io: &mut dyn Io) {
    let closing = match shared.borrow_mut().as_mut() {
        Some(open) if !open.working => open.closing.take(),
        _ => None,
    };
    if let Some((commit, done)) = closing {
        finish(shared, io, commit, done);
    }
}

fn finish(shared: &Shared, io: &mut dyn Io, commit: bool, done: Done<Unpacked>) {
    let closing = {
        let mut open = shared.borrow_mut();
        let Some(open) = open.as_mut() else {
            return done(io, Ok(Unpacked::default()));
        };
        let Some(staging) = open.staging.clone() else {
            return done(io, Err(error("internal")));
        };
        if commit && (open.gate.get() || !open.access.begin_write()) {
            // A pack, Git read or file write is active: the transfer stays open for a later commit.
            None
        } else if commit {
            open.gate.set(true);
            (open.working, open.committing) = (true, true);
            Some(Job::Unpack(UnpackJob {
                archive: staging.path.join(ARCHIVE),
                staging,
                policy: open.policy,
                names: open.names.clone(),
                replacements: open.replacements.clone(),
                stop: open.stop.clone(),
            }))
        } else {
            open.working = true;
            Some(Job::Discard(staging))
        }
    };
    let Some(closing) = closing else {
        return done(io, Err(error("busy")));
    };
    let shared = shared.clone();
    job(io, closing, move |io, result| {
        let open = shared.borrow_mut().take();
        let stopped = open.as_ref().is_some_and(|open| open.stop.is_set());
        if let Some(open) = &open
            && open.committing
        {
            open.gate.set(false);
            open.access.end_write();
        }
        // A close that arrived meanwhile (its client leaving) finds the transfer already ended.
        if let Some((_, close)) = open.and_then(|open| open.closing) {
            close(io, Ok(Unpacked::default()));
        }
        let result = match result {
            Ok(Output::Unpacked(unpacked)) => Ok(unpacked),
            Ok(Output::Removed) => Ok(Unpacked::default()),
            Err(value) if !commit && value.kind() == io::ErrorKind::NotFound => Ok(Unpacked::default()),
            Err(value) if stopped && value.raw_os_error().is_none() && value.kind() == io::ErrorKind::Interrupted => {
                Err(error("cancelled"))
            }
            Ok(_) => Err(error("internal")),
            Err(value) => Err(failure(value)),
        };
        done(io, result);
    });
}
