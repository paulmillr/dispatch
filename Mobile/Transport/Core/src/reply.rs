use std::sync::Mutex;
use tokio::sync::oneshot;

/// What Swift answers to a question.
pub enum Answer {
    Bool(bool),
    Strings(Vec<String>),
    Bytes(Vec<u8>),
    Cancel,
}

/// A one-shot answer slot handed to Swift as `dms_reply *`. Consumed by exactly one `dms_reply_*` call.
pub struct Reply(Mutex<Option<oneshot::Sender<Answer>>>);

impl Reply {
    /// The raw pointer for Swift and the receiver Rust awaits. A dropped receiver (the operation ended)
    /// makes the later answer a no-op.
    pub fn make() -> (*mut Reply, oneshot::Receiver<Answer>) {
        let (sender, receiver) = oneshot::channel();
        (Box::into_raw(Box::new(Reply(Mutex::new(Some(sender))))), receiver)
    }

    /// # Safety
    /// `reply` must come from `make` and not have been answered yet.
    pub unsafe fn answer(reply: *mut Reply, answer: Answer) {
        if reply.is_null() {
            return;
        }
        let reply = unsafe { Box::from_raw(reply) };
        if let Some(sender) = reply.0.lock().map(|mut slot| slot.take()).ok().flatten() {
            let _ = sender.send(answer);
        }
    }
}

/// A Swift context pointer: opaque, only passed back to Swift's callbacks.
#[derive(Clone, Copy)]
pub struct Context(pub *mut std::ffi::c_void);
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Context {
    /// By value, so closures capture the whole (Send) context rather than its raw pointer field.
    pub fn get(self) -> *mut std::ffi::c_void {
        self.0
    }
}
