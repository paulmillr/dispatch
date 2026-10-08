import Foundation
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
#if SWIFT_PACKAGE
    @testable import DispatchHelperClient
#else
    @testable import DispatchApp
#endif

final class HelperRendererTests: XCTestCase {
    func testRealDescriptorTransferAndOrderedDrain() async throws {
        let frames = try HelperClientTests.fixture().frames
        let input = frames["read"]!.first!.wire
        let output = frames["write"]!.first!.wire
        var sockets = [Int32](repeating: -1, count: 2)
        #if canImport(Darwin)
            let kind = SOCK_STREAM
        #else
            let kind = Int32(SOCK_STREAM.rawValue)
        #endif
        XCTAssertEqual(socketpair(AF_UNIX, kind, 0, &sockets), 0)
        defer { for fd in sockets { _ = close(fd) } }
        let left = Pipe()
        let right = Pipe()
        var originals = [
            left.fileHandleForReading.fileDescriptor, right.fileHandleForWriting.fileDescriptor,
        ]
        XCTAssertEqual(
            input.withUnsafeBytes {
                renderer_send(sockets[0], $0.baseAddress, $0.count, &originals, 2)
            }, input.count)
        var bytes = [UInt8](repeating: 0, count: input.count)
        var descriptors = [Int32](repeating: -1, count: 2)
        var count = 0
        let first = renderer_receive(sockets[1], &bytes, 1, &descriptors, &count)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(count, 2)
        let handles = descriptors.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
        for fd in descriptors {
            XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
            XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
        }
        var tail = [UInt8](repeating: 0, count: input.count)
        var extra = [Int32](repeating: -1, count: 2)
        var received = 0
        let rest = renderer_receive(sockets[1], &tail, input.count - 1, &extra, &received)
        XCTAssertEqual(received, 0)
        XCTAssertEqual(Data(bytes.prefix(first)) + Data(tail.prefix(rest)), input)
        try left.fileHandleForReading.close()
        try right.fileHandleForWriting.close()

        let channel = HelperTransport(read: handles[0], write: handles[1])
        let peer = HelperTransport(
            read: right.fileHandleForReading, write: left.fileHandleForWriting)
        let drained = expectation(description: "accepted bytes followed by EOF")
        let ended = expectation(description: "channel ended once")
        var actual = Data()
        var typed = Data()
        peer.start(receive: { actual.append($0) }, closed: { _ in drained.fulfill() })
        channel.start(
            receive: { bytes in
                typed.append(bytes)
                if typed.count == input.count {
                    XCTAssertEqual(typed, input)
                    channel.send(output)
                    channel.finish()
                }
            }, closed: { _ in ended.fulfill() })
        defer {
            channel.close()
            peer.close()
        }
        peer.send(input)
        await fulfillment(of: [drained, ended], timeout: 5)
        XCTAssertEqual(actual, output)
    }
}
