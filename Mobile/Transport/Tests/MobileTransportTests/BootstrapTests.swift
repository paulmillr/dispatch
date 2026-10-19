#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import CryptoKit
import Foundation
@testable import MobileTransport
import XCTest

/// Requirement 4: the helper install over an exec channel, with host-side size and SHA-256 checks.
final class BootstrapTests: XCTestCase {
  /// The worktree's helper build (scripts/build-ssh-helper.py), when present.
  static let realHelpers = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/helper-rust/bin")

  private func dummyBinaries(size: Int) throws -> URL {
    let directory = SSHFixture.shared.root.appendingPathComponent("dummy-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var bytes = Data(count: size)
    bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
    for name in ["darwin-universal", "linux-aarch64", "linux-x86_64"] {
      try bytes.write(to: directory.appendingPathComponent(name))
    }
    return directory
  }

  func testInstallsDummyThenReusesCache() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try dummyBinaries(size: 3 << 20)
    let first = try await HelperBootstrap.install(on: connection, binaries: binaries)
    XCTAssertTrue(first.uploaded)
    XCTAssertEqual(first.platform, "darwin-universal")
    let installed = fixture.home.appendingPathComponent(first.relativePath)
    let attributes = try FileManager.default.attributesOfItem(atPath: installed.path)
    XCTAssertEqual(attributes[.size] as? Int, 3 << 20)
    XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: installed)).map { String(format: "%02x", $0) }.joined(), first.digest)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
    XCTAssertEqual(leftovers, ["dispatch-helper"], "no staging directory is left behind")
    let second = try await HelperBootstrap.install(on: connection, binaries: binaries)
    XCTAssertFalse(second.uploaded)
    XCTAssertEqual(second.digest, first.digest)
  }

  /// The host refuses bytes whose SHA-256 differs from the announced digest; nothing is published.
  func testHostRejectsWrongDigest() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let announced = Data(repeating: 1, count: 4096), sent = Data(repeating: 2, count: 4096)
    let digest = SHA256.hash(data: announced).map { String(format: "%02x", $0) }.joined()
    let result = try await connection.run(posixShell(SSHBootstrapScript.upload(digest: digest, size: sent.count, staging: "upload-test")), input: sent)
    XCTAssertNotEqual(result.status, 0)
    let directory = fixture.home.appendingPathComponent(".dispatch/bin/versions/" + digest)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  /// A launch environment (`env NAME=value` before the shell) moves the install with `HOME`: what the live tests use
  /// to keep a Linux host's own home untouched.
  func testEnvironmentMovesTheInstall() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let home = fixture.root.appendingPathComponent("eh-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let binaries = try dummyBinaries(size: 4096)
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: ["HOME": home.path])
    XCTAssertTrue(installed.uploaded)
    XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(installed.relativePath).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(installed.relativePath).path))
    let echoed = try await connection.run(posixShell("printf '%s|%s' \"$HOME\" \"$X_Y\"", environment: ["X_Y": "it's", "1BAD": "no", "HOME": home.path]))
    XCTAssertEqual(echoed.text, home.path + "|it's", "quoted values; invalid names are dropped")
  }

  /// Copies of secrets made for the C ABI (keyboard-interactive answers, passphrases) are zeroed before they are freed.
  func testWipeZeroesACopyBeforeItIsFreed() {
    let copy = strdup("one-time code 123456")!
    defer { free(copy) }
    let count = strlen(copy)
    Engine.wipe(copy, count: count)
    XCTAssertTrue(UnsafeBufferPointer(start: copy, count: count).allSatisfy { $0 == 0 })
    Engine.wipe(nil, count: 4)
  }

  func testPlatformNames() {
    XCTAssertEqual(SSHBootstrapScript.platform("DISPATCH_PLATFORM=Linux:aarch64\n"), .helper("linux-aarch64"))
    XCTAssertEqual(SSHBootstrapScript.platform("DISPATCH_PLATFORM=Linux:x86_64\n"), .helper("linux-x86_64"))
    XCTAssertEqual(SSHBootstrapScript.platform("DISPATCH_PLATFORM=FreeBSD:amd64\n"), .unsupported)
    XCTAssertEqual(SSHBootstrapScript.platform("motd\n"), .unidentified)
  }

  func testInstallsRealHelper() async throws {
    guard FileManager.default.fileExists(atPath: Self.realHelpers.appendingPathComponent("darwin-universal").path) else {
      throw XCTSkip("No helper build at \(Self.realHelpers.path) (scripts/build-ssh-helper.py --build-only)")
    }
    let fixture = try SSHFixture()
    defer { fixture.stop() }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let start = ContinuousClock.now
    let installed = try await HelperBootstrap.install(on: connection, binaries: Self.realHelpers)
    let elapsed = seconds(ContinuousClock.now - start)
    XCTAssertTrue(installed.uploaded)
    let again = ContinuousClock.now
    let cached = try await HelperBootstrap.install(on: connection, binaries: Self.realHelpers)
    XCTAssertFalse(cached.uploaded)
    report(String(format: "bootstrap real helper (%.1f MB darwin-universal): upload %.2f s, cached check %.0f ms",
                  Double(installed.size) / 1e6, elapsed, seconds(ContinuousClock.now - again) * 1000))
  }
}
#endif
