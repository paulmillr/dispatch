import Accelerate
import Foundation

// Weight decoding: the file's f32, f16 and q8_0 bytes to Float32. The CPU backend dequantizes whole tensors once at
// load; Metal keeps the storage type and uses these only for small or odd tensors. Tensor data sits at arbitrary
// byte offsets in the mapped file (the format has no alignment), so nothing here binds the bytes to a wider type
// in place: f32 and f16 are copied into aligned arrays first, and q8_0 scales are read with unaligned loads.

extension WeightDecoding {
  /// The tensor as Float32, row-major in `tensor.shape`.
  public static func floats(of tensor: WeightTensor) -> [Float] {
    let count = tensor.elementCount
    switch tensor.type {
    case .f32: return floats(tensor.data, count: count)
    case .f16: return halfToFloat(tensor.data, count: count)
    case .q8_0: return dequantizeQ8_0(tensor.data, count: count)
    }
  }

  /// `count` little-endian float32 values from the start of `data`.
  ///
  /// The preconditions here guard programming errors: a tensor from `WhisperModelFile.parse` has passed `validate`,
  /// which ties `data.count` to the shape, so a file cannot reach them. They compare without multiplying `count`
  /// (`data.count / width`), so an absurd count fails the check instead of overflowing.
  public static func floats(_ data: Data, count: Int) -> [Float] {
    precondition(count >= 0 && data.count / 4 >= count, "f32 data holds \(data.count) bytes, \(count) values need more")
    return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
      data.copyBytes(to: buffer, count: count * 4)
      initialized = count
    }
  }

  /// `count` IEEE half-precision values (little-endian) from the start of `data`, as Float32. The conversion is
  /// vImage's planar 16F to F, which is exact (every half is representable) and vectorized.
  public static func halfToFloat(_ data: Data, count: Int) -> [Float] {
    precondition(count >= 0 && data.count / 2 >= count, "f16 data holds \(data.count) bytes, \(count) values need more")
    guard count > 0 else { return [] }
    // Stage the halves in an aligned buffer: the file offset can be odd.
    let halves = [UInt16](unsafeUninitializedCapacity: count) { buffer, initialized in
      data.copyBytes(to: buffer, count: count * 2)
      initialized = count
    }
    return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
      halves.withUnsafeBufferPointer { source in
        convertHalves(source, to: buffer)
      }
      initialized = count
    }
  }

  /// `count` values of ggml's q8_0 blocks from the start of `data`: per 32 values a half-precision scale `d` then 32
  /// signed bytes `qs`, value = d * qs[i] (`dequantize_row_q8_0`). `count` must be a multiple of 32.
  public static func dequantizeQ8_0(_ data: Data, count: Int) -> [Float] {
    precondition(count >= 0 && count % 32 == 0, "q8_0 decodes whole blocks of 32, not \(count) values")
    let blocks = count / 32
    precondition(data.count / 34 >= blocks, "q8_0 data holds \(data.count) bytes, \(blocks) blocks need more")
    guard blocks > 0 else { return [] }
    // Convert all the scales in one vImage call, then expand each block. Reading the scale per block with an
    // unaligned load keeps the staging buffer at one half per 34 bytes instead of a copy of the whole tensor.
    let scales = [Float](unsafeUninitializedCapacity: blocks) { floats, initialized in
      let halves = [UInt16](unsafeUninitializedCapacity: blocks) { halves, initializedHalves in
        data.withUnsafeBytes { raw in
          for block in 0..<blocks {
            halves[block] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: block * 34, as: UInt16.self))
          }
        }
        initializedHalves = blocks
      }
      halves.withUnsafeBufferPointer { convertHalves($0, to: floats) }
      initialized = blocks
    }
    return [Float](unsafeUninitializedCapacity: count) { output, initialized in
      data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: Int8.self)
        for block in 0..<blocks {
          let scale = scales[block]
          let source = block * 34 + 2
          let target = block * 32
          for i in 0..<32 {
            output[target + i] = scale * Float(bytes[source + i])
          }
        }
      }
      initialized = count
    }
  }

  /// vImage planar half to float over two equal-length buffers (both must be aligned, which fresh arrays are).
  private static func convertHalves(_ source: UnsafeBufferPointer<UInt16>, to target: UnsafeMutableBufferPointer<Float>) {
    let count = source.count
    guard count > 0 else { return }
    var input = vImage_Buffer(
      data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1, width: vImagePixelCount(count),
      rowBytes: count * 2)
    var output = vImage_Buffer(
      data: UnsafeMutableRawPointer(target.baseAddress!), height: 1, width: vImagePixelCount(count),
      rowBytes: count * 4)
    let status = vImageConvert_Planar16FtoPlanarF(&input, &output, vImage_Flags(kvImageNoFlags))
    precondition(status == kvImageNoError, "vImageConvert_Planar16FtoPlanarF failed: \(status)")
  }
}
