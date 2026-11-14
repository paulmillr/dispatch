import CryptoKit
import Foundation
@testable import MobileTransport
import XCTest

/// The launch from the cache (`HelperBootstrap.cachedLaunchCommand`, `SSHHostSession.bootstrapHelper(fromCache:)`): one
/// exec channel that starts a cached helper with `launchCommand`'s arguments, or starts nothing and says so on stderr.
final class CachedLaunchTests: XCTestCase {
  private let bundled = [
    HelperBootstrap.Bundled(name: "darwin-arm64", size: 10, digest: String(repeating: "a", count: 64)),
    HelperBootstrap.Bundled(name: "linux-aarch64", size: 20, digest: String(repeating: "b", count: 64)),
    HelperBootstrap.Bundled(name: "linux-x86_64", size: 30, digest: String(repeating: "c", count: 64)),
  ]

  // MARK: The script and its report

  /// One case per bundled helper with its size and SHA-256, stdout and stdin set aside until the exec, and the exec
  /// itself `launchCommand`'s, from either root.
  func testTheScriptCarriesEveryHelperAndLaunchCommandsArguments() {
    let script = SSHBootstrapScript.cachedLaunch(bundled.map(\.candidate), arguments: "--remote --capabilities 'events' --stdio")
    XCTAssertTrue(script.hasPrefix("exec 3>&1 1>&2 4<&0 0</dev/null\n" + SSHBootstrapScript.runtimeProbe + "\n"), script)
    XCTAssertTrue(script.contains("  Darwin:arm64) size='10' digest='\(String(repeating: "a", count: 64))';;\n"))
    XCTAssertTrue(script.contains("  Linux:aarch64|Linux:arm64) size='20' digest='\(String(repeating: "b", count: 64))';;\n"))
    XCTAssertTrue(script.contains("  Linux:x86_64) size='30' digest='\(String(repeating: "c", count: 64))';;\n"))
    let exec = "exec ./dispatch-helper --remote --capabilities 'events' --stdio 1>&3 3>&- 0<&4 4<&-"
    XCTAssertEqual(script.components(separatedBy: exec).count, 3, "one exec per root")
    XCTAssertTrue(script.contains("printf 'DISPATCH_LAUNCH=%s\\n' home\n" + exec))
    XCTAssertTrue(script.contains("printf 'DISPATCH_LAUNCH=%s\\n' runtime\n" + exec))
    XCTAssertTrue(script.contains("enter_private .dispatch") && script.contains("enter_private dispatch"))
    XCTAssertTrue(script.hasSuffix("\nexit 3"))
    let command = HelperBootstrap.cachedLaunchCommand(bundled, capabilities: "events", environment: ["X_Y": "1"])
    XCTAssertTrue(command.hasPrefix("exec env X_Y='1' /bin/sh -c '"), command)
    // The same arguments `launchCommand` gives the helper.
    let launch = HelperBootstrap.launchCommand(.init(platform: "darwin-arm64", digest: bundled[0].digest, size: 10),
                                               capabilities: "events")
    XCTAssertTrue(launch.hasSuffix(#"exec ./dispatch-helper --remote --capabilities '\''events'\'' --stdio 1>&3 3>&-'"#))
    XCTAssertTrue(command.contains(#"exec ./dispatch-helper --remote --capabilities '\''events'\'' --stdio 1>&3 3>&- 0<&4 4<&-"#))
  }

  /// The report names the helper, its root and the runtime folder; the helper's stderr is what follows the launch line,
  /// with whatever else the login printed before it. No launch line, or one the phone cannot place, is no launch.
  func testTheReport() throws {
    let home = try XCTUnwrap(HelperBootstrap.launched(
      "motd line\nDISPATCH_PLATFORM=Linux:aarch64\nDISPATCH_LAUNCH=home\nhelper: warning\n", candidates: bundled))
    XCTAssertEqual(home.installed, HelperBootstrap.Installed(platform: "linux-aarch64", digest: bundled[1].digest, size: 20,
                                                             root: .home, uploaded: false, runtimeDirectory: nil))
    XCTAssertEqual(home.stderr, "motd line\nhelper: warning\n")
    let runtime = try XCTUnwrap(HelperBootstrap.launched(
      "DISPATCH_PLATFORM=Darwin:arm64\nDISPATCH_RUNTIME=/run/user/501\nDISPATCH_NOEXEC\nDISPATCH_LAUNCH=runtime\n",
      candidates: bundled))
    XCTAssertEqual(runtime.installed, HelperBootstrap.Installed(platform: "darwin-arm64", digest: bundled[0].digest, size: 10,
                                                                root: .runtimeDirectory, uploaded: false,
                                                                runtimeDirectory: "/run/user/501"))
    XCTAssertEqual(runtime.stderr, "")
    XCTAssertEqual(runtime.installed.path, "/run/user/501/dispatch/bin/versions/\(bundled[0].digest)/dispatch-helper")
    // A home launch keeps the runtime folder its probe saw, for `fallbackRoot` after a 126.
    let withRuntime = try XCTUnwrap(HelperBootstrap.launched(
      "DISPATCH_PLATFORM=Linux:x86_64\nDISPATCH_RUNTIME=/run/user/1000\nDISPATCH_LAUNCH=home\n", candidates: bundled))
    XCTAssertEqual(HelperBootstrap.fallbackRoot(after: 126, installed: withRuntime.installed), .runtimeDirectory)

    XCTAssertNil(HelperBootstrap.launched("", candidates: bundled))
    XCTAssertNil(HelperBootstrap.launched("DISPATCH_PLATFORM=Linux:aarch64\nDISPATCH_NOEXEC\n", candidates: bundled), "a miss")
    XCTAssertNil(HelperBootstrap.launched("DISPATCH_PLATFORM=Linux:aarch64\ndispatch-setup: unsafe folder .dispatch\n",
                                          candidates: bundled))
    XCTAssertNil(HelperBootstrap.launched("DISPATCH_PLATFORM=FreeBSD:amd64\nDISPATCH_LAUNCH=home\n", candidates: bundled))
    XCTAssertNil(HelperBootstrap.launched("DISPATCH_PLATFORM=Linux:aarch64\nDISPATCH_LAUNCH=elsewhere\n", candidates: bundled))
    XCTAssertNil(HelperBootstrap.launched("DISPATCH_LAUNCH=home\n", candidates: bundled), "no platform line")
    XCTAssertNil(HelperBootstrap.launched("DISPATCH_PLATFORM=Linux:aarch64\nDISPATCH_LAUNCH=home\n", candidates: [bundled[0]]),
                 "a helper the app does not bundle")
  }

  #if os(macOS)
  /// Each bundled helper's identity is the expanded file's, as the upload's; a missing one is left out.
  func testBundledIdentities() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bundled-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let plain = Data("plain helper".utf8)
    try plain.write(to: folder.appendingPathComponent("linux-x86_64"))
    let gzip = Process()
    gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    gzip.arguments = ["-9n", "-k", folder.appendingPathComponent("linux-x86_64").path]
    try gzip.run()
    finish(gzip)
    try FileManager.default.moveItem(at: folder.appendingPathComponent("linux-x86_64.gz"),
                                     to: folder.appendingPathComponent("darwin-arm64.gz"))
    let found = HelperBootstrap.bundled(in: folder)
    let digest = SHA256.hash(data: plain).map { String(format: "%02x", $0) }.joined()
    XCTAssertEqual(found, [.init(name: "darwin-arm64", size: plain.count, digest: digest),
                           .init(name: "linux-x86_64", size: plain.count, digest: digest)])
    XCTAssertEqual(HelperBootstrap.bundled(in: folder), found, "again, from what this run computed")
    try Data("changed".utf8).write(to: folder.appendingPathComponent("linux-x86_64"))
    XCTAssertEqual(HelperBootstrap.bundled(in: folder).last?.size, 7, "a changed file is read again")
  }

  // MARK: Under the fixture sshd

  /// A "helper" that reads one line of stdin and reports it, its arguments, a variable of the launch environment and its
  /// folder, then exits with `status`.
  private func scriptBinaries(in fixture: SSHFixture, status: Int32 = 0) throws -> URL {
    let directory = fixture.root.appendingPathComponent("cl-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let body = "#!/bin/sh\n# \(UUID().uuidString)\nIFS= read -r line\nprintf 'read %s|%s|%s\\n' \"$line\" \"$*\" \"$X_Y\"\npwd -P\nexit \(status)\n"
    for name in ["darwin-arm64", "linux-aarch64", "linux-x86_64"] {
      try Data(body.utf8).write(to: directory.appendingPathComponent(name))
    }
    return directory
  }

  private struct Started {
    let stdout: String
    let status: Int32?
    let installed: HelperBootstrap.Installed?
    let stderr: String
    let refusal: SSHTransportError?
  }

  /// The launch from the cache with one line written at once (before any byte comes back), read to its end.
  private func launch(on connection: SSHConnection, binaries: URL, environment: [String: String] = [:]) async throws -> Started {
    let session = try await SSHHostSession.bootstrapHelper(on: connection, binaries: binaries, capabilities: "events",
                                                           environment: environment, fromCache: true, phase: { _ in })
    try session.helper.write.write(contentsOf: Data("hello at once\n".utf8))
    let read = session.helper.read
    let stdout = try await Task.detached { try read.readToEnd() ?? Data() }.value
    let status = await session.helper.exitStatus()
    return Started(stdout: String(decoding: stdout, as: UTF8.self), status: status, installed: session.installed,
                   stderr: await session.stderr(), refusal: session.helper.refusal)
  }

  private func isCachedLaunch(_ command: String) -> Bool { command.contains("DISPATCH_LAUNCH=") }

  /// A cached helper: exactly one remote command, the launch from the cache; the line written at once reaches the
  /// helper (nothing before its exec read stdin), which gets `launchCommand`'s arguments and environment in its
  /// digest's folder; stdout holds only its bytes; `installed` is the install's, not uploaded.
  func testACachedHelperStartsInOneCommand() async throws {
    let (fixture, log) = try CommandLog.fixture()
    defer { fixture.stop(); log.stop() }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try scriptBinaries(in: fixture)
    let environment = ["X_Y": "it's"]
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
    let viaLaunchCommand = try await connection.run(
      HelperBootstrap.launchCommand(installed, capabilities: "events", environment: environment), input: Data("hello at once\n".utf8))
    log.clear()

    let started = try await launch(on: connection, binaries: binaries, environment: environment)
    let commands = log.commands
    XCTAssertEqual(commands.count, 1, commands.joined(separator: "\n----\n"))
    XCTAssertTrue(commands.first.map(isCachedLaunch) == true)
    let folder = URL(fileURLWithPath: fixture.resolvedRoot).appendingPathComponent("home/" + installed.relativePath)
      .deletingLastPathComponent().path
    XCTAssertEqual(started.stdout, "read hello at once|--remote --capabilities events --stdio|it's\n\(folder)\n")
    XCTAssertEqual(started.stdout, viaLaunchCommand.text, "as launchCommand starts it")
    XCTAssertEqual(started.status, 0)
    XCTAssertEqual(started.installed, HelperBootstrap.Installed(platform: installed.platform, digest: installed.digest,
                                                                size: installed.size, root: .home, uploaded: false,
                                                                runtimeDirectory: installed.runtimeDirectory))
    XCTAssertEqual(started.stderr, "", "the script's report is not the helper's stderr")
    XCTAssertNil(started.refusal)
  }

  /// An empty cache: the launch starts nothing (stdout empty, no `installed`, status 3) in one command; the full
  /// bootstrap uploads, and the next launch from the cache starts it.
  func testAMissStartsNothingThenTheFullBootstrapInstalls() async throws {
    let (fixture, log) = try CommandLog.fixture()
    defer { fixture.stop(); log.stop() }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try scriptBinaries(in: fixture)
    let missed = try await launch(on: connection, binaries: binaries)
    XCTAssertEqual(log.commands.count, 1)
    XCTAssertEqual(missed.stdout, "")
    XCTAssertNil(missed.installed)
    XCTAssertEqual(missed.status, 3)
    XCTAssertNil(missed.refusal)
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries)
    XCTAssertTrue(installed.uploaded)
    let started = try await launch(on: connection, binaries: binaries)
    XCTAssertEqual(started.installed?.digest, installed.digest)
    XCTAssertTrue(started.stdout.hasPrefix("read hello at once|"), started.stdout)
  }

  /// A cached file with the right size but other bytes, or another size, fails the launch's check: nothing starts, and
  /// the full bootstrap uploads it again.
  func testADamagedCacheIsInstalledAgain() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try scriptBinaries(in: fixture)
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries)
    let file = fixture.home.appendingPathComponent(installed.relativePath)
    let good = try Data(contentsOf: file)
    var flipped = good
    flipped[flipped.count - 2] ^= 1
    for damaged in [flipped, good + Data("x".utf8)] {
      try damaged.write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      let missed = try await launch(on: connection, binaries: binaries)
      XCTAssertNil(missed.installed, "\(damaged.count) bytes")
      XCTAssertEqual(missed.stdout, "")
      let again = try await HelperBootstrap.install(on: connection, binaries: binaries)
      XCTAssertTrue(again.uploaded)
      XCTAssertEqual(try Data(contentsOf: file), good)
      let started = try await launch(on: connection, binaries: binaries)
      XCTAssertNotNil(started.installed)
    }
  }

  /// A home whose cached helper is right but cannot run (here an ACL denying execute: policy, as a noexec mount answers
  /// `test -x`): the launch moves on to the runtime folder; empty there, it starts nothing, the full bootstrap installs
  /// there, and the launch from the cache then starts it from there in one command.
  func testABlockedHomeStartsFromTheRuntimeFolder() async throws {
    let (fixture, log) = try CommandLog.fixture()
    defer { fixture.stop(); log.stop() }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try scriptBinaries(in: fixture)
    let runtime = fixture.root.appendingPathComponent("xrt")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let environment = ["XDG_RUNTIME_DIR": runtime.path]
    let home = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
    XCTAssertEqual(home.root, .home)
    try deny(execute: fixture.home.appendingPathComponent(home.relativePath))

    let missed = try await launch(on: connection, binaries: binaries, environment: environment)
    XCTAssertNil(missed.installed)
    XCTAssertEqual(missed.stdout, "")
    let moved = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
    XCTAssertEqual(moved.root, .runtimeDirectory, "the full bootstrap moves there too")
    log.clear()
    let started = try await launch(on: connection, binaries: binaries, environment: environment)
    XCTAssertEqual(log.commands.count, 1)
    XCTAssertEqual(started.installed, HelperBootstrap.Installed(platform: home.platform, digest: home.digest, size: home.size,
                                                                root: .runtimeDirectory, uploaded: false,
                                                                runtimeDirectory: runtime.path))
    let folder = URL(fileURLWithPath: fixture.resolvedRoot).appendingPathComponent("xrt/" + moved.relativePath)
      .deletingLastPathComponent().path
    XCTAssertEqual(started.stdout, "read hello at once|--remote --capabilities events --stdio|\n\(folder)\n")
    XCTAssertEqual(started.stderr, "")
  }

  /// Without a usable runtime folder a blocked home starts nothing, and the full bootstrap gives today's text.
  func testABlockedHomeWithoutARuntimeFolderGivesTodaysText() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let home = fixture.root.appendingPathComponent("bh-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let environment = ["HOME": home.path]
    let binaries = try scriptBinaries(in: fixture)
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
    try deny(execute: home.appendingPathComponent(installed.relativePath))
    let missed = try await launch(on: connection, binaries: binaries, environment: environment)
    XCTAssertNil(missed.installed)
    do {
      _ = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
      XCTFail("installed in a home that cannot run it")
    } catch SSHTransportError.bootstrap(let message) {
      XCTAssertEqual(message, HelperBootstrap.launchFailure(status: 126, stderr: "", installed: installed))
    }
  }

  /// A platform no bundled helper serves (`uname` answering FreeBSD here): nothing starts, and the full bootstrap gives
  /// today's message.
  func testAnUnsupportedPlatformGivesTodaysMessage() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let tools = fixture.root.appendingPathComponent("un-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    try Data("#!/bin/sh\ncase \"$1\" in -s) echo FreeBSD;; -m) echo amd64;; *) /usr/bin/uname \"$@\";; esac\n".utf8)
      .write(to: tools.appendingPathComponent("uname"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tools.appendingPathComponent("uname").path)
    let environment = ["PATH": tools.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
    let binaries = try scriptBinaries(in: fixture)
    let missed = try await launch(on: connection, binaries: binaries, environment: environment)
    XCTAssertNil(missed.installed)
    XCTAssertEqual(missed.status, 3)
    do {
      _ = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
      XCTFail("installed for FreeBSD")
    } catch SSHTransportError.bootstrap(let message) {
      XCTAssertEqual(message, "SSH integration requires Linux on ARM64 or x86-64, or macOS on Apple silicon.")
    }
  }

  /// A helper the cache held that exits before greeting: its status, and its own stderr for `launchFailure`.
  func testAHelperThatExitsReportsItsOwnStderr() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let binaries = try scriptBinaries(in: fixture, status: 2)
    _ = try await HelperBootstrap.install(on: connection, binaries: binaries)
    let started = try await launch(on: connection, binaries: binaries)
    XCTAssertEqual(started.status, 2)
    XCTAssertNotNil(started.installed)
    XCTAssertEqual(started.stderr, "")
  }

  /// An ACL that denies the account execute on `file`: its mode stays 0700, `test -x` refuses it and an exec fails
  /// with 126, as on a home the system will not run programs from.
  private func deny(execute file: URL) throws {
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "user:\(NSUserName()) deny execute", file.path]
    try chmod.run()
    finish(chmod)
    XCTAssertEqual(chmod.terminationStatus, 0)
  }
  #endif
}
