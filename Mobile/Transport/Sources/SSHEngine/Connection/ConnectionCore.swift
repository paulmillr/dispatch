/// The connection protocol (RFC 4254) for session channels only, as a synchronous state machine over a
/// `TransportLink`: exec channels and login shells on a PTY, flow control both ways, EOF and close, exit status and
/// signal. Created once the login succeeded (the policy delivers channel messages only then). Sans-I/O: the driver
/// feeds it the channel messages the transport routed to the service, the app's writes and reads, and the
/// connection's end, and drains `poll` after every call.
///
/// Flow control:
/// - Inbound: each channel grants the server `Limits.channelWindow` and announces `Limits.channelMaximumPacket`. The
///   window is granted back only as the driver reports what the app actually read (`consumed`), in adjusts of at
///   least half the window, so a reader that stops stops the server. Data past the window or the maximum packet ends
///   the connection (`windowExceeded`, `packetTooLarge`).
/// - Outbound: what the app writes is sent as the server's window and maximum packet allow; what does not fit waits
///   in the channel, at most `Limits.channelInputBytes`. A write takes what fits and returns how much; while it takes
///   less than offered, or `outboundBacklog` is above `Limits.outboundBacklogBytes`, the writer waits for
///   `.writable` (or the channel's last event): nothing grows without bound and no writer is left waiting.
///
/// Events per channel: `.opened` or `.openFailed` first (a shell's output before its confirmations is held until
/// then), then data, stderr and EOF in arrival order, then exactly one `.closed` (none after `.openFailed`). A server
/// that breaks the protocol on any channel (a number we did not open, a reply with nothing pending, data after its
/// EOF, a window overflow) ends the connection with the violation; every channel then ends with it.
public final class ConnectionCore {
  private let link: any TransportLink
  private var channels: [UInt32: Channel] = [:]
  private var nextNumber: UInt32 = 0
  private var events: [ConnectionEvent] = []
  /// Where `transportDrained` starts, so one busy channel does not always go first.
  private var drainCursor: UInt32 = 0
  /// The connection's end, once known.
  public private(set) var endedWith: SSHError?

  public init(link: any TransportLink) {
    self.link = link
  }

  /// Channels holding a number: open, opening, or closed by us and waiting for the server's close.
  public var channelCount: Int { channels.count }

  // MARK: Opening

  /// Opens a session channel for `command` (exec, no PTY). `.opened` follows once the channel is open and the exec
  /// request (want reply) sent, before the server's reply; a refusal is then the channel's end (`.closed(.refused)`).
  /// Throws `closed(.alreadyEnded)`, `usage(.tooManyChannels)`, `usage(.invalidArgument)` for a command too long.
  public func openExec(_ command: String) throws(SSHError) -> ChannelID {
    try checkCanOpen()
    guard command.utf8.count <= Self.maximumArgumentBytes else { throw .usage(.invalidArgument("a command too long")) }
    return open(.exec(command))
  }

  /// Opens a login shell on a PTY of `term` (a name, as `TERM`) and `size` (each at least 1; no pixel size, no modes):
  /// `pty-req`, then once confirmed `shell`; `.opened` once both are confirmed, `.openFailed(requestRefused)` when
  /// either is refused (the channel is closed, the connection stays up). Throws as `openExec`.
  public func openShell(term: String, size: TerminalSize) throws(SSHError) -> ChannelID {
    try checkCanOpen()
    guard WireReader.name(Array(term.utf8)[...]) != nil else { throw .usage(.invalidArgument("a terminal type that is not a name")) }
    return open(.shell(term: term, size: Self.clamped(size)))
  }

  // MARK: The app's side

  /// Takes as much of `bytes` as the channel holds (`Limits.channelInputBytes` not yet sent) and sends what the
  /// server's window allows. Returns how many bytes it took: fewer than offered (0 too, while the transport's backlog
  /// is full) means wait for `.writable` or the channel's end. Throws `usage(.channelClosed)` after `finishInput` or
  /// `close` or once the channel ended, the connection's end after it, `usage(.invalidArgument)` before `.opened`.
  public func write(_ bytes: some Collection<UInt8>, to id: ChannelID) throws(SSHError) -> Int {
    if let endedWith { throw endedWith }
    guard let channel = channels[id.rawValue], !channel.reported, channel.stage == .open, !channel.inputFinished else {
      throw .usage(.channelClosed)
    }
    guard channel.handedOver else { throw .usage(.invalidArgument("the channel is not open yet")) }
    guard !bytes.isEmpty else { return 0 }
    let room = Limits.channelInputBytes - channel.pendingInput
    guard room > 0, link.outboundBacklog <= Limits.outboundBacklogBytes else {
      channel.writerWaiting = true
      return 0
    }
    let taken = min(room, bytes.count)
    channel.input.append(contentsOf: bytes.prefix(taken))
    if taken < bytes.count { channel.writerWaiting = true }
    flush(channel)
    return taken
  }

  /// The app read `count` bytes of the channel's data or stderr: once at least half the window was read, it is
  /// granted back (WINDOW_ADJUST). More than was delivered and not yet reported counts as what was.
  public func consumed(_ count: Int, on id: ChannelID) {
    guard endedWith == nil, count > 0, let channel = channels[id.rawValue], channel.stage == .open else { return }
    let read = UInt32(min(count, Int(channel.unread)))
    channel.unread -= read
    channel.unadjusted += read
    // No adjust once the server sent EOF: nothing more comes.
    guard channel.unadjusted >= Limits.channelWindow / 2, !channel.remoteEOF else { return }
    let grant = channel.unadjusted
    var writer = WireWriter(.channelWindowAdjust, capacity: 9)
    writer.writeUInt32(channel.remote)
    writer.writeUInt32(grant)
    guard send(writer) else { return }
    channel.window += grant
    channel.unadjusted = 0
  }

  /// EOF after what was written (exec: the command reads end of file and may still answer). Idempotent; nothing for
  /// a channel not open. A shell has no end of file: its driver closes it instead.
  public func finishInput(_ id: ChannelID) {
    guard endedWith == nil, let channel = channels[id.rawValue], channel.stage == .open, channel.handedOver,
      !channel.reported, !channel.inputFinished
    else { return }
    channel.inputFinished = true
    channel.writerWaiting = false
    flush(channel)
  }

  /// Closes the channel: CLOSE (once the server confirmed it, if it has not yet), input not yet sent dropped. The
  /// app's side ends at once: `.closed` with the exit that arrived before (else `.lost`), or `.openFailed(.cancelled)`
  /// for a channel not yet handed over. The number stays taken until the server's CLOSE. Idempotent.
  public func close(_ id: ChannelID) {
    guard endedWith == nil, let channel = channels[id.rawValue] else { return }
    closeLocally(channel)
    report(channel, failure: .cancelled)
  }

  /// Asks for a `window-change` on a shell. Sent at once unless it equals the size in effect; a size asked before
  /// the shell was handed over, or while the transport's backlog is full, waits, and a later one replaces it (the
  /// latest wins). Throws `usage(.channelClosed)` once the shell ended or was closed, `usage(.invalidArgument)` for an
  /// exec channel.
  public func resize(_ id: ChannelID, to size: TerminalSize) throws(SSHError) {
    guard endedWith == nil, let channel = channels[id.rawValue], !channel.reported, channel.stage == .open else {
      throw .usage(.channelClosed)
    }
    guard case .shell = channel.kind else { throw .usage(.invalidArgument("resizing an exec channel")) }
    channel.wantedSize = Self.clamped(size)
    flushResize(channel)
  }

  /// The driver took the transport's outbound bytes: input and window changes that waited for the backlog go now,
  /// and writers that waited may write again (`.writable`).
  public func transportDrained() {
    guard endedWith == nil else { return }
    let numbers = channels.keys.sorted()
    let start = numbers.firstIndex { $0 >= drainCursor } ?? 0
    for number in numbers[start...] + numbers[..<start] {
      guard let channel = channels[number] else { continue }
      flush(channel)
      flushResize(channel)
    }
    drainCursor = drainCursor &+ 1
  }

  /// The connection ended (`TransportEvent.ended`): every channel's app side ends, `.closed` with what arrived
  /// (usually `.lost`) or `.openFailed(error)`. Idempotent.
  public func connectionEnded(_ error: SSHError) {
    guard endedWith == nil else { return }
    endedWith = error
    for number in channels.keys.sorted() {
      if let channel = channels[number] { report(channel, failure: error) }
    }
    channels.removeAll()
  }

  /// The next event, in order; nil when none is queued. Drain after every call.
  public func poll() -> ConnectionEvent? {
    events.isEmpty ? nil : events.removeFirst()
  }

  // MARK: Server messages

  /// A channel message (90-100) the transport routed to the connection layer.
  public func receive(_ message: InboundMessage) {
    guard endedWith == nil else { return }
    do throws(SSHError) {
      try handle(message)
    } catch {
      fail(error)
    }
  }

  private func handle(_ message: InboundMessage) throws(SSHError) {
    switch message.number {
    case .channelOpen: try refuseOpen(message)
    case .channelOpenConfirmation: try confirmed(message)
    case .channelOpenFailure: try openFailed(message)
    case .channelWindowAdjust: try adjusted(message)
    case .channelData, .channelExtendedData: try received(message)
    case .channelEOF: try receivedEOF(message)
    case .channelClose: try receivedClose(message)
    case .channelRequest: try receivedRequest(message)
    case .channelSuccess, .channelFailure: try receivedReply(message)
    default:
      throw .protocolViolation(.unexpectedMessage(message.number, MessagePolicy.Context(transport: .established,
                                                                                        service: .connection)))
    }
  }

  /// The channel `number` names; it must have left `.opening` unless `opening` (an open's answer).
  private func lookup(_ number: UInt32, for message: MessageNumber, opening: Bool = false) throws(SSHError) -> Channel {
    guard let channel = channels[number] else { throw .protocolViolation(.channel(.unknownChannel(number))) }
    guard (channel.stage == .opening) == opening else { throw .protocolViolation(.channel(.unexpectedInState(message))) }
    return channel
  }

  /// RFC 4254 §5.1: the server's own channel opens (forwardings, agent, X11) are refused, administratively
  /// prohibited.
  private func refuseOpen(_ message: InboundMessage) throws(SSHError) {
    let sender = try message.decode { (reader: inout WireReader) throws(WireError) in
      _ = try reader.readName()
      let sender = try reader.readUInt32()
      _ = try reader.readUInt32()
      _ = try reader.readUInt32()
      _ = reader.readRemaining()
      return sender
    }
    var writer = WireWriter(.channelOpenFailure, capacity: 17)
    writer.writeUInt32(sender)
    writer.writeUInt32(ChannelOpenFailureReason.administrativelyProhibited.rawValue)
    writer.writeString([])
    writer.writeString([])
    _ = send(writer)
  }

  private func confirmed(_ message: InboundMessage) throws(SSHError) {
    let (number, sender, window, maximumPacket) = try message.decode { (reader: inout WireReader) throws(WireError) in
      (try reader.readUInt32(), try reader.readUInt32(), try reader.readUInt32(), try reader.readUInt32())
    }
    let channel = try lookup(number, for: message.number, opening: true)
    guard maximumPacket >= Limits.peerMinimumPacket else {
      // GHSA-fw5c-8223-6h42: every write would wait forever. The open fails with the connection.
      throw .protocolViolation(.channel(.maximumPacketTooSmall))
    }
    channel.remote = sender
    channel.peerWindow = window
    channel.peerMaximumPacket = maximumPacket
    channel.stage = .open
    if channel.reported {
      // Closed while opening.
      closeLocally(channel)
      return
    }
    switch channel.kind {
    case .exec(let command):
      var writer = request(channel, "exec", wantReply: true, extra: 4 + command.utf8.count)
      writer.writeString(command)
      channel.replies.append(.exec)
      guard send(writer) else { return }
      channel.handedOver = true
      events.append(.opened(ChannelID(rawValue: number)))
    case .shell(let term, let size):
      var writer = request(channel, "pty-req", wantReply: true, extra: 25 + term.utf8.count)
      writer.writeString(term)
      writer.writeUInt32(size.columns)
      writer.writeUInt32(size.rows)
      writer.writeUInt32(0)  // width in pixels
      writer.writeUInt32(0)  // height in pixels
      writer.writeString([Self.ttyOpEnd])  // no modes, only TTY_OP_END (RFC 4254 §8)
      channel.replies.append(.ptyRequest)
      _ = send(writer)
    }
  }

  private func openFailed(_ message: InboundMessage) throws(SSHError) {
    let (number, reason, description) = try message.decode { (reader: inout WireReader) throws(WireError) in
      let number = try reader.readUInt32()
      let reason = try reader.readUInt32()
      let description = try reader.readDisplayText(limit: Limits.channelMessageBytes)
      _ = try reader.readDisplayText(limit: Limits.languageTagBytes)
      return (number, reason, description)
    }
    let channel = try lookup(number, for: message.number, opening: true)
    channels[number] = nil
    report(channel, failure: .channelOpenFailed(ChannelOpenFailureReason(reason),
                                                description: DisplayText.sanitize(Array(description.utf8))))
  }

  private func adjusted(_ message: InboundMessage) throws(SSHError) {
    let (number, bytes) = try message.decode { (reader: inout WireReader) throws(WireError) in
      (try reader.readUInt32(), try reader.readUInt32())
    }
    let channel = try lookup(number, for: message.number)
    let (window, overflow) = channel.peerWindow.addingReportingOverflow(bytes)
    guard !overflow else { throw .protocolViolation(.channel(.windowOverflow)) }
    channel.peerWindow = window
    flush(channel)
  }

  /// CHANNEL_DATA, or EXTENDED_DATA of type stderr (any other type ends the connection: `ChannelOutput` knows only
  /// stderr). A shell's stderr is its output (a PTY merges them; servers send none).
  private func received(_ message: InboundMessage) throws(SSHError) {
    let extended = message.number == .channelExtendedData
    let (number, type, data) = try message.decode { (reader: inout WireReader) throws(WireError) in
      let number = try reader.readUInt32()
      let type = extended ? try reader.readUInt32() : 0
      // The transport bounds the payload; the channel's own bound is checked below with its own error.
      return (number, type, try reader.readString(limit: Limits.packetLength))
    }
    let channel = try lookup(number, for: message.number)
    guard !extended || type == ExtendedDataType.stderr else {
      throw .protocolViolation(.channel(.unknownExtendedDataType))
    }
    guard !channel.remoteEOF else { throw .protocolViolation(.channel(.unexpectedInState(message.number))) }
    guard data.count <= Int(Limits.channelMaximumPacket) else { throw .protocolViolation(.channel(.packetTooLarge)) }
    guard data.count <= Int(channel.window) else { throw .protocolViolation(.channel(.windowExceeded)) }
    let size = UInt32(data.count)
    channel.window -= size
    // After our CLOSE (or the app's end) data is dropped: nobody reads it.
    guard channel.stage == .open, !channel.reported, !data.isEmpty else { return }
    channel.unread += size
    let id = ChannelID(rawValue: number)
    if !channel.handedOver {
      channel.early.append(contentsOf: data)
    } else if extended, case .exec = channel.kind {
      events.append(.stderr(id, data))
    } else {
      events.append(.data(id, data))
    }
  }

  private func receivedEOF(_ message: InboundMessage) throws(SSHError) {
    let number = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
    let channel = try lookup(number, for: message.number)
    guard !channel.remoteEOF else { throw .protocolViolation(.channel(.unexpectedInState(message.number))) }
    channel.remoteEOF = true
    if channel.handedOver, !channel.reported { events.append(.eof(ChannelID(rawValue: number))) }
  }

  /// The server's CLOSE: ours answers it unless already sent, and the number is free again. The app's side ends now
  /// if it had not.
  private func receivedClose(_ message: InboundMessage) throws(SSHError) {
    let number = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
    let channel = try lookup(number, for: message.number)
    closeLocally(channel)
    channels[number] = nil
    report(channel, failure: .closed(.channelClosed))
  }

  /// A request the server makes on one of our channels: exit-status and exit-signal are kept (the first one) and,
  /// if a reply is wanted, confirmed; everything else (`keepalive@openssh.com`, `eow@openssh.com`, unknown names) is
  /// not acted on and answered with FAILURE when a reply is wanted, as OpenSSH's client does. No reply once our CLOSE
  /// went.
  private func receivedRequest(_ message: InboundMessage) throws(SSHError) {
    let (number, wantReply, exit) = try message.decode { (reader: inout WireReader) throws(WireError) in
      let number = try reader.readUInt32()
      let name = try reader.readName()
      let wantReply = try reader.readBoolean()
      let exit: ChannelExit?
      switch name {
      case "exit-status":
        exit = .status(try reader.readUInt32())
      case "exit-signal":
        let signal = try reader.readName()
        let coreDumped = try reader.readBoolean()
        let text = try reader.readDisplayText(limit: Limits.channelMessageBytes)
        _ = try reader.readDisplayText(limit: Limits.languageTagBytes)
        exit = .signal(name: signal, coreDumped: coreDumped, message: DisplayText.sanitize(Array(text.utf8)))
      default:
        _ = reader.readRemaining()
        exit = nil
      }
      return (number, wantReply, exit)
    }
    let channel = try lookup(number, for: message.number)
    guard channel.stage == .open else { return }
    if channel.exit == nil { channel.exit = exit }
    guard wantReply else { return }
    var writer = WireWriter(exit != nil ? .channelSuccess : .channelFailure, capacity: 5)
    writer.writeUInt32(channel.remote)
    _ = send(writer)
  }

  /// The answer to our oldest request wanting one (RFC 4254 §5.4: replies come in order).
  private func receivedReply(_ message: InboundMessage) throws(SSHError) {
    let number = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
    let channel = try lookup(number, for: message.number)
    guard !channel.replies.isEmpty else { throw .protocolViolation(.channel(.unexpectedInState(message.number))) }
    let answered = channel.replies.removeFirst()
    guard channel.stage == .open, !channel.reported else { return }
    let success = message.number == .channelSuccess
    switch (answered, success) {
    case (.exec, true):
      break
    case (.exec, false):
      // Nothing runs on the channel: close it rather than leave it open on the server.
      channel.refused = true
      closeLocally(channel)
      report(channel, failure: .cancelled)
    case (.ptyRequest, true):
      _ = send(request(channel, "shell", wantReply: true, extra: 0))
      channel.replies.append(.shell)
    case (.shell, true):
      handOver(channel)
    case (.ptyRequest, false), (.shell, false):
      closeLocally(channel)
      report(channel, failure: .requestRefused(answered == .ptyRequest ? .ptyRequest : .shell))
    }
  }

  // MARK: Channels

  static let maximumArgumentBytes = Limits.packetLength / 2
  static let ttyOpEnd: UInt8 = 0

  private enum Kind {
    case exec(String)
    case shell(term: String, size: TerminalSize)
  }

  private enum Request { case exec, ptyRequest, shell }

  private enum Stage {
    /// CHANNEL_OPEN sent, not answered.
    case opening
    /// Confirmed; our CLOSE not sent.
    case open
    /// Our CLOSE sent; the server's is next.
    case closing
  }

  private final class Channel {
    let number: UInt32
    let kind: Kind
    var stage = Stage.opening
    var remote: UInt32 = 0
    /// `.opened` was emitted.
    var handedOver = false
    /// The app's side ended (`.closed` or `.openFailed` emitted): nothing more is emitted.
    var reported = false
    /// A shell's output before it was handed over (bounded by the window).
    var early: [UInt8] = []

    // Inbound. Always `window + unread + unadjusted == Limits.channelWindow`.
    var window = Limits.channelWindow
    var unread: UInt32 = 0
    var unadjusted: UInt32 = 0
    var remoteEOF = false

    // Outbound.
    var peerWindow: UInt32 = 0
    var peerMaximumPacket: UInt32 = 0
    var input: [UInt8] = []
    var inputStart = 0
    var inputFinished = false
    var eofSent = false
    var writerWaiting = false

    var replies: [Request] = []
    var wantedSize: TerminalSize?
    var sentSize: TerminalSize?
    var exit: ChannelExit?
    var refused = false

    init(number: UInt32, kind: Kind) {
      self.number = number
      self.kind = kind
      if case .shell(_, let size) = kind { sentSize = size }
    }

    var pendingInput: Int { input.count - inputStart }
    var finalExit: ChannelExit { refused ? .refused : exit ?? .lost }
  }

  private func checkCanOpen() throws(SSHError) {
    guard endedWith == nil, link.isOpen else { throw .closed(.alreadyEnded) }
    guard channels.count < Limits.channels else { throw .usage(.tooManyChannels) }
  }

  private func open(_ kind: Kind) -> ChannelID {
    while channels[nextNumber] != nil { nextNumber &+= 1 }
    let number = nextNumber
    nextNumber &+= 1
    channels[number] = Channel(number: number, kind: kind)
    var writer = WireWriter(.channelOpen, capacity: 24)
    writer.writeName("session")
    writer.writeUInt32(number)
    writer.writeUInt32(Limits.channelWindow)
    writer.writeUInt32(Limits.channelMaximumPacket)
    // A failed send means the connection is ending: its end reports the open.
    _ = send(writer)
    return ChannelID(rawValue: number)
  }

  /// `byte 98, uint32 recipient, string name, boolean want reply`, `extra` bytes reserved for the fields after.
  private func request(_ channel: Channel, _ name: String, wantReply: Bool, extra: Int) -> WireWriter {
    var writer = WireWriter(.channelRequest, capacity: 14 + name.utf8.count + extra)
    writer.writeUInt32(channel.remote)
    writer.writeName(name)
    writer.writeBoolean(wantReply)
    return writer
  }

  /// Both confirmations came: the shell is the app's, with what arrived before.
  private func handOver(_ channel: Channel) {
    channel.handedOver = true
    let id = ChannelID(rawValue: channel.number)
    events.append(.opened(id))
    if !channel.early.isEmpty {
      events.append(.data(id, channel.early))
      channel.early = []
    }
    if channel.remoteEOF { events.append(.eof(id)) }
    flushResize(channel)
  }

  /// Sends what waits as the window, the maximum packet and the backlog allow, then EOF once all of it went.
  private func flush(_ channel: Channel) {
    guard channel.stage == .open else { return }
    while channel.pendingInput > 0, channel.peerWindow > 0, link.outboundBacklog <= Limits.outboundBacklogBytes {
      let size = min(channel.pendingInput, Int(channel.peerWindow), Int(channel.peerMaximumPacket),
                     Int(Limits.channelMaximumPacket))
      var writer = WireWriter(.channelData, capacity: 9 + size)
      writer.writeUInt32(channel.remote)
      writer.writeString(channel.input[channel.inputStart..<channel.inputStart + size])
      guard send(writer) else { return }
      channel.inputStart += size
      channel.peerWindow -= UInt32(size)
    }
    if channel.inputStart == channel.input.count {
      channel.input = []
      channel.inputStart = 0
    } else if channel.inputStart >= channel.input.count / 2 {
      channel.input.removeFirst(channel.inputStart)
      channel.inputStart = 0
    }
    if channel.pendingInput == 0, channel.inputFinished, !channel.eofSent {
      var writer = WireWriter(.channelEOF, capacity: 5)
      writer.writeUInt32(channel.remote)
      guard send(writer) else { return }
      channel.eofSent = true
    }
    if channel.writerWaiting, !channel.inputFinished, channel.pendingInput < Limits.channelInputBytes,
      link.outboundBacklog <= Limits.outboundBacklogBytes, !channel.reported
    {
      channel.writerWaiting = false
      events.append(.writable(ChannelID(rawValue: channel.number)))
    }
  }

  /// Sends the latest size asked for, if it is not the one in effect and the backlog has room.
  private func flushResize(_ channel: Channel) {
    guard channel.stage == .open, channel.handedOver, let size = channel.wantedSize, size != channel.sentSize,
      link.outboundBacklog <= Limits.outboundBacklogBytes
    else { return }
    var writer = request(channel, "window-change", wantReply: false, extra: 16)
    writer.writeUInt32(size.columns)
    writer.writeUInt32(size.rows)
    writer.writeUInt32(0)
    writer.writeUInt32(0)
    guard send(writer) else { return }
    channel.sentSize = size
    channel.wantedSize = nil
  }

  /// Our CLOSE; what was not sent is dropped.
  private func closeLocally(_ channel: Channel) {
    guard channel.stage == .open else { return }
    channel.stage = .closing
    channel.input = []
    channel.inputStart = 0
    channel.writerWaiting = false
    var writer = WireWriter(.channelClose, capacity: 5)
    writer.writeUInt32(channel.remote)
    _ = send(writer)
  }

  /// The app's side ends, once: `.closed` with the exit for a channel handed over, else `.openFailed(failure)`.
  private func report(_ channel: Channel, failure: SSHError) {
    guard !channel.reported else { return }
    channel.reported = true
    channel.early = []
    let id = ChannelID(rawValue: channel.number)
    events.append(channel.handedOver ? .closed(id, channel.finalExit) : .openFailed(id, failure))
  }

  private func fail(_ error: SSHError) {
    link.end(error)
    connectionEnded(error)
  }

  /// False when the link refused: after the end that is the connection's end, reported by `connectionEnded`.
  private func send(_ writer: WireWriter) -> Bool {
    guard let payload = try? writer.finish() else { return false }
    do throws(SSHError) {
      try link.send(payload)
      return true
    } catch {
      return false
    }
  }

  private static func clamped(_ size: TerminalSize) -> TerminalSize {
    TerminalSize(columns: max(1, size.columns), rows: max(1, size.rows))
  }
}

/// A channel, by the number the engine gave it.
public struct ChannelID: Sendable, Hashable, CustomStringConvertible {
  public let rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public var description: String { "channel \(rawValue)" }
}

/// What the connection core tells its driver, in order.
public enum ConnectionEvent: Sendable, Equatable {
  /// The channel is the app's: an exec once its request was sent, a shell once both requests were confirmed.
  case opened(ChannelID)
  /// The channel did not open, the last event for it: `channelOpenFailed`, `requestRefused`, `closed(.channelClosed)`
  /// (a shell the server closed first), `cancelled` (closed while opening), or the connection's end.
  case openFailed(ChannelID, SSHError)
  /// Output (a shell's stderr too). Report what the app read with `consumed`.
  case data(ChannelID, [UInt8])
  /// An exec's stderr (extended data type 1). Counts against the window like data.
  case stderr(ChannelID, [UInt8])
  /// The server sent EOF: no more output (the channel may still take input).
  case eof(ChannelID)
  /// The channel ended for the app, the last event for it: the server's CLOSE, ours, a refused exec, or the
  /// connection's end.
  case closed(ChannelID, ChannelExit)
  /// A write that took less than offered may go on.
  case writable(ChannelID)
}
