//! Native streams use the core's line framer and nonblocking IO.
use crate::native::error;
use dispatch_helper_core::{
    api::{Error, Io},
    rpc::Lines,
    system::queue::Queue,
};
use std::{io, os::fd::RawFd};

pub(super) const LIMIT: usize = 1_048_576;

pub struct Stream {
    pub input: RawFd,
    pub output: RawFd,
    pub lines: Lines,
    pub queue: Queue,
}
impl Stream {
    pub fn new(input: RawFd, output: RawFd) -> Self {
        Self {
            input,
            output,
            // Controller rasters retain the existing 16 MiB logical frame bound;
            // typed RPC sets the old helper's 1 MiB reply bound separately.
            lines: Lines::buffer(16 * 1024 * 1024),
            queue: Queue::new(LIMIT),
        }
    }
    pub fn send(&mut self, io: &mut dyn Io, mut bytes: Vec<u8>) -> Result<(), Error> {
        bytes.push(b'\n');
        self.queue
            .push(bytes)
            .map_err(|_| error("Herdr request exceeded the size limit."))?;
        io.interest(self.input, self.input == self.output, true)
            .map_err(|e| error(e.to_string()))
    }
    pub fn flush(&mut self, io: &mut dyn Io) -> Result<(), Error> {
        if let Some(front) = self.queue.front() {
            match io.write(self.input, front) {
                Ok(0) => return Err(error("Herdr connection closed while sending a request.")),
                Ok(n) => {
                    self.queue
                        .consume(n)
                        .map_err(|_| error("Invalid herdr write count."))?;
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) => {}
                Err(e) => return Err(error(e.to_string())),
            }
        }
        io.interest(
            self.input,
            self.input == self.output,
            self.queue.front().is_some(),
        )
        .map_err(|e| error(e.to_string()))
    }
    pub fn read(&mut self, io: &mut dyn Io) -> Result<(Vec<Vec<u8>>, bool), Error> {
        let mut bytes = [0u8; 65536];
        let mut records = Vec::new();
        match io.read(self.output, &mut bytes) {
            Ok(0) => Ok((records, true)),
            Ok(n) => {
                self.lines
                    .feed(&bytes[..n], |line| {
                        records.push(line.to_vec());
                        Ok(())
                    })
                    .map_err(|_| error("Invalid or oversized herdr line."))?;
                Ok((records, false))
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) =>
            {
                Ok((records, false))
            }
            Err(e) => Err(error(e.to_string())),
        }
    }
    pub fn close(self, io: &mut dyn Io) {
        io.close(self.input);
        if self.output != self.input {
            io.close(self.output);
        }
    }
}
