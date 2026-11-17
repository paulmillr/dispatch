import Foundation
@testable import SSHEngine

/// What the scripted server's login and channel layers do (`ScriptedServer.Configuration.session`). Plain data, so a
/// loopback server hands the same script to every connection.
struct SessionScript: Sendable {
  /// One keyboard-interactive round: the INFO_REQUEST the server sends, and the answers it takes to go on.
  struct Round: Sendable {
    var name = ""
    var instruction = ""
    var prompts: [(text: String, echo: Bool)]
    var answers: [String]
  }

  /// One thing a command does, in order.
  enum Step: Sendable {
    /// CHANNEL_SUCCESS (true) or CHANNEL_FAILURE (false), if the client asked for a reply.
    case reply(Bool)
    case stdout([UInt8])
    case stderr([UInt8])
    case exitStatus(UInt32)
    /// exit-signal with this name (without `SIG`), no core dump, an empty message.
    case exitSignal(String)
    case eof
    case close
  }

  /// An exec behaviour: `start` runs when the request arrives; the client's input is echoed on stdout or dropped;
  /// `atEOF` runs at the client's EOF, after every echoed byte went out.
  struct Command: Sendable {
    var start: [Step]
    var echo = false
    var atEOF: [Step] = [.exitStatus(0), .eof, .close]

    static func text(_ text: String) -> [UInt8] { Array(text.utf8) }
    /// Replies, writes `stdout` and `stderr`, exits with `status`.
    static func output(_ stdout: String, stderr: String = "", status: UInt32) -> Command {
      Command(start: [.reply(true)] + (stdout.isEmpty ? [] : [.stdout(text(stdout))])
        + (stderr.isEmpty ? [] : [.stderr(text(stderr))]) + [.exitStatus(status), .eof, .close])
    }
    /// Replies and echoes stdin until EOF, then exits 0 (`cat`).
    static let echoing = Command(start: [.reply(true)], echo: true)
    /// Declines the request.
    static let declined = Command(start: [.reply(false)])
  }

  /// The one user that can log in.
  var user = "phone"
  var passwords: Set<String> = ["s3cret"]
  /// Public key blobs that may log in.
  var authorizedKeys: [[UInt8]] = []
  /// Signature algorithms a publickey login may use (OpenSSH's PubkeyAcceptedAlgorithms). The `server-sig-algs` the
  /// transport sends is `ScriptedServer.Configuration.extensions`, set apart (`ParityServer` makes it this list), so a
  /// test can make the two disagree.
  var publicKeyAlgorithms = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                             "rsa-sha2-512", "rsa-sha2-256"]
  /// Empty: keyboard-interactive is refused.
  var keyboardInteractive: [Round] = []
  /// USERAUTH_FAILURE's methods (after `none` and every refusal).
  var methods = ["password", "publickey", "keyboard-interactive"]
  var partialSuccess = false
  /// Exec behaviours by command line; others get `unknownCommand`.
  var commands: [String: Command] = [:]
  var unknownCommand = Command(start: [.reply(true), .stderr(Array("command not found\n".utf8)), .exitStatus(127), .eof,
                                       .close])
  /// The shell's first output; its input echoes, and a line `exit <n>` ends it with status n.
  var prompt = Array("$ ".utf8)
  /// pty-req with one of these TERMs is refused (a server without PTYs, `no-pty`).
  var refusedTerminals: Set<String> = ["refused"]
  var refusesShell = false
  /// The server's receive window and maximum packet for each channel.
  var window: UInt32 = 2 * 1024 * 1024
  var maximumPacket: UInt32 = 32 * 1024
}

/// The server side of userauth (RFC 4252, 4256) and the connection protocol's session channels (RFC 4254) over a
/// `ScriptedServer`'s transport, driven by a `SessionScript`. Everything goes out through `ScriptedServer.sendUpper`
/// (held back during a key exchange). Signed publickey requests are verified with the engine's
/// `SSHSignatureVerifier` over the session id and the request (RFC 4252 §7), whether or not the key is authorized.
/// Flow control both ways: the server never sends past the client's window or maximum packet, queues what does not
/// fit, and grants its own window back only for input it consumed (echoed input once the echo went out), so a slow
/// reader stops a fast writer end to end. Client data past the window or the maximum packet, data after EOF, and
/// messages for unknown channels are recorded as `ServerLog.violations` and the server goes on (data past the window
/// is dropped, as OpenSSH does); a message out of phase (a channel before the login) is a failure that ends the
/// connection.
final class ServerSession {
  private enum Phase { case serviceNotRequested, userauth, connection }

  private enum Pending {
    /// Channel data (`extended`: stderr), and how much of the server's window it gives back once sent.
    case data([UInt8], extended: Bool, credit: Int)
    case message([UInt8])
  }

  private final class Channel {
    let local: UInt32
    let remote: UInt32
    var remoteWindow: UInt64
    let remoteMaximumPacket: Int
    /// What the client may still send, and what it consumed that is not granted back yet.
    var localWindow: UInt64
    var consumed = 0
    var queue: [Pending] = []
    var command: SessionScript.Command?
    var shell = false
    var line: [UInt8] = []
    var sentEOF = false
    var sentClose = false
    var receivedEOF = false
    /// Input after this point is dropped (the channel is ending).
    var ending = false

    init(local: UInt32, remote: UInt32, window: UInt32, maximumPacket: UInt32, localWindow: UInt32) {
      self.local = local
      self.remote = remote
      remoteWindow = UInt64(window)
      remoteMaximumPacket = Int(max(1, min(maximumPacket, 32 * 1024)))
      self.localWindow = UInt64(localWindow)
    }

    var echoes: Bool { shell || command?.echo == true }
  }

  let script: SessionScript
  private let log: Watched<ServerLog>
  private var phase = Phase.serviceNotRequested
  private var keyboardRound: Int?
  private var channels: [UInt32: Channel] = [:]
  private var nextChannel: UInt32 = 0

  init(script: SessionScript, log: Watched<ServerLog>) {
    self.script = script
    self.log = log
  }

  /// Whether a message with this number is this layer's (5, 50-79, 80, 90-127).
  static func handles(_ number: UInt8) -> Bool {
    number == MessageNumber.serviceRequest.rawValue || (50...79).contains(number)
      || number == MessageNumber.globalRequest.rawValue || (90...127).contains(number)
  }

  func handle(_ payload: [UInt8], on server: ScriptedServer) throws {
    var reader = WireReader(payload)
    let number = try reader.readByte()
    switch MessageNumber(number) {
    case .serviceRequest:
      let name = try reader.readName()
      guard name == "ssh-userauth", phase == .serviceNotRequested else {
        throw ScriptedServer.Failure(description: "service request \(name) in \(phase)")
      }
      phase = .userauth
      var writer = WireWriter(.serviceAccept)
      writer.writeName(name)
      server.sendUpper(try writer.finish())
    case .userauthRequest:
      try userauth(&reader, on: server)
    case .userauthInfoResponse:
      try infoResponse(&reader, on: server)
    case .globalRequest:
      _ = try reader.readText(limit: 1024)
      if try reader.readBoolean() { server.sendUpper([MessageNumber.requestFailure.rawValue]) }
    default:
      guard phase == .connection else { throw ScriptedServer.Failure(description: "message \(number) before the login") }
      try connection(MessageNumber(number), &reader, on: server)
    }
  }

  // MARK: Userauth

  private func userauth(_ reader: inout WireReader, on server: ScriptedServer) throws {
    // RFC 4252 §5.1: requests after success are ignored.
    guard phase == .userauth else { return }
    keyboardRound = nil
    let user = try reader.readText(limit: 1024)
    let service = try reader.readName()
    let method = try reader.readName()
    let known = user == script.user && service == "ssh-connection"
    switch method {
    case "password":
      let change = try reader.readBoolean()
      let password = try reader.readText(limit: 1024)
      record(user, "password")
      answer(known && !change && script.passwords.contains(password), on: server)
    case "publickey":
      let signed = try reader.readBoolean()
      let algorithm = try reader.readName()
      let blob = try reader.readString(limit: 16 * 1024)
      let acceptable = known && script.publicKeyAlgorithms.contains(algorithm) && script.authorizedKeys.contains(blob)
      guard signed else {
        record(user, "publickey-query")
        if acceptable {
          var writer = WireWriter(.userauthPKOK)
          writer.writeName(algorithm)
          writer.writeString(blob)
          send(try writer.finish(), on: server)
        } else {
          answer(false, on: server)
        }
        return
      }
      let signature = try reader.readString(limit: 16 * 1024)
      var signedData = WireWriter(capacity: 512)
      signedData.writeString(server.sessionIdentifier ?? [])
      signedData.writeByte(MessageNumber.userauthRequest.rawValue)
      signedData.writeString(user)
      signedData.writeString(service)
      signedData.writeString("publickey")
      signedData.writeBoolean(true)
      signedData.writeString(algorithm)
      signedData.writeString(blob)
      let verified = SignatureAlgorithm(rawValue: algorithm).flatMap { algorithm in
        (try? PublicKeyBlob(decoding: blob)).map { key in
          SSHSignatureVerifier.isValid(signatureBlob: signature, over: (try? signedData.finish()) ?? [], key: key,
                                       algorithm: algorithm)
        }
      } ?? false
      let accepted = verified && acceptable
      // One change, so a test waiting for the signature sees its login too.
      log.update {
        $0.logins.append(.init(user: user, method: "publickey-signed"))
        $0.signatures.append(.init(algorithm: algorithm, keyBlob: blob, verified: verified, accepted: accepted,
                                   whileHeld: $0.holding))
      }
      answer(accepted, on: server)
    case "keyboard-interactive":
      _ = try reader.readString(limit: 1024)
      _ = try reader.readString(limit: 1024)
      record(user, "keyboard-interactive")
      guard known, !script.keyboardInteractive.isEmpty else { return answer(false, on: server) }
      keyboardRound = 0
      try sendRound(0, on: server)
    default:
      record(user, method)
      answer(false, on: server)
    }
  }

  private func infoResponse(_ reader: inout WireReader, on server: ScriptedServer) throws {
    guard let round = keyboardRound else { throw ScriptedServer.Failure(description: "INFO_RESPONSE without a request") }
    let count = try reader.readUInt32()
    var answers: [String] = []
    for _ in 0..<min(count, 64) { answers.append(try reader.readText(limit: 1024)) }
    log.update { $0.keyboardResponses.append(answers) }
    guard answers == script.keyboardInteractive[round].answers else {
      keyboardRound = nil
      return answer(false, on: server)
    }
    if round + 1 < script.keyboardInteractive.count {
      keyboardRound = round + 1
      try sendRound(round + 1, on: server)
    } else {
      keyboardRound = nil
      answer(true, on: server)
    }
  }

  private func sendRound(_ index: Int, on server: ScriptedServer) throws {
    let round = script.keyboardInteractive[index]
    var writer = WireWriter(.userauthInfoRequest)
    writer.writeString(round.name)
    writer.writeString(round.instruction)
    writer.writeString("")
    writer.writeUInt32(UInt32(round.prompts.count))
    for prompt in round.prompts {
      writer.writeString(prompt.text)
      writer.writeBoolean(prompt.echo)
    }
    send(try writer.finish(), on: server)
  }

  private func record(_ user: String, _ method: String) {
    log.update { $0.logins.append(.init(user: user, method: method)) }
  }

  /// USERAUTH_SUCCESS, or USERAUTH_FAILURE with the script's methods.
  private func answer(_ success: Bool, on server: ScriptedServer) {
    if success {
      phase = .connection
      send([MessageNumber.userauthSuccess.rawValue], on: server)
    } else {
      var writer = WireWriter(.userauthFailure)
      writer.writeNameList(script.methods)
      writer.writeBoolean(script.partialSuccess)
      // swiftlint:disable:next force_try
      send(try! writer.finish(), on: server)
    }
  }

  /// Sends a userauth answer and notes it on the last login.
  private func send(_ payload: [UInt8], on server: ScriptedServer) {
    log.update { log in
      if !log.logins.isEmpty { log.logins[log.logins.count - 1].answer = payload.first }
    }
    server.sendUpper(payload)
  }

  // MARK: Channels

  private func connection(_ number: MessageNumber, _ reader: inout WireReader, on server: ScriptedServer) throws {
    if number == .channelOpen { return try open(&reader, on: server) }
    let local = try reader.readUInt32()
    guard let channel = channels[local] else {
      log.update { $0.violations.append("message \(number.rawValue) for unknown channel \(local)") }
      return
    }
    switch number {
    case .channelWindowAdjust:
      channel.remoteWindow += UInt64(try reader.readUInt32())
    case .channelData, .channelExtendedData:
      let extended = number == .channelExtendedData
      if extended { _ = try reader.readUInt32() }
      let data = try reader.readString(limit: Limits.packetLength)
      try receive(data, extended: extended, on: channel, server: server)
    case .channelEOF:
      channel.receivedEOF = true
      if let command = channel.command, !channel.ending, !channel.shell { run(command.atEOF, on: channel) }
    case .channelClose:
      if channel.shell { log.update { $0.terminal.append("close") } }
      channel.queue = []
      if !channel.sentClose {
        channel.sentClose = true
        server.sendUpper([MessageNumber.channelClose.rawValue] + Raw.u32(channel.remote))
      }
      channels[local] = nil
      return
    case .channelRequest:
      try request(&reader, on: channel)
    case .channelSuccess, .channelFailure:
      log.update { $0.violations.append("a reply to no request on channel \(local)") }
    default:
      log.update { $0.violations.append("message \(number.rawValue) on channel \(local)") }
    }
    flush(channel, on: server)
  }

  private func open(_ reader: inout WireReader, on server: ScriptedServer) throws {
    let type = try reader.readName()
    let sender = try reader.readUInt32()
    let window = try reader.readUInt32()
    let maximumPacket = try reader.readUInt32()
    guard type == "session" else {
      var writer = WireWriter(.channelOpenFailure)
      writer.writeUInt32(sender)
      writer.writeUInt32(3)
      writer.writeString("unknown channel type")
      writer.writeString("")
      return server.sendUpper(try writer.finish())
    }
    let channel = Channel(local: nextChannel, remote: sender, window: window, maximumPacket: maximumPacket,
                          localWindow: script.window)
    nextChannel += 1
    channels[channel.local] = channel
    log.update { $0.channels.append((window, maximumPacket)) }
    var writer = WireWriter(.channelOpenConfirmation)
    writer.writeUInt32(sender)
    writer.writeUInt32(channel.local)
    writer.writeUInt32(script.window)
    writer.writeUInt32(script.maximumPacket)
    server.sendUpper(try writer.finish())
  }

  private func receive(_ data: [UInt8], extended: Bool, on channel: Channel, server: ScriptedServer) throws {
    if channel.receivedEOF { log.update { $0.violations.append("data after EOF on channel \(channel.local)") } }
    guard UInt64(data.count) <= channel.localWindow else {
      log.update { $0.violations.append("\(data.count) bytes past a window of \(channel.localWindow)") }
      return
    }
    if data.count > Int(script.maximumPacket) {
      log.update { $0.violations.append("\(data.count) bytes in one packet past \(self.script.maximumPacket)") }
    }
    channel.localWindow -= UInt64(data.count)
    guard channel.echoes, !extended, !channel.ending else { return credit(data.count, on: channel, server: server) }
    channel.queue.append(.data(data, extended: false, credit: data.count))
    guard channel.shell else { return }
    for byte in data {
      if byte == 0x0D || byte == 0x0A {
        let text = String(decoding: channel.line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        channel.line = []
        if text.hasPrefix("exit "), let status = UInt32(text.dropFirst("exit ".count)) {
          run([.exitStatus(status), .eof, .close], on: channel)
          return
        }
      } else {
        channel.line.append(byte)
      }
    }
  }

  private func request(_ reader: inout WireReader, on channel: Channel) throws {
    let type = try reader.readName()
    let wantsReply = try reader.readBoolean()
    func reply(_ success: Bool) {
      guard wantsReply else { return }
      let number = success ? MessageNumber.channelSuccess : .channelFailure
      channel.queue.append(.message([number.rawValue] + Raw.u32(channel.remote)))
    }
    switch type {
    case "pty-req":
      let term = try reader.readText(limit: 256)
      let columns = try reader.readUInt32(), rows = try reader.readUInt32()
      let width = try reader.readUInt32(), height = try reader.readUInt32()
      let modes = try reader.readString(limit: 4096)
      log.update { $0.terminal.append("pty \(term) \(columns)x\(rows) \(width)x\(height) modes=\(Self.countModes(modes))") }
      reply(!script.refusedTerminals.contains(term))
    case "shell":
      log.update { $0.terminal.append("shell") }
      guard !script.refusesShell, channel.command == nil, !channel.shell else { return reply(false) }
      channel.shell = true
      reply(true)
      if !script.prompt.isEmpty { channel.queue.append(.data(script.prompt, extended: false, credit: 0)) }
    case "window-change":
      let columns = try reader.readUInt32(), rows = try reader.readUInt32()
      let width = try reader.readUInt32(), height = try reader.readUInt32()
      log.update { $0.terminal.append("resize \(columns)x\(rows) \(width)x\(height)") }
      reply(false)
    case "env":
      let name = try reader.readText(limit: 1024)
      log.update { $0.terminal.append("env \(name)") }
      reply(false)
    case "exec":
      let line = try reader.readText(limit: 64 * 1024)
      log.update { $0.commands.append(line) }
      guard channel.command == nil, !channel.shell else { return reply(false) }
      let command = script.commands[line] ?? script.unknownCommand
      channel.command = command
      for step in command.start {
        if case .reply(let success) = step { reply(success) } else { run([step], on: channel) }
        if case .reply(false) = step { channel.ending = true }
      }
    default:
      reply(false)
    }
  }

  /// Opcodes in an encoded terminal modes string (RFC 4254 §8) before TTY_OP_END.
  static func countModes(_ modes: [UInt8]) -> Int {
    var count = 0, index = 0
    while index < modes.count, modes[index] != 0 {
      count += 1
      index += modes[index] < 160 ? 5 : modes.count
    }
    return count
  }

  /// Queues `steps` behind what the channel already queued (so output, the status and the close keep their order).
  private func run(_ steps: [SessionScript.Step], on channel: Channel) {
    for step in steps {
      switch step {
      case .reply:
        break
      case .stdout(let bytes):
        channel.queue.append(.data(bytes, extended: false, credit: 0))
      case .stderr(let bytes):
        channel.queue.append(.data(bytes, extended: true, credit: 0))
      case .exitStatus(let status):
        channel.ending = true
        var writer = WireWriter(.channelRequest)
        writer.writeUInt32(channel.remote)
        writer.writeString("exit-status")
        writer.writeBoolean(false)
        writer.writeUInt32(status)
        // swiftlint:disable:next force_try
        channel.queue.append(.message(try! writer.finish()))
      case .exitSignal(let name):
        channel.ending = true
        var writer = WireWriter(.channelRequest)
        writer.writeUInt32(channel.remote)
        writer.writeString("exit-signal")
        writer.writeBoolean(false)
        writer.writeString(name)
        writer.writeBoolean(false)
        writer.writeString("")
        writer.writeString("")
        // swiftlint:disable:next force_try
        channel.queue.append(.message(try! writer.finish()))
      case .eof:
        channel.queue.append(.message([MessageNumber.channelEOF.rawValue] + Raw.u32(channel.remote)))
      case .close:
        channel.ending = true
        channel.queue.append(.message([MessageNumber.channelClose.rawValue] + Raw.u32(channel.remote)))
      }
    }
  }

  /// Sends what the client's window and maximum packet allow, in order; credits consumed input as its echo leaves.
  private func flush(_ channel: Channel, on server: ScriptedServer) {
    while let head = channel.queue.first {
      switch head {
      case .message(let payload):
        channel.queue.removeFirst()
        if payload.first == MessageNumber.channelEOF.rawValue {
          guard !channel.sentEOF else { continue }
          channel.sentEOF = true
        }
        if payload.first == MessageNumber.channelClose.rawValue {
          guard !channel.sentClose else { continue }
          channel.sentClose = true
        }
        server.sendUpper(payload)
      case .data(let bytes, let extended, let credit):
        guard !channel.sentEOF, !channel.sentClose, !bytes.isEmpty else {
          channel.queue.removeFirst()
          continue
        }
        let count = min(bytes.count, channel.remoteMaximumPacket, Int(min(channel.remoteWindow, UInt64(Int.max))))
        guard count > 0 else { return }
        channel.remoteWindow -= UInt64(count)
        var writer = WireWriter(extended ? .channelExtendedData : .channelData, capacity: count + 16)
        writer.writeUInt32(channel.remote)
        if extended { writer.writeUInt32(1) }
        writer.writeString(bytes.prefix(count))
        // swiftlint:disable:next force_try
        server.sendUpper(try! writer.finish())
        let credited = credit == 0 ? 0 : min(credit, count)
        if count == bytes.count {
          channel.queue.removeFirst()
        } else {
          channel.queue[0] = .data(Array(bytes[count...]), extended: extended, credit: credit - credited)
        }
        if credited > 0 { self.credit(credited, on: channel, server: server) }
      }
    }
  }

  /// Gives `count` consumed bytes back to the client once half the window is consumed.
  private func credit(_ count: Int, on channel: Channel, server: ScriptedServer) {
    guard !channel.sentClose else { return }
    channel.consumed += count
    guard channel.consumed >= Int(script.window / 2) else { return }
    channel.localWindow += UInt64(channel.consumed)
    server.sendUpper([MessageNumber.channelWindowAdjust.rawValue] + Raw.u32(channel.remote) + Raw.u32(UInt32(channel.consumed)))
    channel.consumed = 0
  }
}
