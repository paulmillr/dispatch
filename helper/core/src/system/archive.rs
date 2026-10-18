//! The files plugin's transfer jobs (system.rs execute): packing a selection into a temporary `.tar.zst`
//! (tar.rs inside zstd.rs's level-1 encoder), appending to a staged archive, extracting and moving one in, removing
//! a tree, and sweeping old archives. Each runs whole on a worker; nothing here follows a symlink it did not make
//! the caller name.
//!
//! Extraction writes only below `<staging>/tree/` and then renames top-level entries into the target with
//! no-replace renames on pinned directories. Symbolic links are created after every other entry and no entry may
//! lie beneath one, so while files and folders are created no link exists in the tree to lead a path outside it.
use super::{native, stats, tar, zstd};
use crate::api::{Expected, FileIdentity, Packed, Policy, Staging, Stop, UnpackJob, Unpacked};
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsStr,
    fs::{self, File},
    io::{self, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Component, Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// The name prefix of the staging directory files.unpack.open makes inside a target.
pub(crate) const STAGING: &str = ".dispatch-copy-";
/// Entries one extraction accepts; the names it keeps for checking stay bounded.
const UNPACK_LIMIT: u64 = 1_000_000;
/// "name 2" … "name 10000": past that a conflict fails instead of searching on.
const NUMBERS: u32 = 10_000;
/// Bytes of names (and link targets) one extraction keeps for its late passes over folders and links.
const NAMES_HELD: u64 = 64 << 20;
/// File content one extraction writes at most.
const CONTENT: u64 = 64 << 30;
/// Compressed bytes staged for one incoming transfer. Expanded content and headers have their own bounds; this
/// prevents an endless upload that never reaches an archive end.
const ARCHIVE_LIMIT: u64 = 128 << 30;
/// Free space an extraction leaves on the target's file system.
const RESERVE: u64 = 64 << 20;

/// Refuses before a packed archive consumes the free-space reserve measured when the pack began.
struct Reserved<'a> {
    file: &'a File,
    left: u64,
}

impl Write for Reserved<'_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() as u64 > self.left {
            return Err(limited("not enough free space for the archive"));
        }
        let mut file = self.file;
        let written = file.write(bytes)?;
        self.left -= written as u64;
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut file = self.file;
        file.flush()
    }
}

fn refused(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("archive: {message}"))
}

/// A bound: QuotaExceeded without an OS number, which the plugin reports as `limit`.
fn limited(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::QuotaExceeded, message.to_owned())
}

fn exceeded() -> io::Error {
    limited("more entries than the limit")
}

/// A file that changed while it was packed (its identity or its size): StaleNetworkFileHandle without an OS
/// number, which the plugin reports as `changed`.
fn changed() -> io::Error {
    io::Error::new(io::ErrorKind::StaleNetworkFileHandle, "a file changed while packing")
}

/// A job stopped by its Stop: Interrupted without an OS number.
fn stopped() -> io::Error {
    io::Error::new(io::ErrorKind::Interrupted, "cancelled")
}

/// `path` with `.` and `..` resolved lexically; None for a relative path.
pub(crate) fn normal(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut result = PathBuf::from("/");
    for part in path.components() {
        match part {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            Component::Normal(name) => result.push(name),
            Component::Prefix(_) => return None,
        }
    }
    Some(result)
}

/// A child directory of a pinned directory, opened without following a symlink.
fn directory(parent: &File, name: &OsStr) -> io::Result<File> {
    let file = native::open(parent, name, None)?;
    if !file.metadata()?.is_dir() {
        return Err(io::ErrorKind::NotADirectory.into());
    }
    Ok(file)
}

fn time(seconds: i64, nanos: u32) -> Option<SystemTime> {
    if seconds >= 0 {
        UNIX_EPOCH.checked_add(Duration::new(seconds as u64, nanos))
    } else {
        UNIX_EPOCH.checked_sub(Duration::new(seconds.unsigned_abs(), 0))?.checked_add(Duration::new(0, nanos))
    }
}

/// Job::Pack.
pub(super) fn pack(base: &Path, paths: &[PathBuf], archive: &Path, limit: u64, stop: &Stop) -> io::Result<Packed> {
    let base = normal(base).ok_or(io::ErrorKind::InvalidInput)?;
    let mut selected = Vec::new();
    for path in paths {
        let path = normal(path).ok_or(io::ErrorKind::InvalidInput)?;
        let name = path.strip_prefix(&base).map_err(|_| io::ErrorKind::InvalidInput)?;
        if name.as_os_str().is_empty() {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let name = name.as_os_str().as_bytes().to_vec();
        selected.push((path, name));
    }
    // A path inside another selected one is already in the archive: storing it twice would make the copy fail.
    selected.sort_by(|a, b| a.1.split(|&c| c == b'/').cmp(b.1.split(|&c| c == b'/')));
    let mut kept: Vec<(PathBuf, Vec<u8>)> = Vec::new();
    for (path, name) in selected {
        let inside = kept.last().is_some_and(|(_, last)| {
            name == *last || (name.starts_with(last) && name.get(last.len()) == Some(&b'/'))
        });
        if !inside {
            kept.push((path, name));
        }
    }
    let directory = archive.parent().ok_or(io::ErrorKind::InvalidInput)?;
    let file_name = archive.file_name().ok_or(io::ErrorKind::InvalidInput)?;
    let parent = native::directory(directory, Expected::Any)?;
    let file = native::open(&parent, file_name, Some(0o600))?;
    let result = (|| {
        let own = file.metadata()?;
        let mut packed = Packed {
            archive: archive.to_string_lossy().into_owned(),
            ..Packed::default()
        };
        let room = stats::available(directory)?.saturating_sub(RESERVE);
        let output = Reserved { file: &file, left: room };
        let mut writer = tar::Writer::new(zstd::Encoder::live(output)?);
        let mut stack: Vec<Walked> = kept.into_iter().rev().map(|(path, name)| Walked { holder: None, path, name, kind: UNKNOWN }).collect();
        while let Some(walked) = stack.pop() {
            if stop.is_set() {
                return Err(stopped());
            }
            // A selected path's folder is opened as named (the caller may reach it through a symlink); every entry
            // below comes through the descriptor of the folder it was listed in.
            let holder = match walked.holder {
                Some(holder) => holder,
                None => {
                    let parent = walked.path.parent().ok_or(io::ErrorKind::InvalidInput)?;
                    std::rc::Rc::new(native::directory(parent, Expected::Any)?)
                }
            };
            let leaf = walked.path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
            // The readdir type when the listing gave one, else the path's lstat, whose identity the entry opened
            // through `holder` must then have.
            let (kind, seen) = match walked.kind {
                UNKNOWN => {
                    let m = fs::symlink_metadata(&walked.path)?;
                    let t = m.file_type();
                    let kind = if t.is_dir() { DIRECTORY } else if t.is_file() { REGULAR } else if t.is_symlink() { LINK } else { OTHER };
                    (kind, Some((m.dev(), m.ino())))
                }
                kind => (kind, None),
            };
            let same = |m: &fs::Metadata| seen.is_none_or(|(dev, ino)| m.dev() == dev && m.ino() == ino);
            let header = |m: &fs::Metadata, kind| tar::Header {
                name: walked.name.clone(),
                kind,
                mode: m.mode() & 0o7777,
                uid: m.uid().into(),
                gid: m.gid().into(),
                size: 0,
                modified: (m.mtime(), u32::try_from(m.mtime_nsec()).unwrap_or(0)),
                link: Vec::new(),
            };
            match kind {
                DIRECTORY => {
                    // A folder this account cannot read is skipped and counted: its content could not be sent.
                    let folder = match native::folder(&holder, leaf) {
                        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
                            packed.skipped += 1;
                            continue;
                        }
                        Err(e) if e.raw_os_error().is_some_and(|n| n == native::ELOOP || n == native::ENOTDIR) => {
                            return Err(changed());
                        }
                        folder => folder?,
                    };
                    let m = folder.metadata()?;
                    if !m.is_dir() || !same(&m) {
                        return Err(changed());
                    }
                    // If the immediate children alone do not fit, fail before retaining the whole directory.
                    let remaining = limit.saturating_sub(packed.entries.saturating_add(1));
                    let remaining = usize::try_from(remaining).unwrap_or(usize::MAX);
                    let mut children = match native::entries_bounded(&folder, remaining) {
                        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
                            packed.skipped += 1;
                            continue;
                        }
                        children => children?,
                    };
                    count(&mut packed, limit)?;
                    packed.folders += 1;
                    writer.entry(&header(&m, tar::Kind::Directory))?;
                    children.sort();
                    let folder = std::rc::Rc::new(folder);
                    for (child, kind) in children.into_iter().rev() {
                        let name = [walked.name.as_slice(), b"/", child.as_bytes()].concat();
                        let path = walked.path.join(&child);
                        stack.push(Walked { holder: Some(folder.clone()), path, name, kind });
                    }
                }
                REGULAR => {
                    let mut source = match native::open(&holder, leaf, None) {
                        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
                            packed.skipped += 1;
                            continue;
                        }
                        // ELOOP: a link now where a file was listed.
                        Err(e) if e.raw_os_error() == Some(native::ELOOP) => return Err(changed()),
                        source => source?,
                    };
                    let m = source.metadata()?;
                    if !m.is_file() || !same(&m) {
                        return Err(changed());
                    }
                    // The archive itself when the selection holds the temporary directory.
                    if m.dev() == own.dev() && m.ino() == own.ino() {
                        continue;
                    }
                    count(&mut packed, limit)?;
                    let mut header = header(&m, tar::Kind::File);
                    header.size = m.len();
                    let bytes = packed.bytes.checked_add(header.size).filter(|&bytes| bytes <= CONTENT);
                    let bytes = bytes.ok_or_else(|| limited("more than 64 GiB of content"))?;
                    packed.files += 1;
                    packed.bytes = bytes;
                    writer.entry(&header)?;
                    // Check cancellation within one large file instead of only between entries.
                    let mut left = header.size;
                    let mut buffer = [0u8; 1 << 17];
                    while left > 0 {
                        if stop.is_set() {
                            return Err(stopped());
                        }
                        let length = buffer.len().min(usize::try_from(left).unwrap_or(usize::MAX));
                        let read = source.read(&mut buffer[..length])?;
                        if read == 0 {
                            return Err(changed());
                        }
                        writer.write_all(&buffer[..read])?;
                        left -= read as u64;
                    }
                    let after = source.metadata()?;
                    if after.dev() != m.dev()
                        || after.ino() != m.ino()
                        || after.len() != m.len()
                        || after.mtime() != m.mtime()
                        || after.mtime_nsec() != m.mtime_nsec()
                        || after.ctime() != m.ctime()
                        || after.ctime_nsec() != m.ctime_nsec()
                    {
                        return Err(changed());
                    }
                }
                LINK => {
                    // EINVAL: no longer a link. Not the client's doing, so not invalid_request.
                    let target = native::read_link(&holder, leaf).map_err(|e| {
                        if e.raw_os_error() == Some(22) { io::Error::other("a symbolic link changed while packing") } else { e }
                    })?;
                    // A link's own mode, owner and time, which nothing restores, come from its path.
                    let m = fs::symlink_metadata(&walked.path)?;
                    if !m.file_type().is_symlink() || !same(&m) {
                        return Err(changed());
                    }
                    count(&mut packed, limit)?;
                    let mut header = header(&m, tar::Kind::Symlink);
                    header.link = target;
                    writer.entry(&header)?;
                }
                _ => packed.skipped += 1,
            }
        }
        writer.finish()?.finish()?;
        file.sync_all()?;
        packed.size = file.metadata()?.len();
        Ok(packed)
    })();
    if result.is_err() {
        let _ = native::remove(&parent, file_name);
    }
    result
}

// readdir's d_type values (the same on macOS and Linux); OTHER stands for every kind a pack leaves out.
const UNKNOWN: u8 = 0;
const DIRECTORY: u8 = 4;
const REGULAR: u8 = 8;
const LINK: u8 = 10;
const OTHER: u8 = 1;

/// One entry the pack walk will store: its folder's descriptor (None for a selected path, whose folder is opened by
/// path), its path for messages and a link's metadata, its archive name and its readdir type.
struct Walked {
    holder: Option<std::rc::Rc<File>>,
    path: PathBuf,
    name: Vec<u8>,
    kind: u8,
}

/// One more stored entry, within `limit`.
fn count(packed: &mut Packed, limit: u64) -> io::Result<()> {
    packed.entries += 1;
    if packed.entries > limit {
        return Err(exceeded());
    }
    Ok(())
}

/// Job::Append.
pub(super) fn append(staging: &Staging, bytes: &[u8]) -> io::Result<u64> {
    let (_, folder, _) = pinned(staging)?;
    let folder = folder.ok_or(io::ErrorKind::NotFound)?;
    let mut file = native::append(&folder, OsStr::new(ARCHIVE))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    if metadata.len().checked_add(bytes.len() as u64).is_none_or(|total| total > ARCHIVE_LIMIT) {
        return Err(limited("more than 128 GiB of archive data"));
    }
    if bytes.len() as u64 > stats::available(&staging.target)?.saturating_sub(RESERVE) {
        return Err(limited("not enough free space for the archive"));
    }
    file.write_all(bytes)?;
    Ok(file.metadata()?.len())
}

/// Job::RemoveTree: the entry at `path`, through its pinned parent (see remove_at).
pub(super) fn remove_tree(path: &Path) -> io::Result<()> {
    let parent = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
    let name = path.file_name().ok_or(io::ErrorKind::InvalidInput)?;
    remove_at(&native::directory(parent, Expected::Any)?, name)
}

/// `name` in the pinned `parent`, with everything in it when it is a folder: each folder is opened without
/// following a link, listed through its descriptor and emptied through it, so no path swapped meanwhile leads the
/// removal elsewhere. A folder that forbids its owner (copied in read-only) is opened up first: only the owner's
/// bits change, and only on what is being removed.
fn remove_at(parent: &File, name: &OsStr) -> io::Result<()> {
    match native::remove(parent, name) {
        Err(e) if e.kind() == io::ErrorKind::DirectoryNotEmpty => {}
        done => return done,
    }
    // Each level: an open folder, the names in it still to remove, and its own name in the level above.
    let mut levels = vec![opened(parent, name)?];
    loop {
        let Some(depth) = levels.len().checked_sub(1) else { return Ok(()) };
        match levels[depth].1.pop() {
            Some(child) => match native::remove(&levels[depth].0, &child) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) if e.kind() == io::ErrorKind::DirectoryNotEmpty => {
                    let (folder, names, _) = opened(&levels[depth].0, &child)?;
                    levels.push((folder, names, child));
                }
                Err(e) => return Err(e),
            },
            None => {
                let Some((folder, _, own)) = levels.pop() else { return Ok(()) };
                drop(folder);
                let holder = levels.last().map_or(parent, |level| &level.0);
                native::remove(holder, &own)?;
            }
        }
    }
}

/// A folder about to be emptied: open, its owner's bits opened up, and its names.
fn opened(parent: &File, name: &OsStr) -> io::Result<(File, Vec<std::ffi::OsString>, std::ffi::OsString)> {
    let folder = match native::folder(parent, name) {
        // Not even readable by its owner: its bits change first, never through a link (fchmodat refuses one).
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            native::chmod(parent, name, 0o700)?;
            native::folder(parent, name)?
        }
        folder => folder?,
    };
    let mode = folder.metadata()?.mode() & 0o7777;
    if mode & 0o700 != 0o700 {
        folder.set_permissions(fs::Permissions::from_mode(mode | 0o700))?;
    }
    let names = native::entries(&folder)?.into_iter().map(|(name, _)| name).collect();
    Ok((folder, names, name.to_owned()))
}

/// Job::Stage: see api.rs. Made through the pinned target, so the identity answered is the folder's that holds the
/// archive.
pub(super) fn stage(path: &Path, expected: FileIdentity) -> io::Result<fs::Metadata> {
    let parent = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
    let name = path.file_name().filter(|name| name.as_bytes().starts_with(STAGING.as_bytes())).ok_or(io::ErrorKind::InvalidInput)?;
    let target = native::directory(parent, Expected::Any)?;
    let current = target.metadata()?;
    if current.dev() != expected.device || current.ino() != expected.inode {
        return Err(io::Error::from_raw_os_error(native::ESTALE));
    }
    // Never recursive and never an existing folder: whatever a later removal takes, this job made.
    native::mkdir(&target, name, 0o700)?;
    let made = (|| {
        let folder = native::folder(&target, name)?;
        native::open(&folder, OsStr::new(ARCHIVE), Some(0o600))?;
        folder.metadata()
    })();
    if made.is_err() {
        let _ = remove_at(&target, name);
    }
    made
}

/// The staging folder's archive inside it.
pub(crate) const ARCHIVE: &str = "archive.tar.zst";

/// `staging`'s target and folder, opened and checked to be the ones Job::Stage made; None for the folder when
/// it is gone. A target renamed or replaced since is reported with the folder's path as it was.
fn pinned(staging: &Staging) -> io::Result<(File, Option<File>, &OsStr)> {
    let name = staging
        .path
        .file_name()
        .filter(|name| name.as_bytes().starts_with(STAGING.as_bytes()) && name.len() > STAGING.len())
        .ok_or(io::ErrorKind::InvalidInput)?;
    if staging.path.parent() != Some(staging.target.as_path()) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let moved = || {
        io::Error::other(format!(
            "{} moved or was replaced during the copy; its staging folder {} was left in it",
            staging.target.display(),
            name.to_string_lossy()
        ))
    };
    let same = |m: &fs::Metadata, at: FileIdentity| m.dev() == at.device && m.ino() == at.inode;
    let target = match native::directory(&staging.target, Expected::Any) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(moved()),
        target => target?,
    };
    if !same(&target.metadata()?, staging.parent) {
        return Err(moved());
    }
    let folder = match native::folder(&target, name) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok((target, None, name)),
        folder => folder?,
    };
    if !same(&folder.metadata()?, staging.folder) {
        return Err(io::Error::from_raw_os_error(native::ESTALE));
    }
    Ok((target, Some(folder), name))
}

/// Job::Discard.
pub(super) fn discard(staging: &Staging) -> io::Result<()> {
    let (target, folder, name) = pinned(staging)?;
    if folder.is_none() {
        return Ok(());
    }
    drop(folder);
    match remove_at(&target, name) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        removed => removed,
    }
}

/// Job::Sweep: never follows a link, never touches another account's file.
pub(super) fn sweep(prefix: &str, age: Duration) -> io::Result<(PathBuf, u64)> {
    let directory = std::env::temp_dir();
    let parent = native::directory(&directory, Expected::Any)?;
    // SAFETY: getuid only reads the calling process's account.
    let uid = unsafe { native::getuid() };
    let before = SystemTime::now().checked_sub(age);
    let mut removed = 0;
    for entry in fs::read_dir(&directory)?.flatten() {
        let name = entry.file_name();
        if !name.as_bytes().starts_with(prefix.as_bytes()) {
            continue;
        }
        let Ok(m) = entry.metadata() else { continue };
        let old = before.is_some_and(|before| m.modified().is_ok_and(|at| at < before));
        if m.is_file() && m.uid() == uid && old && native::remove(&parent, &name).is_ok() {
            removed += 1;
        }
    }
    Ok((directory, removed))
}

/// An archive entry's name as its relative components: never absolute, empty, `..`, NUL or a staging name.
fn components(name: &[u8]) -> io::Result<Vec<&[u8]>> {
    if name.first() == Some(&b'/') {
        return Err(refused("an absolute name"));
    }
    if name.contains(&0) {
        return Err(refused("a NUL in a name"));
    }
    let mut parts = Vec::new();
    for part in name.split(|&b| b == b'/') {
        match part {
            b"." => {}
            b"" => return Err(refused("an empty name or component")),
            b".." => return Err(refused("a name leaving its folder")),
            part => parts.push(part),
        }
    }
    match parts.first() {
        None => Err(refused("an empty name")),
        Some(top) if top.starts_with(STAGING.as_bytes()) => Err(refused("a staging folder's name")),
        Some(_) => Ok(parts),
    }
}

/// One extraction into `<staging>/tree/`.
struct Tree {
    root: PathBuf,
    /// Every folder in the tree, named or implied by a deeper entry: its mode and, when named, its mtime.
    directories: BTreeMap<Vec<u8>, (u32, Option<(i64, u32)>)>,
    /// Symbolic links (name, target), made once everything else is.
    links: BTreeMap<Vec<u8>, Vec<u8>>,
    tops: BTreeSet<Vec<u8>>,
    /// The top-level names the client packed: any other top is refused, so an archive cannot add or swap in an
    /// entry (a `.zprofile` beside the folder being copied) the user never chose.
    names: BTreeSet<Vec<u8>>,
    counts: Unpacked,
    buffer: Vec<u8>,
    /// Bytes of names in `directories` and `links` (NAMES_HELD).
    held: u64,
    /// Content bytes the target's file system can take, less RESERVE, when extraction began.
    room: u64,
    stop: Stop,
}

impl Tree {
    fn path(&self, name: &[u8]) -> PathBuf {
        self.root.join(OsStr::from_bytes(name))
    }

    /// `bytes` more of names kept until the end.
    fn hold(&mut self, bytes: usize) -> io::Result<()> {
        self.held = self.held.saturating_add(bytes as u64);
        if self.held > NAMES_HELD {
            return Err(limited("more than 64 MiB of names"));
        }
        Ok(())
    }

    /// A folder `name` exists (made 0700 when new; its own mode comes last).
    fn folder(&mut self, name: &[u8], mode: u32, modified: Option<(i64, u32)>) -> io::Result<()> {
        if self.links.contains_key(name) {
            return Err(refused("an entry inside or over a symbolic link"));
        }
        if !self.directories.contains_key(name) {
            self.hold(name.len())?;
            match fs::DirBuilder::new().mode(0o700).create(self.path(name)) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    return Err(refused("a folder and a file of the same name"));
                }
                Err(e) => return Err(e),
            }
        }
        let entry = self.directories.entry(name.to_vec()).or_insert((mode, modified));
        if modified.is_some() {
            *entry = (mode, modified);
        }
        Ok(())
    }

    fn entry<R: Read>(&mut self, header: &tar::Header, content: &mut R) -> io::Result<()> {
        if self.stop.is_set() {
            return Err(stopped());
        }
        self.counts.entries += 1;
        if self.counts.entries > UNPACK_LIMIT {
            return Err(exceeded());
        }
        let parts = components(&header.name)?;
        let Some(&top) = parts.first() else {
            return Err(refused("an empty name"));
        };
        if !self.names.contains(top) {
            let top = String::from_utf8_lossy(top);
            return Err(refused(&format!("a top-level entry that was not sent: {top:?}")));
        }
        let Some((last, above)) = parts.split_last() else {
            return Err(refused("an empty name"));
        };
        // Each folder above the entry, its name grown by one component at a time.
        let mut name = Vec::with_capacity(header.name.len());
        for part in above {
            if !name.is_empty() {
                name.push(b'/');
            }
            name.extend_from_slice(part);
            self.folder(&name, 0o777, None)?;
        }
        if !name.is_empty() {
            name.push(b'/');
        }
        name.extend_from_slice(last);
        self.tops.insert(top.to_vec());
        match header.kind {
            tar::Kind::Directory => {
                let modified = Some(header.modified);
                self.folder(&name, header.mode & 0o777, modified)
            }
            tar::Kind::Symlink => {
                if self.directories.contains_key(&name) || self.links.contains_key(&name) {
                    return Err(refused("a symbolic link over another entry"));
                }
                self.hold(name.len() + header.link.len())?;
                self.links.insert(name, header.link.clone());
                Ok(())
            }
            tar::Kind::File => {
                if self.directories.contains_key(&name) || self.links.contains_key(&name) {
                    return Err(refused("a file over another entry"));
                }
                // Before the file exists: a size bomb (sparse or cut) fails here instead of filling the disk.
                let total = self.counts.bytes.checked_add(header.size).filter(|&total| total <= CONTENT);
                let total = total.ok_or_else(|| limited("more than 64 GiB of content"))?;
                if total > self.room {
                    return Err(limited("not enough free space in the target folder"));
                }
                // The kernel applies the umask to the mode; set-id bits are never restored.
                let mut file = File::options()
                    .write(true)
                    .create_new(true)
                    .mode(header.mode & 0o777)
                    .custom_flags(native::O_NOFOLLOW | native::O_CLOEXEC)
                    .open(self.path(&name))
                    .map_err(|e| if e.kind() == io::ErrorKind::AlreadyExists { refused("a duplicate file") } else { e })?;
                let mut left = header.size;
                while left > 0 {
                    if self.stop.is_set() {
                        return Err(stopped());
                    }
                    let length = self.buffer.len().min(usize::try_from(left).unwrap_or(usize::MAX));
                    let n = content.read(&mut self.buffer[..length])?;
                    if n == 0 {
                        return Err(refused("cut inside a file's content"));
                    }
                    file.write_all(&self.buffer[..n])?;
                    left -= n as u64;
                }
                let at = time(header.modified.0, header.modified.1).ok_or_else(|| refused("an mtime out of range"))?;
                file.set_times(fs::FileTimes::new().set_modified(at))?;
                self.counts.bytes += header.size;
                Ok(())
            }
        }
    }
}

/// "name 2": before a file's extension (not a leading dot's), after a folder's whole name.
fn numbered(name: &[u8], number: u32, folder: bool) -> Vec<u8> {
    let at = name.iter().rposition(|&b| b == b'.').filter(|&at| !folder && at > 0 && at + 1 < name.len());
    let (stem, extension) = name.split_at(at.unwrap_or(name.len()));
    [stem, format!(" {number}").as_bytes(), extension].concat()
}

/// Job::Unpack; see the module comment. The staging directory is removed whatever happens.
pub(super) fn unpack(job: &UnpackJob) -> io::Result<Unpacked> {
    let (archive, staging, policy) = (job.archive.as_path(), job.staging.path.as_path(), job.policy);
    if !archive.starts_with(staging) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    // Nothing is touched, not even removed, unless the target and its staging folder are still the ones opened.
    let (target_dir, staging_dir, staged) = pinned(&job.staging)?;
    let staging_dir = staging_dir.ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "the staging folder is gone"))?;
    let mut stranded = false;
    let result = (|| {
        let root = staging.join("tree");
        fs::DirBuilder::new().mode(0o777).create(&root)?;
        // The account's umask, as the kernel applied it to the folder just made: folder modes are set after
        // their content, so they cannot come from mkdir.
        let umask = !fs::symlink_metadata(&root)?.mode() & 0o777;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        let mut tree = Tree {
            root,
            directories: BTreeMap::new(),
            links: BTreeMap::new(),
            tops: BTreeSet::new(),
            names: job.names.clone(),
            counts: Unpacked::default(),
            buffer: vec![0; 1 << 17],
            held: 0,
            room: stats::available(staging)?.saturating_sub(RESERVE),
            stop: job.stop.clone(),
        };
        let input = File::options()
            .read(true)
            .custom_flags(native::O_NOFOLLOW | native::O_NONBLOCK | native::O_CLOEXEC)
            .open(archive)?;
        // Content and headers (each at most a pax header and its block) of the most entries one extraction takes.
        let expanded = CONTENT.saturating_add(UNPACK_LIMIT.saturating_mul(66 << 10));
        let expanded = usize::try_from(expanded).unwrap_or(usize::MAX);
        let mut reader = tar::Reader::new(zstd::Decoder::archive(io::BufReader::new(input), expanded)?);
        while let Some(header) = reader.next()? {
            tree.entry(&header, &mut reader)?;
        }
        // The rest of the stream: zstd checks its content checksum at its end, so a damaged archive fails here,
        // still before anything moved. Only zero padding may follow the end blocks.
        let mut decoder = reader.into_inner();
        let mut rest = [0u8; 8192];
        loop {
            let n = decoder.read(&mut rest)?;
            if n == 0 {
                break;
            }
            if rest[..n].iter().any(|&b| b != 0) {
                return Err(refused("data after the end of the archive"));
            }
        }
        if tree.stop.is_set() {
            return Err(stopped());
        }
        for (name, link) in std::mem::take(&mut tree.links) {
            std::os::unix::fs::symlink(OsStr::from_bytes(&link), tree.path(&name))
                .map_err(|e| if e.kind() == io::ErrorKind::AlreadyExists { refused("a symbolic link over another entry") } else { e })?;
        }
        let tree_dir = directory(&staging_dir, OsStr::new("tree"))?;
        let (mut moved, mut settled) = (BTreeMap::new(), Unpacked::default());
        let outcome = place(
            &tree,
            &tree_dir,
            &staging_dir,
            &target_dir,
            policy,
            &job.replacements,
            &mut moved,
            &mut settled,
            &mut stranded,
        );
        // Folder modes and times last, deepest first: a read-only folder could not have been filled or moved.
        let mut folders: Vec<_> = tree.directories.iter().collect();
        folders.sort_by_key(|(name, _)| std::cmp::Reverse(name.iter().filter(|&&b| b == b'/').count()));
        for (name, &(mode, modified)) in folders {
            let mut parts = name.split(|&b| b == b'/');
            let Some(top) = parts.next() else { continue };
            let Some(placed) = moved.get(top) else { continue };
            // Best effort: a folder left 0700 or with a new mtime is safe, and its content is in place.
            let _ = (|| {
                let mut folder = directory(&target_dir, OsStr::from_bytes(placed))?;
                for part in parts {
                    folder = directory(&folder, OsStr::from_bytes(part))?;
                }
                if let Some(at) = modified.and_then(|(seconds, nanos)| time(seconds, nanos)) {
                    folder.set_times(fs::FileTimes::new().set_modified(at))?;
                }
                folder.set_permissions(fs::Permissions::from_mode(mode & 0o777 & !umask))
            })();
        }
        outcome.map(|()| Unpacked {
            replaced: settled.replaced,
            kept: settled.kept,
            skipped: settled.skipped,
            ..tree.counts
        })
    })();
    // Whatever was skipped, set aside by a replace, or left by a failure goes with the staging directory, unless
    // it holds an original a failed replace could not put back.
    if stranded {
        return result.map_err(|e| io::Error::other(format!("{e} {}", staging.join("old").display())));
    }
    drop(staging_dir);
    let _ = remove_at(&target_dir, staged);
    result
}

#[cfg(test)]
thread_local! {
    /// Runs right after an existing entry steps aside for a replace, in the job's thread: a test takes its name
    /// so that the moves after it fail.
    pub(super) static ASIDE: std::cell::RefCell<Option<Box<dyn FnMut(&OsStr)>>> = const { std::cell::RefCell::new(None) };
}

fn folder_of(tree: &Tree, top: &[u8]) -> bool {
    tree.directories.contains_key(top)
}

/// A replace whose new entry could not take `top`'s name: the original, set aside in `old`, goes back, or when
/// its name is taken meanwhile to "name 2", "name 3"… beside it. Some(error) says where it is when not back;
/// None when it is back. Left in `old` (`stranded`), the staging folder must stay.
fn restore(old: &File, target: &File, top: &[u8], folder: bool, stranded: &mut bool) -> Option<io::Error> {
    let name = OsStr::from_bytes(top);
    if native::rename(old, name, target, name).is_ok() {
        return None;
    }
    let shown = String::from_utf8_lossy(top);
    for number in 2..=NUMBERS {
        let candidate = numbered(top, number, folder);
        match native::rename(old, name, target, OsStr::from_bytes(&candidate)) {
            Ok(()) => {
                let placed = String::from_utf8_lossy(&candidate);
                return Some(io::Error::other(format!(
                    "the copy could not take the place of {shown:?}, whose name was taken meanwhile; the original is now {placed:?}"
                )));
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(_) => break,
        }
    }
    *stranded = true;
    Some(io::Error::other(format!(
        "the copy could not take the place of {shown:?}, and the original could not go back; it stays in"
    )))
}

/// The move phase: each top-level entry into `target`, conflicts settled by `policy` and counted in `counts`.
/// `moved` maps each original name to its name in target.
#[allow(clippy::too_many_arguments)]
fn place(
    tree: &Tree,
    from: &File,
    staging: &File,
    target: &File,
    policy: Policy,
    replacements: &BTreeMap<Vec<u8>, FileIdentity>,
    moved: &mut BTreeMap<Vec<u8>, Vec<u8>>,
    counts: &mut Unpacked,
    stranded: &mut bool,
) -> io::Result<()> {
    let mut aside: Option<File> = None;
    for top in &tree.tops {
        let name = OsStr::from_bytes(top);
        match native::rename(from, name, target, name) {
            Ok(()) => {
                moved.insert(top.clone(), top.clone());
                continue;
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        match policy {
            Policy::Skip => counts.skipped += 1,
            Policy::Keep => {
                let folder = tree.directories.contains_key(top);
                let mut placed = None;
                for number in 2..=NUMBERS {
                    let candidate = numbered(top, number, folder);
                    match native::rename(from, name, target, OsStr::from_bytes(&candidate)) {
                        Ok(()) => {
                            placed = Some(candidate);
                            break;
                        }
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                        Err(e) => return Err(e),
                    }
                }
                let placed = placed.ok_or_else(|| {
                    limited(&format!("no free name for {:?} up to number {NUMBERS}", String::from_utf8_lossy(top)))
                })?;
                counts.kept += 1;
                moved.insert(top.clone(), placed);
            }
            Policy::Replace => {
                // A conflict may have existed when the client listed the directory or appeared later. Only the
                // former carries consent to replace, bound to that exact directory entry. Moving it aside before
                // checking closes the check/rename race; a mismatch is restored without exposing the incoming item.
                let expected = replacements
                    .get(top)
                    .copied()
                    .ok_or_else(|| io::Error::from_raw_os_error(native::ESTALE))?;
                if aside.is_none() {
                    native::mkdir(staging, OsStr::new("old"), 0o700)?;
                    aside = Some(directory(staging, OsStr::new("old"))?);
                }
                let Some(old) = &aside else { continue };
                // The existing entry steps aside first and comes back if the new one cannot take its name, so a
                // failure never loses both; once replaced it is removed with the staging directory.
                native::rename(target, name, old, name)?;
                let mismatch = match native::identity(old, name) {
                    Ok(current) if current == expected => None,
                    Ok(_) => Some(io::Error::from_raw_os_error(native::ESTALE)),
                    Err(error) => Some(error),
                };
                if let Some(error) = mismatch {
                    return Err(restore(old, target, top, folder_of(tree, top), stranded).unwrap_or(error));
                }
                #[cfg(test)]
                ASIDE.with_borrow_mut(|hook| hook.as_mut().map(|hook| hook(name)));
                if let Err(e) = native::rename(from, name, target, name) {
                    return Err(restore(old, target, top, folder_of(tree, top), stranded).unwrap_or(e));
                }
                counts.replaced += 1;
                moved.insert(top.clone(), top.clone());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "archive.test.rs"]
mod tests;
