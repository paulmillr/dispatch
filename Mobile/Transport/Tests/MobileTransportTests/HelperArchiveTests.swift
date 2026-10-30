#if os(macOS)
// gzip(1) makes the archives: macOS only, as the other bootstrap tests.
import Foundation
@testable import MobileTransport
import XCTest

/// The app bundles its helpers gzipped (App Store Connect refuses a Mach-O file that is not a bundle's executable):
/// `HelperBootstrap.helper` expands `<platform>.gz`, and reads `<platform>` as it is where no archive exists.
final class HelperArchiveTests: XCTestCase {
  private func folder() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-archive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func gzip(_ file: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-n", "-9", file.path]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  func testExpandsTheArchiveAndFallsBackToThePlainFile() throws {
    let directory = try folder()
    let binary = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try binary.write(to: directory.appendingPathComponent("darwin-arm64"))
    try gzip(directory.appendingPathComponent("darwin-arm64"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("darwin-arm64").path))
    XCTAssertEqual(try HelperBootstrap.helper("darwin-arm64", in: directory), binary)

    let plain = Data("plain".utf8)
    try plain.write(to: directory.appendingPathComponent("linux-x86_64"))
    XCTAssertEqual(try HelperBootstrap.helper("linux-x86_64", in: directory), plain)
  }

  func testABrokenArchiveIsABootstrapError() throws {
    let directory = try folder()
    try Data("not gzip".utf8).write(to: directory.appendingPathComponent("linux-aarch64.gz"))
    XCTAssertThrowsError(try HelperBootstrap.helper("linux-aarch64", in: directory)) { error in
      guard case SSHTransportError.bootstrap(let message) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(message, "SSH helper is missing or invalid (not a gzip file).")
    }
  }
}
#endif
