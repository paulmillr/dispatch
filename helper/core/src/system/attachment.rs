//! The private copies of chat attachments (dispatch/attachments.rs) as native jobs:
//! - "attachment.put": {root,folder,name,data:bytes} -> {path}; `<root>` made 0700 when
//!   missing, `<folder>` a new 0700 directory (never one that exists), `<name>` a new 0600 file;
//! - "attachment.read": {root,folder,name,limit} -> {size,data:bytes}; the file's first `limit`
//!   bytes, at most attachment::LIMIT in all;
//! - "attachment.clock": {} -> {ms}; the wall clock in Unix milliseconds (when a send with
//!   attachments was delivered, for the delivery index).
//!
//! Every level is this account's, private, and opened without following a symlink.
use super::native::{self, O_CLOEXEC, O_DIRECTORY, O_NOFOLLOW, O_NONBLOCK};
use crate::{api::attachment, json::Data};
use std::{
    ffi::OsStr,
    fs::File,
    io::{self, Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

fn invalid() -> io::Error {
    io::ErrorKind::InvalidInput.into()
}

/// This account's private file or directory, and nothing else.
fn private(file: &File, directory: bool, uid: u32) -> io::Result<()> {
    let metadata = file.metadata()?;
    let kind = if directory { metadata.is_dir() } else { metadata.is_file() && metadata.nlink() == 1 };
    if !kind || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}

/// The attachments root, for a request whose names `attachments.put` could have made.
fn open(root: &Path, folder: &str, name: &str, create: bool, uid: u32) -> io::Result<File> {
    let path = format!("{}/{folder}/{name}", root.to_str().ok_or_else(invalid)?);
    if !root.is_absolute() || attachment::stored(root, &path).is_none() {
        return Err(invalid());
    }
    if create {
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::DirBuilder::new().mode(0o700).create(root) {
            Err(error) if error.kind() != io::ErrorKind::AlreadyExists => return Err(error),
            _ => {}
        }
    }
    let file = File::options()
        .read(true)
        .custom_flags(O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        .open(root)?;
    private(&file, true, uid)?;
    Ok(file)
}

pub(super) fn native(name: &str, input: &[u8]) -> io::Result<Vec<u8>> {
    let request = crate::wire::body::decode_plain(input).map_err(|_| invalid())?;
    let write = |value: &Data<'_>| crate::wire::body::encode_plain(value).map_err(|_| invalid());
    if name == "attachment.clock" {
        let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| invalid())?;
        return write(&Data::Object(vec![("ms", Data::Signed(i64::try_from(since.as_millis()).map_err(|_| invalid())?))]));
    }
    let field = |key: &str| request.get(key).and_then(Data::string).ok_or_else(invalid);
    let root = request.get("root").and_then(Data::path).ok_or_else(invalid)?;
    let (folder, file) = (field("folder")?, field("name")?);
    let uid = native::account()?.uid;
    match name {
        "attachment.put" => {
            let data = request.get("data").and_then(Data::bytes).ok_or_else(invalid)?;
            if data.is_empty() || data.len() as u64 > attachment::LIMIT {
                return Err(invalid());
            }
            let parent = open(root, folder, file, true, uid)?;
            put(&parent, OsStr::new(folder), OsStr::new(file), data, uid)?;
            let path = root.join(folder).join(file);
            write(&Data::Object(vec![("path", Data::from(path.as_path()))]))
        }
        "attachment.read" => {
            let limit = request.get("limit").and_then(Data::unsigned).ok_or_else(invalid)?;
            let parent = open(root, folder, file, false, uid)?;
            let (size, data) = read(&parent, OsStr::new(folder), OsStr::new(file), limit, uid)?;
            write(&Data::Object(vec![("size", Data::Unsigned(size)), ("data", Data::Bytes(&data))]))
        }
        _ => Err(io::ErrorKind::Unsupported.into()),
    }
}

/// A new folder with one new file; on failure nothing of it stays.
fn put(root: &File, folder: &OsStr, name: &OsStr, data: &[u8], uid: u32) -> io::Result<()> {
    native::mkdir(root, folder, 0o700)?;
    let result = (|| {
        let directory = native::folder(root, folder)?;
        private(&directory, true, uid)?;
        let mut file = native::open(&directory, name, Some(0o600))?;
        let written = file.write_all(data).and_then(|()| file.sync_all());
        if let Err(error) = written {
            let _ = native::remove(&directory, name);
            return Err(error);
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = native::remove(root, folder);
    }
    result
}

fn read(root: &File, folder: &OsStr, name: &OsStr, limit: u64, uid: u32) -> io::Result<(u64, Vec<u8>)> {
    let directory = native::folder(root, folder)?;
    private(&directory, true, uid)?;
    let file = native::open(&directory, name, None)?;
    private(&file, false, uid)?;
    let size = file.metadata()?.len();
    if size > attachment::LIMIT {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut data = Vec::new();
    (&file).take(limit.min(size)).read_to_end(&mut data)?;
    Ok((size, data))
}

#[cfg(test)]
#[path = "attachment.test.rs"]
mod tests;
