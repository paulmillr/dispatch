#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import CryptoKit
import Foundation
import MobileTransport
import XCTest

/// Requirement 3 (throughput) and 8 (latency, idle memory) against the loopback sshd. Numbers are
/// printed as `MEASURE` lines for docs/ios-ssh-spike.md.
final class MeasurementTests: XCTestCase {
  static let size = 50 * 1024 * 1024

  func testUpload50MBIntoCat() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let target = fixture.resolvedRoot + "/home/upload.bin"
    var chunk = Data(count: 1 << 20)
    for index in chunk.indices { chunk[index] = UInt8(truncatingIfNeeded: index &* 31) }
    var hash = SHA256()
    let baseline = residentBytes()
    let start = ContinuousClock.now
    let exec = try await connection.exec("cat > '\(target)'")
    for _ in 0..<(Self.size >> 20) {
      try await exec.write(chunk)
      hash.update(data: chunk)
    }
    try await exec.finishInput()
    for try await _ in exec {}
    let status = try await exec.exitStatus()
    let elapsed = seconds(ContinuousClock.now - start)
    XCTAssertEqual(status, 0)
    let check = try await connection.run("wc -c < '\(target)' | tr -d ' '; shasum -a 256 '\(target)' | cut -d ' ' -f 1; rm -f '\(target)'")
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(check.text, "\(Self.size)\n\(digest)\n")
    report(String(format: "upload 50 MiB into cat: %.2f s, %.1f MB/s, resident +%.1f MB, peak RSS %.1f MB",
                  elapsed, Double(Self.size) / elapsed / 1e6, Double(residentBytes() - baseline) / 1e6, Double(peakResidentBytes()) / 1e6))
  }

  func testDownload50MBFromYes() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let baseline = residentBytes()
    let start = ContinuousClock.now
    let exec = try await connection.exec("yes | head -c \(Self.size)")
    try await exec.finishInput()
    var received = 0, chunks = 0, wrong = false
    for try await output in exec {
      guard case .stdout(let data) = output else { continue }
      // `yes` prints "y\n": every even offset is 'y'.
      if !wrong, let first = data.first, first != (received % 2 == 0 ? UInt8(ascii: "y") : UInt8(ascii: "\n")) { wrong = true }
      received += data.count
      chunks += 1
    }
    let elapsed = seconds(ContinuousClock.now - start)
    let status = try await exec.exitStatus()
    XCTAssertEqual(status, 0)
    XCTAssertEqual(received, Self.size)
    XCTAssertFalse(wrong)
    report(String(format: "download 50 MiB from yes | head: %.2f s, %.1f MB/s, %d reads, resident +%.1f MB, peak RSS %.1f MB",
                  elapsed, Double(Self.size) / elapsed / 1e6, chunks, Double(residentBytes() - baseline) / 1e6, Double(peakResidentBytes()) / 1e6))
  }

  /// A consumer that stops reading stalls the remote writer (SSH window), so memory stays bounded.
  func testSlowReaderBoundsBuffering() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let exec = try await connection.exec("head -c \(Self.size) /dev/zero")
    try await exec.finishInput()
    var iterator = exec.makeAsyncIterator()
    _ = try await iterator.next()
    let before = residentBytes()
    try await Task.sleep(for: .seconds(1))
    let grown = residentBytes() - before
    // Unread data is held to the channel window (about 2 MB here), not the 50 MB the command writes.
    XCTAssertLessThan(grown, 16 << 20)
    var received = 0
    while let output = try await iterator.next() { if case .stdout(let data) = output { received += data.count } }
    XCTAssertGreaterThan(received, Self.size - (4 << 20))
    report(String(format: "paused reader for 1 s: resident +%.1f MB while 50 MB were pending", Double(grown) / 1e6))
  }

  func testConnectLatencyAndIdleMemory() async throws {
    let fixture = SSHFixture.shared
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    var totals: [Double] = [], handshakes: [Double] = [], auths: [Double] = []
    // Warm up NIO's loop, Citadel's registration and the sshd.
    await (try fixture.connect([.key(key)])).close()
    for _ in 0..<20 {
      let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
      totals.append(seconds(connection.timings.total) * 1000)
      handshakes.append(seconds(connection.timings.handshake) * 1000)
      auths.append(seconds(connection.timings.authentication) * 1000)
      await connection.close()
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    report(String(format: "connect+auth ed25519 (20 runs): median %.1f ms (handshake %.1f ms, auth %.1f ms), max %.1f ms",
                  median(totals), median(handshakes), median(auths), totals.max() ?? 0))

    let count = 20
    let before = residentBytes(), heapBefore = heapBytes()
    var idle: [SSHConnection] = []
    for _ in 0..<count { idle.append(try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)) }
    try await Task.sleep(for: .milliseconds(500))
    let after = residentBytes(), heapAfter = heapBytes()
    for connection in idle { XCTAssertTrue(connection.isActive) }
    report(String(format: "idle connection memory: %.0f KB heap, %.0f KB resident each (delta over %d connections)",
                  Double(heapAfter - heapBefore) / Double(count) / 1024, Double(after - before) / Double(count) / 1024, count))
    for connection in idle { await connection.close() }
  }
}
#endif
