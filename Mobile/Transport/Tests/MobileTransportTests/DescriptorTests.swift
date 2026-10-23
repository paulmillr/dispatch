#if os(macOS)
import Darwin
import Foundation
@testable import MobileTransport
import XCTest

/// The socket end exec and shell channels own: closing it never frees a number an operation still uses.
final class DescriptorTests: XCTestCase {
  /// `close()` during an operation shuts the socket down at once but keeps the number until the operation finished,
  /// so a read or write queued just before the close cannot land on a socket that reused the number.
  func testCloseKeepsTheNumberUntilTheOperationInFlightFinished() async throws {
    var pair: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { Darwin.close(pair[1]) }
    let number = pair[0]
    let socket = Self.identity(number)
    let descriptor = Descriptor(number)
    let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      descriptor.using { _ in
        entered.signal()
        proceed.wait()
      }
      done.signal()
    }
    await Self.wait(entered)
    descriptor.close()
    XCTAssertNil(descriptor.fd)
    XCTAssertNil(descriptor.take())
    let read = try await descriptor.read()
    XCTAssertNil(read, "no read starts after the close")
    do {
      try await descriptor.write(Data("x".utf8))
      XCTFail("a write started after the close")
    } catch { XCTAssertEqual(error as? SSHTransportError, .channelClosed) }
    XCTAssertEqual(Self.identity(number), socket, "the number was freed while in use")
    var byte: UInt8 = 0
    XCTAssertEqual(Darwin.read(pair[1], &byte, 1), 0, "the socket is shut down at once")
    proceed.signal()
    await Self.wait(done)
    XCTAssertNotEqual(Self.identity(number), socket, "the last operation closes the number")
  }

  static func wait(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        semaphore.wait()
        continuation.resume()
      }
    }
  }

  /// The socket behind a number (its inode), nil when the number is not open.
  static func identity(_ fd: Int32) -> UInt64? {
    var info = stat()
    return fstat(fd, &info) == 0 ? UInt64(info.st_ino) : nil
  }
}
#endif
