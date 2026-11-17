//! The engine against a scripted SSH server that misbehaves on purpose: plain tokio, X25519, SHA-256 and AES-256-GCM
//! from ring, host keys signed with ssh-key. It covers what a well-behaved russh server cannot send: the pre-authentication
//! flaws published for russh 0.64 (a nested certificate as the host key, `EXT_INFO` floods, a zero maximum packet size)
//! and the host key at every rekey (the same key, another key of the same algorithm, another algorithm, repeated, with a
//! channel streaming). Each must end in a bounded error: no abort, no unbounded memory, no writer left blocked.
//!
//! The server rekeys when the channel data it receives holds `rekey\n`, once per occurrence, with the plan's next key.
//! For direct public key logins it can hold its service accept until the first USERAUTH_REQUEST, and logs whether each
//! public key request was a query or signed, and whether it came before the accept.

use dispatch_mobile_ssh::{AuthOutcome, Code, ConnectOptions, ExecEvents, Exit, Failure, HostKey, LoadedKey, Session, SessionEvents, exec, runtime, shell};
use ring::{aead, agreement, digest, rand::SystemRandom};
use russh::keys::PrivateKey;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const VERSION: &[u8] = b"SSH-2.0-DispatchHostile_1.0";
const TRIGGER: &[u8] = b"rekey\n";

// MARK: - Keys

/// Host keys made once per run by ssh-keygen: the trusted one, another of its algorithm, one of another algorithm.
fn key(name: &str) -> PrivateKey {
    static DIRECTORY: OnceLock<PathBuf> = OnceLock::new();
    let directory = DIRECTORY.get_or_init(|| {
        let directory = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hostile-keys");
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        for (name, args) in [("host", ["-t", "ed25519", "", ""]), ("other", ["-t", "ed25519", "", ""]), ("ecdsa", ["-t", "ecdsa", "-b", "256"])] {
            let status = Command::new("/usr/bin/ssh-keygen")
                .args(["-q", "-N", "", "-f"])
                .arg(directory.join(name))
                .args(args.iter().filter(|a| !a.is_empty()))
                .status()
                .unwrap();
            assert!(status.success());
        }
        directory
    });
    (*LoadedKey::parse(&std::fs::read(directory.join(name)).unwrap(), None).unwrap().key).clone()
}

// MARK: - Wire format

fn put_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn put_string(out: &mut Vec<u8>, bytes: &[u8]) {
    put_u32(out, bytes.len() as u32);
    out.extend_from_slice(bytes);
}

fn put_mpint(out: &mut Vec<u8>, magnitude: &[u8]) {
    let start = magnitude.iter().position(|&b| b != 0).unwrap_or(magnitude.len());
    let trimmed = &magnitude[start..];
    let mut value = Vec::new();
    if trimmed.first().is_some_and(|&b| b & 0x80 != 0) {
        value.push(0);
    }
    value.extend_from_slice(trimmed);
    put_string(out, &value);
}

struct Fields<'a>(&'a [u8]);

impl<'a> Fields<'a> {
    fn u8(&mut self) -> u8 {
        let (first, rest) = self.0.split_first().expect("a byte");
        self.0 = rest;
        *first
    }
    fn u32(&mut self) -> u32 {
        let (head, rest) = self.0.split_at(4);
        self.0 = rest;
        u32::from_be_bytes(head.try_into().unwrap())
    }
    fn string(&mut self) -> &'a [u8] {
        let length = self.u32() as usize;
        let (head, rest) = self.0.split_at(length);
        self.0 = rest;
        head
    }
}

fn sha256(parts: &[&[u8]]) -> Vec<u8> {
    let mut context = digest::Context::new(&digest::SHA256);
    parts.iter().for_each(|part| context.update(part));
    context.finish().as_ref().to_vec()
}

/// One direction of aes256-gcm@openssh.com: the packet length is the associated data, the nonce counts packets.
struct Gcm {
    key: aead::LessSafeKey,
    nonce: [u8; 12],
}

impl Gcm {
    fn new(key: &[u8], iv: &[u8]) -> Gcm {
        Gcm {
            key: aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, &key[..32]).unwrap()),
            nonce: iv[..12].try_into().unwrap(),
        }
    }

    fn next(&mut self) -> aead::Nonce {
        let nonce = aead::Nonce::assume_unique_for_key(self.nonce);
        for byte in self.nonce.iter_mut().rev() {
            *byte = byte.wrapping_add(1);
            if *byte != 0 {
                break;
            }
        }
        nonce
    }
}

struct Wire {
    stream: tokio::net::TcpStream,
    incoming: Option<Gcm>,
    outgoing: Option<Gcm>,
}

impl Wire {
    async fn send(&mut self, payload: &[u8]) -> std::io::Result<()> {
        // Plain packets align length, padding length, payload and padding to 8; GCM aligns all but the length to 16.
        let (block, counted) = if self.outgoing.is_some() { (16, 0) } else { (8, 4) };
        let mut padding = block - (counted + 1 + payload.len()) % block;
        if padding < 4 {
            padding += block;
        }
        let mut packet = Vec::with_capacity(4 + 1 + payload.len() + padding + 16);
        put_u32(&mut packet, (1 + payload.len() + padding) as u32);
        packet.push(padding as u8);
        packet.extend_from_slice(payload);
        packet.resize(packet.len() + padding, 0);
        if let Some(gcm) = &mut self.outgoing {
            let nonce = gcm.next();
            let (length, body) = packet.split_at_mut(4);
            let tag = gcm.key.seal_in_place_separate_tag(nonce, aead::Aad::from(&*length), body).unwrap();
            packet.extend_from_slice(tag.as_ref());
        }
        self.stream.write_all(&packet).await
    }

    async fn receive(&mut self) -> std::io::Result<Vec<u8>> {
        let mut length = [0u8; 4];
        self.stream.read_exact(&mut length).await?;
        let size = u32::from_be_bytes(length) as usize;
        if size > 1 << 20 {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "oversized packet"));
        }
        let mut body = vec![0u8; size + if self.incoming.is_some() { 16 } else { 0 }];
        self.stream.read_exact(&mut body).await?;
        let plain = match &mut self.incoming {
            Some(gcm) => {
                let nonce = gcm.next();
                gcm.key
                    .open_in_place(nonce, aead::Aad::from(length), &mut body)
                    .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "not sealed with the expected keys"))?
                    .to_vec()
            }
            None => body,
        };
        let padding = *plain.first().unwrap_or(&0) as usize;
        Ok(plain.get(1..plain.len().saturating_sub(padding)).unwrap_or_default().to_vec())
    }
}

// MARK: - Server

/// Whom the server claims to be in an exchange: a key it signs with, or a host key blob it cannot sign for.
#[derive(Clone)]
enum Identity {
    Key(PrivateKey),
    Blob(Vec<u8>),
}

impl Identity {
    fn algorithm(&self) -> String {
        match self {
            Identity::Key(key) => key.algorithm().as_str().to_owned(),
            Identity::Blob(_) => "ssh-ed25519".to_owned(),
        }
    }
}

#[derive(Clone)]
struct Plan {
    first: Identity,
    /// One identity per `rekey\n` the channel carries, in order (further triggers are ignored).
    rekeys: Vec<Identity>,
    /// What the confirmation of a channel open announces.
    max_packet: u32,
    /// Payloads sent right after the first exchange, before anything the client asks.
    after_first: Vec<Vec<u8>>,
    /// A packet length announced after the first exchange, followed by zeros until the client stops reading.
    announce: Option<u32>,
    /// The answer to SERVICE_REQUEST, held until the first USERAUTH_REQUEST (or 500 ms without one): these payloads,
    /// the accept among them. None: the accept goes at once.
    held_accept: Option<Vec<Vec<u8>>>,
    /// The public key blob the server accepts (`publickey`, with a valid signature).
    user_key: Option<Vec<u8>>,
    /// Close the connection on the first USERAUTH_REQUEST, without an answer.
    close_on_userauth: bool,
    /// Never answer a USERAUTH_REQUEST (the accept still goes): a server that drops a request sent before its accept.
    silent_on_userauth: bool,
}

impl Plan {
    fn new(first: Identity) -> Plan {
        Plan {
            first,
            rekeys: Vec::new(),
            max_packet: 32768,
            after_first: Vec::new(),
            announce: None,
            held_accept: None,
            user_key: None,
            close_on_userauth: false,
            silent_on_userauth: false,
        }
    }
}

type Log = Arc<Mutex<Vec<String>>>;

struct Hostile {
    wire: Wire,
    plan: Plan,
    log: Log,
    client_version: Vec<u8>,
    session_id: Option<Vec<u8>>,
    current: Identity,
    rekeys: usize,
    /// The rekey that finished last, while the client has not yet sent a packet under its keys.
    unproven: Option<usize>,
    /// What arrived during a rekey before the client's KEXINIT, handled once the exchange is done.
    pending: VecDeque<Vec<u8>>,
    channel: u32,
    scanned: Vec<u8>,
}

fn kexinit(host_key_algorithm: &str) -> Vec<u8> {
    let mut payload = vec![20];
    payload.extend_from_slice(&[7u8; 16]);
    for list in ["curve25519-sha256", host_key_algorithm, "aes256-gcm@openssh.com", "aes256-gcm@openssh.com", "hmac-sha2-256", "hmac-sha2-256", "none", "none", "", ""] {
        put_string(&mut payload, list.as_bytes());
    }
    payload.push(0);
    put_u32(&mut payload, 0);
    payload
}

impl Hostile {
    fn note(&self, line: impl Into<String>) {
        self.log.lock().unwrap().push(line.into());
    }

    /// The next packet; the first one opened with a rekey's keys is noted (the client accepted them).
    async fn receive(&mut self) -> std::io::Result<Vec<u8>> {
        let packet = self.wire.receive().await?;
        if let Some(rekey) = self.unproven.take() {
            self.note(format!("rekey {rekey}: the client uses the new keys"));
        }
        Ok(packet)
    }

    /// One key exchange with `identity`. `theirs` is the client's KEXINIT when it started the exchange.
    async fn exchange(&mut self, identity: Identity, theirs: Option<Vec<u8>>) -> std::io::Result<()> {
        let ours = kexinit(&identity.algorithm());
        self.wire.send(&ours).await?;
        let theirs = match theirs {
            Some(theirs) => theirs,
            None => loop {
                let packet = self.receive().await?;
                if packet.first() == Some(&20) {
                    break packet;
                }
                self.pending.push_back(packet);
            },
        };
        let init = self.receive().await?;
        assert_eq!(init.first(), Some(&30), "expected KEX_ECDH_INIT");
        let client_public = Fields(&init[1..]).string().to_vec();
        let random = SystemRandom::new();
        let private = agreement::EphemeralPrivateKey::generate(&agreement::X25519, &random).unwrap();
        let server_public = private.compute_public_key().unwrap().as_ref().to_vec();
        let secret = agreement::agree_ephemeral(private, &agreement::UnparsedPublicKey::new(&agreement::X25519, &client_public), |s| s.to_vec()).unwrap();
        let host_key = match &identity {
            Identity::Key(key) => key.public_key().to_bytes().unwrap(),
            Identity::Blob(blob) => blob.clone(),
        };
        let mut hashed = Vec::new();
        for part in [&self.client_version[..], VERSION, &theirs, &ours, &host_key, &client_public, &server_public] {
            put_string(&mut hashed, part);
        }
        put_mpint(&mut hashed, &secret);
        let hash = sha256(&[&hashed]);
        let signature = match &identity {
            Identity::Key(key) => {
                use russh::keys::signature::Signer;
                use russh::keys::ssh_encoding::Encode;
                let signature: russh::keys::ssh_key::Signature = key.try_sign(&hash).unwrap();
                signature.encode_vec().unwrap()
            }
            Identity::Blob(_) => {
                let mut junk = Vec::new();
                put_string(&mut junk, b"ssh-ed25519");
                put_string(&mut junk, &[0u8; 64]);
                junk
            }
        };
        let mut reply = vec![31];
        put_string(&mut reply, &host_key);
        put_string(&mut reply, &server_public);
        put_string(&mut reply, &signature);
        self.wire.send(&reply).await?;
        let session_id = self.session_id.get_or_insert_with(|| hash.clone()).clone();
        let mut shared = Vec::new();
        put_mpint(&mut shared, &secret);
        let derive = |letter: u8| sha256(&[&shared, &hash, &[letter], &session_id]);
        self.wire.send(&[21]).await?;
        self.wire.outgoing = Some(Gcm::new(&derive(b'D'), &derive(b'B')));
        let newkeys = self.wire.receive().await?;
        assert_eq!(newkeys, [21], "expected NEWKEYS");
        self.wire.incoming = Some(Gcm::new(&derive(b'C'), &derive(b'A')));
        self.current = identity;
        Ok(())
    }

    async fn run(mut self) {
        if let Err(error) = self.serve().await {
            self.note(format!("closed: {error}"));
        }
    }

    async fn serve(&mut self) -> std::io::Result<()> {
        self.wire.stream.write_all(&[VERSION, b"\r\n"].concat()).await?;
        let mut line = Vec::new();
        while !line.ends_with(b"\n") && line.len() < 256 {
            line.push(self.wire.stream.read_u8().await?);
        }
        self.client_version = line.trim_ascii_end().to_vec();
        let theirs = self.wire.receive().await?;
        self.exchange(self.plan.first.clone(), Some(theirs)).await?;
        self.note("first exchange");
        for payload in self.plan.after_first.clone() {
            self.wire.send(&payload).await?;
        }
        if let Some(length) = self.plan.announce {
            let mut written = 4usize;
            self.wire.stream.write_all(&length.to_be_bytes()).await?;
            let zeros = vec![0u8; 64 * 1024];
            while written < length as usize {
                if let Err(error) = self.wire.stream.write_all(&zeros).await {
                    self.note(format!("stopped after {written} bytes: {error}"));
                    return Ok(());
                }
                written += zeros.len();
            }
            self.note(format!("wrote all {written} bytes"));
            return Ok(());
        }
        loop {
            let packet = match self.pending.pop_front() {
                Some(packet) => packet,
                None => self.receive().await?,
            };
            self.handle(packet).await?;
        }
    }

    async fn handle(&mut self, packet: Vec<u8>) -> std::io::Result<()> {
        let Some((&kind, body)) = packet.split_first() else { return Ok(()) };
        let mut fields = Fields(body);
        match kind {
            1 => return Err(std::io::Error::new(std::io::ErrorKind::ConnectionAborted, "the client disconnected")),
            5 if self.plan.held_accept.is_some() => self.hold_accept().await?,
            5 => {
                let mut accept = vec![6];
                put_string(&mut accept, fields.string());
                self.wire.send(&accept).await?;
            }
            20 => self.exchange(self.current.clone(), Some(packet.clone())).await?,
            50 if self.plan.close_on_userauth => {
                self.note("userauth request: closing without an answer");
                return Err(std::io::Error::new(std::io::ErrorKind::ConnectionAborted, "closed at the userauth request"));
            }
            50 if self.plan.silent_on_userauth => self.note("userauth request: no answer"),
            50 if self.plan.user_key.is_some() => self.userauth(&packet).await?,
            50 => {
                let (_user, _service, method) = (fields.string(), fields.string(), fields.string());
                let accepted = method == b"password" && {
                    fields.u8();
                    fields.string() == b"s3cret"
                };
                if accepted {
                    self.wire.send(&[52]).await?;
                } else {
                    let mut failure = vec![51];
                    put_string(&mut failure, b"password");
                    failure.push(0);
                    self.wire.send(&failure).await?;
                }
            }
            80 => {
                let (_name, want_reply) = (fields.string(), fields.u8());
                if want_reply != 0 {
                    self.wire.send(&[82]).await?;
                }
            }
            90 => {
                let (_kind, sender) = (fields.string(), fields.u32());
                self.channel = sender;
                let mut confirmation = vec![91];
                for value in [sender, 0, 1 << 30, self.plan.max_packet] {
                    put_u32(&mut confirmation, value);
                }
                self.wire.send(&confirmation).await?;
            }
            94 => {
                let data = { fields.u32(); fields.string().to_vec() };
                self.scanned.extend_from_slice(&data);
                let triggers = self.scanned.windows(TRIGGER.len()).filter(|w| *w == TRIGGER).count();
                let keep = self.scanned.len().saturating_sub(TRIGGER.len() - 1);
                self.scanned.drain(..keep);
                for _ in 0..triggers {
                    let Some(identity) = self.plan.rekeys.get(self.rekeys).cloned() else { break };
                    self.rekeys += 1;
                    self.note(format!("rekey {} with {}", self.rekeys, identity.algorithm()));
                    self.exchange(identity, None).await?;
                    self.note(format!("rekey {} sent its keys", self.rekeys));
                    self.unproven = Some(self.rekeys);
                }
                let mut echo = vec![94];
                put_u32(&mut echo, self.channel);
                put_string(&mut echo, &data);
                self.wire.send(&echo).await?;
            }
            96 => {
                let mut status = vec![98];
                put_u32(&mut status, self.channel);
                put_string(&mut status, b"exit-status");
                status.push(0);
                put_u32(&mut status, 0);
                self.wire.send(&status).await?;
                for message in [96u8, 97] {
                    let mut end = vec![message];
                    put_u32(&mut end, self.channel);
                    self.wire.send(&end).await?;
                }
            }
            98 => {
                let (_recipient, _kind, want_reply) = (fields.u32(), fields.string(), fields.u8());
                if want_reply != 0 {
                    let mut success = vec![99];
                    put_u32(&mut success, self.channel);
                    self.wire.send(&success).await?;
                }
            }
            _ => {}
        }
        Ok(())
    }
}

/// Serves one connection by `plan` on a loopback port; the log says what happened, in order.
fn serve(plan: Plan) -> (u16, Log) {
    let listener = runtime().block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).unwrap();
    let port = listener.local_addr().unwrap().port();
    let log = Log::default();
    let shared = log.clone();
    runtime().spawn(async move {
        let Ok((stream, _)) = listener.accept().await else { return };
        let current = plan.first.clone();
        let wire = Wire { stream, incoming: None, outgoing: None };
        Hostile { wire, plan, log: shared, client_version: Vec::new(), session_id: None, current, rekeys: 0, unproven: None, pending: VecDeque::new(), channel: 0, scanned: Vec::new() }
            .run()
            .await;
    });
    (port, log)
}

// MARK: - Client side

struct Events {
    trusted: Vec<u8>,
    asked: Mutex<Vec<HostKey>>,
    ended: Mutex<Vec<(Code, String)>>,
}

impl SessionEvents for Events {
    fn host_key(&self, key: HostKey) -> dispatch_mobile_ssh::BoxFuture<bool> {
        let trusted = key.blob == self.trusted;
        self.asked.lock().unwrap().push(key);
        Box::pin(async move { trusted })
    }
    fn disconnected(&self, code: Code, message: String) {
        self.ended.lock().unwrap().push((code, message));
    }
}

fn connect(port: u16) -> (Result<Arc<Session>, Failure>, Arc<Events>) {
    let events = Arc::new(Events { trusted: key("host").public_key().to_bytes().unwrap(), asked: Mutex::default(), ended: Mutex::default() });
    let options = ConnectOptions {
        host: "127.0.0.1".into(),
        port,
        timeout: Duration::from_secs(10),
        keepalive_interval: Duration::from_secs(15),
        keepalive_max: 3,
    };
    (runtime().block_on(Session::connect(options, events.clone())), events)
}

fn logged_in(plan: Plan) -> (Arc<Session>, Arc<Events>, Log) {
    let (port, log) = serve(plan);
    let (session, events) = connect(port);
    let session = session.expect("connects");
    let outcome = runtime().block_on(session.auth_password("phone", "s3cret"));
    assert!(matches!(outcome, AuthOutcome::Success), "{outcome:?}");
    (session, events, log)
}

fn eventually(what: &str, check: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !check() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn logged(log: &Log, prefix: &str) -> bool {
    log.lock().unwrap().iter().any(|line| line.starts_with(prefix))
}

#[derive(Default)]
struct ExecLog {
    exit: Mutex<Option<Exit>>,
}

impl ExecEvents for ExecLog {
    fn stderr(&self, _: &[u8]) {}
    fn exited(&self, exit: Exit) {
        *self.exit.lock().unwrap() = Some(exit);
    }
}

fn echo_channel(session: &Session) -> (UnixStream, Arc<ExecLog>) {
    let log = Arc::new(ExecLog::default());
    let fd = runtime().block_on(exec(session, "cat", log.clone())).expect("exec");
    let socket = unsafe { UnixStream::from_raw_fd(fd) };
    socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    (socket, log)
}

/// Writes `line` and reads until its echo has arrived.
fn round_trip(socket: &mut UnixStream, line: &[u8]) {
    socket.write_all(line).unwrap();
    let mut seen = Vec::new();
    let mut buffer = [0u8; 4096];
    while !seen.windows(line.len()).any(|w| w == line) {
        let count = socket.read(&mut buffer).unwrap_or_else(|e| panic!("reading the echo of {:?}: {e}", String::from_utf8_lossy(line)));
        assert!(count > 0, "the channel ended before the echo of {:?}", String::from_utf8_lossy(line));
        seen.extend_from_slice(&buffer[..count]);
    }
}

/// The socket reaches its end (the engine closed it) within the read timeout.
fn reaches_end(socket: &mut UnixStream) {
    let mut buffer = [0u8; 4096];
    loop {
        match socket.read(&mut buffer) {
            Ok(0) => return,
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => return,
            Err(error) => panic!("the channel did not end: {error}"),
        }
    }
}

// MARK: - Nested certificates (GHSA-3hm4-p7h4-rvwp)

/// The smallest certificate chain where each level's signing key is the next certificate (russh's own fixture).
fn nested_certificate(depth: usize) -> Vec<u8> {
    let mut inner = Vec::new();
    put_string(&mut inner, b"a@b");
    put_string(&mut inner, b"");
    for _ in 0..depth {
        let mut level = Vec::new();
        put_string(&mut level, b"a-cert-v01@x");
        put_string(&mut level, b""); // nonce
        put_string(&mut level, b""); // opaque public key
        level.extend(0u64.to_be_bytes()); // serial
        put_u32(&mut level, 1); // user certificate
        put_string(&mut level, b""); // key id
        put_string(&mut level, b""); // principals
        level.extend(0u64.to_be_bytes());
        level.extend(u64::MAX.to_be_bytes());
        put_string(&mut level, b""); // critical options
        put_string(&mut level, b""); // extensions
        put_string(&mut level, b""); // reserved
        put_string(&mut level, &inner); // signature key
        let mut signature = Vec::new();
        put_string(&mut signature, b"a@b");
        put_string(&mut signature, b"x");
        put_string(&mut level, &signature);
        inner = level;
    }
    inner
}

/// 2000 levels (184 KB, inside one packet) overflow any thread stack without russh 0.65's depth check; 9 is the
/// first depth it refuses.
#[test]
fn a_nested_certificate_host_key_fails_the_handshake() {
    for depth in [9, 2000] {
        let (port, log) = serve(Plan::new(Identity::Blob(nested_certificate(depth))));
        let (result, events) = connect(port);
        let failure = result.err().unwrap_or_else(|| panic!("depth {depth}: connected"));
        assert_eq!(failure.code, Code::Protocol, "depth {depth}: {failure}");
        assert!(events.asked.lock().unwrap().is_empty(), "depth {depth}: asked about a key it could not parse");
        eventually("the server seeing the close", || logged(&log, "closed"));
        assert!(!logged(&log, "first exchange"), "depth {depth}: {:?}", log.lock().unwrap());
        assert!(events.ended.lock().unwrap().is_empty(), "a failed connect never reports a disconnect");
    }
}

fn armored_key(public_blob: &[u8]) -> Vec<u8> {
    let mut binary = b"openssh-key-v1\0".to_vec();
    put_string(&mut binary, b"none");
    put_string(&mut binary, b"none");
    put_string(&mut binary, b"");
    put_u32(&mut binary, 1);
    put_string(&mut binary, public_blob);
    put_string(&mut binary, &[0u8; 16]);
    let mut file = b"-----BEGIN OPENSSH PRIVATE KEY-----\n".to_vec();
    for line in base64(&binary).chunks(70) {
        file.extend_from_slice(line);
        file.push(b'\n');
    }
    file.extend_from_slice(b"-----END OPENSSH PRIVATE KEY-----\n");
    file
}

fn base64(binary: &[u8]) -> Vec<u8> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = Vec::new();
    for chunk in binary.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, &b)| n | u32::from(b) << (16 - 8 * i));
        for i in 0..4 {
            encoded.push(if i <= chunk.len() { ALPHABET[(n >> (18 - 6 * i) & 63) as usize] } else { b'=' });
        }
    }
    encoded
}

/// A PuTTY v3 key file without encryption around `public_blob`, with the MAC PuTTY computes (HMAC-SHA-256, empty key):
/// ssh-key checks it before it decodes the public half.
fn ppk_key(public_blob: &[u8]) -> Vec<u8> {
    let private = [0u8; 36];
    let mut mac = Vec::new();
    for field in [&b"ssh-ed25519"[..], b"none", b"Sam Example", public_blob, &private] {
        put_string(&mut mac, field);
    }
    let tag = ring::hmac::sign(&ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &[]), &mac);
    let lines = |bytes: &[u8]| base64(bytes).chunks(64).map(|line| String::from_utf8(line.to_vec()).unwrap()).collect::<Vec<_>>();
    let (public, private) = (lines(public_blob), lines(&private));
    let hex: String = tag.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: Sam Example\nPublic-Lines: {}\n{}\nPrivate-Lines: {}\n{}\nPrivate-MAC: {hex}\n",
        public.len(),
        public.join("\n"),
        private.len(),
        private.join("\n")
    )
    .into_bytes()
}

/// ssh-key decodes a key file's public half through the same recursion (OpenSSH, and PPK after its MAC): an imported
/// file is refused before it, whatever its format.
#[test]
fn a_key_file_with_nested_certificates_is_refused() {
    let failure = LoadedKey::parse(&armored_key(&nested_certificate(2000)), None).err().expect("refused");
    assert_eq!(failure.code, Code::InvalidKey, "{failure}");
    // The encoder is right: the same file around a real public key gets past the check (and fails later, as junk).
    let real = key("host").public_key().to_bytes().unwrap();
    let failure = LoadedKey::parse(&armored_key(&real), None).err().expect("junk private half");
    assert_ne!(failure.message, "the key file holds nested certificates");

    let failure = LoadedKey::parse(&ppk_key(&nested_certificate(2000)), None).err().expect("refused");
    assert_eq!((failure.code, failure.message.as_str()), (Code::InvalidKey, "the key file holds nested certificates"));
    // The MAC is right: around a real public key the file passes it, and its zero private half reads as a key.
    if let Err(failure) = LoadedKey::parse(&ppk_key(&real), None) {
        assert!(!failure.message.contains("MAC") && failure.message != "the key file holds nested certificates", "{failure}");
    }
}

// MARK: - EXT_INFO (GHSA-4p9f-7p9m-5vfg)

/// An EXT_INFO of `count` extensions of 14 bytes each (10,000: 140 KB, near the 256 KiB packet limit).
fn ext_info(count: u32) -> Vec<u8> {
    let mut payload = vec![7];
    put_u32(&mut payload, count);
    for index in 0..count {
        put_string(&mut payload, format!("x{index:05}").as_bytes());
        put_string(&mut payload, b"");
    }
    payload
}

#[test]
fn two_large_ext_infos_are_kept_and_a_third_ends_the_connection() {
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.after_first = vec![ext_info(10_000), ext_info(10_000)];
    let (session, events, _) = logged_in(plan.clone());
    assert!(events.ended.lock().unwrap().is_empty(), "two are allowed (RFC 8308)");
    runtime().block_on(session.close());

    plan.after_first.push(ext_info(10_000));
    let (port, log) = serve(plan);
    let (result, events) = connect(port);
    if let Ok(session) = result {
        let outcome = runtime().block_on(session.auth_password("phone", "s3cret"));
        // A connection gone mid-login reads as a refusal without methods.
        assert!(!matches!(outcome, AuthOutcome::Success), "{outcome:?}");
    }
    eventually("the server seeing the close", || logged(&log, "closed"));
    eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
}

/// A count far beyond what the packet holds fails decoding at the packet's end: nothing is reserved for the count.
#[test]
fn an_ext_info_claiming_more_than_it_holds_ends_the_connection() {
    let mut payload = vec![7];
    put_u32(&mut payload, u32::MAX);
    put_string(&mut payload, b"server-sig-algs");
    put_string(&mut payload, b"ssh-ed25519");
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.after_first = vec![payload];
    let (port, log) = serve(plan);
    let (result, _) = connect(port);
    if let Ok(session) = result {
        let outcome = runtime().block_on(session.auth_password("phone", "s3cret"));
        // A connection gone mid-login reads as a refusal without methods.
        assert!(!matches!(outcome, AuthOutcome::Success), "{outcome:?}");
    }
    eventually("the server seeing the close", || logged(&log, "closed"));
}

/// A 1 GiB packet announced after the exchange: the client refuses the length instead of reading (or reserving) it.
#[test]
fn an_oversized_packet_is_refused_by_its_length() {
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.announce = Some(1 << 30);
    let (port, log) = serve(plan);
    let (result, events) = connect(port);
    if let Ok(session) = result {
        let outcome = runtime().block_on(session.auth_password("phone", "s3cret"));
        // A connection gone mid-login reads as a refusal without methods.
        assert!(!matches!(outcome, AuthOutcome::Success), "{outcome:?}");
        eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
    }
    eventually("the server's writes failing", || logged(&log, "stopped after"));
    let line = log.lock().unwrap().iter().find(|line| line.starts_with("stopped after")).cloned().unwrap();
    let written: usize = line.split(' ').nth(2).unwrap().parse().unwrap();
    assert!(written < 32 << 20, "the client read {written} bytes of it");
}

// MARK: - Zero maximum packet size (GHSA-fw5c-8223-6h42)

/// A channel whose confirmation announces a maximum packet size of 0 fails at once: before 0.65 every write to it
/// waited forever (the helper upload and terminal input write through it).
#[test]
fn a_zero_maximum_packet_size_fails_the_channel() {
    for terminal in [false, true] {
        let mut plan = Plan::new(Identity::Key(key("host")));
        plan.max_packet = 0;
        let (session, events, _) = logged_in(plan);
        let started = Instant::now();
        let result = runtime().block_on(async {
            let log: Arc<ExecLog> = Arc::default();
            let open = async {
                if terminal { shell(&session, "xterm-256color", 80, 24, log).await.map(|(fd, _)| fd) } else { exec(&session, "cat", log).await }
            };
            tokio::time::timeout(Duration::from_secs(10), open).await
        });
        let failure = result.expect("bounded").err().expect("the channel is refused");
        assert!(started.elapsed() < Duration::from_secs(5), "{failure}");
        eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
    }
}

// MARK: - Host key at every rekey

#[test]
fn rekeys_with_the_same_key_keep_the_session() {
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.rekeys = vec![Identity::Key(key("host")); 3];
    let (session, events, log) = logged_in(plan);
    let (mut socket, exit) = echo_channel(&session);
    for line in [&b"one rekey\n"[..], b"two rekey\n", b"three rekey\n", b"after\n"] {
        round_trip(&mut socket, line);
    }
    for rekey in 1..=3 {
        assert!(logged(&log, &format!("rekey {rekey}: the client uses the new keys")), "{:?}", log.lock().unwrap());
    }
    assert_eq!(events.asked.lock().unwrap().len(), 1, "a rekey never asks");
    assert_eq!(session.rekeys(), 3);
    assert!(events.ended.lock().unwrap().is_empty());
    assert!(exit.exit.lock().unwrap().is_none());
}

/// A rekey presenting `identity` ends the connection with `message`, before the client sends under its keys.
fn rekey_is_refused(identity: Identity, message: &str) {
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.rekeys = vec![identity];
    let (session, events, log) = logged_in(plan);
    let (mut socket, exit) = echo_channel(&session);
    round_trip(&mut socket, b"hello\n");
    socket.write_all(b"rekey\n").unwrap();
    reaches_end(&mut socket);
    eventually("the exit", || exit.exit.lock().unwrap().is_some());
    assert_eq!(*exit.exit.lock().unwrap(), Some(Exit::Lost));
    eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
    assert_eq!(events.ended.lock().unwrap()[0], (Code::HostKeyChanged, message.to_owned()));
    eventually("the server seeing the close", || logged(&log, "closed"));
    let log = log.lock().unwrap();
    assert!(log.iter().any(|line| line == "rekey 1 sent its keys"), "{log:?}");
    assert!(!log.iter().any(|line| line.contains("uses the new keys")), "{log:?}");
    assert_eq!(events.asked.lock().unwrap().len(), 1, "a rekey never asks");
}

#[test]
fn a_rekey_with_another_key_of_the_same_algorithm_is_refused() {
    rekey_is_refused(Identity::Key(key("other")), "the server presented a different host key at a key re-exchange");
}

#[test]
fn a_rekey_with_another_algorithm_is_refused() {
    rekey_is_refused(
        Identity::Key(key("ecdsa")),
        "the host key algorithm changed at a key re-exchange (ssh-ed25519, now ecdsa-sha2-nistp256)",
    );
}

/// Two good rekeys, then a different key while input streams in: the connection ends, and the writer (terminal input,
/// a helper upload) gets an error instead of blocking.
#[test]
fn a_refused_rekey_while_input_streams_ends_the_writer() {
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.rekeys = vec![Identity::Key(key("host")), Identity::Key(key("host")), Identity::Key(key("other"))];
    let (session, events, log) = logged_in(plan);
    let (socket, exit) = echo_channel(&session);
    let mut reader = socket.try_clone().unwrap();
    let draining = std::thread::spawn(move || {
        let mut buffer = vec![0u8; 64 * 1024];
        while reader.read(&mut buffer).is_ok_and(|count| count > 0) {}
    });
    let mut writer = socket;
    // A writer the engine leaves blocked fails the test instead of hanging it.
    writer.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
    let writing = std::thread::spawn(move || {
        let filler = vec![b'.'; 4096];
        let started = Instant::now();
        for chunk in 0.. {
            let data: &[u8] = if chunk % 16 == 15 { b"rekey\n" } else { &filler };
            if let Err(error) = writer.write_all(data) {
                return (chunk, error.kind());
            }
            assert!(started.elapsed() < Duration::from_secs(20), "the writer kept going after the rekey");
        }
        unreachable!()
    });
    let (chunks, error) = writing.join().unwrap();
    assert!(chunks >= 48, "ended after {chunks} chunks");
    assert!(matches!(error, std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset), "{error:?}");
    draining.join().unwrap();
    eventually("the exit", || exit.exit.lock().unwrap().is_some());
    assert_eq!(*exit.exit.lock().unwrap(), Some(Exit::Lost));
    eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
    assert_eq!(events.ended.lock().unwrap()[0].0, Code::HostKeyChanged);
    eventually("the server seeing the close", || logged(&log, "closed"));
    let log = log.lock().unwrap();
    assert!(log.iter().any(|line| line == "rekey 2: the client uses the new keys"), "{log:?}");
    assert!(!log.iter().any(|line| line == "rekey 3: the client uses the new keys"), "{log:?}");
}

// MARK: - Direct public key logins

/// SERVICE_ACCEPT for `ssh-userauth`.
fn service_accept() -> Vec<u8> {
    let mut accept = vec![6];
    put_string(&mut accept, b"ssh-userauth");
    accept
}

/// An EXT_INFO with `server-sig-algs`, as OpenSSH sends after its NEWKEYS (and again before USERAUTH_SUCCESS).
fn server_sig_algs() -> Vec<u8> {
    let mut payload = vec![7];
    put_u32(&mut payload, 1);
    put_string(&mut payload, b"server-sig-algs");
    put_string(&mut payload, b"ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256");
    payload
}

impl Hostile {
    /// SERVICE_REQUEST with the accept held: a client that does not wait sends its USERAUTH_REQUEST now (answered with
    /// the held payloads first); one that waits gets them after 500 ms.
    async fn hold_accept(&mut self) -> std::io::Result<()> {
        let mut byte = [0u8; 1];
        // peek, not receive: a timeout must not cut a packet in half.
        if tokio::time::timeout(Duration::from_millis(500), self.wire.stream.peek(&mut byte)).await.is_err() {
            self.note("no request within 500 ms: accept sent");
            self.release_accept().await?;
        }
        Ok(())
    }

    async fn release_accept(&mut self) -> std::io::Result<()> {
        for payload in self.plan.held_accept.take().unwrap_or_default() {
            self.wire.send(&payload).await?;
        }
        Ok(())
    }

    /// A USERAUTH_REQUEST: password as `handle` does; publickey logged as a query or signed (and whether before the
    /// accept), a query of the user's key answered with PK_OK, a signed request checked against the session id.
    async fn userauth(&mut self, packet: &[u8]) -> std::io::Result<()> {
        let before = self.plan.held_accept.is_some();
        self.release_accept().await?;
        let mut fields = Fields(&packet[1..]);
        let (_user, _service, method) = (fields.string(), fields.string(), fields.string());
        let accepted = match method {
            b"password" => {
                fields.u8();
                self.note(format!("userauth password{}", if before { " before the accept" } else { "" }));
                fields.string() == b"s3cret"
            }
            b"publickey" => {
                let signed = fields.u8() != 0;
                let (algorithm, blob) = (fields.string().to_vec(), fields.string().to_vec());
                let kind = if signed { "signed" } else { "query" };
                self.note(format!("userauth publickey {kind}{}", if before { " before the accept" } else { "" }));
                let known = self.plan.user_key.as_deref() == Some(&blob[..]);
                if !signed {
                    if known {
                        let mut ok = vec![60];
                        put_string(&mut ok, &algorithm);
                        put_string(&mut ok, &blob);
                        return self.wire.send(&ok).await;
                    }
                    false
                } else {
                    let signature = fields.string();
                    let mut signed_data = Vec::new();
                    put_string(&mut signed_data, self.session_id.as_deref().unwrap_or_default());
                    signed_data.extend_from_slice(&packet[..packet.len() - 4 - signature.len()]);
                    let verified = known && verify(&blob, &signed_data, signature);
                    self.note(format!("signature {}", if verified { "verified" } else { "refused" }));
                    verified
                }
            }
            _ => false,
        };
        if accepted {
            self.wire.send(&[52]).await
        } else {
            let mut failure = vec![51];
            put_string(&mut failure, b"publickey,password");
            failure.push(0);
            self.wire.send(&failure).await
        }
    }
}

fn verify(blob: &[u8], data: &[u8], signature: &[u8]) -> bool {
    use russh::keys::ssh_encoding::Decode;
    use russh::keys::signature::Verifier;
    let (Ok(key), Ok(signature)) = (russh::keys::PublicKey::from_bytes(blob), russh::keys::ssh_key::Signature::decode(&mut &signature[..]))
    else {
        return false;
    };
    Verifier::verify(&key, data, &signature).is_ok()
}

/// The user's key: one the server never presents as a host key.
fn user_key() -> PrivateKey {
    key("other")
}

fn direct_plan(held: Vec<Vec<u8>>) -> Plan {
    let mut plan = Plan::new(Identity::Key(key("host")));
    plan.held_accept = Some(held);
    plan.user_key = Some(user_key().public_key().to_bytes().unwrap());
    plan
}

/// What CryptoKit returns for Ed25519: the 64 bytes.
fn ed25519_signer(key: PrivateKey) -> dispatch_mobile_ssh::SignCallback {
    Box::new(move |data| {
        use russh::keys::signature::Signer;
        let signature: russh::keys::ssh_key::Signature = key.try_sign(&data).unwrap();
        let raw = signature.as_bytes().to_vec();
        Box::pin(async move { Some(raw) })
    })
}

fn log_of(log: &Log) -> Vec<String> {
    log.lock().unwrap().clone()
}

/// The signed request leaves right behind SERVICE_REQUEST: the server, holding its accept, gets it first (no query),
/// then sends the accept and its answer. A file key and the external signer.
#[test]
fn a_direct_request_arrives_before_the_service_accept() {
    for signer in [false, true] {
        let (port, log) = serve(direct_plan(vec![service_accept()]));
        let (session, events) = connect(port);
        let session = session.expect("connects");
        let key = user_key();
        let outcome = if signer {
            runtime().block_on(session.auth_signer_direct("phone", key.public_key().clone(), ed25519_signer(key)))
        } else {
            runtime().block_on(session.auth_key_direct("phone", Arc::new(key)))
        };
        assert!(matches!(outcome, AuthOutcome::Success), "signer {signer}: {outcome:?}");
        let log = log_of(&log);
        assert_eq!(log[1..], ["userauth publickey signed before the accept", "signature verified"], "signer {signer}");
        // The connection works on: a channel's round trip.
        let (mut socket, _) = echo_channel(&session);
        round_trip(&mut socket, b"after\n");
        assert!(events.ended.lock().unwrap().is_empty());
    }
}

/// The same server and key without `direct`: the request waits for the accept, and the key is queried first.
#[test]
fn a_queried_request_waits_for_the_service_accept() {
    let (port, log) = serve(direct_plan(vec![service_accept()]));
    let (session, _) = connect(port);
    let outcome = runtime().block_on(session.expect("connects").auth_key("phone", Arc::new(user_key())));
    assert!(matches!(outcome, AuthOutcome::Success), "{outcome:?}");
    assert_eq!(log_of(&log)[1..], ["no request within 500 ms: accept sent", "userauth publickey query", "userauth publickey signed", "signature verified"]);
}

/// The accept arrives late, with EXT_INFO before or after it while the request is pending (OpenSSH sends one after
/// its NEWKEYS and may send another before USERAUTH_SUCCESS): both are handled and the login succeeds.
#[test]
fn a_late_accept_and_ext_info_while_the_direct_request_is_pending() {
    for held in [vec![server_sig_algs(), service_accept()], vec![service_accept(), server_sig_algs()], vec![server_sig_algs(), service_accept(), server_sig_algs()]] {
        for signer in [false, true] {
            let (port, log) = serve(direct_plan(held.clone()));
            let (session, events) = connect(port);
            let session = session.expect("connects");
            let key = user_key();
            let outcome = if signer {
                runtime().block_on(session.auth_signer_direct("phone", key.public_key().clone(), ed25519_signer(key)))
            } else {
                runtime().block_on(session.auth_key_direct("phone", Arc::new(key)))
            };
            assert!(matches!(outcome, AuthOutcome::Success), "{} payloads, signer {signer}: {outcome:?}", held.len());
            assert!(log_of(&log).iter().any(|line| line == "userauth publickey signed before the accept"));
            let (mut socket, _) = echo_channel(&session);
            round_trip(&mut socket, b"after\n");
            assert!(events.ended.lock().unwrap().is_empty());
        }
    }
}

/// A refused direct request (another key) before the accept is an ordinary failure; the next credential on the same
/// connection, sent after the accept arrived, logs in.
#[test]
fn a_refused_direct_request_before_the_accept_falls_through() {
    let (port, log) = serve(direct_plan(vec![server_sig_algs(), service_accept()]));
    let (session, _) = connect(port);
    let session = session.expect("connects");
    let outcome = runtime().block_on(session.auth_key_direct("phone", Arc::new(key("ecdsa"))));
    assert!(matches!(outcome, AuthOutcome::Failure { remaining: 3, partial: false }), "{outcome:?}");
    let outcome = runtime().block_on(session.auth_key_direct("phone", Arc::new(user_key())));
    assert!(matches!(outcome, AuthOutcome::Success), "{outcome:?}");
    assert_eq!(
        log_of(&log)[1..],
        ["userauth publickey signed before the accept", "signature refused", "userauth publickey signed", "signature verified"]
    );
}

/// A server that ends the connection at the direct request, before any answer (as one that cannot take a pipelined
/// request might): the attempt ends promptly as the connection's end (`Closed`), not as a refusal, which would be
/// final for the host, and the disconnect is reported once.
#[test]
fn a_connection_ending_before_the_direct_answer_does_not_hang() {
    for signer in [false, true] {
        let mut plan = direct_plan(vec![service_accept()]);
        plan.close_on_userauth = true;
        let (port, log) = serve(plan);
        let (session, events) = connect(port);
        let session = session.expect("connects");
        let key = user_key();
        let started = Instant::now();
        let outcome = runtime().block_on(async {
            let attempt = async {
                if signer {
                    session.auth_signer_direct("phone", key.public_key().clone(), ed25519_signer(key)).await
                } else {
                    session.auth_key_direct("phone", Arc::new(key)).await
                }
            };
            tokio::time::timeout(Duration::from_secs(10), attempt).await
        });
        let outcome = outcome.expect("bounded");
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(matches!(&outcome, AuthOutcome::Error(failure) if failure.code == Code::Closed), "signer {signer}: {outcome:?}");
        eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
        assert!(log_of(&log).iter().any(|line| line == "userauth request: closing without an answer"));
    }
}

/// A server that accepts the service and says nothing about the direct request (as one that dropped a request sent
/// before its accept would): the attempt gives up after the answer's deadline as a timeout, not a refusal, and the
/// engine closes the connection, reported once. A signer's own time does not count: it signs after 400 ms, longer than
/// the deadline, and the request still goes.
#[test]
fn a_direct_request_nobody_answers_ends_the_connection() {
    for signer in [false, true] {
        let mut plan = direct_plan(vec![service_accept()]);
        plan.silent_on_userauth = true;
        let (port, log) = serve(plan);
        let (session, events) = connect(port);
        let session = session.expect("connects");
        session.set_direct_answer(Duration::from_millis(300));
        let key = user_key();
        let started = Instant::now();
        let outcome = runtime().block_on(async {
            let attempt = async {
                if signer {
                    let public = key.public_key().clone();
                    let sign: dispatch_mobile_ssh::SignCallback = Box::new(move |data| {
                        use russh::keys::signature::Signer;
                        let signature: russh::keys::ssh_key::Signature = key.try_sign(&data).unwrap();
                        let raw = signature.as_bytes().to_vec();
                        Box::pin(async move {
                            tokio::time::sleep(Duration::from_millis(400)).await;
                            Some(raw)
                        })
                    });
                    session.auth_signer_direct("phone", public, sign).await
                } else {
                    session.auth_key_direct("phone", Arc::new(key)).await
                }
            };
            tokio::time::timeout(Duration::from_secs(10), attempt).await
        });
        let outcome = outcome.expect("bounded");
        let elapsed = started.elapsed();
        assert!(matches!(&outcome, AuthOutcome::Error(failure) if failure.code == Code::Timeout), "signer {signer}: {outcome:?}");
        assert!(elapsed >= Duration::from_millis(if signer { 700 } else { 300 }) && elapsed < Duration::from_secs(5), "signer {signer}: {elapsed:?}");
        assert!(log_of(&log).iter().any(|line| line == "userauth request: no answer"), "signer {signer}: the request was sent");
        eventually("one disconnect", || events.ended.lock().unwrap().len() == 1);
    }
}
