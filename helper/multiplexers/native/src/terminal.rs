use dispatch_helper_core::api::*;
use std::{collections::VecDeque, io};

// c1654cc ssh-helper relay.rs:8. Retain at most the existing input window.
const LIMIT: usize = 1_048_576;

pub(crate) struct Input {
    pub bytes: Vec<u8>,
    pub offset: usize,
    pub ends: VecDeque<usize>,
    pub process: Option<Process>,
    pub done: Done<()>,
}

pub(crate) struct Terminal {
    pub node: Node,
    pub title: String,
    pub child: Spawned,
    pub reader: std::os::fd::RawFd,
    pub writer: std::os::fd::RawFd,
    pub observed: Option<Process>,
    pub control: Option<Process>,
    pub client: Option<Process>,
    pub screen: Option<Screen>,
    pub output: Vec<u8>,
    pub group: Option<i32>,
    pub members: Vec<Process>,
    pub candidates: Vec<Process>,
    pub retry: Option<(std::time::Instant, u8, std::time::Duration)>,
    pub changed: bool,
    pub waiters: Vec<Done<Screen>>,
    pub input: VecDeque<Input>,
    pub retained: usize,
    pub checking: bool,
    pub discovering: bool,
    pub scan: Option<std::time::Instant>,
    pub refresh: bool,
    pub attached: bool,
    pub eof: bool,
    pub closed: bool,
    pub exited: bool,
}

pub(crate) fn error(code: &'static str, message: impl std::fmt::Display) -> Error {
    Error {
        code,
        message: message.to_string(),
    }
}

fn partial(failure: &Error) -> Error {
    let reason = if failure.message.is_empty() {
        failure.code
    } else {
        &failure.message
    };
    error("uncertain", reason)
}

impl Terminal {
    pub fn queue(
        &mut self,
        bytes: &[u8],
        process: Option<Process>,
        done: Done<()>,
    ) -> Result<(), Done<()>> {
        if self.closed || self.exited || bytes.len() > LIMIT - self.retained {
            return Err(done);
        }
        self.retained += bytes.len();
        self.input.push_back(Input {
            bytes: bytes.into(),
            offset: 0,
            ends: VecDeque::from([bytes.len()]),
            process,
            done,
        });
        Ok(())
    }

    pub fn interest(&self, io: &mut dyn Io) -> io::Result<()> {
        if self.closed || self.exited {
            return Ok(());
        }
        let writing = !self.checking && !self.input.is_empty();
        io.interest(
            self.reader,
            !self.eof && (self.attached || self.output.len() < LIMIT),
            writing && self.writer == self.reader,
        )?;
        if self.writer != self.reader {
            io.interest(self.writer, false, writing)?;
        }
        Ok(())
    }

    pub fn read(&mut self, io: &mut dyn Io, ui: &mut dyn Ui) -> bool {
        self.flush(ui);
        let available = if self.attached {
            LIMIT
        } else {
            LIMIT - self.output.len()
        };
        if available == 0 || self.eof {
            return false;
        }
        let mut bytes = [0; 65_536];
        let size = bytes.len().min(available);
        let result = io.read(self.reader, &mut bytes[..size]);
        let received = result.as_ref().is_ok_and(|count| *count > 0);
        match result {
            Ok(0) => self.eof = true,
            Ok(count) if self.attached => ui.update(Update::Output {
                terminal: self.node.id,
                bytes: bytes[..count].into(),
            }),
            Ok(count) => self.output.extend_from_slice(&bytes[..count]),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) => {}
            Err(_) => self.eof = true,
        }
        let _ = self.interest(io);
        received
    }

    pub fn flush(&mut self, ui: &mut dyn Ui) {
        if self.attached && !self.closed && !self.output.is_empty() {
            ui.update(Update::Output {
                terminal: self.node.id,
                bytes: std::mem::take(&mut self.output),
            });
        }
    }

    pub fn write(&mut self, io: &mut dyn Io) -> Vec<(Done<()>, Result<(), Error>)> {
        let mut finished = Vec::new();
        if let Some(input) = self.input.front_mut() {
            let result = if input.offset == input.bytes.len() {
                Ok(0)
            } else {
                io.write(
                    self.writer,
                    &input.bytes[input.offset..*input.ends.front().unwrap()],
                )
            };
            match result {
                Ok(0) if input.offset != input.bytes.len() => {
                    finished = self.fail(error("input_closed", ""));
                }
                Ok(count) => {
                    input.offset += count;
                    if input.ends.front() == Some(&input.offset) {
                        input.ends.pop_front();
                    }
                    if input.offset == input.bytes.len() {
                        finished.push(self.finish(Ok(())));
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                Err(failure) => {
                    finished = self.fail(error("io_failure", failure));
                }
            }
        }
        if let Err(failure) = self.interest(io) {
            finished.extend(self.fail(error("io_failure", failure)));
        }
        finished
    }

    pub fn finish(&mut self, result: Result<(), Error>) -> (Done<()>, Result<(), Error>) {
        let input = self.input.pop_front().unwrap();
        self.retained -= input.bytes.len();
        let result = result.map_err(|failure| {
            if input.offset == 0 {
                failure
            } else {
                partial(&failure)
            }
        });
        (input.done, result)
    }

    pub fn fail(&mut self, failure: Error) -> Vec<(Done<()>, Result<(), Error>)> {
        self.retained = 0;
        self.checking = false;
        self.input
            .drain(..)
            .map(|input| {
                let failure = if input.offset == 0 {
                    failure.clone()
                } else {
                    partial(&failure)
                };
                (input.done, Err(failure))
            })
            .collect()
    }

    pub fn close(&mut self, io: &mut dyn Io) -> io::Result<()> {
        if self.closed {
            return Ok(());
        }
        io.hangup(self.writer)?;
        if self.reader != self.writer {
            io.close(self.reader);
        }
        if let Some(stderr) = self.child.stderr {
            io.close(stderr);
        }
        self.closed = true;
        Ok(())
    }
}
