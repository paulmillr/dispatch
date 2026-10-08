//! A native RPC fork: the parent is reference context and owns no side pipe.
use crate::{
    bridge::{self, Shared},
    records::{LIMIT, text},
};
use dispatch_helper4_core::{
    api::*,
    json::{self, Data, Json},
    rpc,
};
use std::{
    io,
    os::fd::RawFd,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub struct Side {
    input: RawFd,
    output: RawFd,
    stderr: Option<RawFd>,
    bytes: Vec<u8>,
    offset: usize,
    lines: rpc::Lines,
    ready: bool,
    deadline: Instant,
    question: String,
    done: Option<Done<Binding>>,
    close: Option<Done<()>>,
}
pub fn start(
    runtime: &Shared,
    io: &mut dyn Io,
    parent: &Binding,
    question: &str,
    read_only: bool,
    done: Done<Binding>,
) {
    let parent = parent.clone();
    let question = question.to_owned();
    let saved = runtime.clone();
    bridge::call(
        runtime,
        io,
        &parent.clone(),
        "state",
        Vec::new(),
        Box::new(move |io, result| {
            let document = match result {
                Ok(value) => value,
                Err(e) => {
                    done(io, Err(e));
                    return;
                }
            };
            let state = document.root().get("state");
            let model = state
                .and_then(|value| value.get("model"))
                .map(|value| [text(value, "provider"), text(value, "id")]);
            let effort = state.map(|value| text(value, "effort")).unwrap_or_default();
            let mut record = saved
                .borrow()
                .registrations
                .get(&parent.process.pid)
                .expect("successful state exchange stores its registration")
                .clone();
            record.leaf = state
                .and_then(|value| value.get("leafId"))
                .and_then(dispatch_helper4_core::json::Value::string)
                .map(str::to_owned);
            let Some(path) = record.path else {
                done(
                    io,
                    Err(bridge::fail(
                        "side",
                        "Pi needs a saved session before it can fork a side conversation.",
                    )),
                );
                return;
            };
            let next = saved.clone();
            let transcript = path.clone();
            bridge::job(
                &saved,
                io,
                Job::Read {
                    path,
                    offset: 0,
                    length: 65536,
                },
                Box::new(move |io, result| {
                    let mut done = Some(done);
                    let result = (|| {
                        let Output::Read { bytes, .. } = result? else {
                            return Err(bridge::fail(
                                "side",
                                "The Pi session header is unavailable.",
                            ));
                        };
                        let end = bytes.iter().position(|v| *v == b'\n').ok_or_else(|| {
                            bridge::fail("side", "The Pi session header is unavailable.")
                        })?;
                        let header = Json::parse(&bytes[..end])?;
                        let cwd = text(header.root(), "cwd");
                        if text(header.root(), "id") != parent.session {
                            return Err(bridge::fail(
                                "changed",
                                "The parent Pi transcript changed.",
                            ));
                        }
                        let mut command = Command::new(&parent.process.executable);
                        if crate::harness::prefix(&parent.process) == Some(2) {
                            let cli = record.cli.as_deref()
                                .or_else(|| parent.process.arguments.get(1).map(String::as_str))
                                .filter(|v| v.ends_with("/cli.js"))
                                .ok_or_else(|| bridge::fail(
                                    "side",
                                    "Reload the current Dispatch Pi extension before starting a side conversation.",
                                ))?;
                            command.arg(cli);
                        }
                        let boundary = "You are in a separate side conversation. \
                            The inherited thread is reference context only. \
                            Do not continue its task or goal. \
                            Answer only new messages in this side conversation. \
                            Do not interact with the main thread or its agents.";
                        command
                            .current_dir(cwd)
                            .args(["--mode", "rpc", "--fork"])
                            .arg(transcript)
                            .arg("--append-system-prompt")
                            .arg(boundary)
                            .arg("--extension")
                            .arg(record.home.join("extensions/dispatch-chat.js"))
                            .env("PI_CODING_AGENT_DIR", &record.home)
                            .env("DISPATCH_PI_OWNED", "1")
                            .env("DISPATCH_PI_LEAF", record.leaf.unwrap_or_default())
                            .stdin(Stdio::piped())
                            .stdout(Stdio::piped())
                            .stderr(Stdio::piped());
                        if let Some(model) = model {
                            command.args(["--provider", &model[0], "--model", &model[1]]);
                        }
                        if !effort.is_empty() {
                            command.args(["--thinking", &effort]);
                        }
                        if read_only {
                            command.args([
                                "--tools",
                                "read,grep,find,ls",
                                "--no-extensions",
                                "--no-skills",
                                "--no-prompt-templates",
                            ]);
                        }
                        let mut bytes = json::write(&Data::Object(vec![
                            ("type", Data::String("prompt")),
                            ("message", Data::String("/dispatch-side-initialize")),
                        ]))?;
                        bytes.push(b'\n');
                        let spawned = io
                            .spawn(command, None)
                            .map_err(|e| bridge::fail("side", e.to_string()))?;
                        let input = spawned.input.expect("configured Pi side stdin pipe");
                        let output = spawned.output.expect("configured Pi side stdout pipe");
                        let deadline = io.now() + Duration::from_secs(10);
                        next.borrow_mut().sides.insert(
                            spawned.pid,
                            Side {
                                input,
                                output,
                                stderr: spawned.stderr,
                                bytes,
                                offset: 0,
                                lines: rpc::Lines::new(LIMIT),
                                ready: false,
                                deadline,
                                question,
                                done: done.take(),
                                close: None,
                            },
                        );
                        io.timer(deadline);
                        let setup = io
                            .child(spawned.pid)
                            .and_then(|_| io.interest(input, false, true))
                            .and_then(|_| io.interest(output, true, false))
                            .and_then(|_| {
                                spawned
                                    .stderr
                                    .map_or(Ok(()), |fd| io.interest(fd, true, false))
                            });
                        if let Err(e) = setup {
                            finish(
                                &next,
                                io,
                                spawned.pid,
                                Some(bridge::fail("side", e.to_string())),
                            );
                        }
                        Ok(())
                    })();
                    // `done` moves into the live side only after all fallible preparation.
                    if let Err(error) = result {
                        deferred(done.take().unwrap())(io, Err(error));
                    }
                }),
            );
        }),
    );
}
pub fn close(runtime: &Shared, io: &mut dyn Io, binding: &Binding, done: Done<()>) {
    let mut runtime = runtime.borrow_mut();
    let Some(side) = runtime.sides.get_mut(&binding.process.pid) else {
        io.defer(Box::new(move |io| done(io, Ok(()))));
        return;
    };
    if side.close.is_some() {
        io.defer(Box::new(move |io| {
            done(
                io,
                Err(bridge::fail(
                    "side",
                    "The side conversation is already closing.",
                )),
            )
        }));
        return;
    }
    io.close(side.input);
    side.input = -1;
    side.close = Some(done);
}
fn finish(runtime: &Shared, io: &mut dyn Io, pid: u32, error: Option<Error>) {
    let Some(mut side) = runtime.borrow_mut().sides.remove(&pid) else {
        return;
    };
    if side.input >= 0 {
        io.close(side.input);
    }
    io.close(side.output);
    if let Some(fd) = side.stderr {
        io.close(fd);
    }
    if let Some(done) = side.done.take() {
        done(
            io,
            Err(error.clone().unwrap_or_else(|| {
                bridge::fail("side", "Pi exited before the side conversation was ready.")
            })),
        );
    }
    if let Some(done) = side.close.take() {
        done(io, error.map_or(Ok(()), Err));
    }
}
pub fn event(runtime: &Shared, io: &mut dyn Io, event: &Event) {
    match *event {
        Event::Exit { pid, .. } => finish(runtime, io, pid, None),
        Event::Timer { .. } => {
            let expired = runtime
                .borrow()
                .sides
                .iter()
                .filter_map(|(&pid, s)| (!s.ready && s.deadline <= io.now()).then_some(pid))
                .collect::<Vec<_>>();
            for pid in expired {
                finish(
                    runtime,
                    io,
                    pid,
                    Some(bridge::fail(
                        "deadline",
                        "Pi did not finish starting the side conversation.",
                    )),
                );
            }
        }
        Event::Ready { fd, read, write } => {
            let pid = runtime.borrow().sides.iter().find_map(|(&pid, s)| {
                (s.input == fd || s.output == fd || s.stderr == Some(fd)).then_some(pid)
            });
            let Some(pid) = pid else {
                return;
            };
            let mut ready = false;
            let mut error = None;
            {
                let mut runtime = runtime.borrow_mut();
                let side = runtime.sides.get_mut(&pid).unwrap();
                if write && fd == side.input && side.offset < side.bytes.len() {
                    match io.write(fd, &side.bytes[side.offset..]) {
                        Ok(0) => error = Some(io::ErrorKind::WriteZero.into()),
                        Ok(n) => side.offset += n,
                        Err(e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(e) => error = Some(e),
                    }
                    let _ = io.interest(fd, false, side.offset < side.bytes.len());
                }
                if read && fd == side.output {
                    let mut bytes = [0; 65536];
                    match io.read(fd, &mut bytes) {
                        Ok(0) => {
                            let _ = io.interest(fd, false, false);
                        }
                        Ok(n) => {
                            if side
                                .lines
                                .feed(&bytes[..n], |line| {
                                    let document =
                                        Json::parse(line).map_err(|_| rpc::Error::Shape)?;
                                    let root = document.root();
                                    ready |= text(root, "type") == "extension_ui_request"
                                        && text(root, "method") == "notify"
                                        && text(root, "message") == "dispatch-side-ready";
                                    Ok(())
                                })
                                .is_err()
                            {
                                error = Some(io::ErrorKind::InvalidData.into());
                            }
                        }
                        Err(e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(e) => error = Some(e),
                    }
                }
                if read && side.stderr == Some(fd) {
                    let mut bytes = [0; 65536];
                    match io.read(fd, &mut bytes) {
                        Ok(0) => {
                            let _ = io.interest(fd, false, false);
                        }
                        Ok(_) => {}
                        Err(e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                            ) => {}
                        Err(e) => error = Some(e),
                    }
                }
            }
            if let Some(error) = error {
                finish(
                    runtime,
                    io,
                    pid,
                    Some(bridge::fail("side", error.to_string())),
                );
                return;
            }
            if ready {
                runtime.borrow_mut().sides.get_mut(&pid).unwrap().ready = true;
                let next = runtime.clone();
                bridge::job(
                    runtime,
                    io,
                    Job::Process { pid },
                    Box::new(move |io, result| {
                        let process = match result {
                            Ok(Output::Process(p)) => p,
                            Ok(_) => {
                                finish(
                                    &next,
                                    io,
                                    pid,
                                    Some(bridge::fail(
                                        "side",
                                        "Pi process identity is unavailable.",
                                    )),
                                );
                                return;
                            }
                            Err(e) => {
                                finish(&next, io, pid, Some(e));
                                return;
                            }
                        };
                        let saved = next.clone();
                        bridge::registration(
                            &next,
                            io,
                            &process.clone(),
                            Box::new(move |io, result| {
                                let record = match result {
                                    Ok(v) => v,
                                    Err(e) => {
                                        finish(&saved, io, pid, Some(e));
                                        return;
                                    }
                                };
                                let binding = Binding {
                                    session: record.session,
                                    transcript: record.path,
                                    process,
                                };
                                let next = saved.clone();
                                let question =
                                    saved.borrow().sides.get(&pid).map(|s| s.question.clone());
                                let Some(question) = question else {
                                    return;
                                };
                                bridge::call(
                                    &saved,
                                    io,
                                    &binding.clone(),
                                    "prompt",
                                    vec![("text", Data::String(&question))],
                                    Box::new(move |io, result| match result {
                                        Ok(_) => {
                                            let done = next
                                                .borrow_mut()
                                                .sides
                                                .get_mut(&pid)
                                                .and_then(|s| s.done.take());
                                            if let Some(done) = done {
                                                done(io, Ok(binding));
                                            }
                                        }
                                        Err(e) => finish(&next, io, pid, Some(e)),
                                    }),
                                );
                            }),
                        );
                    }),
                );
            }
        }
        _ => {}
    }
}
