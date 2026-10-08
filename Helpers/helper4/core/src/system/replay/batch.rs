//! Sequential, isolated replay of unchanged captures.
use crate::json::{self, Data, Json};
use std::{
    fs::{self, File},
    io::{self, BufRead, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// Returns false if any selected case failed, timed out, was skipped, or no case ran.
/// Lists are JSON arrays of paths relative to DIR. Contexts are keyed by those
/// paths and contain {cwd, env, args}; they are required for legacy captures.
/// Completion-required mode admits bridge/listener entries only with a receipt
/// from finish_replay. The default remains compatible with older stdio helpers.
pub fn run(args: &[String]) -> io::Result<bool> {
    if args.len() < 2 || args.len() % 2 != 0 {
        return Err(io::Error::other(
            "usage: capture-redact --replay-batch DIR HELPER [--list FILE] [--contexts FILE] [--output DIR] [--timeout SECONDS] [--completion required]",
        ));
    }
    let directory = fs::canonicalize(&args[0])?;
    let helper = fs::canonicalize(&args[1])?;
    let mut list = None;
    let mut contexts = None;
    let mut output = directory.join(format!("replay-results-{}", std::process::id()));
    let mut timeout = Duration::from_secs(20);
    let mut completion = false;
    for pair in args[2..].chunks_exact(2) {
        match pair[0].as_str() {
            "--completion" if pair[1] == "required" => completion = true,
            "--list" => list = Some(document(Path::new(&pair[1]))?),
            "--contexts" => contexts = Some(document(Path::new(&pair[1]))?),
            "--output" => output = PathBuf::from(&pair[1]),
            "--timeout" => {
                timeout = Duration::from_secs(
                    pair[1]
                        .parse()
                        .map_err(|_| io::Error::other("invalid timeout"))?,
                );
                if timeout.is_zero() {
                    return Err(io::Error::other("timeout must be positive"));
                }
            }
            _ => return Err(io::Error::other("unknown batch option")),
        }
    }
    if contexts
        .as_ref()
        .is_some_and(|value| value.root().object().is_none())
    {
        return Err(io::Error::other(
            "contexts must be an object keyed by capture path",
        ));
    }
    let mut paths = Vec::new();
    if let Some(list) = list {
        for value in list
            .root()
            .array()
            .ok_or_else(|| io::Error::other("list must be an array"))?
        {
            paths.push(PathBuf::from(
                value
                    .string()
                    .ok_or_else(|| io::Error::other("list entries must be paths"))?,
            ));
        }
    } else {
        let mut directories = vec![directory.clone()];
        for index in 0.. {
            let Some(parent) = directories.get(index) else {
                break;
            };
            let entries = fs::read_dir(parent)?.collect::<io::Result<Vec<_>>>()?;
            for entry in entries {
                let kind = entry.file_type()?;
                if kind.is_dir() {
                    directories.push(entry.path());
                } else if kind.is_file() && entry.path().extension().is_some_and(|v| v == "jsonl") {
                    paths.push(entry.path().strip_prefix(&directory).unwrap().to_owned());
                }
            }
        }
        paths.sort();
    }
    fs::DirBuilder::new().mode(0o700).create(&output)?;
    let output = fs::canonicalize(output)?;
    let mut report = File::options()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(output.join("report.jsonl"))?;
    let mut counts = [0usize; 4];
    for (index, relative) in paths.iter().enumerate() {
        let started = Instant::now();
        let name = relative.to_string_lossy();
        let log = output.join(format!("{index:06}.stderr"));
        let receipt = output.join(format!("{index:06}.complete"));
        let mut boundary = None;
        let artifacts = output.join(format!("{index:06}.mismatch"));
        let result =
            (|| -> io::Result<(&str, Option<i32>, String)> {
                let path = fs::canonicalize(directory.join(relative))?;
                if !path.starts_with(&directory) {
                    return Err(io::Error::other("capture lies outside DIR"));
                }
                let mut reader = io::BufReader::new(File::open(&path)?);
                let mut embedded = false;
                let mut entry = false;
                let mut terminal = false;
                loop {
                    let mut line = Vec::new();
                    let limit = crate::wire::LIMIT as u64 * 8;
                    if reader
                        .by_ref()
                        .take(limit + 1)
                        .read_until(b'\n', &mut line)?
                        == 0
                    {
                        break;
                    }
                    if line.len() as u64 > limit {
                        return Err(io::Error::other("capture row exceeds bound"));
                    }
                    let json =
                        Json::parse(&line).map_err(|_| io::Error::other("invalid capture JSON"))?;
                    let row = json.root();
                    if row.get("invalid").is_some() {
                        return Err(io::Error::other("capture is marked invalid"));
                    }
                    let section = row.get("section").and_then(|v| v.string());
                    let op = row.get("op").and_then(|v| v.string());
                    if section.is_none() || op.is_none() {
                        return Ok(("skip", None, "not a System capture".into()));
                    }
                    embedded |= section == Some("startup") && op == Some("context");
                    terminal |= section == Some("lifecycle") && matches!(op, Some("return" | "handoff" | "signal"));
                    if (matches!(section, Some("startup" | "ui")) && op == Some("stdio"))
                        || (completion && matches!(op, Some("stdio" | "listen")))
                    {
                        entry = true;
                        break;
                    }
                }
                entry |= completion && embedded && terminal;
                if !entry {
                    return Ok(("skip", None, if completion && embedded { "recorded startup has no completion boundary or server entry" } else if completion { "no supported recorded entry" } else { "no recorded stdio entry" }.into()));
                }
                let context = contexts.as_ref().and_then(|v| v.root().get(&name));
                if !embedded && context.is_none() {
                    return Ok((
                        "skip",
                        None,
                        "legacy capture has no supplied launch context".into(),
                    ));
                }
                let mut command = Command::new(&helper);
                if let Some(context) = context {
                    let cwd = context
                        .get("cwd")
                        .and_then(|v| v.string())
                        .ok_or_else(|| io::Error::other("context requires cwd"))?;
                    let environment = context
                        .get("env")
                        .and_then(|v| v.object())
                        .ok_or_else(|| io::Error::other("context requires env object"))?;
                    let arguments = context
                        .get("args")
                        .and_then(|v| v.array())
                        .ok_or_else(|| io::Error::other("context requires args array"))?;
                    command.env_clear().current_dir(cwd);
                    for (key, value) in environment {
                        command.env(
                            key,
                            value.string().ok_or_else(|| {
                                io::Error::other("context env must contain strings")
                            })?,
                        );
                    }
                    for value in arguments {
                        command.arg(value.string().ok_or_else(|| {
                            io::Error::other("context args must contain strings")
                        })?);
                    }
                } else {
                    command.arg("--stdio");
                }
                // A parent replay/record session must never affect this child.
                for (key, _) in std::env::vars_os() {
                    if key.as_encoded_bytes().starts_with(b"DISPATCH_REPLAY")
                        || key == "DISPATCH_CAPTURE"
                    {
                        command.env_remove(key);
                    }
                }
                command
                    .env_remove("DISPATCH_CAPTURE")
                    .env_remove("DISPATCH_REPLAY_OUTPUT")
                    .env("DISPATCH_REPLAY", path)
                    .env("DISPATCH_REPLAY_DIAGNOSTICS", &artifacts)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null());
                if completion {
                    command.env("DISPATCH_REPLAY_COMPLETE", &receipt);
                }
                if let Some(image) = std::env::var_os("DISPATCH_REPLAY_IMAGE") {
                    command.env("DISPATCH_REPLAY_IMAGE", image);
                }
                let diagnostics = File::options()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&log)?;
                command.stderr(diagnostics);
                let deadline = Instant::now()
                    .checked_add(timeout)
                    .ok_or_else(|| io::Error::other("timeout is too large"))?;
                let mut child = command.spawn()?;
                let mut stopped = None;
                let status = loop {
                    match child.try_wait() {
                        Ok(Some(status)) => break status,
                        Ok(None) => {}
                        Err(error) => {
                            let _ = child.kill();
                            let _ = child.wait();
                            return Err(error);
                        }
                    }
                    if Instant::now() >= deadline {
                        stopped = Some("timeout");
                    } else {
                        match fs::metadata(&log) {
                            Ok(metadata) if metadata.len() > 1_048_576 => {
                                stopped = Some("diagnostic limit exceeded")
                            }
                            Ok(_) => {}
                            Err(error) => {
                                let _ = child.kill();
                                let _ = child.wait();
                                return Err(error);
                            }
                        }
                    }
                    if stopped.is_some() {
                        let _ = child.kill();
                        break child.wait()?;
                    }
                    std::thread::sleep(Duration::from_millis(1));
                };
                if stopped.is_none() && status.success() && completion
                    && !fs::symlink_metadata(&receipt).is_ok_and(|meta| meta.is_file())
                {
                    stopped = Some("replay completion was not verified");
                }
                if receipt.is_file() {
                    let mut bytes = Vec::new();
                    File::open(&receipt)?.take(4097).read_to_end(&mut bytes)?;
                    if bytes.len() > 4096 { return Err(io::Error::other("completion receipt exceeds bound")); }
                    if !bytes.is_empty() {
                        boundary = Some(Json::parse(&bytes).map_err(|_| io::Error::other("invalid completion receipt"))?);
                    }
                }
                let mut bytes = Vec::new();
                File::open(&log)?.take(4096).read_to_end(&mut bytes)?;
                let diagnostic = String::from_utf8_lossy(&bytes).into_owned();
                Ok((
                    if stopped == Some("timeout") {
                        "timeout"
                    } else if stopped.is_some() || !status.success() {
                        "fail"
                    } else {
                        "pass"
                    },
                    status.code(),
                    stopped.map_or(diagnostic.clone(), |reason| {
                        format!("{reason}\n{diagnostic}")
                    }),
                ))
            })();
        let (status, code, diagnostic) =
            result.unwrap_or_else(|error| ("fail", None, error.to_string()));
        counts[match status {
            "pass" => 0,
            "fail" => 1,
            "timeout" => 2,
            _ => 3,
        }] += 1;
        let elapsed = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
        let logname = log.to_string_lossy();
        let mismatch = artifacts.join("mismatch.json");
        let mismatch_name = mismatch.to_string_lossy();
        let mut fields = vec![
            ("capture", Data::String(&name)),
            ("status", Data::String(status)),
            ("rerun", Data::Bool(status != "pass")),
            ("milliseconds", Data::Unsigned(elapsed)),
            ("exit", code.map_or(Data::Null, |v| Data::Signed(v.into()))),
            ("completion", boundary.as_ref().map_or(Data::Null, |v| Data::Value(v.root()))),
            (
                "stderr",
                if log.exists() {
                    Data::String(&logname)
                } else {
                    Data::Null
                },
            ),
            ("diagnostic", Data::String(&diagnostic)),
        ];
        if mismatch.is_file() { fields.push(("mismatch", Data::String(&mismatch_name))); }
        let value = json::write(&Data::Object(fields))
        .map_err(|_| io::Error::other("cannot encode report"))?;
        report.write_all(&value)?;
        report.write_all(b"\n")?;
        report.flush()?;
        println!("{status}\t{elapsed}ms\t{name}");
    }
    println!(
        "{} passed; {} failed; {} timed out; {} skipped; report: {}",
        counts[0],
        counts[1],
        counts[2],
        counts[3],
        output.join("report.jsonl").display()
    );
    Ok(counts[0] > 0 && counts[1..].iter().all(|count| *count == 0))
}

fn document(path: &Path) -> io::Result<Json> {
    let mut bytes = Vec::new();
    File::open(path)?
        .take(crate::wire::LIMIT as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > crate::wire::LIMIT as usize {
        return Err(io::Error::other("batch metadata exceeds bound"));
    }
    Json::parse(&bytes).map_err(|_| io::Error::other("invalid batch metadata JSON"))
}
