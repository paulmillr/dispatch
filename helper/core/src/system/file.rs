//! Same-descriptor bounded file reads and lossless file completion captures.
mod replay;
use super::*;
use crate::json::Data;
pub(super) use replay::Replay;
use std::io::{Seek, SeekFrom};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::OpenOptionsExt;

pub(super) const LIMIT: u64 = 128 * 1024 * 1024 + 4096;
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

pub(super) fn field<'a, 'b, T>(
    value: &'b Data<'a>,
    name: &str,
    get: impl FnOnce(&'b Data<'a>) -> Option<T>,
) -> io::Result<T> {
    value.get(name).and_then(get).ok_or_else(invalid)
}

pub(super) fn kind(kind: FileKind) -> &'static str {
    match kind {
        FileKind::File => "file",
        FileKind::Directory => "directory",
        FileKind::Symlink => "symlink",
        FileKind::Other => "other",
    }
}

fn facts(value: Metadata) -> io::Result<Data<'static>> {
    let time = |ns: i128| i64::try_from(ns).map(Data::Signed).map_err(|_| invalid());
    Ok(Data::Object(vec![
        ("kind", Data::String(kind(value.kind))),
        ("size", Data::Unsigned(value.size)),
        ("device", Data::Unsigned(value.device)),
        ("inode", Data::Unsigned(value.inode)),
        ("modified_ns", time(value.modified_ns)?),
        ("changed_ns", time(value.changed_ns)?),
    ]))
}

/// A completion's output as a capture value (capture/trace.rs): bytes stay bytes.
pub(super) fn encode(result: &io::Result<Output>) -> io::Result<Vec<u8>> {
    let kinds: Vec<_>;
    let value = match result {
        Ok(Output::Metadata(value)) => {
            Data::Object(vec![("kind", Data::String("stat")), ("metadata", facts(*value)?)])
        }
        Ok(Output::Read {
            before,
            after,
            bytes,
        }) => Data::Object(vec![
            ("kind", Data::String("read")),
            ("before", facts(*before)?),
            ("after", facts(*after)?),
            ("bytes", Data::Bytes(bytes)),
        ]),
        Ok(Output::Bytes(bytes)) => {
            Data::Object(vec![("kind", Data::String("bytes")), ("bytes", Data::Bytes(bytes))])
        }
        Ok(Output::Value(value)) => Data::Object(vec![
            ("kind", Data::String("value")),
            ("value", crate::wire::body::decode_plain(value).map_err(|_| invalid())?),
        ]),
        Ok(Output::Written) => Data::Object(vec![("kind", Data::String("written"))]),
        Ok(Output::Locked) => Data::Object(vec![("kind", Data::String("locked"))]),
        Ok(Output::Packed(p)) => Data::Object(vec![
            ("kind", Data::String("packed")),
            ("archive", Data::String(&p.archive)),
            ("entries", Data::Unsigned(p.entries)),
            ("files", Data::Unsigned(p.files)),
            ("folders", Data::Unsigned(p.folders)),
            ("bytes", Data::Unsigned(p.bytes)),
            ("size", Data::Unsigned(p.size)),
            ("skipped", Data::Unsigned(p.skipped)),
        ]),
        Ok(Output::Appended(size)) => {
            Data::Object(vec![("kind", Data::String("appended")), ("size", Data::Unsigned(*size))])
        }
        Ok(Output::Unpacked(u)) => Data::Object(vec![
            ("kind", Data::String("unpacked")),
            ("entries", Data::Unsigned(u.entries)),
            ("bytes", Data::Unsigned(u.bytes)),
            ("replaced", Data::Unsigned(u.replaced)),
            ("kept", Data::Unsigned(u.kept)),
            ("skipped", Data::Unsigned(u.skipped)),
        ]),
        Ok(Output::Removed) => Data::Object(vec![("kind", Data::String("removed"))]),
        Ok(Output::Swept(directory, removed)) => Data::Object(vec![
            ("kind", Data::String("swept")),
            ("directory", Data::Bytes(directory.as_os_str().as_bytes())),
            ("removed", Data::Unsigned(*removed)),
        ]),
        Ok(Output::Exit { status, stdout }) => Data::Object(vec![
            ("kind", Data::String("exit")),
            (
                "status",
                status.map_or(Data::Null, |v| Data::Signed(v.into())),
            ),
            ("stdout", Data::Bytes(stdout)),
        ]),
        Ok(Output::Collected(c)) => Data::Object(vec![
            ("kind", Data::String("collected")),
            ("status", c.status.map_or(Data::Null, |v| Data::Signed(v.into()))),
            ("stdout", Data::Bytes(&c.stdout)),
            ("stderr", Data::Bytes(&c.stderr)),
            ("truncated", Data::Bool(c.truncated)),
        ]),
        Ok(Output::List(entries)) => {
            kinds = entries.iter().map(|(_, k)| format!("{k:?}")).collect();
            Data::Object(vec![
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
            ])
        }
        Ok(Output::Entries(entries, truncated, directory)) => super::listing::encode_entries(entries, *truncated, *directory)?,
        Ok(Output::Summary(totals)) => super::listing::encode_summary(totals),
        Ok(Output::Process(p)) => Data::Object(vec![
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
            ("executable", Data::Bytes(p.executable.as_os_str().as_bytes())),
            (
                "arguments",
                Data::Array(p.arguments.iter().map(|v| Data::String(v)).collect()),
            ),
            (
                "files",
                Data::Array(
                    p.files
                        .iter()
                        .map(|f| {
                            Data::Object(vec![
                                ("path", Data::Bytes(f.path.as_os_str().as_bytes())),
                                ("device", Data::Unsigned(f.identity.device)),
                                ("inode", Data::Unsigned(f.identity.inode)),
                            ])
                        })
                        .collect(),
                ),
            ),
        ]),
        Err(error) => {
            kinds = vec![format!("{:?}", error.kind()), error.to_string()];
            Data::Object(vec![
                ("kind", Data::String("error")),
                (
                    "errno",
                    error
                        .raw_os_error()
                        .map_or(Data::Null, |value| Data::Signed(i64::from(value))),
                ),
                ("code", Data::String(&kinds[0])),
                ("message", Data::String(&kinds[1])),
            ])
        }
    };
    crate::wire::body::encode_plain(&value).map_err(|error| io::Error::other(error.message))
}

fn restore(value: &Data<'_>) -> io::Result<Metadata> {
    Ok(Metadata {
        kind: match field(value, "kind", Data::string)? {
            "file" => FileKind::File,
            "directory" => FileKind::Directory,
            "symlink" => FileKind::Symlink,
            "other" => FileKind::Other,
            _ => return Err(invalid()),
        },
        size: field(value, "size", Data::unsigned)?,
        device: field(value, "device", Data::unsigned)?,
        inode: field(value, "inode", Data::unsigned)?,
        modified_ns: field(value, "modified_ns", Data::signed)?.into(),
        changed_ns: field(value, "changed_ns", Data::signed)?.into(),
    })
}

/// A recorded completion: its job sequence and its output value (encode).
pub(super) fn decode(sequence: u64, output: &[u8], os: &str) -> io::Result<Completion> {
    let value = crate::wire::body::decode_plain(output).map_err(|_| invalid())?;
    let value = &value;
    let path = |v: &Data<'_>| -> io::Result<PathBuf> {
        Ok(std::ffi::OsString::from_vec(v.bytes().ok_or_else(invalid)?.to_vec()).into())
    };
    let result = match field(value, "kind", Data::string)? {
        "stat" => Ok(Output::Metadata(restore(
            value.get("metadata").ok_or_else(invalid)?,
        )?)),
        "read" => Ok(Output::Read {
            before: restore(value.get("before").ok_or_else(invalid)?)?,
            after: restore(value.get("after").ok_or_else(invalid)?)?,
            bytes: field(value, "bytes", Data::bytes)?.to_vec(),
        }),
        "bytes" => Ok(Output::Bytes(field(value, "bytes", Data::bytes)?.to_vec())),
        "written" => Ok(Output::Written),
        "locked" => Ok(Output::Locked),
        "packed" => Ok(Output::Packed(crate::api::Packed {
            archive: field(value, "archive", Data::string)?.to_owned(),
            entries: field(value, "entries", Data::unsigned)?,
            files: field(value, "files", Data::unsigned)?,
            folders: field(value, "folders", Data::unsigned)?,
            bytes: field(value, "bytes", Data::unsigned)?,
            size: field(value, "size", Data::unsigned)?,
            skipped: field(value, "skipped", Data::unsigned)?,
        })),
        "appended" => Ok(Output::Appended(field(value, "size", Data::unsigned)?)),
        "unpacked" => Ok(Output::Unpacked(crate::api::Unpacked {
            entries: field(value, "entries", Data::unsigned)?,
            bytes: field(value, "bytes", Data::unsigned)?,
            replaced: field(value, "replaced", Data::unsigned)?,
            kept: field(value, "kept", Data::unsigned)?,
            skipped: field(value, "skipped", Data::unsigned)?,
        })),
        "removed" => Ok(Output::Removed),
        "swept" => Ok(Output::Swept(
            path(value.get("directory").ok_or_else(invalid)?)?,
            field(value, "removed", Data::unsigned)?,
        )),
        "exit" => Ok(Output::Exit {
            status: value
                .get("status")
                .and_then(Data::signed)
                .map(i32::try_from)
                .transpose()
                .map_err(|_| invalid())?,
            stdout: field(value, "stdout", Data::bytes)?.to_vec(),
        }),
        "collected" => Ok(Output::Collected(crate::api::Collected {
            status: value
                .get("status")
                .and_then(Data::signed)
                .map(i32::try_from)
                .transpose()
                .map_err(|_| invalid())?,
            stdout: field(value, "stdout", Data::bytes)?.to_vec(),
            stderr: field(value, "stderr", Data::bytes)?.to_vec(),
            truncated: field(value, "truncated", Data::boolean)?,
        })),
        "list" => Ok(Output::List(
            field(value, "entries", Data::array)?
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
        "entries" => super::listing::decode_entries(value),
        "summary" => super::listing::decode_summary(value),
        "process" => {
            let start: Vec<_> = field(value, "start", Data::array)?
                .map(|v| v.unsigned().ok_or_else(invalid))
                .collect::<io::Result<_>>()?;
            Ok(Output::Process(crate::api::Process {
                pid: field(value, "pid", Data::unsigned)?
                    .try_into()
                    .map_err(|_| invalid())?,
                parent: field(value, "parent", Data::unsigned)?
                    .try_into()
                    .map_err(|_| invalid())?,
                group: field(value, "group", Data::signed)?
                    .try_into()
                    .map_err(|_| invalid())?,
                foreground: field(value, "foreground", Data::signed)?
                    .try_into()
                    .map_err(|_| invalid())?,
                tty: field(value, "tty", Data::unsigned)?,
                start: start.try_into().map_err(|_| invalid())?,
                executable: path(value.get("executable").ok_or_else(invalid)?)?,
                arguments: field(value, "arguments", Data::array)?
                    .map(|v| v.string().map(str::to_owned).ok_or_else(invalid))
                    .collect::<io::Result<_>>()?,
                files: field(value, "files", Data::array)?
                    .map(|v| {
                        Ok(crate::api::OpenFile {
                            path: path(v.get("path").ok_or_else(invalid)?)?,
                            identity: crate::api::FileIdentity {
                                device: field(v, "device", Data::unsigned)?,
                                inode: field(v, "inode", Data::unsigned)?,
                            },
                        })
                    })
                    .collect::<io::Result<_>>()?,
            }))
        }
        "value" => Ok(Output::Value(
            crate::wire::body::encode_plain(value.get("value").ok_or_else(invalid)?).map_err(|_| invalid())?,
        )),
        "error" => Err(failure(value, os)?),
        _ => return Err(invalid()),
    };
    Ok(Completion {
        held: None,
        sequence: Some(sequence),
        result,
    })
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

/// The io::Error a record's error object describes (encode's Err arm).
pub(super) fn failure(value: &Data<'_>, os: &str) -> io::Result<io::Error> {
    Ok(if let Some(number) = value.get("errno").and_then(Data::signed) {
        recorded(i32::try_from(number).map_err(|_| invalid())?, os)
    } else {
        macro_rules! kinds {
            ($($name:ident),*) => { match field(value, "code", Data::string)? {
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
        io::Error::new(kind, field(value, "message", Data::string)?.to_owned())
    })
}

/// The errors whose number or text differs between macOS and Linux (the rest are the same on both): name, macOS number,
/// Linux number, macOS text, Linux text, from both systems' <errno.h> and strerror. Linux has one number for EOPNOTSUPP
/// and ENOTSUP; it reads back as EOPNOTSUPP.
const ERRNO: [(&str, i32, i32, &str, &str); 60] = [
    ("ENXIO", 6, 6, "Device not configured", "No such device or address"),
    ("EDEADLK", 11, 35, "Resource deadlock avoided", "Resource deadlock avoided"),
    ("EBUSY", 16, 16, "Resource busy", "Device or resource busy"),
    ("EXDEV", 18, 18, "Cross-device link", "Invalid cross-device link"),
    ("ENODEV", 19, 19, "Operation not supported by device", "No such device"),
    ("ERANGE", 34, 34, "Result too large", "Numerical result out of range"),
    ("EAGAIN", 35, 11, "Resource temporarily unavailable", "Resource temporarily unavailable"),
    ("EINPROGRESS", 36, 115, "Operation now in progress", "Operation now in progress"),
    ("EALREADY", 37, 114, "Operation already in progress", "Operation already in progress"),
    ("ENOTSOCK", 38, 88, "Socket operation on non-socket", "Socket operation on non-socket"),
    ("EDESTADDRREQ", 39, 89, "Destination address required", "Destination address required"),
    ("EMSGSIZE", 40, 90, "Message too long", "Message too long"),
    ("EPROTOTYPE", 41, 91, "Protocol wrong type for socket", "Protocol wrong type for socket"),
    ("ENOPROTOOPT", 42, 92, "Protocol not available", "Protocol not available"),
    ("EPROTONOSUPPORT", 43, 93, "Protocol not supported", "Protocol not supported"),
    ("ESOCKTNOSUPPORT", 44, 94, "Socket type not supported", "Socket type not supported"),
    ("EPFNOSUPPORT", 46, 96, "Protocol family not supported", "Protocol family not supported"),
    ("EAFNOSUPPORT", 47, 97, "Address family not supported by protocol family", "Address family not supported by protocol"),
    ("EADDRINUSE", 48, 98, "Address already in use", "Address already in use"),
    ("EADDRNOTAVAIL", 49, 99, "Can't assign requested address", "Cannot assign requested address"),
    ("ENETDOWN", 50, 100, "Network is down", "Network is down"),
    ("ENETUNREACH", 51, 101, "Network is unreachable", "Network is unreachable"),
    ("ENETRESET", 52, 102, "Network dropped connection on reset", "Network dropped connection on reset"),
    ("ECONNABORTED", 53, 103, "Software caused connection abort", "Software caused connection abort"),
    ("ECONNRESET", 54, 104, "Connection reset by peer", "Connection reset by peer"),
    ("ENOBUFS", 55, 105, "No buffer space available", "No buffer space available"),
    ("EISCONN", 56, 106, "Socket is already connected", "Transport endpoint is already connected"),
    ("ENOTCONN", 57, 107, "Socket is not connected", "Transport endpoint is not connected"),
    ("ESHUTDOWN", 58, 108, "Can't send after socket shutdown", "Cannot send after transport endpoint shutdown"),
    ("ETOOMANYREFS", 59, 109, "Too many references: can't splice", "Too many references: cannot splice"),
    ("ETIMEDOUT", 60, 110, "Operation timed out", "Connection timed out"),
    ("ECONNREFUSED", 61, 111, "Connection refused", "Connection refused"),
    ("ELOOP", 62, 40, "Too many levels of symbolic links", "Too many levels of symbolic links"),
    ("ENAMETOOLONG", 63, 36, "File name too long", "File name too long"),
    ("EHOSTDOWN", 64, 112, "Host is down", "Host is down"),
    ("EHOSTUNREACH", 65, 113, "No route to host", "No route to host"),
    ("ENOTEMPTY", 66, 39, "Directory not empty", "Directory not empty"),
    ("EUSERS", 68, 87, "Too many users", "Too many users"),
    ("EDQUOT", 69, 122, "Disc quota exceeded", "Disk quota exceeded"),
    ("ESTALE", 70, 116, "Stale NFS file handle", "Stale file handle"),
    ("EREMOTE", 71, 66, "Too many levels of remote in path", "Object is remote"),
    ("ENOLCK", 77, 37, "No locks available", "No locks available"),
    ("ENOSYS", 78, 38, "Function not implemented", "Function not implemented"),
    ("EOVERFLOW", 84, 75, "Value too large to be stored in data type", "Value too large for defined data type"),
    ("ECANCELED", 89, 125, "Operation canceled", "Operation canceled"),
    ("EIDRM", 90, 43, "Identifier removed", "Identifier removed"),
    ("ENOMSG", 91, 42, "No message of desired type", "No message of desired type"),
    ("EILSEQ", 92, 84, "Illegal byte sequence", "Invalid or incomplete multibyte or wide character"),
    ("EBADMSG", 94, 74, "Bad message", "Bad message"),
    ("EMULTIHOP", 95, 72, "EMULTIHOP (Reserved)", "Multihop attempted"),
    ("ENODATA", 96, 61, "No message available on STREAM", "No data available"),
    ("ENOLINK", 97, 67, "ENOLINK (Reserved)", "Link has been severed"),
    ("ENOSR", 98, 63, "No STREAM resources", "Out of streams resources"),
    ("ENOSTR", 99, 60, "Not a STREAM", "Device not a stream"),
    ("EPROTO", 100, 71, "Protocol error", "Protocol error"),
    ("ETIME", 101, 62, "STREAM ioctl timeout", "Timer expired"),
    ("EOPNOTSUPP", 102, 95, "Operation not supported on socket", "Operation not supported"),
    ("ENOTRECOVERABLE", 104, 131, "State not recoverable", "State not recoverable"),
    ("EOWNERDEAD", 105, 130, "Previous owner died", "Owner died"),
    ("ENOTSUP", 45, 95, "Operation not supported", "Operation not supported"),
];

/// A failure recorded on another system: this system's number for it, and the text the recording system gave it (the
/// helper writes error texts to its peers: replay writes what capture wrote).
#[derive(Clone, Debug)]
struct Foreign {
    errno: i32,
    text: String,
}

impl std::fmt::Display for Foreign {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

impl std::error::Error for Foreign {}

/// A recorded errno as an error of this system: `os` is the recording's. Recorded on another system (macOS and Linux
/// number some errors differently and word some differently), it means the same error here and reads as recorded.
fn recorded(number: i32, os: &str) -> io::Error {
    let side = match (os, std::env::consts::OS) {
        ("macos", "linux") => 0,
        ("linux", "macos") => 1,
        _ => return io::Error::from_raw_os_error(number),
    };
    let numbers = |&(_, macos, linux, macos_text, linux_text): &(&str, i32, i32, &'static str, &'static str)| {
        if side == 0 { (macos, linux, macos_text) } else { (linux, macos, linux_text) }
    };
    let Some((_, here, text)) = ERRNO.iter().map(numbers).find(|(there, ..)| *there == number) else {
        return io::Error::from_raw_os_error(number);
    };
    let kind = io::Error::from_raw_os_error(here).kind();
    io::Error::new(kind, Foreign { errno: here, text: format!("{text} (os error {number})") })
}

/// An error's number on this system, also for a failure recorded on another one: what code compares with errno
/// constants instead of `raw_os_error`.
pub(crate) fn errno(error: &io::Error) -> Option<i32> {
    error.raw_os_error().or_else(|| error.get_ref()?.downcast_ref::<Foreign>().map(|foreign| foreign.errno))
}

/// A copy of `error` (io::Error is not Clone): the same number, kind and text.
pub(crate) fn copy(error: &io::Error) -> io::Error {
    if let Some(foreign) = error.get_ref().and_then(|inner| inner.downcast_ref::<Foreign>()) {
        return io::Error::new(error.kind(), foreign.clone());
    }
    error.raw_os_error().map(io::Error::from_raw_os_error).unwrap_or_else(|| io::Error::new(error.kind(), error.to_string()))
}

#[cfg(test)]
#[path = "file.test.rs"]
mod tests;
