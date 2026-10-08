//! Same-descriptor bounded file reads and lossless file completion captures.
mod replay;
use super::*;
use crate::json::{self, Data, Json, Value};
pub(super) use replay::Replay;
use std::io::BufRead;
use std::io::{Seek, SeekFrom};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::OpenOptionsExt;

pub(super) const LIMIT: u64 = 128 * 1024 * 1024 + 4096;
pub(super) struct Row {
    pub op: String,
    pub args: String,
    pub data: Vec<u8>,
}

pub(super) struct Completion {
    pub sequence: Option<u64>,
    pub held: Option<File>,
    pub result: io::Result<Output>,
}

pub(super) fn open(path: &Path) -> io::Result<File> {
    #[cfg(target_os = "linux")]
    const FLAGS: i32 = 0x800 | 0x80000;
    #[cfg(target_os = "macos")]
    const FLAGS: i32 = 4 | 0x1000000;
    File::options().read(true).custom_flags(FLAGS).open(path)
}

pub(super) fn read(path: &Path, offset: u64, length: u64) -> io::Result<Output> {
    if offset > i64::MAX as u64 {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let mut file = open(path)?;
    let before = file.metadata()?;
    if !before.is_file() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    // Take bounds bytes at the caller's limit; Read collects short reads/EINTR.
    (&mut file).take(length).read_to_end(&mut bytes)?;
    Ok(Output::Read {
        before: metadata(before),
        after: metadata(file.metadata()?),
        bytes,
    })
}

pub(super) fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid file capture")
}

pub(super) fn field<'a, T>(
    value: Value<'a>,
    name: &str,
    get: impl FnOnce(Value<'a>) -> Option<T>,
) -> io::Result<T> {
    value.get(name).and_then(get).ok_or_else(invalid)
}

fn facts<'a>(value: Metadata, times: &'a [String]) -> Data<'a> {
    Data::Object(vec![
        (
            "kind",
            Data::String(match value.kind {
                FileKind::File => "file",
                FileKind::Directory => "directory",
                FileKind::Symlink => "symlink",
                FileKind::Other => "other",
            }),
        ),
        ("size", Data::Unsigned(value.size)),
        ("device", Data::Unsigned(value.device)),
        ("inode", Data::Unsigned(value.inode)),
        ("modified_ns", Data::String(&times[0])),
        ("changed_ns", Data::String(&times[1])),
    ])
}

fn frame(sequence: u64, fields: Vec<(&str, Data<'_>)>) -> io::Result<Vec<u8>> {
    json::write(&Data::Object(vec![
        ("sequence", Data::Unsigned(sequence)),
        ("output", Data::Object(fields)),
    ]))
    .map_err(|error| io::Error::other(error.message))
}

pub(super) fn encode(result: &io::Result<Output>, sequence: u64) -> io::Result<Vec<u8>> {
    match result {
        Ok(Output::Metadata(value)) => {
            let times = [value.modified_ns.to_string(), value.changed_ns.to_string()];
            frame(
                sequence,
                vec![
                    ("kind", Data::String("stat")),
                    ("metadata", facts(*value, &times)),
                ],
            )
        }
        Ok(Output::Read {
            before,
            after,
            bytes,
        }) => {
            let times = [
                before.modified_ns.to_string(),
                before.changed_ns.to_string(),
                after.modified_ns.to_string(),
                after.changed_ns.to_string(),
            ];
            let bytes = capture::hex(bytes);
            frame(
                sequence,
                vec![
                    ("kind", Data::String("read")),
                    ("before", facts(*before, &times[..2])),
                    ("after", facts(*after, &times[2..])),
                    ("bytes", Data::String(&bytes)),
                ],
            )
        }
        Ok(Output::Bytes(bytes)) => {
            let bytes = capture::hex(bytes);
            frame(
                sequence,
                vec![
                    ("kind", Data::String("bytes")),
                    ("bytes", Data::String(&bytes)),
                ],
            )
        }
        Ok(Output::Written) => frame(sequence, vec![("kind", Data::String("written"))]),
        Ok(Output::Locked) => frame(sequence, vec![("kind", Data::String("locked"))]),
        Ok(Output::Exit { status, stdout }) => {
            let stdout = capture::hex(stdout);
            frame(
                sequence,
                vec![
                    ("kind", Data::String("exit")),
                    (
                        "status",
                        status.map_or(Data::Null, |v| Data::Signed(v.into())),
                    ),
                    ("stdout", Data::String(&stdout)),
                ],
            )
        }
        Ok(Output::List(entries)) => {
            let kinds: Vec<_> = entries.iter().map(|(_, k)| format!("{k:?}")).collect();
            frame(
                sequence,
                vec![
                    ("kind", Data::String("list")),
                    (
                        "entries",
                        Data::Array(
                            entries
                                .iter()
                                .zip(&kinds)
                                .map(|((name, _), kind)| {
                                    Data::Array(vec![Data::String(name), Data::String(kind)])
                                })
                                .collect(),
                        ),
                    ),
                ],
            )
        }
        Ok(Output::Process(p)) => {
            let executable = capture::hex(p.executable.as_os_str().as_bytes());
            let files: Vec<_> = p
                .files
                .iter()
                .map(|p| capture::hex(p.path.as_os_str().as_bytes()))
                .collect();
            frame(
                sequence,
                vec![
                    ("kind", Data::String("process")),
                    ("pid", Data::Unsigned(p.pid.into())),
                    ("parent", Data::Unsigned(p.parent.into())),
                    ("group", Data::Signed(p.group.into())),
                    ("foreground", Data::Signed(p.foreground.into())),
                    ("tty", Data::Unsigned(p.tty)),
                    (
                        "start",
                        Data::Array(p.start.iter().map(|v| Data::Unsigned(*v)).collect()),
                    ),
                    ("executable", Data::String(&executable)),
                    (
                        "arguments",
                        Data::Array(p.arguments.iter().map(|v| Data::String(v)).collect()),
                    ),
                    (
                        "files",
                        Data::Array(
                            files
                                .iter()
                                .zip(&p.files)
                                .map(|(path, f)| {
                                    Data::Object(vec![
                                        ("path", Data::String(path)),
                                        ("device", Data::Unsigned(f.identity.device)),
                                        ("inode", Data::Unsigned(f.identity.inode)),
                                    ])
                                })
                                .collect(),
                        ),
                    ),
                ],
            )
        }
        Err(error) => {
            let kind = format!("{:?}", error.kind());
            let message = error.to_string();
            frame(
                sequence,
                vec![
                    ("kind", Data::String("error")),
                    (
                        "errno",
                        error
                            .raw_os_error()
                            .map_or(Data::Null, |value| Data::Signed(i64::from(value))),
                    ),
                    ("code", Data::String(&kind)),
                    ("message", Data::String(&message)),
                ],
            )
        }
    }
}

fn restore(value: Value<'_>) -> io::Result<Metadata> {
    Ok(Metadata {
        kind: match field(value, "kind", Value::string)? {
            "file" => FileKind::File,
            "directory" => FileKind::Directory,
            "symlink" => FileKind::Symlink,
            "other" => FileKind::Other,
            _ => return Err(invalid()),
        },
        size: field(value, "size", Value::unsigned)?,
        device: field(value, "device", Value::unsigned)?,
        inode: field(value, "inode", Value::unsigned)?,
        modified_ns: field(value, "modified_ns", Value::string)?
            .parse()
            .map_err(|_| invalid())?,
        changed_ns: field(value, "changed_ns", Value::string)?
            .parse()
            .map_err(|_| invalid())?,
    })
}

pub(super) fn decode(bytes: &[u8]) -> io::Result<Completion> {
    let json = Json::parse(bytes).map_err(|_| invalid())?;
    let value = json.root();
    let sequence = field(value, "sequence", Value::unsigned)?;
    let value = value.get("output").ok_or_else(invalid)?;
    let result = match field(value, "kind", Value::string)? {
        "stat" => Ok(Output::Metadata(restore(
            value.get("metadata").ok_or_else(invalid)?,
        )?)),
        "read" => Ok(Output::Read {
            before: restore(value.get("before").ok_or_else(invalid)?)?,
            after: restore(value.get("after").ok_or_else(invalid)?)?,
            bytes: capture::unhex(field(value, "bytes", Value::string)?)?,
        }),
        "bytes" => Ok(Output::Bytes(capture::unhex(field(
            value,
            "bytes",
            Value::string,
        )?)?)),
        "written" => Ok(Output::Written),
        "locked" => Ok(Output::Locked),
        "exit" => Ok(Output::Exit {
            status: value
                .get("status")
                .and_then(Value::signed)
                .map(i32::try_from)
                .transpose()
                .map_err(|_| invalid())?,
            stdout: capture::unhex(field(value, "stdout", Value::string)?)?,
        }),
        "list" => Ok(Output::List(
            value
                .get("entries")
                .and_then(Value::array)
                .ok_or_else(invalid)?
                .map(|entry| {
                    let parts: Vec<_> = entry.array().ok_or_else(invalid)?.collect();
                    if parts.len() != 2 {
                        return Err(invalid());
                    }
                    Ok((
                        parts[0].string().ok_or_else(invalid)?.into(),
                        match parts[1].string().ok_or_else(invalid)? {
                            "File" => FileKind::File,
                            "Directory" => FileKind::Directory,
                            "Symlink" => FileKind::Symlink,
                            "Other" => FileKind::Other,
                            _ => return Err(invalid()),
                        },
                    ))
                })
                .collect::<io::Result<_>>()?,
        )),
        "process" => {
            let start: Vec<_> = value
                .get("start")
                .and_then(Value::array)
                .ok_or_else(invalid)?
                .map(|v| v.unsigned().ok_or_else(invalid))
                .collect::<io::Result<_>>()?;
            let path = |v: Value<'_>| -> io::Result<PathBuf> {
                Ok(
                    std::ffi::OsString::from_vec(capture::unhex(v.string().ok_or_else(invalid)?)?)
                        .into(),
                )
            };
            Ok(Output::Process(crate::api::Process {
                pid: field(value, "pid", Value::unsigned)?
                    .try_into()
                    .map_err(|_| invalid())?,
                parent: field(value, "parent", Value::unsigned)?
                    .try_into()
                    .map_err(|_| invalid())?,
                group: field(value, "group", Value::signed)?
                    .try_into()
                    .map_err(|_| invalid())?,
                foreground: field(value, "foreground", Value::signed)?
                    .try_into()
                    .map_err(|_| invalid())?,
                tty: field(value, "tty", Value::unsigned)?,
                start: start.try_into().map_err(|_| invalid())?,
                executable: path(value.get("executable").ok_or_else(invalid)?)?,
                arguments: value
                    .get("arguments")
                    .and_then(Value::array)
                    .ok_or_else(invalid)?
                    .map(|v| v.string().map(str::to_owned).ok_or_else(invalid))
                    .collect::<io::Result<_>>()?,
                files: value
                    .get("files")
                    .and_then(Value::array)
                    .ok_or_else(invalid)?
                    .map(|v| {
                        Ok(crate::api::OpenFile {
                            path: path(v.get("path").ok_or_else(invalid)?)?,
                            identity: crate::api::FileIdentity {
                                device: field(v, "device", Value::unsigned)?,
                                inode: field(v, "inode", Value::unsigned)?,
                            },
                        })
                    })
                    .collect::<io::Result<_>>()?,
            }))
        }
        "error" => {
            let error = if let Some(errno) = value.get("errno").and_then(Value::signed) {
                io::Error::from_raw_os_error(i32::try_from(errno).map_err(|_| invalid())?)
            } else {
                macro_rules! kinds {
                    ($($name:ident),*) => { match field(value, "code", Value::string)? {
                        $(stringify!($name) => io::ErrorKind::$name,)* _ => return Err(invalid()),
                    } };
                }
                let kind = kinds!(
                    NotFound,
                    PermissionDenied,
                    ConnectionRefused,
                    ConnectionReset,
                    HostUnreachable,
                    NetworkUnreachable,
                    ConnectionAborted,
                    NotConnected,
                    AddrInUse,
                    AddrNotAvailable,
                    NetworkDown,
                    BrokenPipe,
                    AlreadyExists,
                    WouldBlock,
                    NotADirectory,
                    IsADirectory,
                    DirectoryNotEmpty,
                    ReadOnlyFilesystem,
                    StaleNetworkFileHandle,
                    InvalidInput,
                    InvalidData,
                    TimedOut,
                    WriteZero,
                    StorageFull,
                    NotSeekable,
                    QuotaExceeded,
                    FileTooLarge,
                    ResourceBusy,
                    ExecutableFileBusy,
                    Deadlock,
                    CrossesDevices,
                    TooManyLinks,
                    InvalidFilename,
                    ArgumentListTooLong,
                    Interrupted,
                    Unsupported,
                    UnexpectedEof,
                    OutOfMemory,
                    Other
                );
                io::Error::new(kind, field(value, "message", Value::string)?.to_owned())
            };
            Err(error)
        }
        _ => return Err(invalid()),
    };
    Ok(Completion {
        held: None,
        sequence: Some(sequence),
        result,
    })
}

/// The stable helper copy (Io::executable): replaced atomically when its bytes differ from
/// the running executable.
pub(super) fn stable() -> io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let directory = hooks::base()?.join("bin");
    match std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&directory)
    {
        Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e),
        _ => {}
    }
    let path = directory.join("dispatch-helper");
    // Verified once per process (a full compare reads both binaries: ~190 ms for a debug
    // build); later calls only check it is still that file. Replacement (new inode) or an
    // in-place write (new ctime) forces a full check again.
    static VERIFIED: std::sync::Mutex<Option<(PathBuf, [i64; 7])>> = std::sync::Mutex::new(None);
    let identity = |path: &Path| {
        use std::os::unix::fs::MetadataExt;
        std::fs::symlink_metadata(path).ok().map(|m| {
            [
                m.dev() as i64,
                m.ino() as i64,
                m.size() as i64,
                m.mtime(),
                m.mtime_nsec(),
                m.ctime(),
                m.ctime_nsec(),
            ]
        })
    };
    let verified = |path: &Path| {
        let mut slot = VERIFIED.lock().unwrap_or_else(|e| e.into_inner());
        *slot = identity(path).map(|id| (path.to_owned(), id));
    };
    if let Some(id) = identity(&path)
        && VERIFIED
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|(known, was)| *known == path && *was == id)
    {
        return Ok(path);
    }
    let running = std::fs::read(std::env::current_exe()?)?;
    if std::fs::read(&path).is_ok_and(|current| current == running) {
        verified(&path);
        return Ok(path);
    }
    // Writers (other helpers, or Systems in one process) take the bin directory's lock and
    // check again, so a copy that just became current is never replaced and keeps its inode.
    // The wait is bounded by another writer's copy of one binary (debug builds are ~150 MB).
    let _lock = super::native::advisory(
        &directory.join(".lock"),
        std::time::Instant::now() + std::time::Duration::from_secs(30),
    )?;
    if std::fs::read(&path).is_ok_and(|current| current == running) {
        verified(&path);
        return Ok(path);
    }
    let staged = directory.join(format!(".dispatch-helper-{}", std::process::id()));
    let written = (|| {
        let mut file = std::fs::File::options()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o700)
            .open(&staged)?;
        std::io::Write::write_all(&mut file, &running)?;
        file.sync_all()?;
        std::fs::rename(&staged, &path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&staged);
    }
    written.map(|()| {
        verified(&path);
        path
    })
}

fn line(reader: &mut io::BufReader<File>) -> io::Result<Option<Json>> {
    let mut bytes = Vec::new();
    if reader.take(LIMIT + 1).read_until(b'\n', &mut bytes)? == 0 {
        return Ok(None);
    }
    if bytes.len() as u64 > LIMIT || bytes.last() != Some(&b'\n') {
        return Err(invalid());
    }
    let json = Json::parse(&bytes).map_err(|_| invalid())?;
    if json.root().get("invalid").is_some() {
        return Err(invalid());
    }
    Ok(Some(json))
}
#[derive(Default)]
pub(in crate::system) struct Book {
    issued: BTreeMap<String, u64>,
    recorded: BTreeMap<String, u64>,
}
impl Book {
    pub(in crate::system) fn order(&self, section: &str) -> u64 {
        self.issued.get(section).copied().unwrap_or(0)
    }
    pub(in crate::system) fn admit(&mut self, section: &str) {
        *self.issued.entry(section.into()).or_default() += 1;
    }
    pub(in crate::system) fn sequence(&mut self, section: &str) -> u64 {
        let next = self.recorded.entry(section.into()).or_default();
        let value = *next;
        *next += 1;
        value
    }
}
