//! The iPhone SSH engine: russh, driven from Swift through the C ABI in `include/dispatch_mobile_ssh.h`.
//!
//! One tokio runtime runs every session. Each operation completes through a C callback with the caller's
//! context pointer; questions to Swift (host key, keyboard-interactive prompts, external signatures) carry a
//! one-shot `dms_reply` that Swift answers exactly once, from any thread, whenever it is ready.

mod error;
mod exec;
pub mod ffi;
mod keys;
mod reply;
mod session;

pub use error::{Code, Failure};
pub use exec::{ExecEvents, Exit, exec};
pub use keys::{KeyInfo, LoadedKey};
pub use session::{AuthOutcome, BoxFuture, ConnectOptions, HostKey, Prompt, Session, SessionEvents, SignCallback};

use std::sync::OnceLock;
use tokio::runtime::Runtime;

/// The process-wide runtime: two workers are plenty for a phone's handful of hosts.
pub fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("dispatch-ssh")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}
