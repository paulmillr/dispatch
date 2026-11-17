#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import MobileTransport
import XCTest

/// Descriptors and memory over many connections on the Swift engine, through the public API against the fixture sshd:
/// connect, log in, exec, close, repeated; and connections cut (through `CutRelay`, a reset) while the client waits for
/// the host key's trust, while it signs its login, and with an exec and a shell open. Every loop must end with no
/// descriptor it did not start with (by what it refers to: earlier tests may still close theirs meanwhile) and no
/// steady heap growth: the median heap of the loop's last quarter against that of
/// its second quarter (after the warm-up), and in the long mode the heap 65 s after the loop against its start.
/// `DISPATCH_SSH_LOOPS` sets the cycles per loop and the long mode (default 40 and short; the quality pass ran 500),
/// `DISPATCH_SSH_LEAKS=1` also runs `leaks` on this process at the end of each loop; `DISPATCH_SSH_HEAPDIFF=1`,
/// `DISPATCH_SSH_SETTLE=<s>` and `DISPATCH_SSH_TASKDUMP=1` print what grew (`heap`, `swift-inspect`; with
/// `MallocStackLogging=1`, where the tasks still alive were made).
final class ResourceLoopTests: XCTestCase {
  static let cycles = Int(ProcessInfo.processInfo.environment["DISPATCH_SSH_LOOPS"] ?? "") ?? 40
  /// `DISPATCH_SSH_LOOPS` set: the long mode, which also waits out what closed connections free later.
  static let long = ProcessInfo.processInfo.environment["DISPATCH_SSH_LOOPS"] != nil

  /// A cut loop's own sshd, which the test stops: OpenSSH's per-source penalties would refuse a source whose
  /// connections end before the login (what these loops do on purpose). Not a shared static: nothing stops a static
  /// fixture when the test process exits, and its sshd would outlive it.
  static func lenientFixture() throws -> SSHFixture {
    try SSHFixture(extraConfiguration: ["PerSourcePenalties no", "MaxStartups 100"])
  }

  /// One loopback port for every cut loop's relay (a new endpoint per cycle would also grow Network.framework's
  /// per-endpoint state, which no app does).
  static let relayPort: UInt16 = {
    let probe = try? CutRelay(to: 1, port: 0)
    defer { probe?.stop() }
    return UInt16(probe?.port ?? 0)
  }()

  private var saved: SSHTransportEngine = .standard
  override func setUp() {
    saved = SSHTransportEngine.preferred
    // DISPATCH_SSH_LOOP_ENGINE=russh runs the same loops on russh, for comparison (a `DISPATCH_RUSSH` build).
    SSHTransportEngine.preferred = ProcessInfo.processInfo.environment["DISPATCH_SSH_LOOP_ENGINE"]
      .flatMap(SSHTransportEngine.init(rawValue:)) ?? .swift
  }
  override func tearDown() { SSHTransportEngine.preferred = saved }

  func testConnectLoginExecClose() async throws {
    let fixture = SSHFixture.shared
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let body = ProcessInfo.processInfo.environment["DISPATCH_SSH_LOOP_BODY"] ?? "exec"
    try await loop("connect, login, exec, close") { _ in
      let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
      if body == "exec" {
        let result = try await connection.run("echo fictional")
        XCTAssertEqual(result.text, "fictional\n")
      }
      await connection.close()
    }
  }

  func testCutDuringTheHandshake() async throws {
    let fixture = try Self.lenientFixture()
    defer { fixture.stop() }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    try await loop("cut while the host key waits for trust") { _ in
      let relay = try CutRelay(to: fixture.port, port: Self.relayPort)
      defer { relay.stop() }
      let trust = CuttingTrust(expected: fixture.hostPublicKey, relay: relay)
      let endpoint = SSHEndpoint(host: "127.0.0.1", port: relay.port, username: fixture.user)
      do {
        let connection = try await SSHConnection.connect(to: endpoint, credentials: [.key(key)], trust: trust)
        XCTFail("connected through a cut relay")
        await connection.close()
      } catch {}
    }
  }

  func testCutDuringTheLogin() async throws {
    let fixture = try Self.lenientFixture()
    defer { fixture.stop() }
    let signing = Curve25519.Signing.PrivateKey()
    let blob = publicKeyBlob(SSHKey(ed25519: signing))
    try fixture.authorize("ssh-ed25519 " + blob.base64EncodedString())
    try await loop("cut while the login's signature is made") { _ in
      let relay = try CutRelay(to: fixture.port, port: Self.relayPort)
      defer { relay.stop() }
      let key = SSHKey(kind: .ed25519, publicKeyBlob: blob, hardwareBacked: false) { data in
        relay.cut()
        return try signing.signature(for: data)
      }
      let endpoint = SSHEndpoint(host: "127.0.0.1", port: relay.port, username: fixture.user)
      do {
        let connection = try await SSHConnection.connect(to: endpoint, credentials: [.key(key)], trust: fixture.trust)
        XCTFail("logged in through a cut relay")
        await connection.close()
      } catch {}
    }
  }

  func testCutWithChannelsOpen() async throws {
    let fixture = try Self.lenientFixture()
    defer { fixture.stop() }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    try await loop("cut with an exec and a shell open") { _ in
      let relay = try CutRelay(to: fixture.port, port: Self.relayPort)
      defer { relay.stop() }
      let endpoint = SSHEndpoint(host: "127.0.0.1", port: relay.port, username: fixture.user)
      let connection = try await SSHConnection.connect(to: endpoint, credentials: [.key(key)], trust: fixture.trust)
      let exec = try await connection.exec("cat")
      try await exec.write(Data("fictional\n".utf8))
      var iterator = exec.makeAsyncIterator()
      _ = try await iterator.next()
      let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
      relay.cut()
      do { while try await iterator.next() != nil {} } catch {}
      do { for try await _ in shell {} } catch {}
      _ = try? await shell.exitStatus()
      await connection.closed()
      await connection.close()
    }
  }

  // MARK: The loop

  private func loop(_ name: String, _ body: (Int) async throws -> Void) async throws {
    // Warm-up: the first connection creates what lives as long as the process (queues, caches, the fixture's keys).
    try await body(-1)
    try await body(-1)
    let descriptors = Self.openDescriptors()
    let baseline = heapBytes()
    var heap: [Int] = []
    let start = ContinuousClock.now
    let diffing = ProcessInfo.processInfo.environment["DISPATCH_SSH_HEAPDIFF"] == "1"
    var early: [String: Int] = [:]
    for index in 0..<Self.cycles {
      try await body(index)
      heap.append(heapBytes())
      if diffing, index == Self.cycles / 4 { early = Self.heapCounts() }
    }
    if diffing {
      if let settle = ProcessInfo.processInfo.environment["DISPATCH_SSH_SETTLE"].flatMap(Double.init) {
        try await Task.sleep(for: .seconds(settle))
        report(String(format: "heap after %.0f s more: %.1f MB", settle, Double(heapBytes()) / 1e6))
      }
      let late = Self.heapCounts()
      let grown = late.map { ($0.key, $0.value - (early[$0.key] ?? 0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
      if ProcessInfo.processInfo.environment["DISPATCH_SSH_TASKDUMP"] == "1" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift-inspect")
        process.arguments = ["dump-concurrency", "\(getpid())"]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("taskdump-\(getpid()).txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        report("task dump: " + file.path)
        // With MallocStackLogging=1: where a few of the dumped tasks were created.
        if ProcessInfo.processInfo.environment["MallocStackLogging"] != nil {
          let dump = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
          let addresses = dump.split(separator: "\n").filter { $0.contains("flags=future enqueuePriority=0x0") }
            .compactMap { $0.split(separator: " ").first { $0.hasPrefix("address=") }?.dropFirst(8) }
          for address in addresses.suffix(4) {
            let history = Process()
            history.executableURL = URL(fileURLWithPath: "/usr/bin/malloc_history")
            history.arguments = ["\(getpid())", String(address)]
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(address).txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            history.standardOutput = try FileHandle(forWritingTo: out)
            history.standardError = history.standardOutput
            try history.run()
            history.waitUntilExit()
            report("history: " + out.path)
          }
        }
      }
      for (name, count) in grown where count >= 40 { report("heap growth \(name): +\(count)") }
    }
    let elapsed = seconds(ContinuousClock.now - start)
    // Descriptors are closed by tasks and dispatch sources that may finish just after the call returned. Only new ones
    // count: an earlier test's connections, closed on tasks of their own, may still go while this one runs.
    var now = Self.openDescriptors()
    for _ in 0..<50 where !now.subtracting(descriptors).isEmpty {
      try await Task.sleep(for: .milliseconds(100))
      now = Self.openDescriptors()
    }
    let added = now.subtracting(descriptors)
    XCTAssertEqual(added.count, 0, "\(name): \(added.count) descriptors more after \(Self.cycles) cycles")
    let quarter = max(1, heap.count / 4)
    let second = Self.median(Array(heap[quarter..<min(heap.count, 2 * quarter)]))
    let last = Self.median(Array(heap[(heap.count - quarter)...]))
    let growth = last - second
    let perCycle = Double(growth) / Double(max(1, heap.count - 2 * quarter))
    report(String(format: "loop %@: %d cycles in %.1f s, descriptors %d -> %d (%d new), heap median %.1f -> %.1f MB (%+.0f bytes per cycle)",
                  name, Self.cycles, elapsed, descriptors.count, now.count, added.count, Double(second) / 1e6, Double(last) / 1e6, perCycle))
    // A leak of a connection's state (tens of KB at least) per cycle would be far above this.
    if Self.long {
      // What a closed connection leaves behind for a while and then frees: the runtime's wake-up jobs of its cancelled
      // timers (the handshake deadline and keepalive, 15 s; a re-exchange timer's slice, at most 60 s). Past them, the
      // heap must be back near where it started.
      try await Task.sleep(for: .seconds(65))
      let settled = heapBytes()
      let left = Double(settled - baseline) / Double(Self.cycles)
      report(String(format: "loop %@: after 65 s, heap %.2f MB against %.2f MB before the cycles (%+.0f bytes per cycle)",
                    name, Double(settled) / 1e6, Double(baseline) / 1e6, left))
      XCTAssertLessThan(left, 256, "\(name): \(Int(left)) bytes per cycle stay")
    } else {
      // Short loops see what closed connections free only later (above): only a connection's state kept for good
      // (tens of KB) fails here.
      XCTAssertLessThan(perCycle, 16 * 1024, "\(name): the heap grows by \(Int(perCycle)) bytes per cycle")
    }
    if ProcessInfo.processInfo.environment["DISPATCH_SSH_LEAKS"] == "1" { report("loop \(name): " + Self.leaks()) }
  }

  /// The open descriptors, each as what it refers to (`fstat`'s device and inode, unique per socket, pipe and file),
  /// so a number another test's close freed and this loop's leak reused still counts as new.
  static func openDescriptors() -> Set<[UInt64]> {
    var open = Set<[UInt64]>()
    for fd in 0..<Int32(getdtablesize()) where fcntl(fd, F_GETFD) != -1 {
      var status = stat()
      guard fstat(fd, &status) == 0 else { continue }
      open.insert([UInt64(fd), UInt64(bitPattern: Int64(status.st_dev)), status.st_ino])
    }
    return open
  }

  static func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }

  /// `heap` on this process: live allocations per class or size class (`COUNT BYTES AVG CLASS TYPE BINARY` lines).
  static func heapCounts() -> [String: Int] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
    process.arguments = ["\(getpid())"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [:] }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    var counts: [String: Int] = [:]
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count >= 4, let count = Int(fields[0]), Int(fields[1]) != nil else { continue }
      counts[fields[3...].joined(separator: " "), default: 0] += count
    }
    return counts
  }

  /// `leaks` on this process: its summary line.
  static func leaks() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
    process.arguments = ["\(getpid())"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return "leaks did not run: \(error)" }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let summary = output.split(separator: "\n").first { $0.contains("leaks for") }.map(String.init)
    return summary ?? "leaks: " + String(output.suffix(400))
  }
}

/// Trusts the fixture's key after cutting the relay: the connection is gone while the client waits for the answer.
struct CuttingTrust: HostKeyTrust {
  let expected: String
  let relay: CutRelay
  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
    relay.cut()
    return key.openSSH == expected ? .trust : .mismatch(expected: expected)
  }
}

/// A loopback TCP relay to the fixture's port that resets every relayed connection on `cut`. One thread accepts;
/// each connection has one thread per direction. `stop` closes everything it opened.
final class CutRelay: @unchecked Sendable {
  let port: Int
  private let listener: Int32
  /// Written at `stop`: wakes the accepting thread.
  private let wake: (read: Int32, write: Int32)
  private let lock = NSLock()
  private var sockets: [Int32] = []
  private var cutDone = false
  private var stopped = false
  private let threads = DispatchGroup()

  /// `port` 0: any free one.
  init(to target: Int, port wanted: UInt16) throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var reuse: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = loopback(port: Int(wanted))
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } }
    guard bound == 0, listen(listener, 16) == 0 else {
      close(listener)
      throw NSError(domain: "CutRelay", code: 1)
    }
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
    port = Int(UInt16(bigEndian: address.sin_port))
    self.listener = listener
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else {
      close(listener)
      throw NSError(domain: "CutRelay", code: 2)
    }
    wake = (fds[0], fds[1])
    let wakeRead = wake.read
    threads.enter()
    Thread { [self] in
      defer { threads.leave() }
      while true {
        var polled = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        guard poll(&polled, 2, -1) >= 0 else { continue }
        if polled[1].revents != 0 { return }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        let server = Self.connect(target)
        let keep = lock.withLock { () -> Bool in
          guard !stopped, !cutDone, server >= 0 else { return false }
          sockets += [client, server]
          return true
        }
        guard keep else {
          close(client)
          if server >= 0 { close(server) }
          continue
        }
        for (from, to) in [(client, server), (server, client)] {
          threads.enter()
          Thread { [self] in
            defer { threads.leave() }
            Self.pump(from, to)
          }.start()
        }
      }
    }.start()
  }

  private static func connect(_ port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = loopback(port: port)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if result != 0 {
      close(fd)
      return -1
    }
    return fd
  }

  private static func pump(_ from: Int32, _ to: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let got = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
      guard got > 0 else { break }
      var offset = 0
      while offset < got {
        let wrote = buffer.withUnsafeBytes { write(to, $0.baseAddress! + offset, got - offset) }
        guard wrote > 0 else { return }
        offset += wrote
      }
    }
    shutdown(to, SHUT_WR)
  }

  /// Resets every relayed connection (both ends see it go) and refuses new ones.
  func cut() {
    let open = lock.withLock { () -> [Int32] in
      cutDone = true
      return sockets
    }
    var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
    for fd in open {
      setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
      shutdown(fd, SHUT_RDWR)
    }
  }

  /// Ends every thread and closes every socket.
  func stop() {
    cut()
    let open = lock.withLock { () -> [Int32] in
      stopped = true
      defer { sockets = [] }
      return sockets
    }
    var byte: UInt8 = 1
    _ = write(wake.write, &byte, 1)
    threads.wait()
    close(listener)
    close(wake.read)
    close(wake.write)
    for fd in open { close(fd) }
  }
}
#endif
