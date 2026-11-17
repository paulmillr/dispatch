// The russh engine, built in only with `DISPATCH_RUSSH=1` (Package.swift): without it this file compiles to nothing.
#if DISPATCH_RUSSH
import DispatchMobileSSHCore
import Foundation

/// The russh engine (Core/, Rust) behind the C ABI of Core/include/dispatch_mobile_ssh.h: the one file that calls
/// `dms_*`. Each operation's context is a retained box that the callback the header names as its last releases.
struct RusshEngine: EngineBackend {
  static let shared = RusshEngine()

  func connect(
    _ options: EngineConnectOptions, events: any EngineSessionEvents,
    connected: @escaping @Sendable (Result<any EngineSession, SSHTransportError>) -> Void
  ) {
    let sessionContext = Context.retain(SessionContext(events))
    let callbacks = dms_session_callbacks(
      context: sessionContext,
      host_key: { context, key, reply in
        let key = key!.pointee
        let reply = RusshReply(reply)
        Context.borrow(context, as: SessionContext.self).value.hostKey(
          EngineHostKey(algorithm: String(cString: key.algorithm), fingerprint: String(cString: key.fingerprint),
                        openSSH: String(cString: key.openssh)),
          answer: { reply.bool($0) })
      },
      disconnected: { context, code, message in
        Context.release(context, as: SessionContext.self).value.disconnected(RusshEngine.error(code, message))
      })
    let box = ConnectContext((session: sessionContext, connected: connected))
    options.host.withCString { host in
      var raw = dms_connect_options(
        host: host, port: UInt16(clamping: options.port), timeout_ms: milliseconds(options.timeout),
        keepalive_interval_ms: milliseconds(options.keepalive), keepalive_max: UInt32(max(0, options.keepaliveMax)))
      dms_connect(&raw, callbacks, Context.retain(box)) { context, session, code, message in
        let box = Context.release(context, as: ConnectContext.self).value
        if let session {
          box.connected(.success(RusshSession(session)))
        } else {
          // A failed connect never calls `disconnected`: the session context is ours to drop.
          _ = Context.release(box.session, as: SessionContext.self)
          box.connected(.failure(RusshEngine.error(code, message)))
        }
      }
    }
  }

  func parseKey(_ file: Data, passphrase: UnsafePointer<CChar>?) throws -> any EngineKey {
    var code: Int32 = 0
    var message: UnsafeMutablePointer<CChar>?
    let handle = file.withUnsafeBytes { bytes in
      dms_key_parse(bytes.bindMemory(to: UInt8.self).baseAddress, file.count, passphrase, &code, &message)
    }
    guard let handle else {
      defer { dms_string_free(message) }
      throw Self.error(code, message)
    }
    return RusshKey(handle)
  }

  /// The engine's result codes as the package's errors.
  static func error(_ code: Int32, _ message: UnsafePointer<CChar>?) -> SSHTransportError {
    let text = message.map { String(cString: $0) } ?? ""
    switch code {
    case DMS_TIMEOUT: return .timedOut(text.isEmpty ? "SSH" : text)
    case DMS_INVALID_KEY: return .invalidKey(text)
    case DMS_WRONG_PASSPHRASE: return .wrongPassphrase
    case DMS_CANCELLED: return .cancelled
    case DMS_UNSUPPORTED: return .unsupportedAuthentication(text)
    case DMS_CLOSED: return .channelClosed
    case DMS_REFUSED: return .commandFailed(status: -1, stderr: text)
    case DMS_NETWORK: return .network(text)
    // The connection's endpoint is filled in by `SessionLink.explain`.
    case DMS_HOST_NOT_FOUND: return .connectFailed(.hostNotFound, host: "", port: 0)
    case DMS_CONNECTION_REFUSED: return .connectFailed(.refused, host: "", port: 0)
    case DMS_UNREACHABLE: return .connectFailed(.unreachable, host: "", port: 0)
    case DMS_NO_ANSWER: return .connectFailed(.noAnswer, host: "", port: 0)
    case DMS_HOST_KEY_CHANGED: return .hostKeyChangedAtRekey(text)
    case DMS_PROTOCOL: return noCommonAlgorithm(text) ?? .protocolError(text)
    default: return .protocolError(text)
    }
  }

  /// russh's negotiation failure, "No common <kind> algorithm - ours: [...], theirs: [...]" (russh 0.65's
  /// `Error::NoCommonAlgo`, through `DMS_PROTOCOL`), as the Swift engine's case for the same condition.
  static func noCommonAlgorithm(_ text: String) -> SSHTransportError? {
    let kinds = ["Kex": "key exchange", "Key": "host key", "Cipher": "cipher", "Mac": "MAC", "Compression": "compression"]
    guard text.hasPrefix("No common "), let kind = text.dropFirst("No common ".count).split(separator: " ").first,
      let category = kinds[String(kind)]
    else { return nil }
    return .noCommonAlgorithm(category)
  }

  /// `dms_exited_fn`'s arguments (the refusal's message travels in `signal`).
  static func exit(kind: Int32, status: UInt32, signal: String) -> EngineExit {
    switch kind {
    case DMS_EXIT_STATUS: .status(status)
    case DMS_EXIT_SIGNAL: .signal(signal)
    case DMS_EXIT_REFUSED: .refused(signal)
    default: .lost
    }
  }
}

/// The engine's session; freed (and closed if still open) with the last reference.
final class RusshSession: EngineSession, @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { dms_session_free(pointer) }

  func close() { dms_session_close(pointer) }

  func authenticate(user: String, password: String, done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    let box = AuthContext(Login(done: done))
    user.withCString { user in
      password.withCString { dms_auth_password(pointer, user, $0, Context.retain(box), Self.authenticated) }
    }
  }

  func authenticate(user: String, key: any EngineKey, direct: Bool,
                    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    guard let key = key as? RusshKey else {
      return done(.failure(.invalidKey("the key was parsed by another SSH engine")))
    }
    let box = AuthContext(Login(done: done, keep: key))
    user.withCString { dms_auth_key(pointer, $0, key.pointer, direct, Context.retain(box), Self.authenticated) }
  }

  func authenticateKeyboardInteractive(
    user: String, prompt: @escaping @Sendable (KeyboardInteractiveChallenge, @escaping @Sendable ([String]?) -> Void) -> Void,
    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void
  ) {
    let box = AuthContext(Login(done: done, prompt: prompt))
    user.withCString {
      dms_auth_keyboard_interactive(pointer, $0, Context.retain(box), { context, name, instruction, prompts, count, reply in
        let box = Context.borrow(context, as: AuthContext.self).value
        let reply = RusshReply(reply)
        guard let prompt = box.prompt else { return reply.cancel() }
        let challenge = KeyboardInteractiveChallenge(
          name: name.map { String(cString: $0) } ?? "", instruction: instruction.map { String(cString: $0) } ?? "",
          prompts: (0..<count).map { KeyboardInteractiveChallenge.Prompt(text: String(cString: prompts![$0].text), echo: prompts![$0].echo) })
        prompt(challenge) { answers in if let answers { reply.strings(answers) } else { reply.cancel() } }
      }, Self.authenticated)
    }
  }

  func authenticate(user: String, signer publicKeyBlob: Data, direct: Bool,
                    sign: @escaping @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void,
                    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    let box = AuthContext(Login(done: done, sign: sign))
    publicKeyBlob.withUnsafeBytes { bytes in
      user.withCString {
        dms_auth_signer(pointer, $0, bytes.bindMemory(to: UInt8.self).baseAddress, publicKeyBlob.count, direct, Context.retain(box), { context, data, length, reply in
          let box = Context.borrow(context, as: AuthContext.self).value
          let reply = RusshReply(reply)
          guard let sign = box.sign else { return reply.cancel() }
          sign(Data(bytes: data!, count: length)) { signature in if let signature { reply.bytes(signature) } else { reply.cancel() } }
        }, Self.authenticated)
      }
    }
  }

  /// Every login's `done`: the last call for its context.
  private static var authenticated: dms_auth_fn {
    { context, code, remaining, _, message in
      let box = Context.release(context, as: AuthContext.self).value
      if code == DMS_OK {
        box.done(.success(.loggedIn))
      } else if code == DMS_AUTH_FAILED {
        // Same bits (`DMS_METHOD_*`).
        box.done(.success(.refused(remaining: EngineMethods(rawValue: remaining))))
      } else {
        box.done(.failure(RusshEngine.error(code, message)))
      }
    }
  }

  func exec(_ command: String, events: any EngineChannelEvents) {
    let context = ChannelContext.retain(events)
    command.withCString { command in
      dms_exec(pointer, command, context, ChannelContext.started, { context, bytes, length in
        Context.borrow(context, as: ChannelContext.self).events.stderr(Data(bytes: bytes!, count: length))
      }, ChannelContext.exited)
    }
  }

  func shell(term: String, columns: UInt32, rows: UInt32, events: any EngineChannelEvents) -> any EngineShell {
    let context = ChannelContext.retain(events)
    let pointer = term.withCString { term in
      dms_shell_open(self.pointer, term, columns, rows, context, ChannelContext.started, ChannelContext.exited)
    }
    return RusshShell(pointer)
  }
}

/// The engine's shell handle (for window changes); freed with the shell. Freeing never closes the channel.
final class RusshShell: EngineShell, @unchecked Sendable {
  let pointer: OpaquePointer?
  init(_ pointer: OpaquePointer?) { self.pointer = pointer }
  deinit { dms_shell_free(pointer) }

  func resize(columns: UInt32, rows: UInt32) { dms_shell_resize(pointer, columns, rows) }
}

/// The engine's parsed key; freed with the last SSHKey copy (and any login still holding it).
final class RusshKey: EngineKey, @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { dms_key_free(pointer) }

  var algorithm: String { String(cString: dms_key_algorithm(pointer)) }
  var publicKey: String { String(cString: dms_key_public_key(pointer)) }
  var fingerprint: String { String(cString: dms_key_fingerprint(pointer)) }
}

/// A `dms_reply *` answered later from Swift concurrency. Each is answered exactly once.
struct RusshReply: @unchecked Sendable {
  let pointer: OpaquePointer?
  init(_ pointer: OpaquePointer?) { self.pointer = pointer }

  func bool(_ value: Bool) { dms_reply_bool(pointer, value) }
  func cancel() { dms_reply_cancel(pointer) }
  func bytes(_ data: Data) {
    data.withUnsafeBytes { dms_reply_bytes(pointer, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
  }
  /// Keyboard-interactive answers: the C copies are wiped before they are freed (the engine wipes its own).
  func strings(_ values: [String]) {
    var copies = values.map { strdup($0) }
    defer {
      for copy in copies {
        if let copy { Engine.wipe(copy, count: strlen(copy)) }
        free(copy)
      }
    }
    copies.withUnsafeMutableBufferPointer { buffer in
      buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
        dms_reply_strings(pointer, $0, values.count)
      }
    }
  }
}

/// C context pointers: a box passed retained, borrowed by callbacks, taken back by the operation's last one.
private enum Context {
  static func retain(_ box: AnyObject) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(box).toOpaque()
  }

  static func borrow<T: AnyObject>(_ context: UnsafeMutableRawPointer?, as type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(context!).takeUnretainedValue()
  }

  static func release<T: AnyObject>(_ context: UnsafeMutableRawPointer?, as type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(context!).takeRetainedValue()
  }
}

/// A context's value as the object `Context` passes.
private final class Box<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// A session's events, for `host_key` and `disconnected`; released by `disconnected` or a failed connect.
private typealias SessionContext = Box<any EngineSessionEvents>

/// `connected` and the session's context it drops on failure.
private typealias ConnectContext = Box<(session: UnsafeMutableRawPointer,
                                        connected: @Sendable (Result<any EngineSession, SSHTransportError>) -> Void)>

/// Context of one login.
private typealias AuthContext = Box<Login>

/// One login's `done`, the question it asks, and the key it must keep alive.
private struct Login {
  let done: @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void
  var keep: RusshKey?
  var sign: (@Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void)?
  var prompt: (@Sendable (KeyboardInteractiveChallenge, @escaping @Sendable ([String]?) -> Void) -> Void)?
}

/// A channel's events. Retained twice, once for `started` and once for `exited`, so that neither can find it freed
/// whichever runs first (the engine's pump starts before `started` is called).
private final class ChannelContext: @unchecked Sendable {
  let events: any EngineChannelEvents
  private init(_ events: any EngineChannelEvents) { self.events = events }

  static func retain(_ events: any EngineChannelEvents) -> UnsafeMutableRawPointer {
    let box = Unmanaged.passRetained(ChannelContext(events))
    _ = box.retain()
    return box.toOpaque()
  }

  static var started: dms_exec_started_fn {
    { context, fd, code, message in
      let box = Unmanaged<ChannelContext>.fromOpaque(context!)
      if fd >= 0 {
        box.takeUnretainedValue().events.opened(.success(fd))
        box.release()
      } else {
        box.takeUnretainedValue().events.opened(.failure(RusshEngine.error(code, message)))
        // No `exited` follows a failed start: both references go.
        box.release()
        box.release()
      }
    }
  }

  static var exited: dms_exited_fn {
    { context, kind, status, signal in
      let events = Context.release(context, as: ChannelContext.self).events
      events.exited(RusshEngine.exit(kind: kind, status: status, signal: signal.map { String(cString: $0) } ?? ""))
    }
  }
}

private func milliseconds(_ duration: Duration) -> UInt32 {
  UInt32(clamping: duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
}
#endif
