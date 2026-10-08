//! Old ssh-helper Pi registration policy, using shared asynchronous IO.
use crate::bridge::{Registration, Shared, current, fail, home, native};
use crate::records::text;
use dispatch_helper_core::{
    api::*,
    json::{Data, Json, Kind, Value},
};
use std::path::PathBuf;
/// Native fields decoded before file/socket/process authentication.
pub struct Decoded {
    pub session: String,
    pub path: Option<String>,
    pub socket: String,
    pub token: String,
    pub version: String,
    pub busy: bool,
    pub leaf: Option<String>,
}
pub fn decode(value: Value<'_>, pid: u32, birth: f64, tolerance: f64) -> Result<Decoded, Error> {
    let start = value
        .get("startedAt")
        .and_then(Value::number)
        .unwrap_or(f64::NAN)
        / 1000.0;
    let session = text(value, "sessionId");
    let token = text(value, "token");
    let socket = text(value, "socket");
    let path = value.get("transcriptPath");
    if value.get("protocol").and_then(Value::unsigned) != Some(1)
        || value.get("pid").and_then(Value::unsigned) != Some(pid.into())
        || !start.is_finite()
        || start < birth - tolerance
        || start >= birth + 5.0
        || !uuid(&session)
        || !uuid(&token)
        || !socket.starts_with('/')
        || socket.len() >= 104
        || socket.contains('\0')
        || path.is_some_and(|path| path.kind() != Kind::Null && !optional(Some(path), 4096, true))
    {
        return Err(fail("not_sent", "Pi registration is unavailable"));
    }
    let busy = value
        .get("busy")
        .and_then(Value::boolean)
        .ok_or_else(|| fail("not_sent", "Pi registration is unavailable"))?;
    Ok(Decoded {
        session,
        token,
        socket,
        path: path.and_then(Value::string).map(str::to_owned),
        version: value
            .get("version")
            .and_then(Value::string)
            .unwrap_or("unknown")
            .to_owned(),
        busy,
        leaf: value
            .get("leafId")
            .and_then(Value::string)
            .map(str::to_owned),
    })
}
pub fn owned(value: Value<'_>, uid: u64) -> Result<Vec<u8>, Error> {
    let before = value
        .get("before")
        .ok_or_else(|| fail("not_sent", "Pi registration metadata is unavailable"))?;
    let after = value
        .get("after")
        .ok_or_else(|| fail("not_sent", "Pi registration metadata is unavailable"))?;
    let data = text(value, "data");
    if ["size", "mtime_ns", "device", "inode"].iter().any(|key| {
        before.get(key).and_then(|v| v.write().ok()) != after.get(key).and_then(|v| v.write().ok())
    }) || before
        .get("links")
        .and_then(Value::unsigned)
        .is_none_or(|links| links > 1)
        || before.get("size").and_then(Value::unsigned) != Some(data.len() as u64)
    {
        return Err(fail("not_sent", "Pi registration changed while reading"));
    }
    if before.get("uid").and_then(Value::unsigned) != Some(uid)
        || before
            .get("mode")
            .and_then(Value::unsigned)
            .is_none_or(|mode| mode & 0o077 != 0)
    {
        return Err(fail("not_sent", "Pi registration is not private"));
    }
    Ok(data.into_bytes())
}
pub fn same(runtime: &Shared, process: &Process, record: &Registration) -> bool {
    runtime
        .borrow()
        .registrations
        .get(&process.pid)
        .is_some_and(|before| {
            before.session == record.session
                && before.token == record.token
                && before.socket == record.socket
        })
}
pub fn registration(
    runtime: &Shared,
    io: &mut dyn Io,
    process: &Process,
    done: Done<Registration>,
) {
    let process = process.clone();
    let next = runtime.clone();
    native(
        runtime,
        io,
        "process",
        Data::Object(vec![("pid", Data::Unsigned(process.pid.into()))]),
        Box::new(move |io, result| {
            let facts = match result {
                Ok(facts) if current(facts.root(), &process) => facts,
                Ok(_) => {
                    done(
                        io,
                        Err(fail(
                            "not_sent",
                            "The Pi process changed. Review Terminal before trying again.",
                        )),
                    );
                    return;
                }
                Err(error) => {
                    done(io, Err(error));
                    return;
                }
            };
            let uid = facts.root().get("uid").and_then(Value::unsigned);
            let birth = facts.root().get("started_at").and_then(Value::number);
            let (Some(uid), Some(birth)) = (uid, birth) else {
                done(
                    io,
                    Err(fail("not_sent", "Pi process identity is unavailable")),
                );
                return;
            };
            let saved = next.clone();
            native(
                &next,
                io,
                "environment",
                Data::Object(vec![
                    ("pid", Data::Unsigned(process.pid.into())),
                    (
                        "start",
                        Data::Array(process.start.iter().copied().map(Data::Unsigned).collect()),
                    ),
                    (
                        "executable",
                        Data::String(process.executable.to_str().unwrap_or("")),
                    ),
                    (
                        "names",
                        Data::Array(vec![
                            Data::String("HOME"),
                            Data::String("PI_CODING_AGENT_DIR"),
                        ]),
                    ),
                ]),
                Box::new(move |io, result| {
                    let environment = match result {
                        Ok(value) => value,
                        Err(error) => {
                            done(io, Err(error));
                            return;
                        }
                    };
                    let home = match home(&saved, environment.root()) {
                        Ok(home) => home,
                        Err(error) => {
                            done(io, Err(error));
                            return;
                        }
                    };
                    let path = format!("{home}/dispatch/sessions/{}.json", process.pid);
                    let checked = saved.clone();
                    private(
                        io,
                        &saved,
                        PathBuf::from(&home).join("dispatch/sessions"),
                        uid,
                        Box::new(move |io, result| {
                            if let Err(error) = result {
                                done(io, Err(error));
                                return;
                            }
                            let next = checked.clone();
                            native(
                                &checked,
                                io,
                                "file.private",
                                Data::Object(vec![
                                    ("path", Data::String(&path)),
                                    ("limit", Data::Unsigned(65536)),
                                ]),
                                Box::new(move |io, result| {
                                    let result = result.and_then(|document| {
                                        let data = owned(document.root(), uid)?;
                                        let record = Json::parse(&data)?;
                                        let value = record.root();
                                        let tolerance =
                                            if cfg!(target_os = "linux") { 1.0 } else { 0.0 };
                                        let decoded = decode(value, process.pid, birth, tolerance)?;
                                        let session = decoded.session;
                                        let token = decoded.token;
                                        let socket = decoded.socket;
                                        let expected = format!(
                                            "/tmp/dispatch-pi-{uid}/{}-{token}.sock",
                                            process.pid
                                        );
                                        if socket != expected
                                            || !optional(value.get("transcriptPath"), 4096, true)
                                            || !optional(value.get("leafId"), 128, false)
                                        {
                                            return Err(fail(
                                                "not_sent",
                                                "Pi registration is unavailable",
                                            ));
                                        }
                                        Ok(Registration {
                                            session,
                                            token,
                                            socket: socket.into(),
                                            path: decoded.path.map(PathBuf::from),
                                            leaf: decoded.leaf,
                                            version: decoded.version,
                                            uid,
                                            home: home.into(),
                                            cli: value
                                                .get("cli")
                                                .and_then(Value::string)
                                                .map(str::to_owned),
                                            start: process.start,
                                        })
                                    });
                                    match result {
                                        Ok(record) => {
                                            let path = record.socket.parent().unwrap().to_owned();
                                            private(
                                                io,
                                                &next,
                                                path,
                                                uid,
                                                Box::new(move |io, result| {
                                                    done(io, result.map(|_| record))
                                                }),
                                            );
                                        }
                                        Err(error) => done(io, Err(error)),
                                    }
                                }),
                            );
                        }),
                    );
                }),
            );
        }),
    );
}

fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn optional(value: Option<Value<'_>>, limit: usize, absolute: bool) -> bool {
    value.is_some_and(|value| {
        value.kind() == Kind::Null
            || value.string().is_some_and(|s| {
                if absolute {
                    s.starts_with('/') && s.len() < limit && !s.contains('\0')
                } else {
                    !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control)
                }
            })
    })
}
fn private(io: &mut dyn Io, runtime: &Shared, path: PathBuf, uid: u64, done: Done<()>) {
    native(
        runtime,
        io,
        "file.lstat",
        Data::Object(vec![("path", Data::String(path.to_str().unwrap()))]),
        Box::new(move |io, result| match result {
            Ok(value)
                if text(value.root(), "kind") == "directory"
                    && value.root().get("uid").and_then(Value::unsigned) == Some(uid)
                    && value
                        .root()
                        .get("mode")
                        .and_then(Value::unsigned)
                        .is_some_and(|v| v & 0o077 == 0) =>
            {
                done(io, Ok(()))
            }
            _ => done(
                io,
                Err(fail("not_sent", "Pi registration directory is not private")),
            ),
        }),
    );
}
