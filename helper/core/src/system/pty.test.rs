use super::*;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;

/// `native::unread` counts what the master wrote and the slave has not read (a complete line in canonical mode),
/// and nothing once the slave read it.
#[test]
fn unread_counts_bytes_the_slave_has_not_read() {
    let (master, slave) = native::pty(Grid { columns: 80, rows: 24, pixels: None }, None).unwrap();
    assert_eq!(native::unread(slave.as_raw_fd()).unwrap(), 0);
    (&master).write_all(b"hello\n").unwrap();
    assert_eq!(native::unread(slave.as_raw_fd()).unwrap(), 6);
    let mut bytes = [0; 16];
    assert_eq!((&slave).read(&mut bytes).unwrap(), 6);
    assert_eq!(native::unread(slave.as_raw_fd()).unwrap(), 0);
}
