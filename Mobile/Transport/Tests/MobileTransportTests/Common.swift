import Foundation
import MobileTransport

func seconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Peak resident set size of this process (getrusage ru_maxrss, bytes on Darwin).
func peakResidentBytes() -> Int {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Int(usage.ru_maxrss)
}

/// Current resident size (task_info), for before/after deltas.
func residentBytes() -> Int {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let status = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
  }
  return status == KERN_SUCCESS ? Int(info.resident_size) : 0
}

/// Records a measurement line (printed as `MEASURE`; `swift test` output is the source).
func report(_ line: String) {
  print("MEASURE " + line)
}

/// Bytes allocated in all malloc zones (more precise than resident size for small deltas). Under the address
/// sanitizer, its allocator's own count of live bytes: the zone statistics it reports there are not live bytes (they
/// grow with every allocation made, freed or not).
func heapBytes() -> Int {
  if let live = sanitizerLiveBytes { return live() }
  var stats = malloc_statistics_t()
  malloc_zone_statistics(nil, &stats)
  return Int(stats.size_in_use)
}

/// `__sanitizer_get_current_allocated_bytes` when the address sanitizer's runtime is loaded.
private let sanitizerLiveBytes: (@Sendable () -> Int)? = {
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__sanitizer_get_current_allocated_bytes") else { return nil }
  typealias Function = @convention(c) () -> Int
  let function = unsafeBitCast(symbol, to: Function.self)
  return { function() }
}()

/// 127.0.0.1:`port`.
func loopback(port: Int) -> sockaddr_in {
  sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
              sin_port: UInt16(port).bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
              sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
}

/// A loopback port nothing listens on: one the system picked, bound by a socket that never listened and is closed.
func closedLoopbackPort() throws -> Int {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EIO) }
  defer { Darwin.close(fd) }
  var address = loopback(port: 0), length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let bound = withUnsafeMutablePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
    }
  }
  guard bound else { throw POSIXError(.EIO) }
  return Int(UInt16(bigEndian: address.sin_port))
}

/// The wire blob of `key`'s public half (its public line's base64).
func publicKeyBlob(_ key: SSHKey) -> Data { Data(base64Encoded: String(key.publicKey.split(separator: " ")[1]))! }

/// Polls `condition` every 2 ms until it holds; throws `timedOut` after `timeout`.
func until(timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else { throw SSHTransportError.timedOut("condition") }
    try await Task.sleep(for: .milliseconds(2))
  }
}
