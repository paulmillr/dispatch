//! files.write: one whole file per request through Job::Write (a temporary name beside the target, fsync, an
//! atomic rename), so a reader never sees half a file.
use super::*;
use dispatch_helper_core::{api::Expected, json::Data, wire::body};
use transfer::{failure, job, plain};

/// Bytes one request may carry; the app sends at most 4 MiB in total this way.
pub(super) const LIMIT: usize = 8 << 20;

pub(super) fn write(
    io: &mut dyn Io,
    path: &Path,
    bytes: Vec<u8>,
    mode: Option<u32>,
    replace: bool,
    done: Done<Metadata>,
) {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return done(io, Err(error("invalid_request")));
    };
    if !plain(path) || mode.is_some_and(|mode| mode > 0o7777) {
        return done(io, Err(error("invalid_request")));
    }
    if bytes.len() > LIMIT {
        return done(io, Err(error("limit")));
    }
    // The kernel applies the umask when the file is created; set-id and sticky bits are never written.
    let mode = mode.unwrap_or(0o644) & 0o777;
    let Ok(value) = body::encode_plain(&Data::Object(vec![("path", Data::from(parent))])) else {
        return done(io, Err(error("invalid_request")));
    };
    let name = name.to_owned();
    // The parent must exist (Job::Write would make it) and is resolved first: a checked write refuses a
    // symlinked parent, and folders are often reached through one (/tmp on macOS).
    job(io, Job::Native { name: "file.realpath", value }, move |io, result| {
        let parent = match result {
            Ok(Output::Value(value)) => match body::decode_plain(&value).ok().and_then(|v| v.get("path").and_then(Data::path).map(PathBuf::from)) {
                Some(parent) => parent,
                None => return done(io, Err(error("internal"))),
            },
            Ok(_) => return done(io, Err(error("internal"))),
            Err(value) => return done(io, Err(failure(value))),
        };
        // Job::Write would take a file there for a folder that exists (EEXIST): say what it is.
        let folder = Job::Stat {
            path: parent.clone(),
            follow: false,
        };
        job(io, folder, move |io, result| {
            match result {
                Ok(Output::Metadata(metadata)) if metadata.kind == FileKind::Directory => {}
                Ok(Output::Metadata(_)) => return done(io, Err(error("not_directory"))),
                Ok(_) => return done(io, Err(error("internal"))),
                Err(value) => return done(io, Err(native(value))),
            }
            let path = parent.join(name);
            let expected = if replace { Expected::Any } else { Expected::Absent };
            let written = Job::Write {
                path: path.clone(),
                bytes,
                mode,
                expected,
            };
            job(io, written, move |io, result| {
                if let Err(value) = result {
                    return done(io, Err(failure(value)));
                }
                job(io, Job::Stat { path, follow: false }, move |io, result| match result {
                    Ok(Output::Metadata(metadata)) => done(io, Ok(metadata)),
                    Ok(_) => done(io, Err(error("internal"))),
                    Err(value) => done(io, Err(native(value))),
                });
            });
        });
    });
}
