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

/// Records a measurement line for docs/ios-ssh-spike.md (printed; `swift test` output is the source).
func report(_ line: String) {
  print("MEASURE " + line)
}

/// Bytes allocated in all malloc zones (more precise than resident size for small deltas).
func heapBytes() -> Int {
  var stats = malloc_statistics_t()
  malloc_zone_statistics(nil, &stats)
  return Int(stats.size_in_use)
}
