#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import SSHEngine

/// A private loopback `/usr/sbin/sshd` for the interoperability tests (after `MobileTransportTests/SSHFixture.swift`,
/// copied rather than shared, since test targets do not import each other): host keys of every type sshd serves
/// (ed25519, ecdsa P-256/384/521, rsa 3072) generated at test time, every algorithm the engine implements enabled.
/// The one way in is the test's own Ed25519 user key (made with CryptoKit per run, in `authorized_keys`), and the one
/// command `/bin/cat` (`ForceCommand`), under a private HOME, so a session echoes what it is sent and touches nothing
/// of the account. Runs as the current user under a temporary root (`/tmp/se-<pid>-<n>`), which `stop` removes along
/// with the one sshd process it started (checked by pid and command line; nothing else is ever signalled).
final class LiveSSHD: @unchecked Sendable {
  let root: URL
  let port: Int
  /// The host key blobs by key type name (`ssh-ed25519`, `ecdsa-sha2-nistp256`, ..., `ssh-rsa`).
  let hostKeyBlobs: [String: [UInt8]]
  let version: String
  /// The `authorized_keys` file.
  let authorizedKeys: URL
  private let daemon: Process
  private let lock = NSLock()
  private var stopped = false
  private static let counter = Counter()

  /// How the daemon is set up.
  struct Options {
    /// OpenSSH public key lines for `authorized_keys` (`authorize` adds more later; sshd rereads it per attempt).
    var authorizedKeys: [String]
    /// sshd's `RekeyLimit` (it starts re-exchanges after authentication).
    var rekeyLimit = "default none"
    var logLevel = "ERROR"
    /// `/bin/cat` for every session (`ForceCommand`), or real commands: a wrapper runs the requested command with
    /// `/bin/sh -c` and a shell request as `/bin/sh -i`, under the private HOME, with PTYs allowed.
    var commands = Commands.cat
    /// sshd's `MaxSessions` (channels per connection).
    var maxSessions = 10
    /// More `sshd_config` lines.
    var extra: [String] = []

    enum Commands { case cat, shell }
  }

  /// `authorizedKey`: an OpenSSH public key line. `rekeyLimit`: sshd's `RekeyLimit` (it starts re-exchanges after
  /// authentication).
  convenience init(authorizedKey: String, rekeyLimit: String = "default none", logLevel: String = "ERROR") throws {
    try self.init(Options(authorizedKeys: [authorizedKey], rekeyLimit: rekeyLimit, logLevel: logLevel))
  }

  init(_ options: Options) throws {
    let rekeyLimit = options.rekeyLimit
    let logLevel = options.logLevel
    guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else { throw Failure("no /usr/sbin/sshd") }
    root = URL(fileURLWithPath: "/tmp/se-\(getpid())-\(Self.counter.next())")
    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var blobs: [String: [UInt8]] = [:]
    var hostKeyLines: [String] = []
    do {
      for (type, bits, name) in [("ed25519", nil, "ed25519"), ("ecdsa", "256", "ecdsa256"), ("ecdsa", "384", "ecdsa384"),
                                 ("ecdsa", "521", "ecdsa521"), ("rsa", "3072", "rsa")] as [(String, String?, String)] {
        let file = root.appendingPathComponent("host_" + name)
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", type] + (bits.map { ["-b", $0] } ?? []) + ["-N", "", "-C", "", "-f", file.path])
        let line = try String(contentsOf: URL(fileURLWithPath: file.path + ".pub"), encoding: .utf8)
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { throw Failure("unreadable \(name).pub") }
        blobs[String(fields[0])] = Array(blob)
        hostKeyLines.append("HostKey \(file.path)")
      }
      hostKeyBlobs = blobs
      port = try Self.availablePort()
      let home = root.appendingPathComponent("home")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let authorized = root.appendingPathComponent("authorized_keys")
      authorizedKeys = authorized
      try (options.authorizedKeys.map { $0 + "\n" }.joined()).write(to: authorized, atomically: true, encoding: .utf8)
      var commandLines = ["ForceCommand /bin/cat", "PermitTTY no"]
      if options.commands == .shell {
        let wrapper = root.appendingPathComponent("run")
        try """
          #!/bin/sh
          if [ -z "$SSH_ORIGINAL_COMMAND" ]; then exec /bin/sh -i; fi
          exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"

          """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        commandLines = ["ForceCommand \(wrapper.path)", "PermitTTY yes"]
      }
      let config = root.appendingPathComponent("sshd_config")
      try ([
        "ListenAddress 127.0.0.1",
        "Port \(port)",
      ] + hostKeyLines + [
        "PidFile \(root.path)/sshd.pid",
        "StrictModes no",
        "UsePAM no",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "PubkeyAuthentication yes",
        "AuthorizedKeysFile \(authorized.path)",
      ] + commandLines + [
        "PermitUserRC no",
        "DisableForwarding yes",
        "MaxSessions \(options.maxSessions)",
        "SetEnv HOME=\(home.path) PATH=/usr/bin:/bin TZ=UTC",
        "RekeyLimit \(rekeyLimit)",
        // Every connection here ends unauthenticated: without this, sshd's penalties would soon refuse the address.
        "PerSourcePenalties no",
        "MaxStartups 100",
        "KexAlgorithms " + KeyExchangeAlgorithm.allCases.map(\.rawValue).joined(separator: ","),
        "HostKeyAlgorithms " + SignatureAlgorithm.allCases.map(\.rawValue).joined(separator: ","),
        "Ciphers " + CipherAlgorithm.allCases.map(\.rawValue).joined(separator: ","),
        "MACs " + MACAlgorithm.allCases.map(\.rawValue).joined(separator: ","),
        "LogLevel \(logLevel)",
      ] + options.extra).joined(separator: "\n").appending("\n").write(to: config, atomically: true, encoding: .utf8)
      version = (try? Self.output("/usr/sbin/sshd", ["-V"])) ?? "sshd"
      daemon = Process()
      daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
      daemon.arguments = ["-D", "-e", "-f", config.path]
      daemon.standardInput = FileHandle.nullDevice
      daemon.standardOutput = FileHandle.nullDevice
      let log = root.appendingPathComponent("sshd.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      daemon.standardError = try FileHandle(forWritingTo: log)
      try daemon.run()
    } catch {
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    let deadline = Date().addingTimeInterval(10)
    while !Self.accepting(port: port) {
      guard daemon.isRunning, Date() < deadline else {
        let log = self.log
        stop()
        throw Failure("sshd did not start: \(log)")
      }
      usleep(20_000)
    }
  }

  deinit { stop() }

  var log: String { (try? String(contentsOf: root.appendingPathComponent("sshd.log"), encoding: .utf8)) ?? "" }

  /// Adds a public key line to `authorized_keys`.
  func authorize(_ line: String) throws {
    let handle = try FileHandle(forWritingTo: authorizedKeys)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
  }

  /// How often `text` appears in sshd's log.
  func count(_ text: String) -> Int { log.components(separatedBy: text).count - 1 }

  /// Waits (on the log file's write events, not by polling) until `text` appears at least `count` times; false when
  /// it did not within `timeout`.
  func waitForLog(_ text: String, count: Int, timeout: TimeInterval = 10) async -> Bool {
    if self.count(text) >= count { return true }
    let path = root.appendingPathComponent("sshd.log").path
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return false }
    let queue = DispatchQueue(label: "LiveSSHD.log")
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
    let done = LogWait()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      done.install(continuation, source: source)
      source.setEventHandler { if self.count(text) >= count { done.finish(true) } }
      source.setCancelHandler { Darwin.close(fd) }
      source.resume()
      queue.async { if self.count(text) >= count { done.finish(true) } }
      queue.asyncAfter(deadline: .now() + timeout) { done.finish(false) }
    }
  }

  private final class LogWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var source: (any DispatchSourceFileSystemObject)?

    func install(_ continuation: CheckedContinuation<Bool, Never>, source: any DispatchSourceFileSystemObject) {
      lock.withLock {
        self.continuation = continuation
        self.source = source
      }
    }

    func finish(_ value: Bool) {
      let (continuation, source) = lock.withLock { () -> (CheckedContinuation<Bool, Never>?, (any DispatchSourceFileSystemObject)?) in
        defer {
          self.continuation = nil
          self.source = nil
        }
        return (self.continuation, self.source)
      }
      source?.cancel()
      continuation?.resume(returning: value)
    }
  }

  /// Stops the daemon this fixture started (only after checking the pid still runs an sshd from our root) and
  /// removes the root.
  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    stopped = true
    if daemon.isRunning {
      let pid = daemon.processIdentifier
      let command = Self.command(of: pid)
      if command.contains("sshd"), command.contains("/tmp/se-") {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while daemon.isRunning, Date() < deadline { usleep(10_000) }
        if daemon.isRunning, Self.command(of: pid).contains("sshd") { kill(pid, SIGKILL) }
      }
    }
    try? FileManager.default.removeItem(at: root)
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  // MARK: Processes and sockets

  private static func run(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    while process.isRunning { usleep(5_000) }
    guard process.terminationStatus == 0 else { throw Failure("\(path) failed: \(process.terminationStatus)") }
  }

  private static func output(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    while process.isRunning { usleep(5_000) }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func command(of pid: Int32) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ww", "-o", "command=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    while process.isRunning { usleep(5_000) }
    return String(decoding: data, as: UTF8.self)
  }

  private static func loopback(port: Int = 0) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    return address
  }

  private static func availablePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure("socket") }
    defer { Darwin.close(fd) }
    var address = loopback()
    return try withUnsafeMutablePointer(to: &address) { pointer in
      try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard bind(fd, raw, length) == 0, getsockname(fd, raw, &length) == 0 else { throw Failure("bind") }
        return Int(UInt16(bigEndian: pointer.pointee.sin_port))
      }
    }
  }

  private static func accepting(port: Int) -> Bool {
    guard let fd = try? connect(port: port) else { return false }
    Darwin.close(fd)
    return true
  }

  /// A connected loopback TCP socket (blocking, no SIGPIPE).
  static func connect(port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure("socket") }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = loopback(port: port)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    guard connected else {
      Darwin.close(fd)
      throw Failure("connect")
    }
    return fd
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
  }
}

/// A test-only blocking driver: one `ClientTransport` over one loopback TCP socket, doing what the real async
/// driver (`ConnectionDriver`) does (write `takeOutbound`, read into `receive`, drain `poll`), with a deadline per call.
final class SocketDriver {
  let core: ClientTransport
  private let fd: Int32
  var service = MessagePolicy.ServicePhase.serviceNotRequested
  /// The host key question's answer; the key is recorded.
  var trust: (HostKey) -> Bool = { _ in true }
  private(set) var events: [TransportEvent] = []
  private var closed = false

  init(port: Int, core: ClientTransport) throws {
    fd = try LiveSSHD.connect(port: port)
    self.core = core
  }

  deinit { close() }

  func close() {
    guard !closed else { return }
    closed = true
    Darwin.close(fd)
  }

  /// Sets the upper layers' phase and lets the core see it at once (one drain of `poll`, events recorded).
  func enter(_ phase: MessagePolicy.ServicePhase) throws {
    service = phase
    while let event = core.poll(service: service) {
      events.append(event)
      try flush()
    }
    try flush()
  }

  /// Writes everything the core queued.
  func flush() throws {
    var bytes = core.takeOutbound()
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { raw in
        Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
      }
      guard written > 0 else { throw LiveSSHD.Failure("write: \(errno)") }
      offset += written
    }
    bytes = []
  }

  /// Runs until an event satisfies `until` (returned), the connection ends (returned, as the last event) or the
  /// deadline passes (thrown).
  @discardableResult
  func run(timeout: TimeInterval = 10, until: (TransportEvent) -> Bool) throws -> TransportEvent {
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      try flush()
      while let event = core.poll(service: service) {
        events.append(event)
        if case .hostKeyNeedsTrust(let key) = event { core.answerHostKey(trusted: trust(key)) }
        try flush()
        if until(event) { return event }
        if case .ended = event { return event }
      }
      try flush()
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw LiveSSHD.Failure("timed out; events: \(events)") }
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining, 10) * 1000))
      guard ready >= 0 else { throw LiveSSHD.Failure("poll: \(errno)") }
      guard ready > 0 else { continue }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
      if count > 0 {
        core.receive(Array(buffer[0..<count]))
      } else if count == 0 {
        core.receiveEnd()
      } else if errno != EINTR {
        core.receiveEnd()
      }
    }
  }

  /// Runs until the next message for the layers above.
  func nextMessage(timeout: TimeInterval = 10) throws -> InboundMessage {
    let event = try run(timeout: timeout) { if case .message = $0 { true } else { false } }
    guard case .message(let message) = event else { throw LiveSSHD.Failure("no message: \(event)") }
    return message
  }
}
#endif
