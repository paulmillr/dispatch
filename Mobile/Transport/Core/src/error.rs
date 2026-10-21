/// Result codes shared with Swift (`DMS_*` in the header).
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Code {
    Ok = 0,
    /// The server refused this credential; others may still work.
    AuthFailed = 1,
    /// TCP or socket failure (unreachable, reset).
    Network = -1,
    Timeout = -2,
    HostKeyRejected = -3,
    /// SSH protocol error, or the connection closed mid-operation.
    Protocol = -4,
    InvalidKey = -5,
    WrongPassphrase = -6,
    Cancelled = -7,
    Unsupported = -8,
    /// The connection is closed.
    Closed = -9,
    /// The remote refused the channel request (exec).
    Refused = -10,
    /// Name resolution found no address for the host.
    HostNotFound = -11,
    /// Nothing accepted the TCP connection on the port.
    ConnectionRefused = -12,
    /// No route to the host from this network (also: Local Network access denied on iOS).
    Unreachable = -13,
    /// The host did not answer the TCP connection before the deadline.
    NoAnswer = -14,
}

#[derive(Debug)]
pub struct Failure {
    pub code: Code,
    pub message: String,
}

impl Failure {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Failure { code, message: message.into() }
    }
}

impl From<russh::Error> for Failure {
    fn from(error: russh::Error) -> Self {
        let code = match &error {
            russh::Error::UnknownKey => Code::HostKeyRejected,
            russh::Error::IO(error) => return Failure::io(error),
            russh::Error::KeepaliveTimeout | russh::Error::InactivityTimeout => {
                return Failure::new(Code::Timeout, "the host stopped answering");
            }
            russh::Error::ConnectionTimeout => Code::Timeout,
            russh::Error::Disconnect | russh::Error::SendError | russh::Error::RecvError | russh::Error::HUP => Code::Closed,
            _ => Code::Protocol,
        };
        Failure::new(code, error.to_string())
    }
}

impl Failure {
    /// A socket error by what it means for the user: refused, unreachable, no answer; else the OS's text.
    pub fn io(error: &std::io::Error) -> Self {
        use std::io::ErrorKind::*;
        let code = match error.kind() {
            ConnectionRefused => Code::ConnectionRefused,
            NetworkUnreachable | HostUnreachable | NetworkDown | AddrNotAvailable => Code::Unreachable,
            TimedOut => Code::NoAnswer,
            ConnectionReset | ConnectionAborted | BrokenPipe | UnexpectedEof => {
                return Failure::new(Code::Closed, "the connection was reset");
            }
            _ => Code::Network,
        };
        Failure::new(code, error.to_string())
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}
