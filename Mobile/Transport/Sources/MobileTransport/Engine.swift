import Foundation
import SSHEngine
import Synchronization

// The seam between the package's public API and the SSH engine under it. `SSHConnection`, `SSHExec`, `SSHShell` and
// `SSHKey` talk only to the protocols below; `SwiftEngine.swift` implements them over Sources/SSHEngine, and, in a build
// with `DISPATCH_RUSSH` (Package.swift), `RusshEngine.swift` over the Rust engine's C ABI (the only file that calls
// `dms_*`). The doc comments are the contract, written as the russh engine first did it. "russh:" marks what that
// engine happens to do where nothing above it depends on it, so another engine may differ (and should say how).

/// Which SSH engine the package runs on. The cases are the engines this build has: `.swift` always, `.russh` only when
/// built with `DISPATCH_RUSSH=1`, so `allCases` is what an app can offer and `init(rawValue:)` refuses an engine this
/// build lacks.
public enum SSHTransportEngine: String, Sendable, Hashable, CaseIterable {
  /// The Swift engine (Sources/SSHEngine), through its adapter (`SwiftEngine.swift`) over the driver
  /// (`SSHClient.connector()`): connections and key files, as the seam's contract below says, with the differences
  /// `SwiftEngine` lists. The default.
  case swift
  #if DISPATCH_RUSSH
  /// Rust russh behind the C ABI in Core/, built in only with `DISPATCH_RUSSH=1`.
  case russh
  #endif

  /// The engine of a build that is told nothing else: the Swift one.
  public static let standard: SSHTransportEngine = .swift

  /// The engine new connections and key files use, process-wide: `standard` unless set. `SSHConnection.connect` and
  /// `SSHKey.openSSH` read it as they start, so set it before the first (at launch): a connection keeps the engine it
  /// started with, and a key file parsed by one engine fails a login on another's connection (`invalidKey`); CryptoKit
  /// and Secure Enclave keys work with either. In Debug builds the default comes from the environment variable
  /// `DISPATCH_SSH_ENGINE` (a raw value of `allCases`; another value, `russh` in a build without it included, stops the
  /// process), so `DISPATCH_RUSSH=1 DISPATCH_SSH_ENGINE=russh swift test` runs every test on russh
  /// (`TEST_RUNNER_DISPATCH_SSH_ENGINE` under xcodebuild). Release builds ignore it.
  public static var preferred: SSHTransportEngine {
    get { current.withLock { $0 } }
    set { current.withLock { $0 = newValue } }
  }

  private static let current = Mutex(environmentChoice ?? standard)

  /// The engine `DISPATCH_SSH_ENGINE` names in a Debug build, read once, nil when it is unset (and always in Release
  /// builds): what `preferred` starts as, and what an app's own choice of engine yields to.
  public static let environmentChoice: SSHTransportEngine? = {
    #if DEBUG
    if let name = ProcessInfo.processInfo.environment["DISPATCH_SSH_ENGINE"], !name.isEmpty {
      guard let engine = SSHTransportEngine(rawValue: name) else {
        preconditionFailure("DISPATCH_SSH_ENGINE=\(name): expected one of \(allCases.map(\.rawValue))"
                            + (name == "russh" ? " (russh is built in only with DISPATCH_RUSSH=1)" : ""))
      }
      return engine
    }
    #endif
    return nil
  }()

  /// The engine behind this choice: the one place an engine is plugged in.
  var backend: any EngineBackend {
    switch self {
    case .swift:
      // SwiftEngine.swift: the adapter over Sources/SSHEngine's facade, on its driver.
      SwiftEngine(connector: SSHClient.connector())
    #if DISPATCH_RUSSH
    case .russh:
      RusshEngine.shared
    #endif
    }
  }
}

// MARK: - The engine

/// An SSH client engine: connections and key files. Rules for everything it hands out:
///
/// - **Callbacks.** Each operation ends with one last callback, called exactly once (connect: `connected`; a login:
///   `done`; a channel: `opened` when it failed, else `exited`), after which nothing it was given is called again or
///   kept. Callbacks run on the engine's threads, never the caller's actor, and may run before the starting call
///   returned, even inside it (russh: its tokio runtime's two `dispatch-ssh` workers, shared by every session; a call
///   with arguments it cannot use, such as a signer's blob it cannot parse, ends inside the call). The wrappers bridge
///   every result through `Once` and locks, so either is fine; a callback must not block (a question is answered
///   later through its `answer`).
/// - **Questions** (host key, keyboard-interactive prompts, signatures) carry an `answer` the wrappers call exactly once,
///   from any thread, whenever the app has decided; they never leave one unanswered. The engine waits for it without a
///   deadline of its own except where a member says so. An answer that comes after its operation ended does nothing.
/// - **Cancellation** never reaches the engine: an operation in flight runs to its last callback, and there is no way
///   to abandon one but closing the session (or, for a channel, its socket). Cancelling the Swift task of
///   `SSHConnection.connect` makes the wrappers withdraw the open questions, which then answer at once: during the
///   handshake nothing changes until `connected`, after which the wrappers close the session before any login; with
///   the host key question open, or asked after, it answers false (the connect fails; one asked after is not put to
///   the app, nor is a later signature or prompt); a signature or prompt answers nil (that login
///   ends with `cancelled`, a direct one reported `withdrawn`); a password or file-key login waits for the server's
///   answer, and then the wrappers close the session.
/// - **Deadlines** are only these: the handshake's (`connect`), a direct login's answer (10 s) and RSA's wait for
///   `server-sig-algs` (3 s). Other logins, channel opens and the shell's requests wait until answered or the connection
///   ends; keepalives (`connect`) bound that once logged in.
/// - **Errors** are `SSHTransportError` values, as named per member. russh's codes map as `RusshEngine.error` shows
///   (`DISPATCH_RUSSH` builds).
protocol EngineBackend: Sendable {
  /// Connects to `options.host`:`options.port`, runs the version exchange and the first key exchange, and asks
  /// `events.hostKey` whether to trust the server's key. `connected` runs exactly once: `.success` once that key
  /// exchange completed with a trusted key (nothing logged in yet), else `.failure`, after which `events` is never
  /// called and the engine keeps no reference to it. After a success `events.disconnected` runs exactly once, when the
  /// connection ends for any reason. The wrappers time the handshake from this call to `connected`, minus the host key
  /// question (`SSHConnection.Timings`), so `connected` should follow the key exchange at once.
  ///
  /// - Name resolution and TCP: every address the name resolves to, in order, until one connects; TCP_NODELAY.
  ///   Failures: no address `connectFailed(.hostNotFound)`, ECONNREFUSED `connectFailed(.refused)`,
  ///   ENETUNREACH/EHOSTUNREACH/ENETDOWN/EADDRNOTAVAIL `connectFailed(.unreachable)`, ETIMEDOUT
  ///   `connectFailed(.noAnswer)`, a reset or EOF `channelClosed`, another socket error `network(<the OS's text>)`. The
  ///   endpoint inside `connectFailed` may be left empty: `SessionLink.explain` fills it in.
  /// - The deadline (`options.timeout`) covers resolution, TCP, the version exchange and the key exchange, and pauses
  ///   while the host key question is open (the user's time does not count). Once it passed the connect fails at once,
  ///   by how far it got: resolving `timedOut("looking up the host's address")`, TCP `connectFailed(.noAnswer)`, SSH
  ///   `timedOut("the SSH handshake")`; and the question is never asked after that (russh: a lock decides between the
  ///   deadline and the question, since its key exchange runs on in a task of its own). russh: time is counted in 50 ms
  ///   ticks outside the question, so the failure comes up to 50 ms late; a zero timeout is 1 ms.
  /// - The host key question: asked once per connection, at the first key exchange, always before `connected`, with
  ///   the key as `EngineHostKey` describes. `answer(true)` goes on, `answer(false)` fails the connect (russh:
  ///   `protocolError("Unknown server key")`, because its rejected-key code has no mapping of its own; the wrappers
  ///   replace it with `hostKeyRejected` or `hostKeyMismatch` from the app's decision, so it only shows when the app
  ///   trusted the key but the connect was cancelled meanwhile). A host certificate, or a key the engine cannot encode,
  ///   fails the same way without asking.
  /// - Rekeys never ask: each must present the first exchange's key (the same blob) under the same negotiated host key
  ///   algorithm, stricter than OpenSSH (rsa-sha2-256 after rsa-sha2-512 is a change), or the connection ends before
  ///   the new keys are used, `disconnected(.hostKeyChangedAtRekey(<reason>))` (russh's reasons: "the host key
  ///   algorithm changed at a key re-exchange (<old>, now <new>)", "the server presented a different host key at a key
  ///   re-exchange"). That outcome is final for the host, like a mismatch. russh: rekeys come from its default limits.
  /// - Algorithms: never `ssh-rsa` (SHA-1) host signatures; RSA host keys through rsa-sha2-512/256. russh: its default
  ///   preferences otherwise.
  /// - Keepalives (`options.keepalive`, `options.keepaliveMax`) start once logged in: after `keepalive` with nothing
  ///   received from the server a `keepalive@openssh.com` request (want reply) goes; anything received resets the
  ///   count; the silent interval after `keepaliveMax` unanswered ones ends the connection with
  ///   `disconnected(.timedOut("the host stopped answering"))`. So a dead link shows after (keepaliveMax + 1) x
  ///   keepalive of silence: 3 s at 1 s x 2 (the setting `KeepaliveTests` runs, which checks only that the end comes
  ///   within 15 s), 60 s at the default 15 s x 3. russh: a zero `keepalive` sends none (one a day, never fatal); a
  ///   zero `keepaliveMax` sends them but never ends the connection; nothing detects a silent server before the login
  ///   ended (only a direct login has a deadline).
  /// - `disconnected` may come before `connected` reports success (russh arms it just before), when the link dies in
  ///   between; the wrappers allow it.
  func connect(
    _ options: EngineConnectOptions, events: any EngineSessionEvents,
    connected: @escaping @Sendable (Result<any EngineSession, SSHTransportError>) -> Void)

  /// Parses a private key file, synchronously on the caller's thread. `passphrase` is NUL-terminated, or nil for none,
  /// and valid only during the call: the engine wipes any copy it makes (the caller wipes its own); russh reads it up to
  /// the first NUL. The private material never comes back to Swift.
  ///
  /// - Formats: OpenSSH (`openssh-key-v1`: Ed25519, ECDSA P-256/384/521, RSA; plain or passphrase-encrypted), PEM and
  ///   PKCS#8; russh also reads PuTTY (PPK) files.
  /// - Errors: not UTF-8 text `invalidKey("not a text key file")`; more than 8 certificate markers (`-cert-v01@`) in
  ///   its base64 runs `invalidKey("the key file holds nested certificates")` (a stack bound against crafted files,
  ///   checked before any decoder); encrypted and no passphrase (an empty one counts as none) or the wrong one
  ///   `wrongPassphrase`; another key type (DSA, …) `unsupportedAuthentication("unsupported key type <name>")`;
  ///   anything else unreadable `invalidKey(<the decoder's text>)` (russh: "Could not read key" for text that is no
  ///   key). The wrappers refuse an `algorithm` outside `SSHKey.Kind` with `unsupportedAuthentication(<algorithm>)`.
  func parseKey(_ file: Data, passphrase: UnsafePointer<CChar>?) throws -> any EngineKey
}

/// What `EngineBackend.connect` is given. The adapter converts: russh takes the port as UInt16 (clamped), durations as
/// UInt32 milliseconds (clamped) and the count as UInt32.
struct EngineConnectOptions: Sendable {
  /// A name or an address, as the user typed it.
  let host: String
  let port: Int
  /// The handshake's deadline, without the host key question.
  let timeout: Duration
  /// Silence after which a keepalive goes (zero: none).
  let keepalive: Duration
  /// Unanswered keepalives before the connection counts as dead (zero: never).
  let keepaliveMax: Int
}

/// The server's host key as the trust question shows it. The strings must be exactly these forms: the app's known-hosts
/// store keeps `openSSH` and compares it as a string, so another form would read as a changed key for every saved host.
struct EngineHostKey: Sendable {
  /// The key's type name: `ssh-ed25519`, `ecdsa-sha2-nistp256` (384, 521), `ssh-rsa` for any RSA key (the key type,
  /// not the signature algorithm negotiated).
  let algorithm: String
  /// `SHA256:` and the unpadded base64 of the key's SHA-256 over its wire blob, as `ssh-keygen -lf` prints it.
  let fingerprint: String
  /// `<type> <base64 of the wire blob>`: one space, no comment.
  let openSSH: String
}

/// What a session tells its owner (`SessionLink`).
protocol EngineSessionEvents: AnyObject, Sendable {
  /// Trust this key? Asked as `EngineBackend.connect` says; `answer` comes later, exactly once.
  func hostKey(_ key: EngineHostKey, answer: @escaping @Sendable (Bool) -> Void)

  /// The connection ended: exactly once per session that connected, the last call for these events. The first reason
  /// stands: `close()`, the release of the session, the server's DISCONNECT, EOF or a reset `channelClosed`; keepalives
  /// `timedOut("the host stopped answering")`; a rekey's key `hostKeyChangedAtRekey`; another socket error
  /// `network(…)`; a protocol violation `protocolError(…)`. Channels and logins still pending end through their own
  /// callbacks, before or after this one.
  func disconnected(_ reason: SSHTransportError)
}

// MARK: - A connection

/// One connected session, owned by its `SSHConnection` alone: channels hold no reference to it.
///
/// Releasing the last reference closes the connection if it is still open (`disconnected` follows), whatever channels
/// are open. Logins run one at a time (the wrappers start the next after `done`); channels may open while others run.
/// russh: every login, channel open and `close` takes the session's lock in call order, so they queue: a channel opens
/// only after the one before got its confirmation (concurrent opens cost a round trip each, one after another), and a
/// `close` during a login takes effect when the login ended.
///
/// After the connection ended everything stays safe to call: `close` does nothing (no second `disconnected`), a
/// channel's `opened` reports `channelClosed`, a login ends with an error (see the logins).
protocol EngineSession: AnyObject, Sendable {
  /// Disconnects (SSH_MSG_DISCONNECT, by application) and returns at once; `disconnected(.channelClosed)` follows.
  /// Every channel ends (`exited(.lost)`, or the status that already arrived).
  func close()

  // Logins. Each runs `done` exactly once: `.loggedIn`; `.refused(remaining:)` for the server's USERAUTH_FAILURE, a
  // partial success included (the wrappers go on with the next credential the remaining methods allow, and stop with
  // `authenticationFailed(methods:)` when none is left); `.failure` for anything else. The wrappers try credentials in
  // order on one connection, each once.
  //
  // russh, on a connection that ends while a login waits for its answer: `.refused(remaining: [])` (it cannot tell the
  // end from a refusal naming no method), so the connect throws `authenticationFailed(methods: [])`, final for the host.
  // Only a direct login turns this into `channelClosed`; another engine should report `.failure(.channelClosed)` for
  // every login. A login started after the end fails with `channelClosed`.

  /// `password` request. No question, no deadline: it waits for the server's answer.
  /// russh: user and password reach the engine up to their first NUL.
  func authenticate(user: String, password: String, done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void)

  /// Public key login with a key this engine parsed (`parseKey`); one parsed by another engine fails with
  /// `invalidKey`. RSA signs rsa-sha2-512, or rsa-sha2-256 when the server's `server-sig-algs` (the EXT_INFO after its
  /// first NEWKEYS, waited for up to 3 s) names that and not rsa-sha2-512; never ssh-rsa, so a server that takes only
  /// SHA-1 refuses the key (`DirectLoginTests.testDirectRSAFollowsServerSigAlgs`).
  ///
  /// Not `direct`: as SSH clients do, the userauth service request (on the first login), the query (is this key
  /// acceptable?), then after PK_OK the signed request. No deadline.
  ///
  /// `direct` (`SSHCredential.directKey`): the signed request at once, without the query (RFC 4252 section 7) and, as
  /// the connection's first login, right behind SERVICE_REQUEST without waiting for its accept (which, with any
  /// EXT_INFO, then arrives while the request is pending): one round trip instead of three. Outcomes, which
  /// `DirectKeyAnswer` reports to the app (`SSHConnection.authenticate`): the server's answer `.loggedIn` or
  /// `.refused` (later logins on the connection work as usual); the connection ending before an answer
  /// `.failure(.channelClosed)`, never a refusal (russh also counts a refusal naming no method as that end); no answer
  /// within 10 s of the request `.failure(.timedOut("the login"))`, after which the engine closes the connection
  /// (`disconnected` follows). A server that cannot take a request sent before its accept shows so; the app then
  /// connects again and asks first.
  func authenticate(user: String, key: any EngineKey, direct: Bool,
                    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void)

  /// RFC 4256. `prompt` runs once per INFO_REQUEST, in order, the next only after the last answer was used (russh: a
  /// round with no prompts is asked too). `answer` takes one response per prompt (the engine wipes its copies), or nil
  /// to cancel: nil and a wrong count end the login with `.failure(.cancelled)`. No submethods, no deadline.
  func authenticateKeyboardInteractive(
    user: String, prompt: @escaping @Sendable (KeyboardInteractiveChallenge, @escaping @Sendable ([String]?) -> Void) -> Void,
    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void)

  /// Public key login where Swift signs (CryptoKit, Secure Enclave): `publicKeyBlob` is the key's SSH wire blob,
  /// Ed25519 or ECDSA. `sign` runs once with the bytes to sign (the session id and the USERAUTH_REQUEST, RFC 4252
  /// section 7); `answer` takes the raw signature (Ed25519's 64 bytes, ECDSA's fixed-width r‖s, which the engine
  /// encodes as mpints) or nil to decline. Not `direct`: `sign` runs after PK_OK. `direct`: as the request is written,
  /// before the server said anything about the key, and the 10 s deadline (`authenticate(user:key:direct:done:)`)
  /// starts once `answer` came, so the signer's own time (Face ID) does not count; declining sends nothing more for it.
  ///
  /// Failures: declined `.failure(.cancelled)`; a signature of the wrong length `.failure(.invalidKey(…))`; a blob the
  /// engine cannot parse `.failure(.invalidKey(…))` without asking (russh: inside the call); an empty blob
  /// `.failure(.protocolError("invalid arguments"))`. russh: an RSA blob is asked to sign, then fails with
  /// `.failure(.unsupportedAuthentication("external signing for … is unsupported"))`.
  func authenticate(user: String, signer publicKeyBlob: Data, direct: Bool,
                    sign: @escaping @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void,
                    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void)

  // Channels. Both open a session channel (a round trip) and hand `events` the caller's end of a socketpair; then the
  // engine pumps the channel through it. The socket (both engines must match, since `HelperTransport`, `FileHandle`
  // and `Descriptor` drive it unchanged):
  //
  // - AF_UNIX, SOCK_STREAM, blocking on the caller's side, FD_CLOEXEC and SO_NOSIGPIPE on both ends, 1 MiB send and
  //   receive buffers. It belongs to the caller from `opened` on; the engine never touches the caller's number (the
  //   wrappers shut it down, dup it, hand it to `FileHandle`, and close it when they like).
  // - Output: channel data is written to the socket in order, read from the channel only as fast as the socket drains,
  //   so a slow reader stops the remote writer (socket buffers, russh's queue of 100 messages and the SSH window bound
  //   what waits: `MeasurementTests.testSlowReaderBoundsBuffering`). Input: what the caller writes goes to the channel
  //   as fast as the remote's window allows (russh: read in 256 KiB chunks).
  // - The remote's EOF shuts the socket's other end for writing: the caller reads end of file after all the data.
  // - When the channel closed (or the connection ended, or the engine closed it) the engine stops reading it, closes
  //   its end entirely (the caller's reads end, writes fail with EPIPE) and then calls `exited`, exactly once, as the
  //   last call: a refusal first, else the exit status, else the signal, else `.lost`.
  // - russh forgets a channel once it sent its own close and drops the server's reply, so the engine ends the channel
  //   itself when it closes one: a status that arrives after that is lost.

  /// Starts `command` (no PTY). `opened(.success(fd))` comes once the channel is open and the exec request (want reply)
  /// sent, before the reply: what the caller writes at once follows the request as far as the channel's window allows
  /// (OpenSSH's sshd grants it only once the command started), and output that comes before the reply reads as usual.
  /// `opened(.failure)` when the channel did not open: the server refused it `protocolError(…)` (russh: "Failed to
  /// open channel (ConnectFailed)" and the like), the connection is gone `channelClosed`, no socketpair `network(…)`;
  /// that is the last call.
  ///
  /// Then: `stderr` (extended data type 1; other types are dropped) in arrival order, as it comes, not paced by the
  /// caller, every chunk before `exited`. The caller's end of input (shutdown(SHUT_WR), or close) sends EOF after what
  /// it wrote; the channel stays open for output. A refused exec request (CHANNEL_FAILURE before any SUCCESS) is the
  /// channel's end: the engine closes it, the socket reads end of file, `exited(.refused("the server refused the exec
  /// request"))` (that text is the user's: "The host refused to run the helper: …"). A channel that closes before any
  /// reply reports `.lost`. A caller that closed its socket entirely gets EOF sent, and the engine closes the channel
  /// when the command next writes (`exited` with what came before, usually `.lost`; russh notices only on that write, so
  /// a command that never writes again keeps its channel until it ends).
  func exec(_ command: String, events: any EngineChannelEvents)

  /// Opens an interactive login shell: the channel, then `pty-req` (want reply: `term`, `columns` x `rows`, at least 1
  /// each, no pixel size, no terminal modes) and `shell` (want reply), each confirmed before the next; then
  /// `opened(.success(fd))`, with what arrived before the confirmations delivered first. No `env` requests, and no
  /// `stderr` (the PTY merges it). Returns the shell's control at once, before `opened`; it is valid whatever happens.
  ///
  /// `opened(.failure)`, the last call: a refused `pty-req` `commandFailed(status: -1, stderr: "the server refused the
  /// terminal (pty-req)")`, a refused `shell` `commandFailed(status: -1, stderr: "the server refused the shell
  /// request")` (the engine closes the channel in both cases; the connection stays up), a channel that closed first
  /// `channelClosed`, and as `exec`'s open.
  ///
  /// Unlike exec the caller's end of input (shutdown(SHUT_WR), or close) closes the channel at once (a PTY has no end of
  /// file) and leaves the connection up: `exited` then reports a status only if one arrived before (russh: what is
  /// already queued goes first), else `.lost`. The server decides when the shell itself ends (sshd hangs it up).
  /// Never `exited(.refused)`.
  func shell(term: String, columns: UInt32, rows: UInt32, events: any EngineChannelEvents) -> any EngineShell
}

/// How a login ended, short of an error (`EngineSession`).
enum EngineAuthOutcome: Sendable, Equatable {
  case loggedIn
  /// The server's USERAUTH_FAILURE, a partial success too: the methods it still allows.
  case refused(remaining: EngineMethods)
}

/// Authentication methods a server allows.
struct EngineMethods: OptionSet, Sendable, Hashable {
  let rawValue: UInt32
  static let password = EngineMethods(rawValue: 1)
  static let publicKey = EngineMethods(rawValue: 2)
  static let keyboardInteractive = EngineMethods(rawValue: 4)
  static let hostbased = EngineMethods(rawValue: 8)

  /// RFC 4252's names, in this order (`SSHTransportError.authenticationFailed(methods:)`).
  var names: [String] {
    [(Self.publicKey, "publickey"), (.password, "password"), (.keyboardInteractive, "keyboard-interactive"),
     (.hostbased, "hostbased")]
      .filter { contains($0.0) }.map(\.1)
  }
}

/// What a channel tells its owner (`ExecState`). Calls come from one engine task per channel, in this order:
/// `opened` once; then, if it succeeded, any `stderr` and finally `exited` once. They may race `opened`'s return to the
/// wrappers (a fast channel can call `stderr` or even `exited` before the wrappers saw the descriptor), which they allow.
protocol EngineChannelEvents: AnyObject, Sendable {
  /// The caller's end of the socketpair, or why the channel did not open (then the last call).
  func opened(_ result: Result<Int32, SSHTransportError>)
  /// A chunk of the command's stderr, valid as given (exec only).
  func stderr(_ data: Data)
  /// How the channel ended; the last call.
  func exited(_ exit: EngineExit)
}

/// How a channel ended. `SSHExec.exitStatus()` makes `.status` the status (as Int32 bit pattern), `.signal` 128,
/// `.lost` `channelClosed`, `.refused` `commandFailed(status: -1, stderr: <message>)`; `SSHShell` makes `.refused`
/// `channelClosed` too.
enum EngineExit: Sendable, Equatable {
  /// exit-status, as the server sent it.
  case status(UInt32)
  /// exit-signal: the signal's name without `SIG` (russh: `TERM`; a name it does not know as `Custom("…")`). Nothing
  /// reads it.
  case signal(String)
  /// The channel or connection went away without a status.
  case lost
  /// The server refused the exec request: the engine's message.
  case refused(String)
}

/// A shell's control side. Releasing it never closes the channel: the socket decides the channel's lifetime.
protocol EngineShell: AnyObject, Sendable {
  /// Asks for a `window-change` (no pixel size) and returns at once; it never fails. Changes reach the server in call
  /// order from one engine task; a size superseded before it was sent is skipped (the latest wins), as is one equal to
  /// the last sent (at first the opening size); one asked before the shell opened is sent once it has; changes after
  /// the channel closed, or after a failed open, are dropped. The wrappers stop calling it once the shell ended.
  func resize(columns: UInt32, rows: UInt32)
}

/// A key file the engine parsed (`EngineBackend.parseKey`), usable for logins on that engine's connections. Released
/// with its last reference (every `SSHKey` copy, and any login still using it).
protocol EngineKey: AnyObject, Sendable {
  /// The key's type name: `ssh-ed25519`, `ecdsa-sha2-nistp256` (384, 521), `ssh-rsa`.
  var algorithm: String { get }
  /// The OpenSSH public key line, `<type> <base64 of the wire blob>`, followed by a space and the file's comment when
  /// it has one (russh keeps it; what the app shows to copy into `authorized_keys`).
  var publicKey: String { get }
  /// `SHA256:` and the unpadded base64 of the blob's SHA-256, as `ssh-keygen -lf` prints it.
  var fingerprint: String { get }
}

// MARK: - Shared helpers

enum Engine {
  /// Overwrites `count` bytes at `pointer` with zeros in a way the optimizer keeps (`memset_s`): for copies of
  /// secrets (keyboard-interactive answers, passphrases) before their memory is freed.
  static func wipe(_ pointer: UnsafeMutableRawPointer?, count: Int) {
    guard let pointer, count > 0 else { return }
    _ = memset_s(pointer, count, 0, count)
  }
}

/// A value set once, from any thread: the first `set` wins and later ones do nothing; every wait, before or after,
/// gets that value. An operation's last callback (as a `Result`), an answer, how a channel or connection ended.
final class Once<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?
  private var waiters: [CheckedContinuation<Value, Never>] = []

  func set(_ value: Value) {
    let waiters = lock.withLock { () -> [CheckedContinuation<Value, Never>] in
      guard stored == nil else { return [] }
      stored = value
      defer { self.waiters = [] }
      return self.waiters
    }
    waiters.forEach { $0.resume(returning: value) }
  }

  /// The value, once set.
  var current: Value? { lock.withLock { stored } }

  var value: Value {
    get async {
      await withCheckedContinuation { continuation in
        let ready = lock.withLock { () -> Value? in
          if stored == nil { waiters.append(continuation) }
          return stored
        }
        if let ready { continuation.resume(returning: ready) }
      }
    }
  }
}

extension Data {
  /// SSH wire string: u32 length then bytes.
  mutating func appendSSHString(_ bytes: Data) {
    var length = UInt32(bytes.count).bigEndian
    Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
    append(bytes)
  }
}
