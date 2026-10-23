import CryptoKit
import Foundation
@testable import MobileTransport
import XCTest

/// The helper's install roots (`HelperBootstrap.Root`): the home cache the Mac shares, byte for byte, and the
/// `$XDG_RUNTIME_DIR` fallback for a home folder that cannot run programs; the text a helper that exited before greeting
/// leaves, and which root comes next.
final class HelperRootTests: XCTestCase {
  private let digest = String(repeating: "a", count: 64)

  private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func installed(_ root: HelperBootstrap.Root, runtime: String? = "/run/user/1000") -> HelperBootstrap.Installed {
    HelperBootstrap.Installed(platform: "linux-x86_64", digest: digest, size: 1, root: root, uploaded: true,
                              runtimeDirectory: runtime)
  }

  // MARK: Scripts

  /// The home root's scripts as both apps send them, pinned: the probe, the private folders, the cache check (with its
  /// `blocked` arm, 0016), the upload, and the Mac's helper launch prefix (`cachePreamble` + `verify`) are what the Mac's
  /// recordings hold (`ReplayMigrationTests` holds the Mac to its migrations; a change here needs one there).
  func testHomeScriptsArePinned() {
    XCTAssertEqual(sha256(SSHBootstrapScript.probe), "06ed42fc0a087afe78882feab1c56c111bfaa5c2c3c3049ddafee54fc092a6f5")
    XCTAssertEqual(sha256(SSHBootstrapScript.privateDirectoryScript),
                   "56aeabae9a35632d21c095361201d9443bb24ba1b6d4e1e7cf4e630c13261bcd")
    XCTAssertEqual(sha256(SSHBootstrapScript.cacheCheck(size: 1, digest: digest)),
                   "2df1c655ef759cf083208dc0fd9e9e4e19e003119687dfced719c5947e9213a8")
    let launch = SSHBootstrapScript.cachePreamble(digest: digest) + "\n" + SSHBootstrapScript.verify(size: 1, digest: digest)
    XCTAssertEqual(sha256(launch), "8824c674e47821a4d6fb25250fb20519458b5e18e0181fcf586438c7597a4346")
    let upload = SSHBootstrapScript.upload(digest: digest, size: 1, staging: "upload-0")
    XCTAssertEqual(sha256(upload), "e23e329e7f0d98e3c01c166fbbd043074dd0ee7a4c381bd751c2259d8c3a68fd")
    XCTAssertEqual(SSHBootstrapScript.cachePreamble(digest: digest, root: .home), SSHBootstrapScript.cachePreamble(digest: digest))
    XCTAssertEqual(SSHBootstrapScript.upload(digest: digest, size: 1, staging: "upload-0", root: .home), upload)
    XCTAssertEqual(SSHBootstrapScript.privateDirectoryScript(root: .home), SSHBootstrapScript.privateDirectoryScript)
    XCTAssertEqual(SSHBootstrapScript.relativePath(digest: digest, root: .home), SSHBootstrapScript.relativePath(digest: digest))
  }

  /// The runtime root runs the same functions and folder checks, entering `$XDG_RUNTIME_DIR/dispatch` instead of
  /// `~/.dispatch`; everything below it is the home cache's text.
  func testRuntimeScriptsEnterTheRuntimeFolder() {
    let home = SSHBootstrapScript.cachePreamble(digest: digest)
    let runtime = SSHBootstrapScript.cachePreamble(digest: digest, root: .runtimeDirectory)
    XCTAssertTrue(runtime.hasPrefix(SSHBootstrapScript.privateFunctions + "\n" + SSHBootstrapScript.runtimeEntry))
    XCTAssertTrue(home.hasPrefix(SSHBootstrapScript.privateFunctions + "\n"))
    XCTAssertFalse(runtime.contains("$HOME"))
    XCTAssertFalse(runtime.contains(".dispatch"))
    XCTAssertTrue(runtime.contains(#"cd -P "$XDG_RUNTIME_DIR""#))
    let tail = { (script: String) in script[script.range(of: "enter_private bin")!.lowerBound...] }
    XCTAssertEqual(tail(runtime), tail(home))
    XCTAssertEqual(SSHBootstrapScript.relativePath(digest: digest, root: .runtimeDirectory),
                   "dispatch/bin/versions/\(digest)/dispatch-helper")
    let upload = SSHBootstrapScript.upload(digest: digest, size: 1, staging: "upload-0", root: .runtimeDirectory)
    XCTAssertTrue(upload.hasPrefix(runtime))
    XCTAssertTrue(SSHBootstrapScript.runtimeProbe.hasPrefix(SSHBootstrapScript.probe + "\n"))
  }

  func testLaunchCommandHonoursTheRoot() {
    let home = HelperBootstrap.launchCommand(installed(.home), capabilities: "events")
    let runtime = HelperBootstrap.launchCommand(installed(.runtimeDirectory), capabilities: "events")
    XCTAssertTrue(home.contains("enter_private .dispatch"))
    XCTAssertFalse(home.contains("XDG_RUNTIME_DIR"))
    XCTAssertTrue(runtime.contains("enter_private dispatch"))
    XCTAssertFalse(runtime.contains("enter_private .dispatch"))
    for command in [home, runtime] {
      XCTAssertTrue(command.contains("'exec 3>&1 1>&2\n"), "stdout is the protocol's: kept off until the helper runs")
      XCTAssertTrue(command.hasSuffix(#"exec ./dispatch-helper --remote --capabilities '\''events'\'' --stdio 1>&3 3>&-'"#), command)
      XCTAssertFalse(command.contains("|| exit 1"), "a failed check says why")
    }
  }

  func testRuntimeDirectoryLine() {
    XCTAssertEqual(SSHBootstrapScript.runtimeDirectory("DISPATCH_PLATFORM=Linux:x86_64\nDISPATCH_RUNTIME=/run/user/1000\n"),
                   "/run/user/1000")
    XCTAssertNil(SSHBootstrapScript.runtimeDirectory("DISPATCH_PLATFORM=Linux:x86_64\n"))
    XCTAssertNil(SSHBootstrapScript.runtimeDirectory("DISPATCH_RUNTIME=run/user/1000\n"), "relative")
    XCTAssertNil(SSHBootstrapScript.runtimeDirectory("DISPATCH_RUNTIME=\n"))
    XCTAssertNil(SSHBootstrapScript.runtimeDirectory("DISPATCH_RUNTIME=/a\nDISPATCH_RUNTIME=/b\n"), "ambiguous")
    // The Mac's reading of the same output: the extra line changes nothing.
    XCTAssertEqual(SSHBootstrapScript.platform("DISPATCH_PLATFORM=Linux:x86_64\nDISPATCH_RUNTIME=/run/user/1000\n"),
                   .helper("linux-x86_64"))
  }

  func testInstalledPaths() {
    XCTAssertEqual(installed(.home).path, "~/.dispatch/bin/versions/\(digest)/dispatch-helper")
    XCTAssertEqual(installed(.runtimeDirectory).path, "/run/user/1000/dispatch/bin/versions/\(digest)/dispatch-helper")
    XCTAssertEqual(installed(.runtimeDirectory, runtime: nil).path, "$XDG_RUNTIME_DIR/dispatch/bin/versions/\(digest)/dispatch-helper")
    XCTAssertEqual(installed(.runtimeDirectory).relativePath, "dispatch/bin/versions/\(digest)/dispatch-helper")
    XCTAssertEqual(HelperBootstrap.Root.allCases, [.home, .runtimeDirectory])
  }

  // MARK: After a helper exited before greeting

  func testLaunchFailureText() {
    let home = installed(.home), alone = installed(.home, runtime: nil), runtime = installed(.runtimeDirectory)
    let noexec = HelperBootstrap.launchFailure(status: 126, stderr: "sh: 4: exec: ./dispatch-helper: Permission denied\n",
                                               installed: home)
    XCTAssertEqual(noexec, "The home folder cannot run programs (noexec mount or policy), so the helper cannot start there.")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 126, stderr: "", installed: alone),
                   noexec + " No private runtime folder (XDG_RUNTIME_DIR) to use instead.")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 126, stderr: "", installed: runtime),
                   "The runtime folder (XDG_RUNTIME_DIR) cannot run programs (noexec mount or policy), so the helper cannot start there.")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 127, stderr: "", installed: home), "The helper could not be started.")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 127, stderr: "sh: 4: exec: ./dispatch-helper: not found\n", installed: home),
                   "The helper could not be started: sh: 4: exec: ./dispatch-helper: not found")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 2, stderr: "\n first line \u{1b}[0m\nsecond\nthird\nfourth\n", installed: home),
                   "The helper stopped before it answered: first line [0m / second / third")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 1, stderr: "dispatch-setup: installed helper does not verify\n",
                                                 installed: home),
                   "Could not start the helper: installed helper does not verify.")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: 3, stderr: " \n", installed: home),
                   "The helper stopped before it answered (exit status 3).")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: nil, stderr: "", installed: home),
                   "The helper stopped before it answered (no exit status: it was killed or the connection closed).")
    let long = HelperBootstrap.launchFailure(status: 1, stderr: String(repeating: "x", count: 1000), installed: home)
    XCTAssertLessThanOrEqual(long.count, 340)
    for status: Int32? in [nil, 0, 1, 2, 126, 127, 255] {
      for stderr in ["", "\n\n", "boom"] {
        XCTAssertFalse(HelperBootstrap.launchFailure(status: status, stderr: stderr, installed: home).isEmpty)
      }
    }
  }

  func testFallbackRoot() {
    XCTAssertEqual(HelperBootstrap.fallbackRoot(after: 126, installed: installed(.home)), .runtimeDirectory)
    XCTAssertNil(HelperBootstrap.fallbackRoot(after: 126, installed: installed(.home, runtime: nil)), "no usable runtime folder")
    XCTAssertNil(HelperBootstrap.fallbackRoot(after: 126, installed: installed(.runtimeDirectory)), "already there")
    for status: Int32? in [nil, 0, 1, 2, 127, 255] {
      XCTAssertNil(HelperBootstrap.fallbackRoot(after: status, installed: installed(.home)), "\(String(describing: status))")
    }
  }

  #if os(macOS)
  // MARK: The scripts on this Mac's /bin/sh

  private func temporary() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp/hr-" + String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  private func sh(_ script: String, environment: [String: String]) throws -> (status: Int32, output: String) {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"].merging(environment) { $1 }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// The probe names the runtime folder only when it is absolute, the account's and 0700, and `dispatch` there is absent
  /// or private and not a link; it writes nothing, and always succeeds, so the platform line is read either way.
  func testRuntimeProbeChecksTheFolder() throws {
    let root = try temporary(), home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let runtime = root.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    func probe(_ value: String?) throws -> String? {
      var environment = ["HOME": home.path]
      environment["XDG_RUNTIME_DIR"] = value
      let ran = try sh(SSHBootstrapScript.runtimeProbe, environment: environment)
      XCTAssertEqual(ran.status, 0, ran.output)
      XCTAssertEqual(SSHBootstrapScript.platform(ran.output), .helper("darwin-arm64"))
      return SSHBootstrapScript.runtimeDirectory(ran.output)
    }
    XCTAssertEqual(try probe(runtime.path), runtime.path)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.path), [], "the probe writes nothing")
    try FileManager.default.createDirectory(at: runtime.appendingPathComponent("dispatch"), withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    XCTAssertEqual(try probe(runtime.path), runtime.path, "an earlier install's folder")
    XCTAssertNil(try probe(nil), "unset")
    XCTAssertNil(try probe(""), "empty")
    XCTAssertNil(try probe("run"), "relative")
    XCTAssertNil(try probe(root.appendingPathComponent("missing").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    XCTAssertNil(try probe(runtime.path), "readable by others")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.appendingPathComponent("dispatch").path)
    XCTAssertNil(try probe(runtime.path), "its dispatch folder readable by others")
    try FileManager.default.removeItem(at: runtime.appendingPathComponent("dispatch"))
    try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("dispatch"), withDestinationURL: home)
    XCTAssertNil(try probe(runtime.path), "its dispatch folder a link to a private folder")
    try FileManager.default.removeItem(at: runtime.appendingPathComponent("dispatch"))
    try Data().write(to: runtime.appendingPathComponent("dispatch"))
    XCTAssertNil(try probe(runtime.path), "a file named dispatch")
  }

  /// `blocked` names only a right, 0700 file that `test -x` refuses: never a missing one, another version, or a file
  /// that is merely not executable by its mode (this Mac's /tmp runs programs, so the noexec case itself cannot be made
  /// here without mounting a file system).
  func testBlockedNamesOnlyAFolderThatCannotRunTheHelper() throws {
    let root = try temporary(), home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let helper = Data("#!/bin/sh\nexit 0\n".utf8)
    let digest = SHA256.hash(data: helper).map { String(format: "%02x", $0) }.joined()
    let check = SSHBootstrapScript.cachePreamble(digest: digest) + "\n"
      + SSHBootstrapScript.verify(size: helper.count, digest: digest) + " && exit 0\n"
      + SSHBootstrapScript.blocked(size: helper.count, digest: digest) + "\nexit 1"
    let file = home.appendingPathComponent(SSHBootstrapScript.relativePath(digest: digest))
    var ran = try sh(check, environment: ["HOME": home.path])
    XCTAssertEqual(ran.status, 1)
    XCTAssertFalse(ran.output.contains("DISPATCH_NOEXEC"), "missing")
    try helper.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    ran = try sh(check, environment: ["HOME": home.path])
    XCTAssertEqual(ran.status, 1)
    XCTAssertFalse(ran.output.contains("DISPATCH_NOEXEC"), "mode 0600")
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    ran = try sh(check, environment: ["HOME": home.path])
    XCTAssertEqual(ran.status, 0, ran.output)
  }
  #endif
}

#if os(macOS)
/// The runtime root over the loopback sshd fixture.
final class HelperRootInstallTests: XCTestCase {
  /// A "helper" that reports where it runs, what it was given, and exits with `status`.
  private func scriptBinaries(_ body: String) throws -> URL {
    let directory = SSHFixture.shared.root.appendingPathComponent("script-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["darwin-arm64", "linux-aarch64", "linux-x86_64"] {
      try Data(("#!/bin/sh\n# \(UUID().uuidString)\n" + body).utf8).write(to: directory.appendingPathComponent(name))
    }
    return directory
  }

  private func runtimeFolder() throws -> URL {
    let folder = SSHFixture.shared.root.appendingPathComponent("xrt-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return folder
  }

  /// Installed in `$XDG_RUNTIME_DIR/dispatch/bin/versions/<sha256>` with the home cache's checks, reused from there, and
  /// started from there by `launchCommand`; the home cache is left alone.
  func testInstallsAndLaunchesFromTheRuntimeFolder() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let runtime = try runtimeFolder()
    let environment = ["XDG_RUNTIME_DIR": runtime.path]
    let binaries = try scriptBinaries("pwd -P\nprintf '%s\\n' \"$@\"\n")
    let first = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment,
                                                  root: .runtimeDirectory)
    XCTAssertEqual(first.root, .runtimeDirectory)
    XCTAssertTrue(first.uploaded)
    XCTAssertEqual(first.runtimeDirectory, runtime.path)
    XCTAssertEqual(first.path, runtime.path + "/dispatch/bin/versions/\(first.digest)/dispatch-helper")
    let file = runtime.appendingPathComponent(first.relativePath)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    for folder in ["dispatch", "dispatch/bin", "dispatch/bin/versions", "dispatch/bin/versions/\(first.digest)"] {
      let mode = try FileManager.default.attributesOfItem(atPath: runtime.appendingPathComponent(folder).path)[.posixPermissions] as? Int
      XCTAssertEqual(mode.map { $0 & 0o777 }, 0o700, folder)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".dispatch/bin/versions/\(first.digest)").path))
    let second = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment,
                                                   root: .runtimeDirectory)
    XCTAssertFalse(second.uploaded)
    let ran = try await connection.run(HelperBootstrap.launchCommand(first, capabilities: "events", environment: environment))
    XCTAssertEqual(ran.status, 0, String(decoding: ran.stderr, as: UTF8.self))
    let resolved = URL(fileURLWithPath: fixture.resolvedRoot).appendingPathComponent(runtime.lastPathComponent)
    XCTAssertEqual(ran.text.split(separator: "\n").map(String.init),
                   [resolved.appendingPathComponent("dispatch/bin/versions/\(first.digest)").path, "--remote", "--capabilities", "events", "--stdio"])
  }

  /// A launch whose checks fail writes nothing on stdout, the helper protocol's stream: the reason goes to stderr, with
  /// status 1, for `launchFailure`.
  func testFailedLaunchChecksKeepStdoutEmpty() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let installed = try await HelperBootstrap.install(on: connection, binaries: try scriptBinaries("echo started\n"))
    let wrong = HelperBootstrap.Installed(platform: installed.platform, digest: installed.digest, size: installed.size + 1)
    let failed = try await connection.run(HelperBootstrap.launchCommand(wrong))
    XCTAssertEqual(failed.status, 1)
    XCTAssertTrue(failed.stdout.isEmpty, failed.text)
    let stderr = String(decoding: failed.stderr, as: UTF8.self)
    XCTAssertEqual(stderr, "dispatch-setup: installed helper does not verify\n")
    XCTAssertEqual(HelperBootstrap.launchFailure(status: failed.status, stderr: stderr, installed: wrong),
                   "Could not start the helper: installed helper does not verify.")
    // A folder check failing (`fail`, which also writes stdout elsewhere): still nothing on stdout.
    let elsewhere = HelperBootstrap.Installed(platform: installed.platform, digest: installed.digest, size: installed.size,
                                              root: .runtimeDirectory)
    let refused = try await connection.run(HelperBootstrap.launchCommand(elsewhere))
    XCTAssertEqual(refused.status, 1)
    XCTAssertTrue(refused.stdout.isEmpty, refused.text)
    XCTAssertEqual(SSHBootstrapScript.reason(String(decoding: refused.stderr, as: UTF8.self)), "no runtime folder (XDG_RUNTIME_DIR)")
    let started = try await connection.run(HelperBootstrap.launchCommand(installed))
    XCTAssertEqual(started.status, 0)
    XCTAssertEqual(started.text, "started\n", "the helper's own stdout reaches the channel")
  }

  /// Without a usable runtime folder the runtime root is refused before anything is written, and the probe says so.
  func testRuntimeRootNeedsAPrivateRuntimeFolder() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try scriptBinaries("exit 0\n")
    let home = try await HelperBootstrap.install(on: connection, binaries: binaries)
    XCTAssertEqual(home.root, .home)
    XCTAssertNil(home.runtimeDirectory, "the fixture's sessions have no XDG_RUNTIME_DIR")
    XCTAssertNil(HelperBootstrap.fallbackRoot(after: 126, installed: home))
    let open = try runtimeFolder()
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
    for environment in [[:], ["XDG_RUNTIME_DIR": open.path]] {
      do {
        _ = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment, root: .runtimeDirectory)
        XCTFail("installed without a private runtime folder: \(environment)")
      } catch SSHTransportError.bootstrap(let message) {
        XCTAssertTrue(message.contains("XDG_RUNTIME_DIR"), message)
      }
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: open.path), [])
  }

  /// A helper that exits with 126 before greeting at home (as a noexec home answers; here the "helper" says so itself
  /// when it runs under ~/.dispatch) leaves the noexec text, and the runtime folder is named next when the probe found
  /// one; installed and started from there, the same file runs.
  func testExitWith126AtHomeFallsBackToTheRuntimeFolder() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let runtime = try runtimeFolder()
    let environment = ["XDG_RUNTIME_DIR": runtime.path]
    let directory = try scriptBinaries(
      "case \"$(pwd -P)\" in */.dispatch/*) echo 'sh: exec: ./dispatch-helper: Permission denied' >&2; exit 126;; esac\necho started\n")
    let home = try await HelperBootstrap.install(on: connection, binaries: directory, environment: environment)
    XCTAssertEqual(home.root, .home)
    XCTAssertEqual(home.runtimeDirectory, runtime.path)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.path), [], "nothing written there until needed")
    let refused = try await connection.run(HelperBootstrap.launchCommand(home, environment: environment))
    XCTAssertEqual(refused.status, 126)
    XCTAssertTrue(HelperBootstrap.launchFailure(status: refused.status, stderr: String(decoding: refused.stderr, as: UTF8.self),
                                                installed: home).contains("cannot run programs"))
    let next = try XCTUnwrap(HelperBootstrap.fallbackRoot(after: refused.status, installed: home))
    XCTAssertEqual(next, .runtimeDirectory)
    let moved = try await HelperBootstrap.install(on: connection, binaries: directory, environment: environment, root: next)
    XCTAssertEqual(moved.digest, home.digest)
    XCTAssertTrue(moved.uploaded)
    let started = try await connection.run(HelperBootstrap.launchCommand(moved, environment: environment))
    XCTAssertEqual(started.status, 0, String(decoding: started.stderr, as: UTF8.self))
    XCTAssertEqual(started.text, "started\n")
    XCTAssertNil(HelperBootstrap.fallbackRoot(after: 126, installed: moved))
  }
}
#endif
