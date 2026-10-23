//! Engine tests against an in-process russh server: keyboard-interactive and password (a user-owned
//! OpenSSH sshd cannot do PAM, and cannot check passwords), the external signer, key files of every type
//! (made with ssh-keygen), and exec and shell (PTY) channels through the socketpair. The Swift tests cover
//! OpenSSH 10.3.

use dispatch_mobile_ssh::{AuthOutcome, Code, ConnectOptions, ExecEvents, Exit, HostKey, LoadedKey, Prompt, Session, SessionEvents, Resizer, exec, runtime, shell};
use russh::keys::{PrivateKey, PublicKey};
use russh::server::{self, Auth, Msg, Response};
use russh::{Channel, ChannelId, MethodKind, MethodSet};
use std::borrow::Cow;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;
use std::path::PathBuf;
use std::process::Command;
use std::collections::HashSet;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const PASSPHRASE: &str = "correct horse";

/// Keys made once per run by ssh-keygen, in cargo's scratch directory for integration tests.
fn keys() -> &'static PathBuf {
    static DIRECTORY: OnceLock<PathBuf> = OnceLock::new();
    DIRECTORY.get_or_init(|| {
        let directory = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("keys");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir(&directory).unwrap();
        for (name, args) in [
            ("host", vec!["-t", "ed25519"]),
            ("ed25519", vec!["-t", "ed25519"]),
            ("ecdsa256", vec!["-t", "ecdsa", "-b", "256"]),
            ("ecdsa384", vec!["-t", "ecdsa", "-b", "384"]),
            ("ecdsa521", vec!["-t", "ecdsa", "-b", "521"]),
            ("rsa", vec!["-t", "rsa", "-b", "3072"]),
        ] {
            for encrypted in [false, true] {
                if name == "host" && encrypted {
                    continue;
                }
                let file = directory.join(format!("{name}{}", if encrypted { "-encrypted" } else { "" }));
                let status = Command::new("/usr/bin/ssh-keygen")
                    .args(["-q", "-N", if encrypted { PASSPHRASE } else { "" }, "-f"])
                    .arg(&file)
                    .args(&args)
                    .status()
                    .unwrap();
                assert!(status.success());
            }
        }
        directory
    })
}

fn key_file(name: &str) -> Vec<u8> {
    std::fs::read(keys().join(name)).unwrap()
}

fn keygen_fingerprint(name: &str) -> String {
    let output = Command::new("/usr/bin/ssh-keygen").arg("-lf").arg(keys().join(format!("{name}.pub"))).output().unwrap();
    String::from_utf8(output.stdout).unwrap().split(' ').nth(1).unwrap().to_owned()
}

// MARK: - Server

#[derive(Clone)]
struct Server {
    authorized: Arc<Mutex<Vec<PublicKey>>>,
    rounds: Arc<Mutex<Vec<String>>>,
    /// What shell channels asked for, in order: "pty <term> <cols>x<rows> <pixels> modes=<n>", "shell",
    /// "resize <cols>x<rows> <pixels>", "close".
    terminal: Arc<Mutex<Vec<String>>>,
    shells: Arc<Mutex<HashSet<ChannelId>>>,
}

impl server::Handler for Server {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        Ok(if user == "phone" && password == "s3cret" { Auth::Accept } else { reject() })
    }

    async fn auth_publickey(&mut self, _user: &str, key: &PublicKey) -> Result<Auth, Self::Error> {
        let known = self.authorized.lock().unwrap().iter().any(|k| k.key_data() == key.key_data());
        Ok(if known { Auth::Accept } else { reject() })
    }

    /// Two rounds: a password prompt (no echo) and a one-time code (echo), as PAM two-factor does.
    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        _user: &str,
        _submethods: &str,
        response: Option<Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let answers: Vec<String> = response.map(|r| r.map(|b| String::from_utf8_lossy(&b).into_owned()).collect()).unwrap_or_default();
        let mut rounds = self.rounds.lock().unwrap();
        rounds.push(answers.join("|"));
        match rounds.len() {
            1 => Ok(Auth::Partial { name: "Login".into(), instructions: "Two steps".into(), prompts: Cow::Owned(vec![("Password: ".into(), false)]) }),
            2 if answers == ["s3cret"] => Ok(Auth::Partial { name: "".into(), instructions: "".into(), prompts: Cow::Owned(vec![("Code: ".into(), true)]) }),
            3 if answers == ["123456"] => Ok(Auth::Accept),
            _ => Ok(reject()),
        }
    }

    async fn channel_open_session(&mut self, _channel: Channel<Msg>, reply: server::ChannelOpenHandle, _session: &mut server::Session) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    /// `echo` replies "hello" on stdout and "warn" on stderr, then exits 7; `cat` echoes stdin until EOF.
    async fn exec_request(&mut self, channel: ChannelId, data: &[u8], session: &mut server::Session) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        if data == b"echo" {
            session.data(channel, &b"hello"[..])?;
            session.extended_data(channel, 1, &b"warn"[..])?;
            session.exit_status_request(channel, 7)?;
            session.eof(channel)?;
            session.close(channel)?;
        }
        Ok(())
    }

    /// A terminal named "refused" is refused, as a server without PTYs (or `no-pty` in authorized_keys) does.
    async fn pty_request(
        &mut self,
        channel: ChannelId,
        term: &str,
        col_width: u32,
        row_height: u32,
        pix_width: u32,
        pix_height: u32,
        modes: &[(russh::Pty, u32)],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.terminal.lock().unwrap().push(format!("pty {term} {col_width}x{row_height} {pix_width}x{pix_height} modes={}", modes.len()));
        if term == "refused" { session.channel_failure(channel) } else { session.channel_success(channel) }
    }

    /// The shell writes a prompt; its input echoes back, and a line "exit <n>" ends it with status n.
    async fn shell_request(&mut self, channel: ChannelId, session: &mut server::Session) -> Result<(), Self::Error> {
        self.terminal.lock().unwrap().push("shell".into());
        self.shells.lock().unwrap().insert(channel);
        session.channel_success(channel)?;
        session.data(channel, &b"$ "[..])?;
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        _channel: ChannelId,
        col_width: u32,
        row_height: u32,
        pix_width: u32,
        pix_height: u32,
        _session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.terminal.lock().unwrap().push(format!("resize {col_width}x{row_height} {pix_width}x{pix_height}"));
        Ok(())
    }

    async fn data(&mut self, channel: ChannelId, data: &[u8], session: &mut server::Session) -> Result<(), Self::Error> {
        let status = self.shells.lock().unwrap().contains(&channel).then(|| std::str::from_utf8(data).ok()?.trim().strip_prefix("exit ")?.parse().ok()).flatten();
        session.data(channel, data.to_vec())?;
        if let Some(status) = status {
            session.exit_status_request(channel, status)?;
            session.eof(channel)?;
            session.close(channel)?;
        }
        Ok(())
    }

    async fn channel_close(&mut self, channel: ChannelId, _session: &mut server::Session) -> Result<(), Self::Error> {
        if self.shells.lock().unwrap().contains(&channel) {
            self.terminal.lock().unwrap().push("close".into());
        }
        Ok(())
    }

    async fn channel_eof(&mut self, channel: ChannelId, session: &mut server::Session) -> Result<(), Self::Error> {
        session.exit_status_request(channel, 0)?;
        session.eof(channel)?;
        session.close(channel)?;
        Ok(())
    }
}

fn reject() -> Auth {
    Auth::Reject {
        proceed_with_methods: Some(MethodSet::from(&[MethodKind::Password, MethodKind::PublicKey, MethodKind::KeyboardInteractive][..])),
        partial_success: false,
    }
}

struct Running {
    port: u16,
    host_key: PublicKey,
    handler: Server,
}

fn start_server() -> Running {
    let host = LoadedKey::parse(&key_file("host"), None).unwrap();
    let host_key = host.key.public_key().clone();
    let config = Arc::new(server::Config {
        keys: vec![(*host.key).clone()],
        auth_rejection_time: Duration::from_millis(1),
        auth_rejection_time_initial: Some(Duration::ZERO),
        methods: MethodSet::from(&[MethodKind::Password, MethodKind::PublicKey, MethodKind::KeyboardInteractive][..]),
        ..Default::default()
    });
    let handler = Server { authorized: Arc::default(), rounds: Arc::default(), terminal: Arc::default(), shells: Arc::default() };
    let listener = runtime().block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
    let port = listener.local_addr().unwrap().port();
    let accept = handler.clone();
    runtime().spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            let (config, handler) = (config.clone(), accept.clone());
            tokio::spawn(async move {
                if let Ok(session) = server::run_stream(config, stream, handler).await {
                    let _ = session.await;
                }
            });
        }
    });
    Running { port, host_key, handler }
}

// MARK: - Client side

struct Events {
    expected: PublicKey,
    seen: Mutex<Vec<HostKey>>,
    disconnects: Mutex<Vec<(Code, String)>>,
}

impl SessionEvents for Events {
    fn host_key(&self, key: HostKey) -> dispatch_mobile_ssh::BoxFuture<bool> {
        let trusted = key.blob == self.expected.to_bytes().unwrap();
        self.seen.lock().unwrap().push(key);
        Box::pin(async move { trusted })
    }
    fn disconnected(&self, code: Code, message: String) {
        self.disconnects.lock().unwrap().push((code, message));
    }
}

fn connect(server: &Running) -> (Arc<Session>, Arc<Events>) {
    let events = Arc::new(Events { expected: server.host_key.clone(), seen: Mutex::default(), disconnects: Mutex::default() });
    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port: server.port,
        timeout: Duration::from_secs(10),
        keepalive_interval: Duration::from_secs(15),
        keepalive_max: 3,
    };
    let session = runtime().block_on(Session::connect(options, events.clone())).unwrap();
    (session, events)
}

#[test]
fn host_key_reports_keygen_fingerprint() {
    let server = start_server();
    let (session, events) = connect(&server);
    let seen = events.seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].algorithm, "ssh-ed25519");
    assert_eq!(seen[0].fingerprint, keygen_fingerprint("host"));
    runtime().block_on(session.close());
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(events.disconnects.lock().unwrap().len(), 1, "disconnected fires once");
}

#[test]
fn rejected_host_key_fails_connect_without_disconnect() {
    let server = start_server();
    let mut other = start_server();
    other.port = server.port;
    other.host_key = LoadedKey::parse(&key_file("ed25519"), None).unwrap().key.public_key().clone();
    let events = Arc::new(Events { expected: other.host_key.clone(), seen: Mutex::default(), disconnects: Mutex::default() });
    let options = ConnectOptions { host: "127.0.0.1".into(), port: server.port, timeout: Duration::from_secs(10), keepalive_interval: Duration::from_secs(15), keepalive_max: 3 };
    let result = runtime().block_on(Session::connect(options, events.clone()));
    assert_eq!(result.err().map(|f| f.code), Some(Code::HostKeyRejected));
    std::thread::sleep(Duration::from_millis(50));
    assert!(events.disconnects.lock().unwrap().is_empty());
}

fn connect_failure(host: &str, port: u16) -> dispatch_mobile_ssh::Failure {
    let events = Arc::new(Events { expected: start_server().host_key.clone(), seen: Mutex::default(), disconnects: Mutex::default() });
    let options = ConnectOptions { host: host.into(), port, timeout: Duration::from_secs(10), keepalive_interval: Duration::from_secs(15), keepalive_max: 3 };
    let failure = runtime().block_on(Session::connect(options, events.clone())).err().expect("connect fails");
    assert!(events.disconnects.lock().unwrap().is_empty());
    failure
}

#[test]
fn a_closed_port_is_refused() {
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    assert_eq!(connect_failure("127.0.0.1", port).code, Code::ConnectionRefused);
}

#[test]
fn a_name_that_does_not_resolve_is_not_found() {
    // RFC 6761: .invalid never resolves.
    assert_eq!(connect_failure("dispatch-test.invalid", 22).code, Code::HostNotFound);
}

/// A proxy to `port` that passes the server's version line at once and holds the rest of what the
/// server sends (its key exchange) back for `delay`.
fn slow_proxy(port: u16, delay: Duration) -> u16 {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = runtime().block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
    let proxy = listener.local_addr().unwrap().port();
    runtime().spawn(async move {
        let Ok((client, _)) = listener.accept().await else { return };
        let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await else { return };
        let (mut client_read, mut client_write) = client.into_split();
        let (mut server_read, mut server_write) = server.into_split();
        tokio::spawn(async move {
            let _ = tokio::io::copy(&mut client_read, &mut server_write).await;
        });
        let mut byte = [0u8; 1];
        loop {
            if server_read.read_exact(&mut byte).await.is_err() || client_write.write_all(&byte).await.is_err() {
                return;
            }
            if byte[0] == b'\n' {
                break;
            }
        }
        tokio::time::sleep(delay).await;
        let _ = tokio::io::copy(&mut server_read, &mut client_write).await;
    });
    proxy
}

/// russh runs the session on a task of its own that outlives a handshake `connect` gave up on: a key
/// exchange that finishes after the deadline must not ask about the host key (Swift has released the
/// session's context once `connect` reported the timeout).
#[test]
fn a_key_exchange_finishing_after_the_deadline_never_asks() {
    let server = start_server();
    let proxy = slow_proxy(server.port, Duration::from_millis(1500));
    let events = Arc::new(Events { expected: server.host_key.clone(), seen: Mutex::default(), disconnects: Mutex::default() });
    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port: proxy,
        timeout: Duration::from_millis(300),
        keepalive_interval: Duration::from_secs(15),
        keepalive_max: 3,
    };
    let result = runtime().block_on(Session::connect(options, events.clone()));
    let failure = result.err().unwrap();
    assert_eq!((failure.code, failure.message.as_str()), (Code::Timeout, "the SSH handshake"), "past TCP: the handshake timed out");
    std::thread::sleep(Duration::from_millis(2500));
    assert!(events.seen.lock().unwrap().is_empty(), "host_key was asked after connect had failed");
    assert!(events.disconnects.lock().unwrap().is_empty());
}

#[test]
fn password() {
    let server = start_server();
    let (session, _) = connect(&server);
    let wrong = runtime().block_on(session.auth_password("phone", "wrong"));
    assert!(matches!(wrong, AuthOutcome::Failure { remaining, .. } if remaining & 1 != 0), "{wrong:?}");
    let right = runtime().block_on(session.auth_password("phone", "s3cret"));
    assert!(matches!(right, AuthOutcome::Success), "{right:?}");
}

#[test]
fn keyboard_interactive_two_rounds() {
    let server = start_server();
    let (session, _) = connect(&server);
    let asked = Arc::new(Mutex::new(Vec::<(String, String, Vec<Prompt>)>::new()));
    let record = asked.clone();
    let outcome = runtime().block_on(session.auth_keyboard_interactive("phone", move |name, instruction, prompts| {
        let answer = if prompts.first().is_some_and(|p| p.text.starts_with("Password")) { "s3cret" } else { "123456" };
        record.lock().unwrap().push((name, instruction, prompts));
        Box::pin(async move { Some(vec![answer.to_owned()]) })
    }));
    assert!(matches!(outcome, AuthOutcome::Success), "{outcome:?}");
    let asked = asked.lock().unwrap();
    assert_eq!(asked.len(), 2);
    assert_eq!((asked[0].0.as_str(), asked[0].1.as_str()), ("Login", "Two steps"));
    assert_eq!((asked[0].2[0].text.as_str(), asked[0].2[0].echo), ("Password: ", false));
    assert_eq!((asked[1].2[0].text.as_str(), asked[1].2[0].echo), ("Code: ", true));
}

#[test]
fn keyboard_interactive_cancel() {
    let server = start_server();
    let (session, _) = connect(&server);
    let outcome = runtime().block_on(session.auth_keyboard_interactive("phone", |_, _, _| Box::pin(async { None })));
    assert!(matches!(outcome, AuthOutcome::Error(ref f) if f.code == Code::Cancelled), "{outcome:?}");
}

#[test]
fn key_files_of_every_type() {
    let server = start_server();
    for name in ["ed25519", "ecdsa256", "ecdsa384", "ecdsa521", "rsa"] {
        for encrypted in [false, true] {
            let file = format!("{name}{}", if encrypted { "-encrypted" } else { "" });
            let key = LoadedKey::parse(&key_file(&file), encrypted.then_some(PASSPHRASE)).unwrap();
            assert_eq!(key.info.fingerprint, keygen_fingerprint(&file), "{file}");
            server.handler.authorized.lock().unwrap().push(key.key.public_key().clone());
            let (session, _) = connect(&server);
            let outcome = runtime().block_on(session.auth_key("phone", key.key.clone()));
            assert!(matches!(outcome, AuthOutcome::Success), "{file}: {outcome:?}");
        }
    }
}

#[test]
fn wrong_or_missing_passphrase() {
    for name in ["ed25519-encrypted", "ecdsa256-encrypted", "rsa-encrypted"] {
        for passphrase in [Some("wrong"), None] {
            let error = LoadedKey::parse(&key_file(name), passphrase).err().unwrap();
            assert_eq!(error.code, Code::WrongPassphrase, "{name} {passphrase:?}");
        }
    }
}

/// The Secure Enclave path: the engine asks for a raw signature and builds the SSH signature itself.
#[test]
fn external_signer() {
    let server = start_server();
    for name in ["ed25519", "ecdsa256", "ecdsa384"] {
        let key: PrivateKey = (*LoadedKey::parse(&key_file(name), None).unwrap().key).clone();
        let public = key.public_key().clone();
        server.handler.authorized.lock().unwrap().push(public.clone());
        let (session, _) = connect(&server);
        let signer = key.clone();
        let outcome = runtime().block_on(session.auth_signer("phone", public, Box::new(move |data| {
            let raw = raw_signature(&signer, &data);
            Box::pin(async move { Some(raw) })
        })));
        assert!(matches!(outcome, AuthOutcome::Success), "{name}: {outcome:?}");
    }
}

/// What CryptoKit returns: Ed25519's 64 bytes, ECDSA's fixed-width r‖s.
fn raw_signature(key: &PrivateKey, data: &[u8]) -> Vec<u8> {
    use russh::keys::signature::Signer;
    let signature: russh::keys::ssh_key::Signature = key.try_sign(data).unwrap();
    let blob = signature.as_bytes();
    match key.algorithm() {
        russh::keys::Algorithm::Ed25519 => blob.to_vec(),
        russh::keys::Algorithm::Ecdsa { curve } => {
            let width = match curve {
                russh::keys::EcdsaCurve::NistP256 => 32,
                russh::keys::EcdsaCurve::NistP384 => 48,
                russh::keys::EcdsaCurve::NistP521 => 66,
            };
            let mut reader = blob;
            let mut out = Vec::new();
            for _ in 0..2 {
                let length = u32::from_be_bytes(reader[..4].try_into().unwrap()) as usize;
                let value = &reader[4..4 + length];
                let value = &value[value.len().saturating_sub(width)..];
                out.extend(std::iter::repeat_n(0, width - value.len()));
                out.extend_from_slice(value);
                reader = &reader[4 + length..];
            }
            out
        }
        _ => unreachable!(),
    }
}

struct ExecLog {
    stderr: Mutex<Vec<u8>>,
    exit: Mutex<Option<Exit>>,
}

impl ExecEvents for ExecLog {
    fn stderr(&self, bytes: &[u8]) {
        self.stderr.lock().unwrap().extend_from_slice(bytes);
    }
    fn exited(&self, exit: Exit) {
        *self.exit.lock().unwrap() = Some(exit);
    }
}

#[test]
fn exec_over_socketpair() {
    let server = start_server();
    let (session, _) = connect(&server);
    assert!(matches!(runtime().block_on(session.auth_password("phone", "s3cret")), AuthOutcome::Success));

    let log = Arc::new(ExecLog { stderr: Mutex::default(), exit: Mutex::default() });
    let fd = runtime().block_on(exec(&session, "echo", log.clone())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    let mut output = String::new();
    socket.read_to_string(&mut output).unwrap();
    assert_eq!(output, "hello");
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(*log.exit.lock().unwrap(), Some(Exit::Status(7)));
    assert_eq!(&*log.stderr.lock().unwrap(), b"warn");

    // stdin streams through and EOF (shutdown) ends the remote side. 1 MB stays inside one SSH window: past it,
    // russh's in-process server sometimes stalls echoing (about one run in three with 8 MB both ways); the
    // Swift tests move 24 MiB each way at once through OpenSSH's sshd.
    let log = Arc::new(ExecLog { stderr: Mutex::default(), exit: Mutex::default() });
    let fd = runtime().block_on(exec(&session, "cat", log.clone())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    let payload: Vec<u8> = (0..1_000_000u32).map(|i| (i % 251) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    let sent = payload.clone();
    let feeder = std::thread::spawn(move || {
        writer.write_all(&sent).unwrap();
        writer.shutdown(std::net::Shutdown::Write).unwrap();
    });
    let mut echoed = Vec::new();
    socket.read_to_end(&mut echoed).unwrap();
    feeder.join().unwrap();
    assert!(echoed == payload, "echoed {} of {} bytes", echoed.len(), payload.len());
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(*log.exit.lock().unwrap(), Some(Exit::Status(0)));
}

// MARK: - Shell (PTY) channels

fn logged_in(server: &Running) -> Arc<Session> {
    let (session, _) = connect(server);
    assert!(matches!(runtime().block_on(session.auth_password("phone", "s3cret")), AuthOutcome::Success));
    session
}

fn exec_log() -> Arc<ExecLog> {
    Arc::new(ExecLog { stderr: Mutex::default(), exit: Mutex::default() })
}

/// Reads until `expected` has arrived (or the socket ends), with a deadline.
fn read_until(socket: &mut std::os::unix::net::UnixStream, expected: &[u8]) -> Vec<u8> {
    socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut seen = Vec::new();
    let mut buffer = [0u8; 4096];
    while !seen.windows(expected.len()).any(|w| w == expected) {
        match socket.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => seen.extend_from_slice(&buffer[..count]),
            Err(error) => panic!("reading {:?}: {error}; seen {:?}", String::from_utf8_lossy(expected), String::from_utf8_lossy(&seen)),
        }
    }
    seen
}

fn eventually(what: &str, mut check: impl FnMut() -> bool) {
    for _ in 0..200 {
        if check() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for {what}");
}

#[test]
fn shell_starts_and_echoes() {
    let server = start_server();
    let session = logged_in(&server);
    let log = exec_log();
    let (fd, _shell) = runtime().block_on(shell(&session, "xterm-256color", 80, 24, log.clone())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    assert_eq!(read_until(&mut socket, b"$ "), b"$ ");
    socket.write_all(b"echo hi\r").unwrap();
    assert_eq!(read_until(&mut socket, b"echo hi\r"), b"echo hi\r");
    assert_eq!(*server.handler.terminal.lock().unwrap(), ["pty xterm-256color 80x24 0x0 modes=0", "shell"], "no pixels, no modes, no env");
    assert!(log.exit.lock().unwrap().is_none());
}

#[test]
fn shell_resize_reaches_the_server() {
    let server = start_server();
    let session = logged_in(&server);
    let (fd, shell) = runtime().block_on(shell(&session, "xterm-256color", 80, 24, exec_log())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    read_until(&mut socket, b"$ ");
    runtime().block_on(shell.resize(120, 40)).unwrap();
    runtime().block_on(shell.resize(100, 30)).unwrap();
    let terminal = server.handler.terminal.clone();
    eventually("both window changes", || terminal.lock().unwrap().len() == 4);
    assert_eq!(terminal.lock().unwrap()[2..], ["resize 120x40 0x0", "resize 100x30 0x0"]);
}

/// The window changes the server saw, as (cols, rows).
fn resizes(terminal: &Mutex<Vec<String>>) -> Vec<(u32, u32)> {
    terminal
        .lock()
        .unwrap()
        .iter()
        .filter_map(|line| {
            let (cols, rows) = line.strip_prefix("resize ")?.split(' ').next()?.split_once('x')?;
            Some((cols.parse().ok()?, rows.parse().ok()?))
        })
        .collect()
}

/// Back-to-back changes (a layout pass, then the keyboard) reach the server in order, and the last one wins.
#[test]
fn rapid_resizes_arrive_in_order_and_the_last_wins() {
    let server = start_server();
    let session = logged_in(&server);
    let resizer = Resizer::new(80, 24);
    // Asked before the shell started: sent once it has.
    resizer.resize(81, 25);
    let (fd, shell) = runtime().block_on(shell(&session, "xterm-256color", 80, 24, exec_log())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    read_until(&mut socket, b"$ ");
    resizer.attach(shell);
    let terminal = server.handler.terminal.clone();
    eventually("the change asked before the start", || resizes(&terminal) == [(81, 25)]);
    for step in 2..=300 {
        resizer.resize(80 + step, 24 + step);
    }
    eventually("the last window change", || resizes(&terminal).last() == Some(&(380, 324)));
    std::thread::sleep(Duration::from_millis(100));
    let seen = resizes(&terminal);
    assert!(seen.windows(2).all(|pair| pair[0].0 < pair[1].0), "out of order: {seen:?}");
    assert_eq!(seen.last(), Some(&(380, 324)), "nothing after the last: {seen:?}");
    resizer.resize(380, 324);
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(resizes(&terminal).len(), seen.len(), "an unchanged size is not sent again");
}

#[test]
fn shell_exit_status_propagates() {
    let server = start_server();
    let session = logged_in(&server);
    let log = exec_log();
    let (fd, _shell) = runtime().block_on(shell(&session, "xterm-256color", 80, 24, log.clone())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    read_until(&mut socket, b"$ ");
    socket.write_all(b"exit 3\r").unwrap();
    let mut rest = Vec::new();
    socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    socket.read_to_end(&mut rest).unwrap();
    assert_eq!(rest, b"exit 3\r", "the output ends with the channel");
    eventually("the exit", || log.exit.lock().unwrap().is_some());
    assert_eq!(*log.exit.lock().unwrap(), Some(Exit::Status(3)));
}

#[test]
fn closing_the_socket_closes_the_shell_channel() {
    let server = start_server();
    let session = logged_in(&server);
    let log = exec_log();
    let (fd, _shell) = runtime().block_on(shell(&session, "xterm-256color", 80, 24, log.clone())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    read_until(&mut socket, b"$ ");
    drop(socket);
    let terminal = server.handler.terminal.clone();
    eventually("the server seeing the close", || terminal.lock().unwrap().last().map(String::as_str) == Some("close"));
    eventually("the exit", || log.exit.lock().unwrap().is_some());
    assert_eq!(*log.exit.lock().unwrap(), Some(Exit::Lost), "closed by the caller before any status");
}

#[test]
fn a_refused_pty_request_is_refused() {
    let server = start_server();
    let session = logged_in(&server);
    let log = exec_log();
    let failure = runtime().block_on(shell(&session, "refused", 80, 24, log.clone())).err().expect("refused");
    assert_eq!(failure.code, Code::Refused);
    assert_eq!(*server.handler.terminal.lock().unwrap(), ["pty refused 80x24 0x0 modes=0"], "no shell request after a refused pty-req");
    std::thread::sleep(Duration::from_millis(50));
    assert!(log.exit.lock().unwrap().is_none(), "no exit after a failed start");
}

#[test]
fn a_lost_connection_ends_the_shell_as_lost() {
    let server = start_server();
    let session = logged_in(&server);
    let log = exec_log();
    let (fd, _shell) = runtime().block_on(shell(&session, "xterm-256color", 80, 24, log.clone())).unwrap();
    let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    read_until(&mut socket, b"$ ");
    runtime().block_on(session.close());
    eventually("the exit", || log.exit.lock().unwrap().is_some());
    assert_eq!(*log.exit.lock().unwrap(), Some(Exit::Lost));
}

// MARK: - The C ABI itself (what Swift calls), for the paths the OpenSSH fixture cannot reach.

mod abi {
    use super::*;
    use dispatch_mobile_ssh::ffi::*;
    use std::ffi::{CStr, CString, c_char, c_void};
    use std::sync::mpsc;

    struct Connect(mpsc::Sender<(usize, i32)>);
    struct Auth {
        done: mpsc::Sender<(i32, u32)>,
        prompts: Mutex<Vec<(String, String, Vec<(String, bool)>)>>,
    }

    unsafe extern "C" fn trust(_: *mut c_void, key: *const DmsHostKey, reply: *mut DmsReply) {
        let fingerprint = unsafe { CStr::from_ptr((*key).fingerprint) }.to_str().unwrap();
        assert!(fingerprint.starts_with("SHA256:"));
        unsafe { dms_reply_bool(reply, true) };
    }

    unsafe extern "C" fn disconnected(_: *mut c_void, _: i32, _: *const c_char) {}

    unsafe extern "C" fn connected(context: *mut c_void, session: *mut DmsSession, code: i32, _: *const c_char) {
        let connect = unsafe { Box::from_raw(context.cast::<Connect>()) };
        connect.0.send((session as usize, code)).unwrap();
    }

    unsafe extern "C" fn done(context: *mut c_void, code: i32, remaining: u32, _: bool, _: *const c_char) {
        let auth = unsafe { &*context.cast::<Auth>() };
        auth.done.send((code, remaining)).unwrap();
    }

    unsafe extern "C" fn prompt(context: *mut c_void, name: *const c_char, instruction: *const c_char, prompts: *const DmsPrompt, count: usize, reply: *mut DmsReply) {
        let auth = unsafe { &*context.cast::<Auth>() };
        let text = |p: *const c_char| unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
        let list: Vec<(String, bool)> = (0..count).map(|i| unsafe { (text((*prompts.add(i)).text), (*prompts.add(i)).echo) }).collect();
        let answer = if list[0].0.starts_with("Password") { "s3cret" } else { "123456" };
        auth.prompts.lock().unwrap().push((text(name), text(instruction), list));
        // Answer from another thread, later: replies are not tied to the callback.
        let reply = reply as usize;
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            let answer = CString::new(answer).unwrap();
            let strings = [answer.as_ptr()];
            unsafe { dms_reply_strings(reply as *mut DmsReply, strings.as_ptr(), 1) };
        });
    }

    fn connect(port: u16) -> *mut DmsSession {
        let host = CString::new("127.0.0.1").unwrap();
        let options = DmsConnectOptions { host: host.as_ptr(), port, timeout_ms: 10_000, keepalive_interval_ms: 15_000, keepalive_max: 3 };
        let callbacks = DmsSessionCallbacks { context: std::ptr::null_mut(), host_key: Some(trust), disconnected: Some(disconnected) };
        let (sender, receiver) = mpsc::channel();
        unsafe { dms_connect(&options, callbacks, Box::into_raw(Box::new(Connect(sender))).cast(), Some(connected)) };
        let (session, code) = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(code, 0);
        session as *mut DmsSession
    }

    #[test]
    fn keyboard_interactive_and_password_through_the_c_abi() {
        let server = start_server();
        let session = connect(server.port);
        let user = CString::new("phone").unwrap();
        let (sender, receiver) = mpsc::channel();
        let auth = Box::new(Auth { done: sender, prompts: Mutex::default() });
        let context = (&*auth as *const Auth).cast_mut().cast();
        unsafe { dms_auth_keyboard_interactive(session, user.as_ptr(), context, Some(prompt), Some(done)) };
        assert_eq!(receiver.recv_timeout(Duration::from_secs(10)).unwrap().0, 0);
        let prompts = auth.prompts.lock().unwrap().clone();
        assert_eq!(prompts.len(), 2);
        assert_eq!(prompts[0], ("Login".into(), "Two steps".into(), vec![("Password: ".into(), false)]));
        assert_eq!(prompts[1].2, vec![("Code: ".to_owned(), true)]);
        unsafe { dms_session_free(session) };

        let session = connect(server.port);
        let password = CString::new("wrong").unwrap();
        unsafe { dms_auth_password(session, user.as_ptr(), password.as_ptr(), context, Some(done)) };
        let (code, remaining) = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(code, 1);
        assert_eq!(remaining & 7, 7, "password, publickey, keyboard-interactive remain");
        let password = CString::new("s3cret").unwrap();
        unsafe { dms_auth_password(session, user.as_ptr(), password.as_ptr(), context, Some(done)) };
        assert_eq!(receiver.recv_timeout(Duration::from_secs(10)).unwrap().0, 0);
        unsafe { dms_session_free(session) };
    }

    struct ShellRun {
        started: mpsc::Sender<(i32, i32)>,
        exited: mpsc::Sender<(i32, u32)>,
    }

    unsafe extern "C" fn shell_started(context: *mut c_void, fd: i32, code: i32, _: *const c_char) {
        let run = unsafe { &*context.cast::<ShellRun>() };
        run.started.send((fd, code)).unwrap();
    }

    unsafe extern "C" fn shell_exited(context: *mut c_void, kind: i32, status: u32, _: *const c_char) {
        let run = unsafe { &*context.cast::<ShellRun>() };
        run.exited.send((kind, status)).unwrap();
    }

    fn logged_in(port: u16) -> *mut DmsSession {
        let session = connect(port);
        let user = CString::new("phone").unwrap();
        let password = CString::new("s3cret").unwrap();
        let (sender, receiver) = mpsc::channel();
        let auth = Box::new(Auth { done: sender, prompts: Mutex::default() });
        unsafe { dms_auth_password(session, user.as_ptr(), password.as_ptr(), (&*auth as *const Auth).cast_mut().cast(), Some(done)) };
        assert_eq!(receiver.recv_timeout(Duration::from_secs(10)).unwrap().0, 0);
        session
    }

    /// DMS_REFUSED (-10) for a refused pty-req, DMS_EXIT_STATUS (0) with the status, window changes through the handle.
    #[test]
    fn shell_through_the_c_abi() {
        let server = start_server();
        let session = logged_in(server.port);
        let (started, started_rx) = mpsc::channel();
        let (exited, exited_rx) = mpsc::channel();
        let run = Box::new(ShellRun { started, exited });
        let context = (&*run as *const ShellRun).cast_mut().cast();

        let refused = CString::new("refused").unwrap();
        let handle = unsafe { dms_shell_open(session, refused.as_ptr(), 80, 24, context, Some(shell_started), Some(shell_exited)) };
        assert!(!handle.is_null());
        assert_eq!(started_rx.recv_timeout(Duration::from_secs(10)).unwrap(), (-1, -10));
        unsafe { dms_shell_resize(handle, 1, 1) }; // ignored: never started
        unsafe { dms_shell_free(handle) };

        let term = CString::new("xterm-256color").unwrap();
        let handle = unsafe { dms_shell_open(session, term.as_ptr(), 80, 24, context, Some(shell_started), Some(shell_exited)) };
        // Most likely before the shell started: sent once it has.
        unsafe { dms_shell_resize(handle, 100, 30) };
        let (fd, code) = started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(code, 0);
        let mut socket = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
        read_until(&mut socket, b"$ ");
        let terminal = server.handler.terminal.clone();
        eventually("the early window change", || resizes(&terminal) == [(100, 30)]);
        for cols in 101..=132 {
            unsafe { dms_shell_resize(handle, cols, 50) };
        }
        eventually("the last window change", || resizes(&terminal).last() == Some(&(132, 50)));
        let seen = resizes(&terminal);
        assert!(seen.windows(2).all(|pair| pair[0].0 < pair[1].0), "out of order: {seen:?}");
        socket.write_all(b"exit 3\r").unwrap();
        assert_eq!(exited_rx.recv_timeout(Duration::from_secs(10)).unwrap(), (0, 3));
        unsafe { dms_shell_free(handle) };
        assert!(exited_rx.recv_timeout(Duration::from_millis(100)).is_err(), "exited runs once");
        unsafe { dms_session_free(session) };
    }
}
