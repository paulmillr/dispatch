use crate::error::{Code, Failure};
use crate::keys::{signature_blob, ssh_string};
use russh::client::{self, DisconnectReason, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::agent::AgentIdentity;
use russh::keys::{HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKey, PublicKeyOrCertificate};
use russh::{MethodKind, MethodSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// The server's host key as the trust-on-first-use sheet shows it.
#[derive(Clone, Debug)]
pub struct HostKey {
    pub algorithm: String,
    /// The SSH wire blob (what known_hosts stores, base64).
    pub blob: Vec<u8>,
    /// `SHA256:` plus unpadded base64, as `ssh-keygen -lf` prints it.
    pub fingerprint: String,
    pub openssh: String,
}

impl HostKey {
    fn of(key: &PublicKey) -> HostKey {
        HostKey {
            algorithm: key.algorithm().as_str().to_owned(),
            blob: key.to_bytes().unwrap_or_default(),
            fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
            openssh: key.to_openssh().unwrap_or_default(),
        }
    }
}

/// What a session asks its owner.
pub trait SessionEvents: Send + Sync + 'static {
    /// Trust this host key? May take as long as the user needs (the handshake deadline pauses).
    fn host_key(&self, key: HostKey) -> BoxFuture<bool>;
    /// The connection ended (lost, keepalive timeout, remote disconnect or `close`). Called exactly once,
    /// and only for a session whose connect succeeded.
    fn disconnected(&self, code: Code, message: String);
}

pub struct ConnectOptions {
    pub host: String,
    pub port: u16,
    /// Handshake deadline (TCP, version, key exchange), excluding the time the host key decision takes.
    pub timeout: Duration,
    /// Send a keepalive after this much silence; after `keepalive_max` unanswered ones the connection is dead.
    pub keepalive_interval: Duration,
    pub keepalive_max: usize,
}

#[derive(Debug)]
pub enum AuthOutcome {
    Success,
    /// `remaining`: bit 0 password, 1 publickey, 2 keyboard-interactive, 3 hostbased.
    Failure { remaining: u32, partial: bool },
    Error(Failure),
}

#[derive(Clone, Debug)]
pub struct Prompt {
    pub text: String,
    pub echo: bool,
}

/// Fires `disconnected` once, only after the connect succeeded (`arm`).
struct Link {
    events: Arc<dyn SessionEvents>,
    state: Mutex<LinkState>,
}

#[derive(Default)]
struct LinkState {
    armed: bool,
    ended: Option<(Code, String)>,
    fired: bool,
}

impl Link {
    fn end(&self, code: Code, message: String) {
        let fire = {
            let mut state = self.state.lock().unwrap();
            if state.ended.is_none() {
                state.ended = Some((code, message));
            }
            let fire = state.armed && !state.fired;
            if fire {
                state.fired = true;
            }
            fire.then(|| state.ended.clone().unwrap())
        };
        if let Some((code, message)) = fire {
            self.events.disconnected(code, message);
        }
    }

    fn arm(&self) {
        let fire = {
            let mut state = self.state.lock().unwrap();
            state.armed = true;
            let fire = state.ended.is_some() && !state.fired;
            if fire {
                state.fired = true;
            }
            fire.then(|| state.ended.clone().unwrap())
        };
        if let Some((code, message)) = fire {
            self.events.disconnected(code, message);
        }
    }
}

/// The handshake's deadline and the host key question, decided under one lock: the deadline never
/// passes while the owner is deciding (the time the user takes does not count), and once it has
/// passed the owner is never asked. russh runs the session on its own task, which outlives a
/// handshake that gave up, so without this a key exchange finishing late would call `host_key`
/// after `connect` had already reported its failure (and the owner had let go of its context).
#[derive(Default)]
struct Gate {
    deciding: bool,
    abandoned: bool,
}

struct Client {
    link: Arc<Link>,
    gate: Arc<Mutex<Gate>>,
    reason: Option<(Code, String)>,
}

impl client::Handler for Client {
    type Error = russh::Error;

    /// The initial key exchange only: russh 0.64.1 does not call this on a rekey, and its `kex_done`
    /// sees only the negotiated algorithm names, so a later exchange's host key is never compared with
    /// the trusted one. The hook a patch would need is in docs/security.md (Dispatch for iPhone, host keys).
    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate) -> Result<bool, Self::Error> {
        let PublicKeyOrCertificate::PublicKey { key, .. } = key else {
            // Host certificates are not part of v1: refuse rather than trust an unchecked CA.
            return Ok(false);
        };
        // Asked under the lock: `connect` cannot give up between this check and the question.
        let decision = {
            let mut gate = self.gate.lock().unwrap();
            if gate.abandoned {
                None
            } else {
                gate.deciding = true;
                Some(self.link.events.host_key(HostKey::of(key)))
            }
        };
        let Some(decision) = decision else { return Ok(false) };
        let trusted = decision.await;
        self.gate.lock().unwrap().deciding = false;
        Ok(trusted)
    }

    async fn disconnected(&mut self, reason: DisconnectReason<Self::Error>) -> Result<(), Self::Error> {
        self.reason = Some(match reason {
            DisconnectReason::ReceivedDisconnect(info) => (Code::Closed, format!("disconnected by the server: {}", info.message)),
            DisconnectReason::Error(error) => {
                let failure = Failure::from(error);
                (failure.code, failure.message)
            }
        });
        Ok(())
    }
}

impl Drop for Client {
    /// The session task owns the handler: dropping it means the connection is gone, however it ended.
    fn drop(&mut self) {
        let (code, message) = self.reason.take().unwrap_or((Code::Closed, "connection closed".into()));
        self.link.end(code, message);
    }
}

pub struct Session {
    handle: tokio::sync::Mutex<Handle<Client>>,
    link: Arc<Link>,
}

impl Session {
    pub async fn connect(options: ConnectOptions, events: Arc<dyn SessionEvents>) -> Result<Arc<Session>, Failure> {
        let link = Arc::new(Link { events, state: Mutex::new(LinkState::default()) });
        let gate = Arc::new(Mutex::new(Gate::default()));
        let config = Arc::new(client::Config {
            keepalive_interval: Some(options.keepalive_interval),
            keepalive_max: options.keepalive_max,
            nodelay: true,
            ..Default::default()
        });
        let client = Client { link: link.clone(), gate: gate.clone(), reason: None };
        let address = (options.host.clone(), options.port);
        let handshake = async move {
            let stream = tokio::net::TcpStream::connect(address)
                .await
                .map_err(|e| Failure::new(Code::Network, e.to_string()))?;
            let _ = stream.set_nodelay(true);
            client::connect_stream(config, stream, client).await.map_err(Failure::from)
        };
        let deadline = {
            let gate = gate.clone();
            async move {
                // The deadline only counts time spent outside the host key decision.
                let tick = Duration::from_millis(50);
                let mut spent = Duration::ZERO;
                loop {
                    tokio::time::sleep(tick).await;
                    let mut gate = gate.lock().unwrap();
                    if gate.deciding {
                        continue;
                    }
                    spent += tick;
                    if spent >= options.timeout {
                        gate.abandoned = true;
                        return;
                    }
                }
            }
        };
        let abandon = |gate: &Mutex<Gate>| gate.lock().unwrap().abandoned = true;
        let handle = tokio::select! {
            result = handshake => match result {
                Ok(handle) => handle,
                Err(failure) => {
                    abandon(&gate);
                    return Err(failure);
                }
            },
            () = deadline => return Err(Failure::new(Code::Timeout, "SSH handshake timed out")),
        };
        let session = Arc::new(Session { handle: tokio::sync::Mutex::new(handle), link });
        session.link.arm();
        Ok(session)
    }

    pub async fn auth_password(&self, user: &str, password: &str) -> AuthOutcome {
        let mut handle = self.handle.lock().await;
        outcome(handle.authenticate_password(user, password).await.map_err(Failure::from))
    }

    /// RSA keys sign rsa-sha2-512 (or rsa-sha2-256 when that is all the server lists), never ssh-rsa.
    pub async fn auth_key(&self, user: &str, key: Arc<PrivateKey>) -> AuthOutcome {
        let mut handle = self.handle.lock().await;
        let hash = if key.algorithm().is_rsa() {
            let advertised = tokio::time::timeout(Duration::from_secs(3), handle.best_supported_rsa_hash()).await;
            match advertised {
                Ok(Ok(Some(Some(HashAlg::Sha256)))) => Some(HashAlg::Sha256),
                _ => Some(HashAlg::Sha512),
            }
        } else {
            None
        };
        outcome(handle.authenticate_publickey(user, PrivateKeyWithHashAlg::new(key, hash)).await.map_err(Failure::from))
    }

    pub async fn auth_keyboard_interactive<F>(&self, user: &str, mut prompt: F) -> AuthOutcome
    where
        F: FnMut(String, String, Vec<Prompt>) -> BoxFuture<Option<Vec<String>>> + Send,
    {
        let mut handle = self.handle.lock().await;
        let mut response = match handle.authenticate_keyboard_interactive_start(user, None::<String>).await {
            Ok(response) => response,
            Err(error) => return AuthOutcome::Error(error.into()),
        };
        loop {
            match response {
                KeyboardInteractiveAuthResponse::Success => return AuthOutcome::Success,
                KeyboardInteractiveAuthResponse::Failure { remaining_methods, partial_success } => {
                    return AuthOutcome::Failure { remaining: bits(&remaining_methods), partial: partial_success };
                }
                KeyboardInteractiveAuthResponse::InfoRequest { name, instructions, prompts } => {
                    let count = prompts.len();
                    let prompts = prompts.into_iter().map(|p| Prompt { text: p.prompt, echo: p.echo }).collect();
                    let Some(answers) = prompt(name, instructions, prompts).await else {
                        return AuthOutcome::Error(Failure::new(Code::Cancelled, "keyboard-interactive cancelled"));
                    };
                    if answers.len() != count {
                        return AuthOutcome::Error(Failure::new(Code::Cancelled, "wrong number of keyboard-interactive answers"));
                    }
                    response = match handle.authenticate_keyboard_interactive_respond(answers).await {
                        Ok(response) => response,
                        Err(error) => return AuthOutcome::Error(error.into()),
                    };
                }
            }
        }
    }

    /// Public key auth where Swift signs (Secure Enclave, Keychain CryptoKit keys): `sign` gets the bytes
    /// to sign and returns the raw signature (Ed25519: 64 bytes; ECDSA: r‖s).
    pub async fn auth_signer(&self, user: &str, public: PublicKey, sign: SignCallback) -> AuthOutcome {
        let mut handle = self.handle.lock().await;
        let mut signer = ExternalSigner { sign: Arc::new(Mutex::new(sign)), algorithm: public.algorithm() };
        match handle.authenticate_publickey_with(user, public, None, &mut signer).await {
            Ok(result) => outcome(Ok(result)),
            Err(SignError::Send) => AuthOutcome::Error(Failure::new(Code::Closed, "connection closed")),
            Err(SignError::Failed(failure)) => AuthOutcome::Error(failure),
        }
    }

    pub async fn open_session(&self) -> Result<russh::Channel<client::Msg>, Failure> {
        let handle = self.handle.lock().await;
        handle.channel_open_session().await.map_err(Failure::from)
    }

    pub async fn close(&self) {
        let handle = self.handle.lock().await;
        let _ = handle.disconnect(russh::Disconnect::ByApplication, "", "").await;
        drop(handle);
        self.link.end(Code::Closed, "closed".into());
    }
}

fn outcome(result: Result<russh::client::AuthResult, Failure>) -> AuthOutcome {
    match result {
        Ok(russh::client::AuthResult::Success) => AuthOutcome::Success,
        Ok(russh::client::AuthResult::Failure { remaining_methods, partial_success }) => {
            AuthOutcome::Failure { remaining: bits(&remaining_methods), partial: partial_success }
        }
        Err(failure) => AuthOutcome::Error(failure),
    }
}

fn bits(methods: &MethodSet) -> u32 {
    methods.iter().fold(0, |bits, method| {
        bits | match method {
            MethodKind::Password => 1,
            MethodKind::PublicKey => 2,
            MethodKind::KeyboardInteractive => 4,
            MethodKind::HostBased => 8,
            _ => 0,
        }
    })
}

enum SignError {
    Send,
    Failed(Failure),
}

impl From<russh::SendError> for SignError {
    fn from(_: russh::SendError) -> Self {
        SignError::Send
    }
}

/// Asks the caller to sign: the bytes to sign in, the raw signature out (None: cancelled).
pub type SignCallback = Box<dyn FnMut(Vec<u8>) -> BoxFuture<Option<Vec<u8>>> + Send>;

struct ExternalSigner {
    sign: Arc<Mutex<SignCallback>>,
    algorithm: russh::keys::Algorithm,
}

impl russh::Signer for ExternalSigner {
    type Error = SignError;

    fn auth_sign(
        &mut self,
        _key: &AgentIdentity,
        _hash_alg: Option<HashAlg>,
        mut to_sign: Vec<u8>,
    ) -> impl Future<Output = Result<Vec<u8>, Self::Error>> + Send {
        let request = (self.sign.lock().unwrap())(to_sign.clone());
        let algorithm = self.algorithm.clone();
        async move {
            let raw = request.await.ok_or_else(|| SignError::Failed(Failure::new(Code::Cancelled, "signing cancelled")))?;
            let (name, signature) = signature_blob(&algorithm, &raw).map_err(SignError::Failed)?;
            // As the agent client does: the signature blob is appended, length-prefixed, to the signed data.
            let mut blob = Vec::new();
            ssh_string(&mut blob, name.as_bytes());
            ssh_string(&mut blob, &signature);
            ssh_string(&mut to_sign, &blob);
            Ok(to_sign)
        }
    }
}
