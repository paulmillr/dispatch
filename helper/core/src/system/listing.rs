//! Job::Entries (files.list) and Job::Summary (files.summary) on a worker, and their capture
//! values (file::encode / file::decode).
use super::*;
use crate::api::{Entry, FolderSummary};
use std::collections::BinaryHeap;
use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;

/// How long one summary may walk. Counted from the walk's start on its worker, not from
/// submission: the bound is there to free the worker (the pool has two). A replay reads the
/// recorded totals, never this clock.
const DEADLINE: Duration = Duration::from_secs(5);

pub(super) fn entries(path: &Path, hidden: bool, limit: u64) -> io::Result<Output> {
    // Names stream into the selection, so only the kept ones are held; a failed read fails
    // the listing (a partial one would claim to be complete).
    let mut failure = None;
    let names = std::fs::read_dir(path)?.map_while(|entry| match entry {
        Ok(entry) => Some(entry.file_name()),
        Err(error) => {
            failure = Some(error);
            None
        }
    });
    let (kept, truncated) = smallest(names, hidden, limit);
    if let Some(error) = failure {
        return Err(error);
    }
    let mut entries = Vec::with_capacity(kept.len());
    for (name, native) in kept {
        let at = path.join(&native);
        let facts = match std::fs::symlink_metadata(&at) {
            Ok(value) => metadata(value),
            // Removed since readdir: it is not there to show.
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        // A target that cannot be resolved (missing, a loop, no search permission) is dangling.
        let target = (facts.kind == FileKind::Symlink)
            .then(|| {
                std::fs::metadata(&at)
                    .ok()
                    .map(|value| metadata(value).kind)
            })
            .flatten();
        entries.push(Entry {
            name,
            kind: facts.kind,
            // A directory's own size is filesystem bookkeeping (APFS counts entries, ext4
            // blocks), nothing a listing should show.
            size: if facts.kind == FileKind::Directory {
                0
            } else {
                facts.size
            },
            // Clamped to what i64 nanoseconds hold (years 1677 to 2262): one file with a wild mtime must not
            // fail the whole listing's capture, and the live answer is what replay gives back.
            modified_ns: facts.modified_ns.clamp(i64::MIN.into(), i64::MAX.into()),
            target,
            mark: None,
        });
    }
    Ok(Output::Entries(entries, truncated))
}

/// The `limit` smallest names in order, each lossy and native, and whether more were left
/// out; dot-names first dropped unless `hidden`. The kept set does not depend on readdir
/// order. Lossy names order the output; the native bytes break ties between names that only
/// differ where they are not UTF-8.
pub(super) fn smallest(
    names: impl IntoIterator<Item = OsString>,
    hidden: bool,
    limit: u64,
) -> (Vec<(String, OsString)>, bool) {
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    // A max-heap of the kept names: memory stays bounded by `limit` in a huge directory.
    let mut kept: BinaryHeap<(String, OsString)> = BinaryHeap::new();
    let mut count = 0u64;
    for native in names {
        if !hidden && native.as_bytes().first() == Some(&b'.') {
            continue;
        }
        count += 1;
        let candidate = (native.to_string_lossy().into_owned(), native);
        if kept.len() < limit {
            kept.push(candidate);
        } else if kept.peek().is_some_and(|largest| candidate < *largest) {
            kept.pop();
            kept.push(candidate);
        }
    }
    let truncated = count > kept.len() as u64;
    (kept.into_sorted_vec(), truncated)
}

pub(super) fn summary(path: &Path, limit: u64) -> io::Result<Output> {
    walk(path, limit, Instant::now() + DEADLINE).map(Output::Summary)
}

/// Depth-first with an explicit stack (no recursion limit) that holds paths, not open
/// directories, so a deep tree costs no descriptors. Only `path` itself must be readable.
pub(super) fn walk(path: &Path, limit: u64, deadline: Instant) -> io::Result<FolderSummary> {
    let mut totals = FolderSummary::default();
    let mut visited = 0u64;
    let mut folders = Vec::new();
    let mut listing = Some(std::fs::read_dir(path)?);
    loop {
        let Some(entries) = listing.take() else {
            let Some(folder) = folders.pop() else {
                return Ok(totals);
            };
            listing = std::fs::read_dir(folder).ok();
            continue;
        };
        // An entry that fails to read ends this directory, not the walk.
        for entry in entries.map_while(Result::ok) {
            if visited == limit || Instant::now() >= deadline {
                totals.truncated = true;
                return Ok(totals);
            }
            visited += 1;
            // DirEntry's type and metadata never follow a symlink.
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() {
                totals.folders += 1;
                folders.push(entry.path());
            } else {
                totals.files += 1;
                if kind.is_file() {
                    let size = entry.metadata().map_or(0, |value| value.len());
                    totals.bytes = totals.bytes.saturating_add(size);
                }
            }
        }
    }
}

fn named(name: &str) -> io::Result<FileKind> {
    Ok(match name {
        "file" => FileKind::File,
        "directory" => FileKind::Directory,
        "symlink" => FileKind::Symlink,
        "other" => FileKind::Other,
        _ => return Err(file::invalid()),
    })
}

/// Output::Entries as a capture value: one record per entry with Entry's fields.
pub(super) fn encode_entries(entries: &[Entry], truncated: bool) -> io::Result<Data<'_>> {
    let entries = entries
        .iter()
        .map(|entry| {
            Ok(Data::Object(vec![
                ("name", Data::String(&entry.name)),
                ("kind", Data::String(file::kind(entry.kind))),
                ("size", Data::Unsigned(entry.size)),
                (
                    "modified_ns",
                    Data::Signed(i64::try_from(entry.modified_ns).map_err(|_| file::invalid())?),
                ),
                (
                    "target",
                    entry
                        .target
                        .map_or(Data::Null, |kind| Data::String(file::kind(kind))),
                ),
                (
                    "mark",
                    entry.mark.as_deref().map_or(Data::Null, Data::String),
                ),
            ]))
        })
        .collect::<io::Result<_>>()?;
    Ok(Data::Object(vec![
        ("kind", Data::String("entries")),
        ("entries", Data::Array(entries)),
        ("truncated", Data::Bool(truncated)),
    ]))
}

/// A field that is null or text; absent is invalid, as encode always writes it.
fn optional<'a>(value: &Data<'a>, name: &str) -> io::Result<Option<&'a str>> {
    match value.get(name) {
        Some(Data::Null) => Ok(None),
        Some(Data::String(text)) => Ok(Some(*text)),
        _ => Err(file::invalid()),
    }
}

pub(super) fn decode_entries(value: &Data<'_>) -> io::Result<Output> {
    let entries = file::field(value, "entries", Data::array)?
        .map(|entry| {
            Ok(Entry {
                name: file::field(entry, "name", Data::string)?.into(),
                kind: named(file::field(entry, "kind", Data::string)?)?,
                size: file::field(entry, "size", Data::unsigned)?,
                modified_ns: file::field(entry, "modified_ns", Data::signed)?.into(),
                target: optional(entry, "target")?.map(named).transpose()?,
                mark: optional(entry, "mark")?.map(str::to_owned),
            })
        })
        .collect::<io::Result<_>>()?;
    Ok(Output::Entries(
        entries,
        file::field(value, "truncated", Data::boolean)?,
    ))
}

pub(super) fn encode_summary(totals: &FolderSummary) -> Data<'static> {
    Data::Object(vec![
        ("kind", Data::String("summary")),
        ("files", Data::Unsigned(totals.files)),
        ("folders", Data::Unsigned(totals.folders)),
        ("bytes", Data::Unsigned(totals.bytes)),
        ("truncated", Data::Bool(totals.truncated)),
    ])
}

pub(super) fn decode_summary(value: &Data<'_>) -> io::Result<Output> {
    Ok(Output::Summary(FolderSummary {
        files: file::field(value, "files", Data::unsigned)?,
        folders: file::field(value, "folders", Data::unsigned)?,
        bytes: file::field(value, "bytes", Data::unsigned)?,
        truncated: file::field(value, "truncated", Data::boolean)?,
    }))
}

#[cfg(test)]
#[path = "listing.test.rs"]
mod tests;
