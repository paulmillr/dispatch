import SSHEngine

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzKeyBlobs(_ data: UnsafePointer<UInt8>?, _ size: Int) -> Int32 {
  guard let data else { return 0 }
  SSHEngineFuzzing.keyBlobs(Array(UnsafeBufferPointer(start: data, count: size)))
  return 0
}
