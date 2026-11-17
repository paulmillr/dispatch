#if os(macOS)
import Foundation
import MobileTransport
import XCTest

/// The engines' speed (the Swift engine's, and russh's in a `DISPATCH_RUSSH` build) through the public API against private loopback sshd daemons, each restricted to one cipher
/// (and MAC) or one key exchange method: throughput both ways, time to a logged-in session, and small-message round
/// trips over one exec channel's socket (the helper protocol's traffic). Numbers print as `MEASURE` lines. Run only
/// with `DISPATCH_SSH_SPEED=1`, and in a release build for meaningful numbers:
///
///     DISPATCH_SSH_SPEED=1 swift test -c release --scratch-path ../../build/spm-release --filter SpeedTests
///
/// Each test sets `SSHTransportEngine.preferred` itself (a release build ignores `DISPATCH_SSH_ENGINE`) and puts it
/// back. CPU is this process's (user + system, `getrusage`): the engine and the test's own reads and writes, not sshd.
final class SpeedTests: XCTestCase {
  static let transferBytes = (Int(ProcessInfo.processInfo.environment["DISPATCH_SSH_SPEED_MIB"] ?? "") ?? 256) << 20
  static let runs = Int(ProcessInfo.processInfo.environment["DISPATCH_SSH_SPEED_RUNS"] ?? "") ?? 3

  override func setUpWithError() throws {
    guard ProcessInfo.processInfo.environment["DISPATCH_SSH_SPEED"] == "1" else {
      throw XCTSkip("set DISPATCH_SSH_SPEED=1 (with -c release) to measure")
    }
  }

  private var saved: SSHTransportEngine = .standard
  override func setUp() { saved = SSHTransportEngine.preferred }
  override func tearDown() { SSHTransportEngine.preferred = saved }

  /// One configuration: an engine and what sshd allows.
  struct Setup {
    let engine: SSHTransportEngine
    let label: String
    let configuration: [String]
  }

  static var throughputSetups: [Setup] {
    var setups: [Setup] = []
    for cipher in ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "chacha20-poly1305@openssh.com"] {
      setups.append(Setup(engine: .swift, label: cipher, configuration: ["Ciphers \(cipher)"]))
    }
    for mac in ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com", "hmac-sha2-256", "hmac-sha2-512"] {
      setups.append(Setup(engine: .swift, label: "aes256-ctr " + mac, configuration: ["Ciphers aes256-ctr", "MACs \(mac)"]))
    }
    setups.append(Setup(engine: .swift, label: "aes128-ctr hmac-sha2-256-etm@openssh.com",
                        configuration: ["Ciphers aes128-ctr", "MACs hmac-sha2-256-etm@openssh.com"]))
    #if DISPATCH_RUSSH
    setups.append(Setup(engine: .russh, label: "default (negotiated: see the sshd log line)", configuration: ["LogLevel DEBUG1"]))
    setups.append(Setup(engine: .russh, label: "chacha20-poly1305@openssh.com",
                        configuration: ["Ciphers chacha20-poly1305@openssh.com"]))
    setups.append(Setup(engine: .russh, label: "aes256-gcm@openssh.com", configuration: ["Ciphers aes256-gcm@openssh.com"]))
    #endif
    setups.append(Setup(engine: .swift, label: "default (negotiated: see the sshd log line)", configuration: ["LogLevel DEBUG1"]))
    return setups
  }

  func testThroughputPerCipher() async throws {
    let only = ProcessInfo.processInfo.environment["DISPATCH_SSH_SPEED_ONLY"]
    for setup in Self.throughputSetups where only.map({ setup.label.contains($0) }) ?? true {
      SSHTransportEngine.preferred = setup.engine
      let fixture = try SSHFixture(extraConfiguration: setup.configuration.filter { !$0.hasPrefix("LogLevel") },
                                   logLevel: setup.configuration.first { $0.hasPrefix("LogLevel") }.map { String($0.dropFirst(9)) } ?? "ERROR")
      defer { fixture.stop() }
      var uploads: [(Double, Double)] = []
      var downloads: [(Double, Double)] = []
      for _ in 0..<Self.runs {
        let connection = try await fixture.connect()
        uploads.append(try await Self.upload(connection, bytes: Self.transferBytes))
        downloads.append(try await Self.download(connection, bytes: Self.transferBytes))
        await connection.close()
      }
      // sshd's DEBUG1 line: "kex: client->server cipher: <name> MAC: <name> compression: none".
      let negotiated = fixture.log.firstMatch(of: /client->server cipher: (\S+) MAC: (\S+)/)
        .map { " [negotiated \($0.1) \($0.2)]" } ?? ""
      for (direction, samples) in [("upload", uploads), ("download", downloads)] {
        let (wall, cpu) = Self.median(samples)
        report(String(format: "throughput %@ %@ %@: %.0f MB/s (%.2f s for %d MiB), CPU %.2f s = %.0f%% of wall, median of %d%@",
                      setup.engine.rawValue, setup.label, direction, Double(Self.transferBytes) / wall / 1e6, wall,
                      Self.transferBytes >> 20, cpu, 100 * cpu / wall, samples.count, negotiated))
      }
    }
  }

  /// Time to a logged-in session (TCP connect, version exchange, key exchange, Ed25519 login) per method.
  func testTimeToLoggedInSession() async throws {
    let iterations = Int(ProcessInfo.processInfo.environment["DISPATCH_SSH_SPEED_CONNECTS"] ?? "") ?? 30
    for kex in ["mlkem768x25519-sha256", "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256",
                "ecdh-sha2-nistp384", "ecdh-sha2-nistp521"] {
      let fixture = try SSHFixture(extraConfiguration: ["KexAlgorithms \(kex)"])
      defer { fixture.stop() }
      for engine in SSHTransportEngine.allCases {
        SSHTransportEngine.preferred = engine
        var totals: [Double] = []
        var handshakes: [Double] = []
        var cpu: [Double] = []
        var failure: Error?
        for index in 0..<(iterations + 2) {
          let before = Self.cpuSeconds()
          let start = ContinuousClock.now
          do {
            let connection = try await fixture.connect()
            let elapsed = seconds(ContinuousClock.now - start)
            let used = Self.cpuSeconds() - before
            if index >= 2 {
              totals.append(elapsed)
              handshakes.append(seconds(connection.timings.handshake))
              cpu.append(used)
            }
            await connection.close()
          } catch {
            failure = error
            break
          }
        }
        if let failure {
          report("connect \(engine.rawValue) \(kex): failed: \(failure)")
          continue
        }
        report(String(format: "connect %@ %@: median %.1f ms to logged in (handshake %.1f ms), min %.1f, max %.1f, CPU %.1f ms, n=%d",
                      engine.rawValue, kex, 1000 * Self.median(totals), 1000 * Self.median(handshakes),
                      1000 * (totals.min() ?? 0), 1000 * (totals.max() ?? 0), 1000 * Self.median(cpu), totals.count))
      }
    }
  }

  /// 100,000 round trips of 300 bytes over one exec's socket (`cat` echoes them), as the helper's frames go.
  func testSmallMessageRoundTrips() async throws {
    let count = Int(ProcessInfo.processInfo.environment["DISPATCH_SSH_SPEED_TRIPS"] ?? "") ?? 100_000
    let fixture = try SSHFixture()
    defer { fixture.stop() }
    for engine in SSHTransportEngine.allCases {
      SSHTransportEngine.preferred = engine
      let connection = try await fixture.connect()
      let exec = try await connection.exec("cat")
      guard let fd = exec.takeFileDescriptor() else { return XCTFail("no descriptor") }
      let message = [UInt8]((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7) })
      var buffer = [UInt8](repeating: 0, count: 4096)
      var samples: [Double] = []
      samples.reserveCapacity(count)
      let before = Self.cpuSeconds()
      let switchesBefore = Self.contextSwitches()
      let start = ContinuousClock.now
      var ok = true
      for _ in 0..<count where ok {
        let one = ContinuousClock.now
        ok = message.withUnsafeBytes { Self.writeAll(fd, $0) }
        var received = 0
        while ok, received < message.count {
          let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
          if got <= 0 { ok = false } else { received += got }
        }
        samples.append(seconds(ContinuousClock.now - one))
      }
      let wall = seconds(ContinuousClock.now - start)
      let cpu = Self.cpuSeconds() - before
      let switches = Self.contextSwitches() - switchesBefore
      shutdown(fd, SHUT_WR)
      close(fd)
      await connection.close()
      XCTAssertTrue(ok, "\(engine)")
      samples.sort()
      report(String(format: "round trips %@: %d of 300 bytes in %.2f s, median %.0f us, p99 %.0f us, max %.1f ms, CPU %.2f s (%.1f us per trip), %.1f context switches per trip",
                    engine.rawValue, samples.count, wall, 1e6 * samples[samples.count / 2], 1e6 * samples[samples.count * 99 / 100],
                    1e3 * (samples.last ?? 0), cpu, 1e6 * cpu / Double(max(1, samples.count)),
                    Double(switches) / Double(max(1, samples.count))))
    }
  }

  // MARK: Helpers

  static func upload(_ connection: SSHConnection, bytes: Int) async throws -> (Double, Double) {
    var chunk = Data(count: 1 << 20)
    for index in chunk.indices { chunk[index] = UInt8(truncatingIfNeeded: index &* 31) }
    let before = cpuSeconds()
    let start = ContinuousClock.now
    let exec = try await connection.exec("cat > /dev/null")
    var sent = 0
    while sent < bytes {
      try await exec.write(chunk)
      sent += chunk.count
    }
    try await exec.finishInput()
    for try await _ in exec {}
    let status = try await exec.exitStatus()
    XCTAssertEqual(status, 0)
    return (seconds(ContinuousClock.now - start), cpuSeconds() - before)
  }

  static func download(_ connection: SSHConnection, bytes: Int) async throws -> (Double, Double) {
    let before = cpuSeconds()
    let start = ContinuousClock.now
    let exec = try await connection.exec("head -c \(bytes) /dev/zero")
    try await exec.finishInput()
    var received = 0
    for try await output in exec { if case .stdout(let data) = output { received += data.count } }
    XCTAssertEqual(received, bytes)
    return (seconds(ContinuousClock.now - start), cpuSeconds() - before)
  }

  static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let wrote = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
      if wrote <= 0 { return false }
      offset += wrote
    }
    return true
  }

  static func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func value(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return value(usage.ru_utime) + value(usage.ru_stime)
  }

  /// Voluntary and involuntary context switches of this process so far.
  static func contextSwitches() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_nvcsw + usage.ru_nivcsw)
  }

  static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }

  static func median(_ samples: [(Double, Double)]) -> (Double, Double) {
    let sorted = samples.sorted { $0.0 < $1.0 }
    return sorted.isEmpty ? (0, 0) : sorted[sorted.count / 2]
  }
}
#endif
