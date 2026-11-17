#if os(macOS)
// gzip(1) makes the archives: macOS only, as the other bootstrap tests.
import Foundation
@testable import MobileTransport
import XCTest

/// The app bundles its helpers gzipped (App Store Connect refuses a Mach-O file that is not a bundle's executable):
/// `HelperBootstrap.helper` expands `<platform>.gz`, and reads `<platform>` as it is where no archive exists.
final class HelperArchiveTests: XCTestCase {
  func testExpandsTheArchiveAndFallsBackToThePlainFile() throws {
    let directory = try temporaryFolder()
    let binary = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try binary.write(to: directory.appendingPathComponent("darwin-arm64"))
    try SSHFixture.run("/usr/bin/gzip", ["-n", "-9", directory.appendingPathComponent("darwin-arm64").path])
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("darwin-arm64").path))
    XCTAssertEqual(try HelperBootstrap.helper("darwin-arm64", in: directory), binary)

    let plain = Data("plain".utf8)
    try plain.write(to: directory.appendingPathComponent("linux-x86_64"))
    XCTAssertEqual(try HelperBootstrap.helper("linux-x86_64", in: directory), plain)
  }

  func testABrokenArchiveIsABootstrapError() throws {
    let directory = try temporaryFolder()
    try Data("not gzip".utf8).write(to: directory.appendingPathComponent("linux-aarch64.gz"))
    XCTAssertThrowsError(try HelperBootstrap.helper("linux-aarch64", in: directory)) { error in
      guard case SSHTransportError.bootstrap(let message) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(message, "SSH helper is missing or invalid (not a gzip file).")
    }
  }
}
#endif
