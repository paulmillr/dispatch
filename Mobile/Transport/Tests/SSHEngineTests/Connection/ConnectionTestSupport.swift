import SSHEngine
import XCTest

/// Channel messages, built by hand (RFC 4254 §5, §6).
enum ChannelWire {
  // The server's.
  static func confirmation(_ recipient: UInt32, sender: UInt32, window: UInt32, maximumPacket: UInt32) -> [UInt8] {
    [91] + Raw.u32(recipient) + Raw.u32(sender) + Raw.u32(window) + Raw.u32(maximumPacket)
  }

  static func openFailure(_ recipient: UInt32, reason: UInt32, _ description: [UInt8]) -> [UInt8] {
    [92] + Raw.u32(recipient) + Raw.u32(reason) + Raw.string(description) + Raw.string("en")
  }

  static func adjust(_ recipient: UInt32, _ bytes: UInt32) -> [UInt8] { [93] + Raw.u32(recipient) + Raw.u32(bytes) }
  static func data(_ recipient: UInt32, _ bytes: [UInt8]) -> [UInt8] { [94] + Raw.u32(recipient) + Raw.string(bytes) }

  static func extended(_ recipient: UInt32, type: UInt32 = 1, _ bytes: [UInt8]) -> [UInt8] {
    [95] + Raw.u32(recipient) + Raw.u32(type) + Raw.string(bytes)
  }

  static func eof(_ recipient: UInt32) -> [UInt8] { [96] + Raw.u32(recipient) }
  static func close(_ recipient: UInt32) -> [UInt8] { [97] + Raw.u32(recipient) }
  static func success(_ recipient: UInt32) -> [UInt8] { [99] + Raw.u32(recipient) }
  static func failure(_ recipient: UInt32) -> [UInt8] { [100] + Raw.u32(recipient) }

  static func request(_ recipient: UInt32, _ name: String, wantReply: Bool, _ fields: [UInt8] = []) -> [UInt8] {
    [98] + Raw.u32(recipient) + Raw.string(name) + [wantReply ? 1 : 0] + fields
  }

  static func exitStatus(_ recipient: UInt32, _ status: UInt32, wantReply: Bool = false) -> [UInt8] {
    request(recipient, "exit-status", wantReply: wantReply, Raw.u32(status))
  }

  static func exitSignal(_ recipient: UInt32, _ name: String, core: Bool, _ message: [UInt8]) -> [UInt8] {
    request(recipient, "exit-signal", wantReply: false, Raw.string(name) + [core ? 1 : 0] + Raw.string(message) + Raw.string(""))
  }

  static func serverOpen(_ type: String, sender: UInt32, extra: [UInt8] = []) -> [UInt8] {
    [90] + Raw.string(type) + Raw.u32(sender) + Raw.u32(1 << 20) + Raw.u32(1 << 15) + extra
  }

  // The client's.
  static func open(_ sender: UInt32) -> [UInt8] {
    [90] + Raw.string("session") + Raw.u32(sender) + Raw.u32(2 * 1024 * 1024) + Raw.u32(32 * 1024)
  }

  static func exec(_ recipient: UInt32, _ command: String) -> [UInt8] {
    request(recipient, "exec", wantReply: true, Raw.string(command))
  }

  static func ptyRequest(_ recipient: UInt32, term: String, columns: UInt32, rows: UInt32) -> [UInt8] {
    request(recipient, "pty-req", wantReply: true, Raw.string(term) + Raw.u32(columns) + Raw.u32(rows) + Raw.u32(0)
      + Raw.u32(0) + Raw.string([0]))
  }

  static func shell(_ recipient: UInt32) -> [UInt8] { request(recipient, "shell", wantReply: true) }

  static func windowChange(_ recipient: UInt32, columns: UInt32, rows: UInt32) -> [UInt8] {
    request(recipient, "window-change", wantReply: false, Raw.u32(columns) + Raw.u32(rows) + Raw.u32(0) + Raw.u32(0))
  }

  /// The bytes of a CHANNEL_DATA payload to `recipient`, or nil for another message.
  static func dataBytes(_ payload: [UInt8], to recipient: UInt32) -> [UInt8]? {
    guard payload.first == 94, Array(payload.dropFirst().prefix(4)) == Raw.u32(recipient) else { return nil }
    return try? WireReader.decode(Array(payload.dropFirst(5))) { (reader: inout WireReader) throws(WireError) in
      try reader.readString(limit: Limits.packetLength)
    }
  }
}

/// A connection core on a fake link, the server's messages routed through the policy in the connection phase. The
/// server addresses our channel numbers (`ChannelID.rawValue`); we address its numbers (`remote`).
final class ChannelHarness {
  let link: FakeTransportLink
  let core: ConnectionCore
  private(set) var events: [ConnectionEvent] = []

  init() {
    link = FakeTransportLink()
    core = ConnectionCore(link: link)
  }

  var sent: [[UInt8]] { link.sent }

  func server(_ payload: [UInt8]) {
    do throws(SSHError) {
      if let message = try link.deliver(payload, service: .connection) { core.receive(message) }
    } catch {
      link.end(error)
      core.connectionEnded(error)
    }
    drain()
  }

  func drain() {
    while let event = core.poll() { events.append(event) }
  }

  func take() -> [ConnectionEvent] {
    defer { events = [] }
    return events
  }

  /// Payloads sent from `index` on.
  func sent(from index: Int) -> [[UInt8]] { Array(sent.dropFirst(index)) }

  /// An exec channel the server confirmed with `window` and `maximumPacket`, numbered `remote` on its side.
  func exec(_ command: String = "cat", remote: UInt32 = 700, window: UInt32 = 1 << 20,
            maximumPacket: UInt32 = 1 << 15, file: StaticString = #filePath, line: UInt = #line) -> ChannelID {
    let id = try! core.openExec(command)
    server(ChannelWire.confirmation(id.rawValue, sender: remote, window: window, maximumPacket: maximumPacket))
    XCTAssertEqual(take(), [.opened(id)], file: file, line: line)
    return id
  }

  /// A shell both of whose requests the server confirmed.
  func shell(remote: UInt32 = 800, size: TerminalSize = TerminalSize(columns: 80, rows: 24), window: UInt32 = 1 << 20,
             file: StaticString = #filePath, line: UInt = #line) -> ChannelID {
    let id = try! core.openShell(term: "xterm-256color", size: size)
    server(ChannelWire.confirmation(id.rawValue, sender: remote, window: window, maximumPacket: 1 << 15))
    server(ChannelWire.success(id.rawValue))
    server(ChannelWire.success(id.rawValue))
    XCTAssertEqual(take(), [.opened(id)], file: file, line: line)
    return id
  }

  /// Writes `bytes`, returning how many the core took.
  @discardableResult
  func write(_ bytes: [UInt8], to id: ChannelID, file: StaticString = #filePath, line: UInt = #line) -> Int {
    do throws(SSHError) {
      let taken = try core.write(bytes, to: id)
      drain()
      return taken
    } catch {
      XCTFail("write threw \(error)", file: file, line: line)
      return 0
    }
  }

  /// Everything sent as CHANNEL_DATA to `recipient` from `index` on, joined, and the sizes of the messages.
  func dataSent(to recipient: UInt32, from index: Int = 0) -> (bytes: [UInt8], sizes: [Int]) {
    var bytes: [UInt8] = []
    var sizes: [Int] = []
    for payload in sent(from: index) {
      if let chunk = ChannelWire.dataBytes(payload, to: recipient) {
        bytes += chunk
        sizes.append(chunk.count)
      }
    }
    return (bytes, sizes)
  }

  /// The WINDOW_ADJUSTs sent to `recipient`, in order.
  func adjustsSent(to recipient: UInt32) -> [UInt32] {
    sent.compactMap { payload in
      guard payload.count == 9, payload.first == 93, Array(payload[1..<5]) == Raw.u32(recipient) else { return nil }
      return payload[5..<9].reduce(0) { $0 << 8 | UInt32($1) }
    }
  }
}

/// A deterministic byte pattern.
func pattern(_ count: Int, seed: UInt8 = 0) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed)) }
  return bytes
}
