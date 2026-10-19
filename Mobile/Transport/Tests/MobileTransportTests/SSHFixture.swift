#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Darwin
import Foundation
import XCTest

/// A private loopback sshd run as the current user (the approach of DispatchTests/SSHTestServer.swift):
/// disposable host and user keys, its own authorized_keys, and a private HOME so remote commands never
/// touch the account's real home. Roots are short (`/tmp/st-<pid>-<run>-<n>`): sun_path is 104 bytes.
final class SSHFixture: @unchecked Sendable {
  static let passphrase = "correct horse battery"
  /// One daemon shared by the cases that need no special configuration; stopped when the bundle ends.
  static let shared: SSHFixture = {
    do {
      let fixture = try SSHFixture()
      Observer.install(fixture)
      return fixture
    } catch { fatalError("Cannot start the test sshd: \(error)") }
  }()

  let root: URL
  /// `root` with symlinks resolved (/tmp is /private/tmp on macOS), for comparing remote paths.
  let resolvedRoot: String
  let home: URL
  let port: Int
  let hostPublicKey: String
  let authorizedKeys: URL
  let user = NSUserName()
  private let daemon: Process
  private let config: URL
  private let lock = NSLock()
  private var stopped = false

  private static let counter = Counter()
  /// SwiftPM links every test target into one bundle and process: each module's copy of this file
  /// keeps its own names.
  static let run = String(UInt32.random(in: 0..<0xFFFF), radix: 16)

  init(extraConfiguration: [String] = []) throws {
    root = URL(fileURLWithPath: "/tmp/st-\(getpid())-\(Self.run)-\(Self.counter.next())")
    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    // URL.resolvingSymlinksInPath keeps /tmp (Foundation strips /private); realpath(3) does not.
    resolvedRoot = realpath(root.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? root.path
    home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let hostKey = root.appendingPathComponent("host_ed25519")
    try Self.keygen(["-t", "ed25519", "-N", "", "-f", hostKey.path])
    hostPublicKey = try String(contentsOf: URL(fileURLWithPath: hostKey.path + ".pub"), encoding: .utf8)
      .split(separator: " ").prefix(2).joined(separator: " ")
    authorizedKeys = root.appendingPathComponent("authorized_keys")
    try TestKeys.shared.publicLines.joined(separator: "\n").appending("\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)
    port = try Self.availablePort()
    config = root.appendingPathComponent("sshd_config")
    try ([
      "ListenAddress 127.0.0.1",
      "Port \(port)",
      "HostKey \(hostKey.path)",
      "AuthorizedKeysFile \(authorizedKeys.path)",
      "PidFile \(root.path)/sshd.pid",
      "StrictModes no",
      "UsePAM no",
      "PasswordAuthentication no",
      "KbdInteractiveAuthentication yes",
      "PubkeyAuthentication yes",
      // A private HOME and helper test root: remote commands and the helper never touch the account's own.
      // tmux and herdr sockets under the root too (sshd sessions carry no $TMUX), so no remote command
      // can reach the user's own servers.
      "SetEnv HOME=\(home.path) DISPATCH_TEST_ROOT=\(root.path)/dt TMUX_TMPDIR=\(root.path) HERDR_SOCKET_PATH=\(root.path)/herdr.sock "
        + "XDG_CONFIG_HOME=\(home.path)/.config XDG_DATA_HOME=\(home.path)/.local/share XDG_STATE_HOME=\(home.path)/.local/state "
        + "PATH=/usr/bin:/bin:/usr/sbin:/sbin TZ=UTC",
      "LogLevel ERROR",
    ] + extraConfiguration).joined(separator: "\n").appending("\n").write(to: config, atomically: true, encoding: .utf8)
    daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    daemon.arguments = ["-D", "-e", "-f", config.path]
    daemon.standardInput = FileHandle.nullDevice
    daemon.standardOutput = FileHandle.nullDevice
    let log = root.appendingPathComponent("sshd.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    daemon.standardError = try FileHandle(forWritingTo: log)
    try daemon.run()
    let deadline = Date().addingTimeInterval(10)
    while !Self.accepting(port: port) {
      guard daemon.isRunning, Date() < deadline else {
        stop()
        throw NSError(domain: "SSHFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "sshd did not start: " + ((try? String(contentsOf: log, encoding: .utf8)) ?? "")])
      }
      usleep(20_000)
    }
  }

  deinit { stop() }

  /// Adds a public key line to authorized_keys (sshd rereads it on every attempt).
  func authorize(_ line: String) throws {
    let handle = try FileHandle(forWritingTo: authorizedKeys)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
  }

  /// Freezes the per-connection sshd processes (children of this fixture's own daemon, checked by parent
  /// pid and command line), so the server goes silent without closing anything: a dead network.
  func freezeSessions() -> [Int32] {
    let listener = daemon.processIdentifier
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-A", "-o", "pid=,ppid=,command="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    finish(ps)
    var frozen: [Int32] = []
    var parents: Set<Int32> = [listener]
    // Sessions and their privilege-separated children: walk down from our listener only.
    for _ in 0..<3 {
      for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), parents.contains(parent),
              pid != listener, !frozen.contains(pid), fields[2].contains("sshd") else { continue }
        frozen.append(pid)
        parents.insert(pid)
      }
    }
    for pid in frozen { kill(pid, SIGSTOP) }
    return frozen
  }

  func thaw(_ pids: [Int32]) {
    for pid in pids where Self.command(of: pid).contains("sshd") { kill(pid, SIGCONT) }
  }

  /// Stops only the daemon this fixture started, after checking that pid still runs our sshd.
  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    stopped = true
    if daemon.isRunning {
      let pid = daemon.processIdentifier
      // Our own unreaped child (Process holds it), still an sshd. Not the config path: sshd retitles
      // itself and the title truncates it.
      let command = Self.command(of: pid)
      if command.contains("sshd"), command.contains("/tmp/st-") {
        kill(pid, SIGTERM)
        // Not waitUntilExit: it spins the calling thread's run loop and can hang on a Swift
        // concurrency thread. isRunning follows Process's own termination monitoring.
        let deadline = Date().addingTimeInterval(5)
        while daemon.isRunning, Date() < deadline { usleep(10_000) }
        if daemon.isRunning, Self.command(of: pid).contains("sshd") { kill(pid, SIGKILL) }
      }
    }
    try? FileManager.default.removeItem(at: root)
  }

  static func command(of pid: Int32) -> String {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-ww", "-o", "command=", "-p", String(pid)]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    finish(ps)
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }

  static func keygen(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-q"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    finish(process)
    guard process.terminationStatus == 0 else { throw NSError(domain: "ssh-keygen", code: Int(process.terminationStatus)) }
  }

  private static func availablePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return try withUnsafeMutablePointer(to: &address) { pointer in
      try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bind(fd, raw, length) == 0, getsockname(fd, raw, &length) == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: pointer.pointee.sin_port))
      }
    }
  }

  private static func accepting(port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
  }

  /// Stops the shared daemon when the test bundle finishes.
  private final class Observer: NSObject, XCTestObservation, @unchecked Sendable {
    let fixture: SSHFixture
    init(_ fixture: SSHFixture) { self.fixture = fixture }
    func testBundleDidFinish(_ testBundle: Bundle) {
      fixture.stop()
      try? FileManager.default.removeItem(at: TestKeys.shared.directory)
    }
    static func install(_ fixture: SSHFixture) {
      let observer = Observer(fixture)
      if Thread.isMainThread {
        MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(observer) }
      } else {
        DispatchQueue.main.sync { MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(observer) } }
      }
    }
  }
}

/// User keys generated once per run with ssh-keygen: one of each type, plain and passphrase-encrypted.
final class TestKeys: @unchecked Sendable {
  static let shared: TestKeys = {
    do { return try TestKeys() } catch { fatalError("Cannot generate test keys: \(error)") }
  }()

  let directory: URL
  /// name (`ed25519`, `ed25519-encrypted`, …) → private key file.
  let files: [String: URL]
  let publicLines: [String]

  private init() throws {
    directory = URL(fileURLWithPath: "/tmp/sk-\(getpid())-\(SSHFixture.run)")
    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var files: [String: URL] = [:]
    var lines: [String] = []
    for (type, bits, base) in [("ed25519", nil, "ed25519"), ("ecdsa", "256", "ecdsa"), ("ecdsa", "384", "ecdsa384"),
                               ("ecdsa", "521", "ecdsa521"), ("rsa", "3072", "rsa")] as [(String, String?, String)] {
      for encrypted in [false, true] {
        let name = base + (encrypted ? "-encrypted" : "")
        let file = directory.appendingPathComponent(name)
        try SSHFixture.keygen(["-t", type] + (bits.map { ["-b", $0] } ?? []) + ["-N", encrypted ? SSHFixture.passphrase : "", "-C", name, "-f", file.path])
        files[name] = file
        lines.append(try String(contentsOf: URL(fileURLWithPath: file.path + ".pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    self.files = files
    publicLines = lines
  }

  func data(_ name: String) throws -> Data { try Data(contentsOf: files[name]!) }

  /// `ssh-keygen -lf` of a key file's public half.
  func fingerprint(_ name: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-lf", files[name]!.path + ".pub"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    finish(process)
    return String(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")[1])
  }
}

/// Waits for a child without `waitUntilExit`, which runs the calling thread's run loop and can hang
/// when called from a Swift concurrency thread.
func finish(_ process: Process) {
  while process.isRunning { usleep(5_000) }
}
#endif
