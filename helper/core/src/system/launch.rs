//! `dispatch-helper launch <key> [args...]`: a typed harness command in the user's own shell.
//! Like c1654cc CodexLauncher.swift:115-140 the launcher owns the prepared command (and any
//! private server the harness started) as its foreground child, forwards interrupt signals,
//! and exits with the child's status.
use super::System;
use crate::api::*;
use std::{cell::RefCell, io, os::unix::process::CommandExt, path::Path, process::Command, rc::Rc};

/// Discards updates: a launcher has no UI.
struct Silent;
impl Ui for Silent {
    fn update(&mut self, _: Update) {}
}

/// A harness names its program bare; this launcher's own shim for it may come first on `PATH`, and would run this
/// launcher again, forever. Past such a shim, the first real program; a command with nothing in the way is unchanged.
fn past_shims(command: Command) -> io::Result<Command> {
    let path = std::env::var("PATH").unwrap_or_default();
    let (Ok(image), Ok(cwd)) = (System::image().and_then(std::fs::metadata), System::cwd()) else { return Ok(command) };
    resolved(command, &path, &cwd, &image)
}

fn resolved(command: Command, path: &str, cwd: &Path, image: &std::fs::Metadata) -> io::Result<Command> {
    let Some(program) = command.get_program().to_str().filter(|name| !name.contains('/')).map(str::to_owned) else {
        return Ok(command);
    };
    if command.get_envs().any(|(name, _)| name == "PATH") {
        return Ok(command);
    }
    let directory = command.get_current_dir().unwrap_or(cwd).to_path_buf();
    let mut found = super::inspect::programs(&program, &directory, path, image);
    if !found.next().is_some_and(|(_, own)| own) {
        return Ok(command);
    }
    let (real, _) = found.find(|(_, own)| !own).ok_or(io::ErrorKind::NotFound)?;
    let mut direct = Command::new(real);
    direct.arg0(&program).args(command.get_args());
    if let Some(directory) = command.get_current_dir() {
        direct.current_dir(directory);
    }
    for (name, value) in command.get_envs() {
        match value {
            Some(value) => direct.env(name, value),
            None => direct.env_remove(name),
        };
    }
    Ok(direct)
}

pub fn run(io: &mut System, harness: Shared<dyn Harness>, arguments: &[String]) -> io::Result<i32> {
    let signals = io.signals(&[1, 2, 3, 15], false)?;
    io.section("launch");
    io.interest(signals, true, false)?;
    let prepared = Rc::new(RefCell::new(None));
    let saved = prepared.clone();
    harness.borrow_mut().launch(
        io,
        &System::cwd()?,
        arguments,
        Box::new(move |_, result| *saved.borrow_mut() = Some(result)),
    );
    let mut child = None;
    let mut forwarded = false;
    let mut finished = None;
    loop {
        io.callbacks();
        // An exit callback may submit cleanup whose completion submits more cleanup.
        // Finish accepted work before dropping System; passive watches do not hold it open.
        if let Some(status) = finished
            && io.jobs.is_empty()
            && io.continued.is_empty()
            && io.callbacks.is_empty()
            && io.later.is_empty()
        {
            return Ok(status);
        }
        if child.is_none()
            && let Some(result) = prepared.borrow_mut().take()
        {
            let command = result.map_err(|error| io::Error::other(error.code))?;
            io.section("launch");
            let program = std::path::PathBuf::from(command.get_program());
            // A replay's PATH is this machine's, not the recording's.
            let resolved = if io.capture.replay.is_some() { Ok(command) } else { past_shims(command) };
            let started = resolved.and_then(|command| io.launch(command, None, true, None));
            match started {
                Ok(spawned) => child = Some(spawned.pid),
                // Shell exit codes for a command that cannot run; old ssh-helper codex.rs:80-86.
                Err(error) => {
                    let name = program.file_name().unwrap_or(program.as_os_str());
                    eprintln!(
                        "dispatch: could not start {}: {error}",
                        name.to_string_lossy()
                    );
                    return Ok(if error.kind() == io::ErrorKind::NotFound {
                        127
                    } else {
                        126
                    });
                }
            }
        }
        let (section, event) = io.next()?;
        match event {
            Event::Exit { pid, status } if Some(pid) == child => {
                let process = Process {
                    pid,
                    parent: io.pid(),
                    group: 0,
                    foreground: 0,
                    tty: 0,
                    start: [0, 0],
                    executable: Default::default(),
                    arguments: arguments.to_vec(),
                    files: Vec::new(),
                };
                harness.borrow_mut().exited(io, &process, status);
                // System reports a signal death as 128 + signal, like the shell.
                finished = Some(status.unwrap_or(1));
            }
            Event::Ready { fd, .. } if fd == signals => {
                let mut bytes = [0; 4];
                if io.read(signals, &mut bytes)? != bytes.len() {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                let flags = u32::from_le_bytes(bytes);
                let number = (0..32).find(|n| flags & 1 << n != 0).unwrap_or(15);
                match child {
                    // Terminal signals already reach the child's process group; an explicit
                    // one (kill) ends the child with SIGTERM, then its Exit ends the launcher.
                    Some(pid) if !forwarded && finished.is_none() => {
                        forwarded = true;
                        io.section("launch");
                        io.terminate(pid)?;
                    }
                    None => return Ok(128 + number),
                    _ => {}
                }
            }
            // These events only schedule System-owned callbacks, drained at the loop boundary.
            event if !["then", "after"].contains(&section.as_str()) => {
                harness.borrow_mut().event(io, &mut Silent, event)
            }
            _ => {}
        }
    }
}

#[cfg(test)]
#[path = "launch.test.rs"]
mod tests;
