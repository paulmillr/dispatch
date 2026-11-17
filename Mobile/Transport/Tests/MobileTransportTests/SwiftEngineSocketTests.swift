import Darwin
import Foundation
@testable import MobileTransport
import XCTest

/// The engine's end of a channel socket (`SwiftEngineSocket`) on its own: a wait must never miss the caller's move,
/// in the order that loses one (the move lands after the EAGAIN, before the wait is registered) and over many waits
/// in a row; and closing wakes a waiter and frees the number only once its sources are done.
final class SwiftEngineSocketTests: XCTestCase {
  /// The caller makes room between the write's EAGAIN and its wait: the write still goes on.
  func testRoomMadeBeforeTheWaitWakesTheWriter() async throws {
    let pair = try SwiftEngineSocketPair.make()
    defer { Darwin.close(pair.caller) }
    let drained = Watched(0)
    let socket = SwiftEngineSocket(pair.engine, retrying: { kind in
      guard kind == .writable else { return }
      // The forced order: all the room the writer needs, made before it registers its wait.
      drained.change { $0 += Self.drain(pair.caller) }
    })
    let data = [UInt8](repeating: 0x5A, count: 8 << 20)
    let wrote = await socket.write(data)
    XCTAssertTrue(wrote)
    XCTAssertGreaterThan(drained.value, 0, "the write never waited")
    let rest = Self.drain(pair.caller)
    XCTAssertEqual(drained.value + rest, data.count)
    await socket.close()
  }

  /// The caller writes between the read's EAGAIN and its wait: the read still returns it.
  func testDataWrittenBeforeTheWaitWakesTheReader() async throws {
    let pair = try SwiftEngineSocketPair.make()
    defer { Darwin.close(pair.caller) }
    let socket = SwiftEngineSocket(pair.engine, retrying: { kind in
      guard kind == .readable else { return }
      _ = Darwin.write(pair.caller, "late", 4)
    })
    for _ in 0..<1_000 {
      let read = await socket.read()
      XCTAssertEqual(read, .data(Array("late".utf8)))
    }
    await socket.close()
  }

  /// Many waits in a row both ways on 32 sockets at once (their sources share one queue), through small buffers so
  /// nearly every chunk waits: each wait wakes and every byte arrives in order. A watchdog fails the test instead of
  /// letting a lost wakeup hang it.
  func testManyWaitsInARowEachWake() async throws {
    let count = 32, size = 1 << 20
    let waits = Watched<[SwiftEngineSocketWait: Int]>([:])
    var pairs: [(engine: Int32, caller: Int32)] = []
    for _ in 0..<count {
      let pair = try SwiftEngineSocketPair.make()
      var small: Int32 = 4096
      for fd in [pair.engine, pair.caller] {
        for option in [SO_SNDBUF, SO_RCVBUF] {
          XCTAssertEqual(setsockopt(fd, SOL_SOCKET, option, &small, socklen_t(MemoryLayout<Int32>.size)), 0)
        }
      }
      pairs.append(pair)
    }
    let sockets = pairs.map { pair in
      SwiftEngineSocket(pair.engine, parked: { kind in waits.change { $0[kind, default: 0] += 1 } })
    }
    let finished = Watched(0)
    let watchdog = Task { [pairs] in
      let done = await finished.until(.seconds(120)) { $0 == count }
      guard !done else { return }
      XCTFail("a socket wait never woke: \(finished.value) of \(count) sockets finished")
      // Unblock everything so the test ends: the callers' blocking calls and the engine's waits.
      for pair in pairs { _ = shutdown(pair.caller, SHUT_RDWR) }
      for socket in sockets { await socket.close() }
    }
    await withTaskGroup(of: Void.self) { group in
      for (pair, socket) in zip(pairs, sockets) {
        group.addTask {
          let outbound = SwiftEngineChannelTests.random(size), inbound = SwiftEngineChannelTests.random(size)
          // Out: the engine writes, the caller reads (blocking, as the wrappers do).
          async let read = CallerSide.readAll(pair.caller, limit: size)
          async let written: Bool = {
            var offset = 0
            while offset < size {
              let end = min(size, offset + 64 * 1024)
              guard await socket.write(Array(outbound[offset..<end])) else { return false }
              offset = end
            }
            return true
          }()
          // In: the caller writes, the engine reads.
          async let sent = CallerSide.write(pair.caller, inbound)
          var received: [UInt8] = []
          received.reserveCapacity(size)
          while received.count < size, case .data(let bytes) = await socket.read() { received += bytes }
          let (wroteAll, readOut, sentAll) = await (written, read, sent)
          XCTAssertTrue(wroteAll)
          XCTAssertTrue(sentAll)
          XCTAssertEqual(sha256(readOut.bytes), sha256(outbound))
          XCTAssertEqual(sha256(received), sha256(inbound))
          finished.change { $0 += 1 }
        }
      }
    }
    watchdog.cancel()
    report("swift engine socket: \(waits.value[.writable] ?? 0) write waits, \(waits.value[.readable] ?? 0) read waits over \(count) sockets, each woken")
    XCTAssertEqual(finished.value, count)
    XCTAssertGreaterThan(waits.value[.writable] ?? 0, 1_000)
    XCTAssertGreaterThan(waits.value[.readable] ?? 0, 1_000)
    for socket in sockets { await socket.close() }
    for pair in pairs { Darwin.close(pair.caller) }
  }

  /// Closing wakes a waiting read and a waiting write, and returns once the number is closed: the caller then reads end
  /// of file, its writes fail, and nothing is left open.
  func testCloseWakesWaitersAndFreesTheNumber() async throws {
    let before = ProcessCounts.descriptors
    let pair = try SwiftEngineSocketPair.make()
    let waits = Watched<[SwiftEngineSocketWait]>([])
    let socket = SwiftEngineSocket(pair.engine, parked: { kind in waits.change { $0.append(kind) } })
    async let read = socket.read()
    async let wrote = socket.write([UInt8](repeating: 1, count: 8 << 20))
    await wait(waits, "both waiting") { $0.contains(.readable) && $0.contains(.writable) }
    await socket.close()
    let (readResult, wroteResult) = await (read, wrote)
    XCTAssertEqual(readResult, .closed)
    XCTAssertFalse(wroteResult)
    await socket.close()  // idempotent
    _ = Self.drain(pair.caller)
    var byte: UInt8 = 0
    XCTAssertEqual(Darwin.read(pair.caller, &byte, 1), 0, "end of file once the engine's end closed")
    XCTAssertEqual(Darwin.write(pair.caller, &byte, 1), -1)
    Darwin.close(pair.caller)
    XCTAssertEqual(ProcessCounts.descriptors, before)
  }

  /// Everything the caller's end holds now, without blocking.
  static func drain(_ fd: Int32) -> Int {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    defer { _ = fcntl(fd, F_SETFL, flags) }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var total = 0
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count <= 0 { return total }
      total += count
    }
  }
}
