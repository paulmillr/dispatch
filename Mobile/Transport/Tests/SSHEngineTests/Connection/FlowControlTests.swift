import SSHEngine
import XCTest

/// Window accounting both ways, the peer's maximum packet, the channel's input bound and the transport's backlog:
/// exact fits and one over, many sizes, interleaved channels, and that no writer is left waiting.
final class FlowControlTests: XCTestCase {
  typealias W = ChannelWire
  static let window = Limits.channelWindow
  static let packet = Int(Limits.channelMaximumPacket)

  // MARK: Inbound: the window we grant

  func testTheWindowIsGrantedBackAsTheAppReads() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 5)
    let n = id.rawValue
    // The whole window, in maximum packets, without a read: exactly fits.
    let packets = Int(Self.window) / Self.packet
    for index in 0..<packets { harness.server(W.data(n, pattern(Self.packet, seed: UInt8(index)))) }
    XCTAssertNil(harness.link.endedWith)
    XCTAssertEqual(harness.take().count, packets)
    XCTAssertEqual(harness.adjustsSent(to: 5), [], "nothing read, nothing granted")
    // Reading less than half grants nothing yet; reaching half grants exactly what was read.
    harness.core.consumed(Int(Self.window / 2) - 1, on: id)
    XCTAssertEqual(harness.adjustsSent(to: 5), [])
    harness.core.consumed(1, on: id)
    XCTAssertEqual(harness.adjustsSent(to: 5), [Self.window / 2])
    // Exactly the granted half fits again; one byte more is past the window.
    for _ in 0..<(packets / 2) { harness.server(W.data(n, pattern(Self.packet))) }
    XCTAssertNil(harness.link.endedWith)
    harness.server(W.data(n, [0]))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.channel(.windowExceeded)))
    XCTAssertEqual(harness.take().last, .closed(id, .lost))
  }

  func testOneByteOverTheWindowEndsTheConnection() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 5)
    let packets = Int(Self.window) / Self.packet
    for _ in 0..<(packets - 1) { harness.server(W.data(id.rawValue, pattern(Self.packet))) }
    harness.server(W.data(id.rawValue, pattern(Self.packet - 1)))
    harness.server(W.extended(id.rawValue, [1]))
    XCTAssertNil(harness.link.endedWith, "stderr counts against the window, and this fits exactly")
    harness.server(W.extended(id.rawValue, [1]))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.channel(.windowExceeded)))
  }

  func testThePacketSizeWeAnnouncedIsHeldToo() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 5)
    harness.server(W.data(id.rawValue, pattern(Self.packet)))
    XCTAssertNil(harness.link.endedWith)
    harness.server(W.extended(id.rawValue, pattern(Self.packet + 1)))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.channel(.packetTooLarge)))
  }

  func testInboundAccountingAcrossManySizes() {
    let random = SeededRandom(seed: 0x1A_B0_0D)
    for _ in 0..<40 {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 6)
      var granted = Int(Self.window)
      var received = 0
      var read = 0
      var unread = 0
      var chunks: [Int: [UInt8]] = [:]
      for _ in 0..<200 {
        let room = granted - received
        guard room > 0 else { break }
        let size = min(room, [1, 2, 4095, 4096, 4097, Self.packet - 1, Self.packet][random.below(7)])
        let chunk = chunks[size] ?? pattern(size)
        chunks[size] = chunk
        harness.server(random.below(4) == 0 ? W.extended(id.rawValue, chunk) : W.data(id.rawValue, chunk))
        received += size
        unread += size
        if random.below(3) == 0 {
          let count = random.below(unread + 1)
          harness.core.consumed(count, on: id)
          read += count
          unread -= count
        }
        granted = Int(Self.window) + Int(harness.adjustsSent(to: 6).reduce(0, +))
        // Never more granted than read, and every grant at least half a window.
        XCTAssertLessThanOrEqual(granted - Int(Self.window), read)
        XCTAssertTrue(harness.adjustsSent(to: 6).allSatisfy { $0 >= Self.window / 2 })
      }
      XCTAssertNil(harness.link.endedWith)
      // Reading more than was delivered counts as what was.
      harness.core.consumed(Int.max, on: id)
      let total = Int(Self.window) + Int(harness.adjustsSent(to: 6).reduce(0, +))
      XCTAssertLessThanOrEqual(total - Int(Self.window), received)
      XCTAssertEqual(harness.take().reduce(0) { sum, event in
        switch event {
        case .data(_, let bytes), .stderr(_, let bytes): sum + bytes.count
        default: sum
        }
      }, received)
    }
  }

  func testNoAdjustAfterTheServersEOF() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 5)
    for _ in 0..<(Int(Self.window) / Self.packet) { harness.server(W.data(id.rawValue, pattern(Self.packet))) }
    harness.server(W.eof(id.rawValue))
    harness.core.consumed(Int(Self.window), on: id)
    XCTAssertEqual(harness.adjustsSent(to: 5), [])
    harness.server(W.data(id.rawValue, [1]))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.channel(.unexpectedInState(.channelData))))
  }

  // MARK: Outbound: the server's window and maximum packet

  func testWritesFollowTheServersWindow() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 8, window: 0, maximumPacket: 1 << 15)
    let n = id.rawValue
    // OpenSSH's session channel: a window of zero until the command started. The input waits in the channel.
    XCTAssertEqual(harness.write(pattern(100), to: id), 100)
    XCTAssertEqual(harness.dataSent(to: 8).sizes, [])
    harness.server(W.adjust(n, 10))
    XCTAssertEqual(harness.dataSent(to: 8).sizes, [10], "exactly the window")
    harness.server(W.adjust(n, 89))
    XCTAssertEqual(harness.dataSent(to: 8).sizes, [10, 89])
    harness.server(W.adjust(n, 1))
    XCTAssertEqual(harness.dataSent(to: 8).sizes, [10, 89, 1])
    XCTAssertEqual(harness.dataSent(to: 8).bytes, pattern(100))
    // One over: the window takes all but one byte.
    harness.server(W.adjust(n, 10))
    XCTAssertEqual(harness.write(pattern(11, seed: 1), to: id), 11)
    XCTAssertEqual(harness.dataSent(to: 8).sizes.last, 10)
    harness.server(W.adjust(n, 5))
    XCTAssertEqual(harness.dataSent(to: 8).sizes.suffix(2), [10, 1])
    // The rest of that adjust is there for the next write.
    XCTAssertEqual(harness.write(pattern(4), to: id), 4)
    XCTAssertEqual(harness.dataSent(to: 8).sizes.last, 4)
  }

  func testThePeersMaximumPacketSplitsWrites() {
    for maximum: UInt32 in [1, 7, 1000, 1 << 15, 1 << 16, .max] {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 9, window: .max, maximumPacket: maximum)
      let input = pattern(100_000)
      var taken = 0
      while taken < input.count { taken += harness.write(Array(input[taken...]), to: id) }
      let (bytes, sizes) = harness.dataSent(to: 9)
      XCTAssertEqual(bytes, input, "\(maximum)")
      let limit = min(Int(maximum), Self.packet)
      XCTAssertTrue(sizes.allSatisfy { $0 <= limit }, "\(maximum)")
      XCTAssertEqual(sizes.dropLast().allSatisfy { $0 == limit }, true, "full packets but the last")
    }
  }

  func testOutboundAccountingAcrossManySizes() {
    let random = SeededRandom(seed: 0x0B_0D_5E)
    for _ in 0..<60 {
      // A maximum of 1 is covered by the splitting test; here it would only cost time.
      let maximum = UInt32([3, 512, 32768, 65536][random.below(4)])
      let harness = ChannelHarness()
      var granted = random.below(3) * 1000
      let id = harness.exec(remote: 10, window: UInt32(granted), maximumPacket: maximum)
      var written: [UInt8] = []
      var bytes: [UInt8] = []
      var sizes: [Int] = []
      var seen = 0
      for step in 0..<40 {
        if random.below(2) == 0 {
          let chunk = pattern(random.below(5000), seed: UInt8(step))
          let taken = harness.write(chunk, to: id)
          written += chunk.prefix(taken)
        } else {
          let grant = UInt32([0, 1, 2, 999, 1000, 1001, 40000][random.below(7)])
          harness.server(W.adjust(id.rawValue, grant))
          granted += Int(grant)
        }
        let new = harness.dataSent(to: 10, from: seen)
        seen = harness.sent.count
        bytes += new.bytes
        sizes += new.sizes
        // In order, never past what the window allowed, never larger than either maximum, and as much as both allow.
        XCTAssertLessThanOrEqual(bytes.count, granted)
        XCTAssertEqual(bytes.count, min(granted, written.count))
        XCTAssertTrue(sizes.allSatisfy { $0 >= 1 && $0 <= min(Int(maximum), Self.packet) })
        XCTAssertLessThanOrEqual(written.count - bytes.count, Limits.channelInputBytes)
      }
      XCTAssertEqual(bytes, Array(written.prefix(bytes.count)))
      XCTAssertNil(harness.link.endedWith)
    }
  }

  func testTheWindowNeverWrapsAndAnOverflowEndsTheConnection() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 11, window: .max - 10)
    harness.server(W.adjust(id.rawValue, 10))
    XCTAssertNil(harness.link.endedWith, "exactly 2^32 - 1")
    harness.server(W.adjust(id.rawValue, 1))
    XCTAssertEqual(harness.link.endedWith, .protocolViolation(.channel(.windowOverflow)))
    XCTAssertEqual(harness.take(), [.closed(id, .lost)])
  }

  // MARK: Backpressure

  func testTheChannelsInputIsBoundedAndTheWriterIsWoken() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 12, window: 0)
    let big = pattern(Limits.channelInputBytes + 5000)
    XCTAssertEqual(harness.write(big, to: id), Limits.channelInputBytes, "takes what fits")
    XCTAssertEqual(harness.write([1], to: id), 0, "full")
    XCTAssertEqual(harness.take(), [])
    // A grant drains some: the waiting writer may go on.
    harness.server(W.adjust(id.rawValue, 100))
    XCTAssertEqual(harness.take(), [.writable(id)])
    XCTAssertEqual(harness.write(Array(big[Limits.channelInputBytes...]), to: id), 100)
    XCTAssertEqual(harness.take(), [])
    // `.writable` only for a writer that waits, and once.
    harness.server(W.adjust(id.rawValue, 1_000_000))
    XCTAssertEqual(harness.take(), [.writable(id)])
    harness.server(W.adjust(id.rawValue, 1_000_000))
    XCTAssertEqual(harness.take(), [])
    XCTAssertEqual(harness.dataSent(to: 12).bytes, Array(big.prefix(Limits.channelInputBytes + 100)))
  }

  func testNoWritesAreTakenWhileTheBacklogIsFull() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 13)
    harness.link.outboundBacklog = Limits.outboundBacklogBytes + 1
    XCTAssertEqual(harness.write([1, 2, 3], to: id), 0)
    harness.core.transportDrained()
    harness.drain()
    XCTAssertEqual(harness.take(), [], "still full")
    harness.link.outboundBacklog = Limits.outboundBacklogBytes
    harness.core.transportDrained()
    harness.drain()
    XCTAssertEqual(harness.take(), [.writable(id)], "at the limit it takes writes again")
    XCTAssertEqual(harness.write([1, 2, 3], to: id), 3)
    XCTAssertEqual(harness.sent.last, W.data(13, [1, 2, 3]))
  }

  /// With a backlog that grows as payloads are sent, the channel sends at most one packet past the limit, then
  /// waits for the driver to write; nothing grows without bound however much the app offers.
  func testSendingStopsAtTheBacklogLimit() {
    let link = BacklogLink()
    let harness = ChannelHarness(link: link)
    let id = harness.exec(remote: 14, window: .max)
    var offered = 0
    var taken = 0
    for _ in 0..<100 {
      let chunk = pattern(64 * 1024)
      offered += chunk.count
      taken += harness.write(chunk, to: id)
      XCTAssertLessThanOrEqual(link.outboundBacklog, Limits.outboundBacklogBytes + Self.packet + 64)
    }
    XCTAssertLessThan(taken, offered)
    XCTAssertLessThanOrEqual(taken - harness.dataSent(to: 14).bytes.count, Limits.channelInputBytes)
    // The driver writes; everything taken goes out in turn, and the writer is told.
    var rounds = 0
    repeat {
      link.drain()
      harness.core.transportDrained()
      harness.drain()
      rounds += 1
    } while harness.dataSent(to: 14).bytes.count < taken && rounds < 100
    XCTAssertEqual(harness.dataSent(to: 14).bytes.count, taken)
    XCTAssertTrue(harness.take().contains(.writable(id)))
  }

  func testInterleavedChannelsKeepTheirOwnWindows() {
    let harness = ChannelHarness()
    let first = harness.exec(remote: 21, window: 0)
    let second = harness.exec(remote: 22, window: 5)
    harness.write(pattern(10, seed: 1), to: first)
    harness.write(pattern(10, seed: 2), to: second)
    harness.server(W.data(second.rawValue, [2]))
    harness.server(W.data(first.rawValue, [1]))
    harness.server(W.adjust(first.rawValue, 3))
    harness.server(W.extended(second.rawValue, [3]))
    harness.server(W.adjust(second.rawValue, 5))
    harness.server(W.adjust(first.rawValue, 7))
    XCTAssertEqual(harness.take(), [.data(second, [2]), .data(first, [1]), .stderr(second, [3])])
    XCTAssertEqual(harness.dataSent(to: 21).sizes, [3, 7])
    XCTAssertEqual(harness.dataSent(to: 21).bytes, pattern(10, seed: 1))
    XCTAssertEqual(harness.dataSent(to: 22).sizes, [5, 5])
    XCTAssertEqual(harness.dataSent(to: 22).bytes, pattern(10, seed: 2))
    // One channel's end leaves the other alone.
    harness.server(W.close(first.rawValue))
    harness.server(W.data(second.rawValue, [4]))
    XCTAssertEqual(harness.take(), [.closed(first, .lost), .data(second, [4])])
    // The backlog drains to every channel in turn.
    harness.link.outboundBacklog = Limits.outboundBacklogBytes + 1
    let third = harness.exec(remote: 23, window: 100)
    harness.write([9], to: second)
    harness.write([8], to: third)
    harness.server(W.adjust(second.rawValue, 1))
    XCTAssertEqual(harness.take(), [])
    harness.link.outboundBacklog = 0
    harness.core.transportDrained()
    harness.drain()
    XCTAssertEqual(Set(harness.take().map { "\($0)" }), ["writable(channel \(second.rawValue))", "writable(channel \(third.rawValue))"])
    XCTAssertEqual(harness.write([9], to: second), 1)
    XCTAssertEqual(harness.write([8], to: third), 1)
    XCTAssertEqual(harness.dataSent(to: 22).bytes.last, 9)
    XCTAssertEqual(harness.dataSent(to: 23).bytes, [8])
  }

  func testEOFWaitsForTheInputBeforeIt() {
    let harness = ChannelHarness()
    let id = harness.exec(remote: 15, window: 2)
    harness.write([1, 2, 3, 4], to: id)
    harness.core.finishInput(id)
    XCTAssertFalse(harness.sent.contains(W.eof(15)))
    harness.server(W.adjust(id.rawValue, 1))
    XCTAssertFalse(harness.sent.contains(W.eof(15)))
    harness.server(W.adjust(id.rawValue, 1))
    XCTAssertEqual(harness.sent.suffix(2), [W.data(15, [4]), W.eof(15)])
    XCTAssertEqual(harness.take(), [], "no writer to wake after finishInput")
  }

  func testAWriterIsNeverLeftWaiting() {
    // Blocked writers learn of every end: the server's CLOSE, our close, a refused exec, the connection's end.
    let ends: [(ChannelHarness, ChannelID) -> Void] = [
      { harness, id in harness.server(W.close(id.rawValue)) },
      { harness, id in harness.core.close(id) },
      { harness, id in harness.server(W.failure(id.rawValue)) },
      { harness, id in
        harness.link.end(.closed(.connectionLost))
        harness.core.connectionEnded(.closed(.connectionLost))
      },
    ]
    for (index, end) in ends.enumerated() {
      let harness = ChannelHarness()
      let id = harness.exec(remote: 16, window: 0)
      XCTAssertEqual(harness.write(pattern(Limits.channelInputBytes), to: id), Limits.channelInputBytes)
      XCTAssertEqual(harness.write([1], to: id), 0)
      end(harness, id)
      harness.drain()
      let events = harness.take()
      XCTAssertEqual(events.count, 1, "\(index)")
      guard case .closed(id, _)? = events.first else { return XCTFail("\(index): \(events)") }
      XCTAssertThrowsError(try harness.core.write([1], to: id), "\(index)")
    }
  }
}
