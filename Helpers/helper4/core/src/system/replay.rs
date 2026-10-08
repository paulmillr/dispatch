//! Whole-capture replay entry shared by Rust tests and the capture tool.
pub mod batch;
use super::{capture, file};
use crate::api::Output;
use std::{
    fs::File,
    io::{self, BufRead},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub fn run() {
    let mut trace = PathBuf::from(std::env::var_os("DISPATCH_REPLAY").expect("capture file"));
    assert!(trace.is_file());
    let helper = std::env::var_os("DISPATCH_HELPER_BINARY")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("CARGO_TARGET_DIR").expect("assembled binary directory"))
                .join("debug/dispatch-helper4")
        });
    let arguments = std::env::var("DISPATCH_REPLAY_ARGS")
        .map(|text| {
            let document = crate::json::Json::parse(text.as_bytes()).unwrap();
            document
                .root()
                .array()
                .unwrap()
                .map(|value| value.string().unwrap().to_owned())
                .collect::<Vec<_>>()
        })
        .unwrap_or_else(|_| vec!["--stdio".into()]);
    let status = std::env::var("DISPATCH_REPLAY_STATUS")
        .map(|text| text.parse::<i32>().unwrap())
        .unwrap_or(0);
    let environment = std::env::var("DISPATCH_REPLAY_ENV")
        .ok()
        .map(|text| crate::json::Json::parse(text.as_bytes()).unwrap());
    let root = PathBuf::from(std::env::var_os("DISPATCH_TEST_ROOT").expect("private test root"));
    std::fs::create_dir_all(&root).unwrap();
    if let Ok(ui) = std::env::var("DISPATCH_REPLAY_UI") {
        use crate::{
            json::{Data, Json},
            wire::{Kind, Message},
        };
        let ui = Json::parse(ui.as_bytes()).unwrap();
        let requests = Json::parse(
            &std::fs::read(ui.root().get("requests").unwrap().string().unwrap()).unwrap(),
        )
        .unwrap();
        let frames = Json::parse(
            &std::fs::read(ui.root().get("frames").unwrap().string().unwrap()).unwrap(),
        )
        .unwrap();
        let encode = |kind: u64, id: u64, value: crate::json::Value<'_>| {
            let kind = match kind {
                1 => Kind::Request,
                2 => Kind::Response,
                3 => Kind::Notify,
                4 => Kind::Cancel,
                _ => panic!("logical message kind"),
            };
            if kind == Kind::Cancel {
                return crate::wire::Header { kind, id, len: 0 }
                    .encode(crate::wire::LIMIT)
                    .unwrap()
                    .to_vec();
            }
            let mut bytes = value.write().unwrap();
            if kind == Kind::Response
                && let Some(result) = value.get("result")
                && result.get("version").is_some()
                && result.get("ops").is_some()
            {
                let result = crate::json::write(&Data::Object(
                    result
                        .object()
                        .unwrap()
                        .map(|(key, field)| {
                            (
                                key,
                                if key == "version" {
                                    Data::Unsigned(crate::wire::VERSION)
                                } else {
                                    Data::Value(field)
                                },
                            )
                        })
                        .collect(),
                ))
                .unwrap();
                let result = Json::parse(&result).unwrap();
                bytes = crate::json::write(&Data::Object(
                    value
                        .object()
                        .unwrap()
                        .map(|(key, field)| {
                            (
                                key,
                                Data::Value(if key == "result" {
                                    result.root()
                                } else {
                                    field
                                }),
                            )
                        })
                        .collect(),
                ))
                .unwrap();
            }
            Message::json(kind, id, bytes)
                .flatten()
                .collect::<Vec<u8>>()
        };
        let writes: Vec<_> = frames
            .root()
            .array()
            .unwrap()
            .flat_map(|frame| {
                let mut frame = frame.array().unwrap();
                encode(
                    frame.next().unwrap().unsigned().unwrap(),
                    frame.next().unwrap().unsigned().unwrap(),
                    frame.next().unwrap(),
                )
            })
            .collect();
        let lines: Vec<_> = io::BufReader::new(File::open(&trace).unwrap())
            .lines()
            .map(|line| Json::parse(line.unwrap().as_bytes()).unwrap())
            .collect();
        let old: usize = lines
            .iter()
            .filter_map(|line| {
                let row = line.root();
                if row.get("section").unwrap().string() != Some("ui")
                    || row.get("op").unwrap().string() != Some("write")
                {
                    return None;
                }
                let completion = file::decode(
                    &capture::unhex(row.get("data").unwrap().string().unwrap()).unwrap(),
                )
                .unwrap();
                match completion.result {
                    Ok(Output::Bytes(value)) => Some(value.len()),
                    _ => None,
                }
            })
            .sum();
        let mut position = 0;
        let mut offset = 0;
        let mut staged = Vec::new();
        for line in &lines {
            let row = line.root();
            let op = row.get("op").unwrap().string().unwrap();
            let mut data = row.get("data").unwrap().string().unwrap().to_owned();
            let mut args = row.get("args").unwrap().string().unwrap().to_owned();
            if row.get("section").unwrap().string() == Some("ui") && matches!(op, "read" | "write")
            {
                let completion = file::decode(&capture::unhex(&data).unwrap()).unwrap();
                if let Ok(Output::Bytes(value)) = completion.result
                    && !value.is_empty()
                {
                    let value = if op == "read" {
                        let key = capture::hex(&value);
                        let group = requests
                            .root()
                            .array()
                            .unwrap()
                            .find(|group| group.get("write").unwrap().string() == Some(&key))
                            .expect("recorded decoded request");
                        group
                            .get("requests")
                            .unwrap()
                            .array()
                            .unwrap()
                            .flat_map(|request| {
                                encode(
                                    request.get("kind").unwrap().unsigned().unwrap(),
                                    request.get("id").unwrap().unsigned().unwrap(),
                                    request.get("value").unwrap(),
                                )
                            })
                            .collect()
                    } else {
                        position += value.len();
                        let end = position * writes.len() / old;
                        let value = writes[offset..end].to_vec();
                        offset = end;
                        args = format!("{} len={}", args.split(' ').next().unwrap(), value.len());
                        value
                    };
                    data = capture::hex(
                        &file::encode(&Ok(Output::Bytes(value)), completion.sequence.unwrap())
                            .unwrap(),
                    );
                }
            }
            let fields = row
                .object()
                .unwrap()
                .map(|(key, value)| {
                    (
                        key,
                        match key {
                            "data" => Data::String(&data),
                            "args" => Data::String(&args),
                            _ => Data::Value(value),
                        },
                    )
                })
                .collect();
            staged.extend(crate::json::write(&Data::Object(fields)).unwrap());
            staged.push(b'\n');
        }
        assert_eq!(offset, writes.len());
        trace = root.join("current-system.jsonl");
        std::fs::write(&trace, staged).unwrap();
    }
    let run = |path: &Path| {
        let mut command = Command::new("/usr/bin/timeout");
        command.arg("20s");
        if let Some(environment) = &environment {
            command.arg("bwrap").args(["--tmpfs", "/"]);
            // A private root permits captured mount names absent on the host.
            for entry in std::fs::read_dir("/").unwrap() {
                let path = entry.unwrap().path();
                command.arg("--ro-bind").arg(&path).arg(&path);
            }
            let bind = std::env::var("DISPATCH_REPLAY_BIND").unwrap_or_else(|_| "/mnt".into());
            let cwd = environment
                .root()
                .get("PWD")
                .and_then(crate::json::Value::string)
                .unwrap_or(&bind);
            if let Ok(relative) = Path::new(cwd).strip_prefix(&bind) {
                std::fs::create_dir_all(root.join(relative)).unwrap();
            }
            command
                .arg("--bind")
                .arg(&root)
                .arg(std::env::var("DISPATCH_REPLAY_BIND").unwrap_or_else(|_| "/mnt".into()))
                .args([
                    "--unshare-net",
                    "--unshare-pid",
                    "--die-with-parent",
                    "--new-session",
                    "--dev",
                    "/dev",
                    "--proc",
                    "/proc",
                ])
                .arg("--chdir")
                .arg(cwd);
            if let Some(pwd) = environment
                .root()
                .get("PWD")
                .and_then(crate::json::Value::string)
            {
                command.args(["--setenv", "PWD", pwd]);
            } else {
                command.args(["--unsetenv", "PWD"]);
            }
            command.env_clear();
            for (key, value) in environment.root().object().unwrap() {
                command.env(key, value.string().unwrap());
            }
        }
        if environment.is_none()
            && let Some(cwd) = std::env::var_os("DISPATCH_REPLAY_CWD")
        {
            command.current_dir(cwd);
        }
        command.env_remove("DISPATCH_REPLAY_OUTPUT");
        if path == trace {
            let output = if environment.is_some() {
                PathBuf::from(
                    std::env::var("DISPATCH_REPLAY_BIND").unwrap_or_else(|_| "/mnt".into()),
                )
            } else {
                root.clone()
            };
            command.env("DISPATCH_REPLAY_OUTPUT", output.join("produced-io"));
        }
        if environment
            .as_ref()
            .is_some_and(|env| env.root().get("PWD").is_none())
        {
            command.args(["/usr/bin/env", "-u", "PWD"]);
        }
        command
            .arg(&helper)
            .args(&arguments)
            .env_remove("DISPATCH_CAPTURE")
            .env("DISPATCH_REPLAY", path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .output()
            .unwrap()
    };
    let output = run(&trace);
    assert_eq!(
        output.status.code(),
        Some(status),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let root = PathBuf::from(std::env::var_os("DISPATCH_TEST_ROOT").expect("private test root"))
        .join(format!("whole-mutations-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let outside: Vec<_> = io::BufReader::new(File::open(&trace).unwrap())
        .lines()
        .enumerate()
        .filter_map(|(index, line)| {
            let line = line.unwrap();
            let document = crate::json::Json::parse(line.as_bytes()).unwrap();
            let row = document.root();
            let section = row.get("section").unwrap().string().unwrap();
            let op = row.get("op").unwrap().string().unwrap();
            if section == "ui" || !matches!(op, "file.done" | "read" | "receive") {
                return None;
            }
            let data = capture::unhex(row.get("data").unwrap().string().unwrap()).unwrap();
            match file::decode(&data).unwrap().result {
                Ok(Output::Bytes(value)) | Ok(Output::Read { bytes: value, .. })
                    if !value.is_empty() =>
                {
                    Some(index)
                }
                _ => None,
            }
        })
        .collect();
    let mut caught = false;
    let probes: Vec<_> = if outside.is_empty() {
        vec![("outside", None)]
    } else {
        outside
            .into_iter()
            .map(|index| ("outside", Some(index)))
            .collect()
    };
    for (side, outside, error) in probes
        .into_iter()
        .flat_map(|probe| [(probe.0, probe.1, false), (probe.0, probe.1, true)])
        .chain(std::iter::once(("app", None, false)))
    {
        if side == "outside" && caught {
            continue;
        }
        let mut changed = false;
        let mut bytes = Vec::new();
        for (index, line) in io::BufReader::new(File::open(&trace).unwrap())
            .lines()
            .enumerate()
        {
            let line = line.unwrap();
            let document = crate::json::Json::parse(line.as_bytes()).unwrap();
            let row = document.root();
            let section = row.get("section").unwrap().string().unwrap();
            let op = row.get("op").unwrap().string().unwrap();
            let selected = !changed
                && match side {
                    "outside" => {
                        outside.map_or(section == "startup" && op == "account", |row| row == index)
                    }
                    _ => section == "ui" && op == "read",
                };
            if selected {
                let data = capture::unhex(row.get("data").unwrap().string().unwrap()).unwrap();
                let completion = file::decode(&data).unwrap();
                let mut output = completion.result.unwrap();
                let value = match &mut output {
                    Output::Bytes(value) | Output::Read { bytes: value, .. } => value,
                    _ => panic!("recorded bytes"),
                };
                if side == "outside" {
                    value[0] ^= 1;
                } else {
                    let header = crate::wire::Header::decode(
                        value[..13].try_into().unwrap(),
                        crate::wire::LIMIT,
                    )
                    .unwrap();
                    assert_eq!(header.kind, crate::wire::Kind::Request);
                    let end = 13 + header.len as usize;
                    let body = crate::wire::body::decode(&value[13..end]).unwrap();
                    let fields = body
                        .root()
                        .object()
                        .unwrap()
                        .map(|(key, field)| {
                            (
                                key,
                                if matches!(key, "method" | "op") {
                                    changed = true;
                                    crate::json::Data::String("unknown.operation")
                                } else {
                                    crate::json::Data::Value(field)
                                },
                            )
                        })
                        .collect();
                    let body = crate::json::write(&crate::json::Data::Object(fields)).unwrap();
                    assert!(changed, "recorded operation");
                    let mut frame = crate::wire::frame(header.kind, header.id, &body).unwrap();
                    frame.extend_from_slice(&value[end..]);
                    *value = frame;
                }
                let data = capture::hex(
                    &file::encode(
                        &if error {
                            Err(io::Error::other("outside mutation"))
                        } else {
                            Ok(output)
                        },
                        completion.sequence.unwrap(),
                    )
                    .unwrap(),
                );
                let fields = row
                    .object()
                    .unwrap()
                    .map(|(key, field)| {
                        (
                            key,
                            if key == "data" {
                                crate::json::Data::String(&data)
                            } else {
                                crate::json::Data::Value(field)
                            },
                        )
                    })
                    .collect();
                bytes.extend(crate::json::write(&crate::json::Data::Object(fields)).unwrap());
                changed = true;
            } else {
                bytes.extend_from_slice(line.as_bytes());
            }
            bytes.push(b'\n');
        }
        assert!(changed, "captured {side} input");
        let path = root.join(format!("{side}.jsonl"));
        std::fs::write(&path, bytes).unwrap();
        let output = run(&path);
        if side == "outside" {
            caught |= output.status.code() != Some(status);
        } else {
            assert_ne!(
                output.status.code(),
                Some(status),
                "app mutation was not caught"
            );
        }
    }
    assert!(caught, "outside mutation was not caught");
}
