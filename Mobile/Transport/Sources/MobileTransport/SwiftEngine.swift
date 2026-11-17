import Foundation
import SSHEngine

/// The Swift engine (Sources/SSHEngine) behind the seam (`Engine.swift`), over its facade (`SSHConnector`,
/// `SSHSession`, `ExecChannel`, `ShellChannel`, `KeyFile`). Every operation runs on a task of its own, detached from
/// the caller, and ends with its one callback from there: callbacks run on the global executor's threads, never the
/// caller's actor, and never inside the starting call except where the arguments are refused at once (a key from
/// another engine, an empty or unusable signer blob). Nothing here cancels a facade call: cancellation stays the
/// wrappers' (they withdraw questions, which then answer at once, and close the session).
///
/// Where it differs from russh, as the seam allows ("russh:" there): logins, channel opens and `close` do not queue
/// behind each other (a `close` during a login ends it at once, `.failure(.channelClosed)`); a connection that ends
/// while a login waits reports `.failure(.channelClosed)`, except at the server's attempt limit (a DISCONNECT, or a close
/// after an earlier refusal, while an asked-for request waits: a refusal with no method left, as russh reports every
/// end of a non-direct login); the host key question is asked only
/// once the server proved it holds the key; a keyboard-interactive round with no prompts is answered without asking;
/// an RSA signer blob is refused without asking; a zero `keepaliveMax` is the engine's largest count (100), not
/// "never" (`options(_:)`).
struct SwiftEngine: EngineBackend {
  /// The driver over Network.framework (`SSHClient.connector()`), or a test's.
  let connector: any SSHConnector

  func connect(
    _ options: EngineConnectOptions, events: any EngineSessionEvents,
    connected: @escaping @Sendable (Result<any EngineSession, SSHTransportError>) -> Void
  ) {
    let connector = connector, engineOptions = Self.options(options)
    Task.detached {
      let session: any SSHSession
      do throws(SSHError) {
        session = try await connector.connect(engineOptions) { key in await Self.trust(key, events: events) }
      } catch {
        // A failed connect has no session and no `ended()`: `events` is never called again.
        return connected(.failure(error.transportError))
      }
      connected(.success(SwiftEngineSession(session)))
      // The one `disconnected`: the facade decides the first reason once.
      events.disconnected(await session.ended().transportError)
    }
  }

  /// The seam's options for the facade. The facade refuses what russh clamps (`ConnectOptions.validate`): a zero
  /// timeout is 1 ms (as russh), a zero keepalive none, a keepalive count outside 1...100 the nearest end of it (russh:
  /// a zero count never ends the connection; here it is 100, so a silent server is given up when a keepalive falls
  /// due with 100 unanswered, (100 + 1) × the interval after its last packet). A port outside UInt16 is
  /// clamped as russh does; port 0 fails the connect with `protocolError` (russh: as the OS refuses it).
  static func options(_ options: EngineConnectOptions) -> ConnectOptions {
    let count = options.keepaliveMax <= 0 ? Limits.keepaliveCountMax : min(options.keepaliveMax, Limits.keepaliveCountMax)
    return ConnectOptions(
      host: options.host, port: UInt16(clamping: options.port), handshakeTimeout: max(options.timeout, .milliseconds(1)),
      keepaliveInterval: options.keepalive > .zero ? options.keepalive : nil, keepaliveCountMax: count)
  }

  /// The host key question as the seam asks it. The facade cancels this task when it abandons the connect; then the
  /// question answers no at once (and is not asked if it was not yet), and the app's later answer does nothing.
  static func trust(_ key: SSHEngine.HostKey, events: any EngineSessionEvents) async -> Bool {
    let shown = EngineHostKey(algorithm: key.keyType, fingerprint: key.fingerprint, openSSH: key.openSSH)
    return await SwiftEngineQuestion.ask(withdrawn: false) { answer in events.hostKey(shown, answer: answer) }
  }

  func parseKey(_ file: Data, passphrase: UnsafePointer<CChar>?) throws -> any EngineKey {
    // Copies the engine wipes when they go (`SecretBytes`); the caller wipes its own.
    let contents = SecretBytes(copying: file)
    let secret = passphrase.map { passphrase in
      let count = strlen(passphrase)
      return SecretBytes(count: count) { $0.copyMemory(from: UnsafeRawBufferPointer(start: passphrase, count: count)) }
    }
    do throws(SSHError) {
      return SwiftEngineKey(try KeyFile.parse(contents, passphrase: secret))
    } catch {
      throw error.keyFileError
    }
  }
}

/// A connected session. Releasing it closes the connection (the facade's session lives on in the tasks that use it,
/// so this closes it explicitly); channels hold no reference to it.
final class SwiftEngineSession: EngineSession, Sendable {
  let session: any SSHSession
  /// Tests: told whenever a channel's socket waits for its caller (to read, or to make room).
  private let parked: (@Sendable (SwiftEngineSocketWait) -> Void)?

  init(_ session: any SSHSession, parked: (@Sendable (SwiftEngineSocketWait) -> Void)? = nil) {
    self.session = session
    self.parked = parked
  }

  deinit { close() }

  /// DISCONNECT by application; returns at once, `disconnected(.channelClosed)` follows (once only: the facade's
  /// `close` is idempotent and `ended()` decided once).
  func close() {
    let session = session
    Task.detached { await session.close() }
  }

  // MARK: Logins

  func authenticate(user: String, password: String, done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    // The `String` cannot be wiped; this copy is, once the login no longer holds it.
    login(user, .password(SecretBytes(utf8: password)), done)
  }

  func authenticate(user: String, key: any EngineKey, direct: Bool,
                    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    guard let key = key as? SwiftEngineKey else {
      return done(.failure(.invalidKey("the key was parsed by another SSH engine")))
    }
    login(user, .publicKey(key.key, direct: direct), done)
  }

  func authenticateKeyboardInteractive(
    user: String, prompt: @escaping @Sendable (KeyboardInteractiveChallenge, @escaping @Sendable ([String]?) -> Void) -> Void,
    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void
  ) {
    login(user, .keyboardInteractive { challenge in
      let shown = KeyboardInteractiveChallenge(
        name: challenge.name, instruction: challenge.instruction,
        prompts: challenge.prompts.map { KeyboardInteractiveChallenge.Prompt(text: $0.text, echo: $0.echo) })
      let answers = await SwiftEngineQuestion.ask(withdrawn: nil) { answer in prompt(shown, answer) }
      // nil and a wrong count cancel the login (the facade checks the count too).
      guard let answers, answers.count == challenge.prompts.count else { return nil }
      return answers.map { SecretBytes(utf8: $0) }
    }, done)
  }

  func authenticate(user: String, signer publicKeyBlob: Data, direct: Bool,
                    sign: @escaping @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void,
                    done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    guard !publicKeyBlob.isEmpty else { return done(.failure(.protocolError("invalid arguments"))) }
    let key: ExternalSignerKey
    do throws(SSHError) {
      key = try ExternalSignerKey(publicKeyBlob: Array(publicKeyBlob)) { (data: [UInt8]) async throws(SSHError) -> [UInt8] in
        // Declined, or withdrawn by the facade (its task cancelled): nothing more is sent for the attempt.
        guard let signature = await SwiftEngineQuestion.ask(withdrawn: nil, { answer in sign(Data(data), answer) }) else {
          throw .cancelled
        }
        return Array(signature)
      }
    } catch {
      // An undecodable blob `invalidKey`, RSA `unsupportedAuthentication`: without asking.
      return done(.failure(error.transportError))
    }
    login(user, .publicKey(key, direct: direct), done)
  }

  /// Runs one login to its one `done`.
  private func login(_ user: String, _ credential: Credential,
                     _ done: @escaping @Sendable (Result<EngineAuthOutcome, SSHTransportError>) -> Void) {
    let session = session
    Task.detached {
      do throws(SSHError) {
        done(.success(Self.outcome(try await session.authenticate(user: user, with: credential))))
      } catch {
        // The connection's end while waiting `channelClosed`, the direct deadline `timedOut("the login")`, a declined
        // signer or prompt `cancelled`.
        done(.failure(error.transportError))
      }
    }
  }

  static func outcome(_ outcome: AuthOutcome) -> EngineAuthOutcome {
    switch outcome {
    case .success: .loggedIn
    // Same bits (`DMS_METHOD_*`).
    case .refused(let remaining, _): .refused(remaining: EngineMethods(rawValue: remaining.rawValue))
    // The engine changes no password: a refusal that leaves the password method (DMS_AUTH_FAILED with its bit).
    case .passwordChangeRequested: .refused(remaining: .password)
    }
  }

  // MARK: Channels

  func exec(_ command: String, events: any EngineChannelEvents) {
    let session = session, parked = parked
    Task.detached {
      let channel: any ExecChannel
      do throws(SSHError) { channel = try await session.exec(command) } catch { return events.opened(.failure(error.transportError)) }
      guard let socket = await Self.socket(closing: { await channel.close() }, parked: parked, events: events) else { return }
      await SwiftEngineBridge.exec(channel, socket: socket, events: events)
    }
  }

  func shell(term: String, columns: UInt32, rows: UInt32, events: any EngineChannelEvents) -> any EngineShell {
    let session = session, parked = parked
    let opening = TerminalSize(columns: max(columns, 1), rows: max(rows, 1))
    let control = SwiftEngineShellControl(opening: opening)
    Task.detached {
      let channel: any ShellChannel
      do throws(SSHError) {
        channel = try await session.shell(term: term, size: opening)
      } catch {
        control.end()
        return events.opened(.failure(error.transportError))
      }
      control.attach(channel)
      guard let socket = await Self.socket(closing: { await channel.close() }, parked: parked, events: events) else {
        return control.end()
      }
      let exit = await SwiftEngineBridge.shell(channel, socket: socket)
      control.end()
      events.exited(exit)
    }
    return control
  }

  /// A new socketpair, its caller's end handed to `opened`; without one the channel is closed and `opened` fails
  /// (`network`), the last call.
  private static func socket(closing close: () async -> Void, parked: (@Sendable (SwiftEngineSocketWait) -> Void)?,
                             events: any EngineChannelEvents) async -> SwiftEngineSocket? {
    let pair: (engine: Int32, caller: Int32)
    do throws(SSHTransportError) {
      pair = try SwiftEngineSocketPair.make()
    } catch {
      await close()
      events.opened(.failure(error))
      return nil
    }
    let socket = SwiftEngineSocket(pair.engine, parked: parked)
    events.opened(.success(pair.caller))
    return socket
  }
}

/// A key file the Swift engine parsed: its connections alone log in with it.
final class SwiftEngineKey: EngineKey {
  let key: FileKey
  init(_ key: FileKey) { self.key = key }

  var algorithm: String { key.keyType }
  /// With the file's comment, as russh shows it.
  var publicKey: String { key.authorizedKeysLine }
  var fingerprint: String { key.fingerprint }
}

/// A question to the app (host key, prompt, signature) answered through a callback exactly once, from any thread.
/// The first of the answer and the task's cancellation wins: a withdrawn question answers `withdrawn` at once (and
/// is not asked at all when the task was cancelled first); a later answer does nothing.
enum SwiftEngineQuestion {
  static func ask<Answer: Sendable>(withdrawn: Answer, _ send: (@escaping @Sendable (Answer) -> Void) -> Void) async -> Answer {
    let slot = Once<Answer>()
    return await withTaskCancellationHandler {
      if Task.isCancelled { return withdrawn }
      send { slot.set($0) }
      return await slot.value
    } onCancel: {
      slot.set(withdrawn)
    }
  }
}
