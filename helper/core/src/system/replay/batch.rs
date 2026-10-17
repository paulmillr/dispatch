//! Sequential, isolated replay of unchanged captures.
use crate::{json::{self, Data}, wire::body::Encoded};
use std::{
    fs::{self, File},
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

/// Every capture under `directory`, sorted: each regular `*.rpl.bz2` file but the app's mismatch diagnostics. A
/// symbolic link is not followed (listed on stderr): nothing outside the tree is read or pruned, and a loop ends.
pub fn captures(directory: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let (kind, path) = (entry.file_type()?, entry.path());
        if kind.is_symlink() {
            eprintln!("{}: a symbolic link, not followed", path.display());
        } else if kind.is_dir() {
            out.extend(captures(&path)?);
        } else if kind.is_file() && path.to_string_lossy().ends_with(".rpl.bz2") && !path.to_string_lossy().contains(".mismatch-") {
            out.push(path);
        }
    }
    out.sort();
    Ok(out)
}

/// Every helper capture under `directory` (relative paths, sorted). App journals beside them are
/// replayed by the app's tests; a capture that cannot be read is listed, so its own report row says why.
pub fn helpers(directory: &Path) -> io::Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for path in captures(directory)? {
        let app = File::open(&path).and_then(|file| crate::system::capture::trace::Reader::new(file, usize::MAX))
            .is_ok_and(|(_, header)| header.layer != crate::system::capture::trace::Layer::Native);
        if !app {
            paths.push(path.strip_prefix(directory).unwrap().to_owned());
        }
    }
    Ok(paths)
}

/// One capture's replay: pass, fail, timeout or skip, the replay's exit and why.
pub struct Replayed {
    pub capture: PathBuf,
    pub status: &'static str,
    pub exit: Option<i32>,
    pub diagnostic: String,
}

/// Replays `paths` (relative to `directory`) one by one, each in a process of this executable: the
/// helper that replays is always the running one, never another build. Each row also goes to
/// `output`/report.jsonl beside its stderr and mismatch artifacts.
pub fn replay(directory: &Path, paths: &[PathBuf], output: &Path, timeout: Duration, completion: bool) -> io::Result<Vec<Replayed>> {
    let helper = fs::canonicalize(std::env::current_exe()?)?;
    let mut rows = Vec::new();
    fs::DirBuilder::new().mode(0o700).create(&output)?;
    let output = fs::canonicalize(output)?;
    let mut report = File::options()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(output.join("report.jsonl"))?;
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
                if fs::metadata(&path)?.len() == 0 {
                    return Ok(("skip", None, "empty capture: the helper ended before recording anything".into()));
                }
                let (mut reader, _) = crate::system::capture::trace::Reader::new(
                    File::open(&path)?,
                    crate::wire::LIMIT as usize * 8,
                )?;
                let mut embedded = false;
                let mut entry = false;
                let mut terminal = false;
                // The recorded entry precedes the work; reading stops there (the helper checks the rest).
                for _ in 0.. {
                    let Some(record) = reader.next()? else {
                        break;
                    };
                    let (section, op) = (record.section.as_str(), record.op.as_str());
                    embedded |= section == "startup" && op == "context";
                    terminal |= section == "lifecycle" && matches!(op, "return" | "handoff" | "signal");
                    if (matches!(section, "startup" | "ui") && op == "stdio")
                        || (completion && matches!(op, "stdio" | "listen"))
                    {
                        entry = true;
                        break;
                    }
                }
                entry |= completion && embedded && terminal;
                if !entry || !embedded {
                    return Ok(("skip", None, if completion && embedded { "recorded startup has no completion boundary or server entry" } else if completion { "no supported recorded entry" } else { "no recorded stdio entry" }.into()));
                }
                let mut command = Command::new(&helper);
                command.arg("--stdio");
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
                // Completion: the replay consumed the whole recording and ended where it did; a recorded
                // return names the exit the replay must end with (a recording that just ends: 0).
                let completed = fs::symlink_metadata(&receipt).is_ok_and(|meta| meta.is_file());
                if stopped.is_none() && completion && !completed {
                    stopped = Some("replay completion was not verified");
                }
                if completed {
                    let mut bytes = Vec::new();
                    File::open(&receipt)?.take(4097).read_to_end(&mut bytes)?;
                    if bytes.len() > 4096 { return Err(io::Error::other("completion receipt exceeds bound")); }
                    if !bytes.is_empty() {
                        boundary = Some(Encoded::plain(&bytes).map_err(|_| io::Error::other("invalid completion receipt"))?);
                    }
                }
                let expected = boundary.as_ref().map_or(Some(0), |v| v.root().get("status").and_then(Data::signed));
                let ended = if completion { status.code().map(i64::from) == expected } else { status.success() };
                let mut bytes = Vec::new();
                File::open(&log)?.take(4096).read_to_end(&mut bytes)?;
                let diagnostic = String::from_utf8_lossy(&bytes).into_owned();
                Ok((
                    if stopped == Some("timeout") {
                        "timeout"
                    } else if stopped.is_some() || !ended {
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
        let elapsed = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
        let logname = log.to_string_lossy();
        let mismatch = artifacts.join("mismatch.value");
        let mismatch_name = mismatch.to_string_lossy();
        let mut fields = vec![
            ("capture", Data::String(&name)),
            ("status", Data::String(status)),
            ("rerun", Data::Bool(status != "pass")),
            ("milliseconds", Data::Unsigned(elapsed)),
            ("exit", code.map_or(Data::Null, |v| Data::Signed(v.into()))),
            ("completion", boundary.as_ref().map_or(Data::Null, Encoded::root)),
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
        rows.push(Replayed { capture: relative.clone(), status, exit: code, diagnostic });
    }
    Ok(rows)
}

#[cfg(test)]
#[path = "batch.test.rs"]
mod tests;
