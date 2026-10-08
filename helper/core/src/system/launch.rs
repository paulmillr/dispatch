//! `dispatch-helper launch <key> [args...]`: a typed harness command in the user's own shell.
//! Like c1654cc CodexLauncher.swift:115-140 the launcher owns the prepared command (and any
//! private server the harness started) as its foreground child, forwards interrupt signals,
//! and exits with the child's status.
use super::System;
use crate::api::*;
use std::{cell::RefCell, io, rc::Rc};

/// Discards updates: a launcher has no UI.
struct Silent;
impl Ui for Silent {
    fn update(&mut self, _: Update) {}
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
            match io.launch(command, None, true, None) {
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
