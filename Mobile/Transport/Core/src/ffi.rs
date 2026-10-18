//! The C ABI of include/dispatch_mobile_ssh.h.
#![allow(clippy::missing_safety_doc)]

use crate::error::{Code, Failure};
use crate::exec::{ExecEvents, Exit, exec};
use crate::keys::LoadedKey;
use crate::reply::{Answer, Context, Reply};
use crate::runtime;
use crate::session::{AuthOutcome, BoxFuture, ConnectOptions, HostKey, Prompt, Session, SessionEvents};
use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr;
use std::sync::Arc;
use std::time::Duration;
use zeroize::Zeroizing;

#[repr(C)]
pub struct DmsHostKey {
    pub algorithm: *const c_char,
    pub blob: *const u8,
    pub blob_length: usize,
    pub fingerprint: *const c_char,
    pub openssh: *const c_char,
}

#[repr(C)]
pub struct DmsPrompt {
    pub text: *const c_char,
    pub echo: bool,
}

#[repr(C)]
pub struct DmsConnectOptions {
    pub host: *const c_char,
    pub port: u16,
    pub timeout_ms: u32,
    pub keepalive_interval_ms: u32,
    pub keepalive_max: u32,
}

pub type HostKeyFn = unsafe extern "C" fn(*mut c_void, *const DmsHostKey, *mut Reply);
pub type DisconnectedFn = unsafe extern "C" fn(*mut c_void, i32, *const c_char);
pub type ConnectedFn = unsafe extern "C" fn(*mut c_void, *mut DmsSession, i32, *const c_char);
pub type AuthFn = unsafe extern "C" fn(*mut c_void, i32, u32, bool, *const c_char);
pub type PromptFn = unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char, *const DmsPrompt, usize, *mut Reply);
pub type SignFn = unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut Reply);
pub type StartedFn = unsafe extern "C" fn(*mut c_void, i32, i32, *const c_char);
pub type StderrFn = unsafe extern "C" fn(*mut c_void, *const u8, usize);
pub type ExitedFn = unsafe extern "C" fn(*mut c_void, i32, u32, *const c_char);

#[repr(C)]
pub struct DmsSessionCallbacks {
    pub context: *mut c_void,
    pub host_key: Option<HostKeyFn>,
    pub disconnected: Option<DisconnectedFn>,
}

pub struct DmsSession(Arc<Session>);
pub use crate::reply::Reply as DmsReply;

pub struct DmsKey {
    key: LoadedKey,
    algorithm: CString,
    public_key: CString,
    fingerprint: CString,
}

fn c_string(text: &str) -> CString {
    CString::new(text.replace('\0', " ")).unwrap_or_default()
}

unsafe fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(pointer) }.to_str().ok().map(str::to_owned)
}

/// A secret's copy (a password, a passphrase), wiped when dropped.
unsafe fn secret(pointer: *const c_char) -> Option<Zeroizing<String>> {
    unsafe { text(pointer) }.map(Zeroizing::new)
}

struct FfiSessionEvents {
    context: Context,
    host_key: Option<HostKeyFn>,
    disconnected: Option<DisconnectedFn>,
}

impl SessionEvents for FfiSessionEvents {
    fn host_key(&self, key: HostKey) -> BoxFuture<bool> {
        let Some(callback) = self.host_key else { return Box::pin(async { false }) };
        let (reply, answer) = Reply::make();
        let algorithm = c_string(&key.algorithm);
        let fingerprint = c_string(&key.fingerprint);
        let openssh = c_string(&key.openssh);
        let record = DmsHostKey {
            algorithm: algorithm.as_ptr(),
            blob: key.blob.as_ptr(),
            blob_length: key.blob.len(),
            fingerprint: fingerprint.as_ptr(),
            openssh: openssh.as_ptr(),
        };
        unsafe { callback(self.context.get(), &record, reply) };
        Box::pin(async move { matches!(answer.await, Ok(Answer::Bool(true))) })
    }

    fn disconnected(&self, code: Code, message: String) {
        if let Some(callback) = self.disconnected {
            let message = c_string(&message);
            unsafe { callback(self.context.get(), code as i32, message.as_ptr()) };
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn dms_version() -> *const c_char {
    concat!("dispatch-mobile-ssh ", env!("CARGO_PKG_VERSION"), " (russh 0.64.1)\0").as_ptr().cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_connect(
    options: *const DmsConnectOptions,
    callbacks: DmsSessionCallbacks,
    context: *mut c_void,
    connected: Option<ConnectedFn>,
) {
    let context = Context(context);
    let Some(connected) = connected else { return };
    let options = unsafe { options.as_ref() }.and_then(|options| {
        Some(ConnectOptions {
            host: unsafe { text(options.host) }?,
            port: options.port,
            timeout: Duration::from_millis(u64::from(options.timeout_ms.max(1))),
            keepalive_interval: Duration::from_millis(u64::from(options.keepalive_interval_ms)),
            keepalive_max: options.keepalive_max as usize,
        })
    });
    let Some(mut options) = options else {
        let message = c_string("invalid connect options");
        unsafe { connected(context.get(), ptr::null_mut(), Code::Protocol as i32, message.as_ptr()) };
        return;
    };
    if options.keepalive_interval.is_zero() {
        options.keepalive_interval = Duration::from_secs(3600 * 24);
        options.keepalive_max = 0;
    }
    let events = Arc::new(FfiSessionEvents {
        context: Context(callbacks.context),
        host_key: callbacks.host_key,
        disconnected: callbacks.disconnected,
    });
    runtime().spawn(async move {
        let context = context;
        match Session::connect(options, events).await {
            Ok(session) => {
                let handle = Box::into_raw(Box::new(DmsSession(session)));
                unsafe { connected(context.get(), handle, Code::Ok as i32, c"".as_ptr()) };
            }
            Err(failure) => {
                let message = c_string(&failure.message);
                unsafe { connected(context.get(), ptr::null_mut(), failure.code as i32, message.as_ptr()) };
            }
        }
    });
}

unsafe fn session(handle: *mut DmsSession) -> Option<Arc<Session>> {
    unsafe { handle.as_ref() }.map(|handle| handle.0.clone())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_session_close(handle: *mut DmsSession) {
    if let Some(session) = unsafe { session(handle) } {
        runtime().spawn(async move { session.close().await });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_session_free(handle: *mut DmsSession) {
    if !handle.is_null() {
        let handle = unsafe { Box::from_raw(handle) };
        let session = handle.0;
        runtime().spawn(async move { session.close().await });
    }
}

fn report(done: AuthFn, context: Context, outcome: AuthOutcome) {
    let (code, remaining, partial, message) = match outcome {
        AuthOutcome::Success => (Code::Ok, 0, false, String::new()),
        AuthOutcome::Failure { remaining, partial } => (Code::AuthFailed, remaining, partial, "authentication failed".into()),
        AuthOutcome::Error(failure) => (failure.code, 0, false, failure.message),
    };
    let message = c_string(&message);
    unsafe { done(context.get(), code as i32, remaining, partial, message.as_ptr()) };
}

fn fail(done: AuthFn, context: Context, message: &str) {
    report(done, context, AuthOutcome::Error(Failure::new(Code::Protocol, message)));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_auth_password(
    handle: *mut DmsSession,
    user: *const c_char,
    password: *const c_char,
    context: *mut c_void,
    done: Option<AuthFn>,
) {
    let context = Context(context);
    let Some(done) = done else { return };
    let (Some(session), Some(user), Some(password)) = (unsafe { session(handle) }, unsafe { text(user) }, unsafe { secret(password) }) else {
        return fail(done, context, "invalid arguments");
    };
    runtime().spawn(async move {
        let context = context;
        report(done, context, session.auth_password(&user, &password).await)
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_auth_key(handle: *mut DmsSession, user: *const c_char, key: *const DmsKey, context: *mut c_void, done: Option<AuthFn>) {
    let context = Context(context);
    let Some(done) = done else { return };
    let (Some(session), Some(user), Some(key)) = (unsafe { session(handle) }, unsafe { text(user) }, unsafe { key.as_ref() }) else {
        return fail(done, context, "invalid arguments");
    };
    let key = key.key.key.clone();
    runtime().spawn(async move {
        let context = context;
        report(done, context, session.auth_key(&user, key).await)
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_auth_keyboard_interactive(
    handle: *mut DmsSession,
    user: *const c_char,
    context: *mut c_void,
    prompt: Option<PromptFn>,
    done: Option<AuthFn>,
) {
    let context = Context(context);
    let Some(done) = done else { return };
    let (Some(session), Some(user), Some(prompt)) = (unsafe { session(handle) }, unsafe { text(user) }, prompt) else {
        return fail(done, context, "invalid arguments");
    };
    runtime().spawn(async move {
        let context = context;
        let ask = move |name: String, instruction: String, prompts: Vec<Prompt>| -> BoxFuture<Option<Vec<String>>> {
            let (reply, answer) = Reply::make();
            let name = c_string(&name);
            let instruction = c_string(&instruction);
            let texts: Vec<CString> = prompts.iter().map(|p| c_string(&p.text)).collect();
            let records: Vec<DmsPrompt> = texts.iter().zip(&prompts).map(|(t, p)| DmsPrompt { text: t.as_ptr(), echo: p.echo }).collect();
            unsafe { prompt(context.get(), name.as_ptr(), instruction.as_ptr(), records.as_ptr(), records.len(), reply) };
            Box::pin(async move {
                match answer.await {
                    Ok(Answer::Strings(strings)) => Some(strings),
                    _ => None,
                }
            })
        };
        report(done, context, session.auth_keyboard_interactive(&user, ask).await)
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_auth_signer(
    handle: *mut DmsSession,
    user: *const c_char,
    public_key: *const u8,
    length: usize,
    context: *mut c_void,
    sign: Option<SignFn>,
    done: Option<AuthFn>,
) {
    let context = Context(context);
    let Some(done) = done else { return };
    let (Some(session), Some(user), Some(sign)) = (unsafe { session(handle) }, unsafe { text(user) }, sign) else {
        return fail(done, context, "invalid arguments");
    };
    if public_key.is_null() {
        return fail(done, context, "invalid arguments");
    }
    let blob = unsafe { std::slice::from_raw_parts(public_key, length) };
    let public = match russh::keys::PublicKey::from_bytes(blob) {
        Ok(public) => public,
        Err(error) => return report(done, context, AuthOutcome::Error(Failure::new(Code::InvalidKey, error.to_string()))),
    };
    runtime().spawn(async move {
        let context = context;
        let ask: crate::session::SignCallback = Box::new(move |data: Vec<u8>| -> BoxFuture<Option<Vec<u8>>> {
            let (reply, answer) = Reply::make();
            unsafe { sign(context.get(), data.as_ptr(), data.len(), reply) };
            Box::pin(async move {
                match answer.await {
                    Ok(Answer::Bytes(bytes)) => Some(bytes),
                    _ => None,
                }
            })
        });
        report(done, context, session.auth_signer(&user, public, ask).await)
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_key_parse(data: *const u8, length: usize, passphrase: *const c_char, code: *mut i32, message: *mut *mut c_char) -> *mut DmsKey {
    let set = |failure: Failure| {
        if let Some(code) = unsafe { code.as_mut() } {
            *code = failure.code as i32;
        }
        if let Some(message) = unsafe { message.as_mut() } {
            *message = c_string(&failure.message).into_raw();
        }
        ptr::null_mut()
    };
    if data.is_null() {
        return set(Failure::new(Code::InvalidKey, "no key data"));
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, length) };
    let passphrase = unsafe { secret(passphrase) };
    match LoadedKey::parse(bytes, passphrase.as_ref().map(|p| p.as_str())) {
        Ok(key) => {
            if let Some(code) = unsafe { code.as_mut() } {
                *code = Code::Ok as i32;
            }
            let algorithm = c_string(&key.info.algorithm);
            let public_key = c_string(&key.info.public_key);
            let fingerprint = c_string(&key.info.fingerprint);
            Box::into_raw(Box::new(DmsKey { key, algorithm, public_key, fingerprint }))
        }
        Err(failure) => set(failure),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_key_algorithm(key: *const DmsKey) -> *const c_char {
    unsafe { key.as_ref() }.map_or(ptr::null(), |key| key.algorithm.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_key_public_key(key: *const DmsKey) -> *const c_char {
    unsafe { key.as_ref() }.map_or(ptr::null(), |key| key.public_key.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_key_fingerprint(key: *const DmsKey) -> *const c_char {
    unsafe { key.as_ref() }.map_or(ptr::null(), |key| key.fingerprint.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_key_free(key: *mut DmsKey) {
    if !key.is_null() {
        drop(unsafe { Box::from_raw(key) });
    }
}

struct FfiExecEvents {
    context: Context,
    stderr: Option<StderrFn>,
    exited: Option<ExitedFn>,
}

impl ExecEvents for FfiExecEvents {
    fn stderr(&self, bytes: &[u8]) {
        if let Some(callback) = self.stderr {
            unsafe { callback(self.context.get(), bytes.as_ptr(), bytes.len()) };
        }
    }

    fn exited(&self, exit: Exit) {
        let Some(callback) = self.exited else { return };
        let (kind, status, signal) = match exit {
            Exit::Status(status) => (0, status, String::new()),
            Exit::Signal(signal) => (1, 0, signal),
            Exit::Lost => (2, 0, String::new()),
        };
        let signal = c_string(&signal);
        unsafe { callback(self.context.get(), kind, status, signal.as_ptr()) };
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_exec(
    handle: *mut DmsSession,
    command: *const c_char,
    context: *mut c_void,
    started: Option<StartedFn>,
    stderr_chunk: Option<StderrFn>,
    exited: Option<ExitedFn>,
) {
    let context = Context(context);
    let Some(started) = started else { return };
    let (Some(session), Some(command)) = (unsafe { session(handle) }, unsafe { text(command) }) else {
        let message = c_string("invalid arguments");
        unsafe { started(context.get(), -1, Code::Protocol as i32, message.as_ptr()) };
        return;
    };
    let events = Arc::new(FfiExecEvents { context, stderr: stderr_chunk, exited });
    runtime().spawn(async move {
        let context = context;
        match exec(&session, &command, events).await {
            Ok(fd) => unsafe { started(context.get(), fd, Code::Ok as i32, c"".as_ptr()) },
            Err(failure) => {
                let message = c_string(&failure.message);
                unsafe { started(context.get(), -1, failure.code as i32, message.as_ptr()) };
            }
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_reply_bool(reply: *mut Reply, value: bool) {
    unsafe { Reply::answer(reply, Answer::Bool(value)) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_reply_strings(reply: *mut Reply, strings: *const *const c_char, count: usize) {
    let values = if strings.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(strings, count) }.iter().map(|&s| unsafe { text(s) }.unwrap_or_default()).collect()
    };
    unsafe { Reply::answer(reply, Answer::Strings(values)) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_reply_bytes(reply: *mut Reply, bytes: *const u8, length: usize) {
    let value = if bytes.is_null() { Vec::new() } else { unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec() };
    unsafe { Reply::answer(reply, Answer::Bytes(value)) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_reply_cancel(reply: *mut Reply) {
    unsafe { Reply::answer(reply, Answer::Cancel) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn dms_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}
