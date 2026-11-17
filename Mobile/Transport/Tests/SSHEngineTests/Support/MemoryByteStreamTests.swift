import SSHEngine
import XCTest

/// The in-memory stream pair keeps `ByteStream`'s contract, so tests over it mean what they would over TCP.
final class MemoryByteStreamTests: XCTestCase {
  /// The error `body` throws, or nil (a non-`SSHError` reads as nil too, and fails the comparison).
  func failure(_ body: () async throws -> Void) async -> SSHError? {
    do {
      try await body()
      return nil
    } catch {
      return error as? SSHError
    }
  }

  func testBytesArriveInOrderWithinTheReadSize() async throws {
    let (client, server) = MemoryByteStream.pair()
    try await client.write([1, 2, 3, 4, 5])
    let first = try await server.read(maximum: 2), rest = try await server.read(maximum: 100)
    XCTAssertEqual(first, [1, 2])
    XCTAssertEqual(rest, [3, 4, 5])
    try await server.write([9])
    let back = try await client.read(maximum: 0)
    XCTAssertEqual(back, [9], "a read returns at least one byte")
  }

  func testAReadWaitsForBytes() async throws {
    let (client, server) = MemoryByteStream.pair()
    let read = Task { try await server.read(maximum: 10) }
    try await client.write([7])
    let bytes = try await read.value
    XCTAssertEqual(bytes, [7])
  }

  func testWritesWaitWhileTheBufferIsFull() async throws {
    let (client, server) = MemoryByteStream.pair(capacity: 4)
    let writer = Task { try await client.write(Array(0..<10)) }
    var received: [UInt8] = []
    while received.count < 10 { received += try await server.read(maximum: 3) }
    try await writer.value
    XCTAssertEqual(received, Array(0..<10))
    let buffered = await client.outgoing.buffered
    XCTAssertEqual(buffered, 0)
  }

  func testEndOfFileAndClose() async throws {
    let (client, server) = MemoryByteStream.pair()
    try await client.write([1])
    await client.finishWriting()
    let buffered = try await server.read(maximum: 10), end = try await server.read(maximum: 10)
    let again = try await server.read(maximum: 10)
    XCTAssertEqual(buffered, [1], "buffered bytes come before the end")
    XCTAssertEqual(end, [])
    XCTAssertEqual(again, [], "and the end repeats")
    let late = await failure { try await client.write([2]) }
    XCTAssertEqual(late, .closed(.byClient))
    // The server closes: its pending read returns at once.
    let pending = Task { try await server.read(maximum: 10) }
    await server.close()
    let closed = try await pending.value
    XCTAssertEqual(closed, [])
    let afterClose = await failure { try await server.write([3]) }
    XCTAssertEqual(afterClose, .closed(.byClient))
  }

  func testWritingToAClosedReaderIsAReset() async {
    let (client, server) = MemoryByteStream.pair()
    await server.close()
    let error = await failure { try await client.write([1]) }
    XCTAssertEqual(error, .closed(.connectionLost))
  }

  func testAResetFailsBothEnds() async {
    let (client, server) = MemoryByteStream.pair()
    let pending = Task { try await server.read(maximum: 10) }
    await client.reset(with: .network("simulated"))
    let read = await failure { _ = try await pending.value }
    XCTAssertEqual(read, .network("simulated"))
    let write = await failure { try await client.write([1]) }
    XCTAssertEqual(write, .network("simulated"))
  }

  func testAWaitingReadHonoursCancellation() async {
    let (_, server) = MemoryByteStream.pair()
    let read = Task { try await server.read(maximum: 10) }
    read.cancel()
    let error = await failure { _ = try await read.value }
    XCTAssertEqual(error, .cancelled)
  }

  func testTheConnector() async throws {
    let (client, _) = MemoryByteStream.pair()
    let stream = try await MemoryConnector(result: .success(client)).connect(host: "devbox.example.test", port: 22, deadline: .now)
    XCTAssertNotNil(stream as? MemoryByteStream)
    let error = await failure {
      _ = try await MemoryConnector(result: .failure(.connectionRefused)).connect(host: "h", port: 22, deadline: .now)
    }
    XCTAssertEqual(error, .connectionRefused)
  }
}
