#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Foundation
import MobileTransport
import XCTest

/// Requirement 1: host key verification through a delegate (trust on first use; a mismatch rejects).
final class HostKeyTests: XCTestCase {
  func testFirstUseAsksWithAlgorithmAndFingerprintThenRemembers() async throws {
    let fixture = SSHFixture.shared
    let asked = Asked()
    let trust = TrustOnFirstUse { key in
      await asked.add(key)
      return true
    }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let first = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: trust)
    await first.close()
    let seen = await asked.keys
    XCTAssertEqual(seen.count, 1)
    XCTAssertEqual(seen.first?.algorithm, "ssh-ed25519")
    // The same fingerprint ssh-keygen prints for the host key.
    let expected = try fingerprint(ofLine: fixture.hostPublicKey)
    XCTAssertEqual(seen.first?.fingerprint, expected)
    XCTAssertEqual(seen.first?.hostPattern, "[127.0.0.1]:\(fixture.port)")
    let remembered = await trust.known
    XCTAssertEqual(remembered["[127.0.0.1]:\(fixture.port)"], fixture.hostPublicKey)

    let second = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: trust)
    await second.close()
    let count = await asked.keys.count
    XCTAssertEqual(count, 1, "A remembered key is not asked about again")
  }

  func testDeclinedFirstUseRejects() async throws {
    let fixture = SSHFixture.shared
    let trust = TrustOnFirstUse { _ in false }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    do {
      _ = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: trust)
      XCTFail("connected with a declined host key")
    } catch SSHTransportError.hostKeyRejected(let info) {
      XCTAssertEqual(info.algorithm, "ssh-ed25519")
    }
  }

  func testChangedKeyIsAMismatch() async throws {
    let fixture = SSHFixture.shared
    let other = try SSHKey.openSSH(TestKeys.shared.data("ed25519-encrypted"), passphrase: SSHFixture.passphrase)
    let pattern = "[127.0.0.1]:\(fixture.port)"
    let trust = TrustOnFirstUse(known: [pattern: other.publicKey]) { _ in
      XCTFail("a known host must not be asked about")
      return true
    }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    do {
      _ = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: trust)
      XCTFail("connected with a changed host key")
    } catch SSHTransportError.hostKeyMismatch(let info, let expected) {
      XCTAssertEqual(expected, other.publicKey)
      XCTAssertEqual(info.openSSH, fixture.hostPublicKey)
    }
  }

  /// Cancelling a connect while its host key question is open withdraws the question: the trust sees the
  /// cancellation (the app's sheet goes away) and the connect fails, rather than both waiting for an answer to a
  /// connection nobody wants any more and logging in once it comes.
  func testCancellingAConnectWithdrawsTheHostKeyQuestion() async throws {
    let fixture = SSHFixture.shared
    let trust = WaitingTrust()
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let connecting = Task { try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: trust) }
    try await until { trust.asked }
    connecting.cancel()
    do {
      try await until { trust.cancelled }
    } catch {
      trust.answer()  // Unblock the connect so the case ends.
      XCTFail("The host key question outlived its cancelled connect")
    }
    do {
      let connection = try await connecting.value
      await connection.close()
      XCTFail("A cancelled connect connected")
    } catch {}
  }

  private func until(_ condition: @escaping @Sendable () -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func fingerprint(ofLine line: String) throws -> String {
    let file = SSHFixture.shared.root.appendingPathComponent("host_ed25519.pub")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-lf", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    finish(process)
    XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasPrefix(line))
    return String(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")[1])
  }
}

/// Asks forever: answers only when its task is cancelled (then no) or `answer()` is called (then trust).
final class WaitingTrust: HostKeyTrust, @unchecked Sendable {
  private let lock = NSLock()
  private var waiter: CheckedContinuation<HostKeyDecision, Never>?
  private var wasAsked = false
  private var wasCancelled = false

  var asked: Bool { lock.withLock { wasAsked } }
  var cancelled: Bool { lock.withLock { wasCancelled } }

  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let cancelled = lock.withLock { () -> Bool in
          wasAsked = true
          if !wasCancelled { waiter = continuation }
          return wasCancelled
        }
        if cancelled { continuation.resume(returning: .reject) }
      }
    } onCancel: {
      let waiter = lock.withLock { () -> CheckedContinuation<HostKeyDecision, Never>? in
        wasCancelled = true
        defer { self.waiter = nil }
        return self.waiter
      }
      waiter?.resume(returning: .reject)
    }
  }

  func answer() {
    let waiter = lock.withLock { () -> CheckedContinuation<HostKeyDecision, Never>? in
      defer { self.waiter = nil }
      return self.waiter
    }
    waiter?.resume(returning: .trust)
  }
}

actor Asked {
  var keys: [HostKeyInfo] = []
  func add(_ key: HostKeyInfo) { keys.append(key) }
}
#endif
