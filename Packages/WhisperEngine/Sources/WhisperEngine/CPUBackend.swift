import Accelerate
import Foundation

// The reference backend: every op in plain Float32 on Accelerate (vDSP, vForce, cblas). It exists so the graph can
// be checked op by op against naive loops and so the Metal backend has something exact to be compared with; it is
// not the shipping path, so weights are simply dequantized to Float32 at upload and views are copies.
//
// The reference keeps Float32 everywhere; whisper.cpp does not. Against whisper.cpp's own CPU path that costs about
// 0.01-0.04 rms on tiny's logits (within whisper.cpp's CPU-vs-Metal spread; `WhisperModel`'s attention padding is
// what matters for parity, not precision). `emulatesGgmlHalfPrecision` reproduces the rounding points for
// diagnosis. Where ggml rounds, on the CPU and on Metal alike:
// - every matmul against an f16 weight rounds the activations to f16 first (ggml-cpu converts src1 to the weight's
//   `vec_dot_type`; Metal's `mul_mm` kernel, used when src1 has more than 8 rows, so for the whole encoder, loads
//   src1 as half); against a q8_0 weight ggml-cpu quantizes the activations to q8_0 blocks;
// - `conv1d`: `ggml_conv_1d` is `ggml_im2col` into an f16 tensor followed by an f16 x f16 matmul (f32 accumulation);
// - attention: the encoder casts K and V to f16 (`ggml_cast(..., wctx.itype)`), the decoder's self and cross caches
//   are f16, and the K*Q and V*softmax matmuls round Q and the probabilities to f16 like any other matmul;
// - `gelu`: with GGML_GELU_FP16 (set in ggml-cpu/vec.h) `ggml_vec_gelu_f32` rounds x to f16 and looks the result up
//   in a 65536-entry f16 table (exact formula below ±10, identity above 10, 0 below -10); the Metal kernel uses the
//   formula on f32, but the next matmul rounds its result to f16 anyway.
// Metal's small-batch `mul_mv` kernels (the decoder, up to 8 rows) keep src1 in f32, Metal's `mul_mm` accumulates in
// f32 where ggml-cpu's arm64 f16 dot products accumulate in f16 lanes, and ggml-cpu quantizes the activations of a
// q8_0 matmul to q8_0; that is where whisper.cpp's CPU and Metal results part company, and the gap is the noise
// floor the parity tests use. The Float32 reference lands nearer Metal.

/// A CPU tensor: Float32 values, row-major in `shape`. A weight and an activation look the same here.
public final class CPUTensor: DeviceTensor, @unchecked Sendable {
  public let shape: [Int]
  /// Mutable only through `CPUBackend.write` (the decoder caches); every other op returns a new tensor.
  var values: [Float]
  /// The model file's type for an uploaded weight (what ggml would multiply against), nil for activations.
  let storage: WeightType?

  init(shape: [Int], values: [Float], storage: WeightType? = nil) {
    precondition(values.count == shape.reduce(1, *), "CPUTensor: \(values.count) values for shape \(shape)")
    self.shape = shape
    self.values = values
    self.storage = storage
  }

  var count: Int { values.count }
}

/// The Accelerate reference backend. Not thread-safe: one graph runs at a time (the `WhisperBackend` contract), hence
/// `@unchecked Sendable` so a model over it can be handed between tasks.
public final class CPUBackend: WhisperBackend, @unchecked Sendable {
  public typealias Tensor = CPUTensor

  /// Diagnostic: reproduce ggml-cpu's reduced-precision points (header; the matmul accumulation itself stays f32, and
  /// the q8_0 activation quantization only approximates ggml's blocked kernels). Off, the backend is the exact Float32
  /// reference. Not for production use.
  @_spi(Diagnostics) public var emulatesGgmlHalfPrecision = false

  public init() {}

  // MARK: Upload and readback

  public func weight(_ tensor: WeightTensor) throws -> CPUTensor {
    let expected = tensor.type.byteCount(elements: tensor.elementCount)
    guard tensor.data.count >= expected else {
      throw WhisperError.truncated("\(tensor.name): \(tensor.data.count) bytes, \(expected) expected")
    }
    return CPUTensor(shape: tensor.shape, values: CPUDequantize.floats(of: tensor), storage: tensor.type)
  }

  public func tensor(_ values: [Float], shape: [Int]) -> CPUTensor {
    CPUTensor(shape: shape, values: values)
  }

  public func read(_ tensor: CPUTensor) -> [Float] { tensor.values }
  public func takeFailure() -> Error? { nil }

  // MARK: Ops

  /// im2col ([outLen, cin * kernel], column c * kernel + t holds x[c, o * stride + t - padding], 0 outside) then one
  /// sgemm against the weight viewed as [cout, cin * kernel], the layout `ggml_conv_1d` uses. ggml's im2col is f16;
  /// this is f32 (see the header).
  public func conv1d(_ x: CPUTensor, weight: CPUTensor, bias: CPUTensor, stride: Int, padding: Int) -> CPUTensor {
    precondition(x.shape.count == 2 && weight.shape.count == 3, "conv1d: x \(x.shape), weight \(weight.shape)")
    let cin = x.shape[0], len = x.shape[1]
    let cout = weight.shape[0], kernel = weight.shape[2]
    precondition(weight.shape[1] == cin && bias.count == cout, "conv1d: weight \(weight.shape), bias \(bias.shape)")
    let outLen = (len + 2 * padding - kernel) / stride + 1
    let width = cin * kernel
    var columns = [Float](repeating: 0, count: outLen * width)
    x.values.withUnsafeBufferPointer { xp in
      columns.withUnsafeMutableBufferPointer { cp in
        for o in 0..<outLen {
          let row = o * width
          for c in 0..<cin {
            let xRow = c * len
            for t in 0..<kernel {
              let i = o * stride + t - padding
              if i >= 0 && i < len { cp[row + c * kernel + t] = xp[xRow + i] }
            }
          }
        }
      }
    }
    if emulatesGgmlHalfPrecision { GgmlPrecision.roundToHalf(&columns) }
    var out = [Float](repeating: 0, count: cout * outLen)
    CPUBackend.gemm(
      transposeB: true, m: cout, n: outLen, k: width, a: weight.values, lda: width, b: columns, ldb: width, c: &out,
      ldc: outLen)
    out.withUnsafeMutableBufferPointer { op in
      bias.values.withUnsafeBufferPointer { bp in
        for c in 0..<cout {
          var b = bp[c]
          vDSP_vsadd(op.baseAddress! + c * outLen, 1, &b, op.baseAddress! + c * outLen, 1, vDSP_Length(outLen))
        }
      }
    }
    return CPUTensor(shape: [cout, outLen], values: out)
  }

  public func linear(_ x: CPUTensor, weight: CPUTensor, bias: CPUTensor?) -> CPUTensor {
    precondition(x.shape.count == 2 && weight.shape.count == 2, "linear: x \(x.shape), weight \(weight.shape)")
    let n = x.shape[0], input = x.shape[1], output = weight.shape[0]
    precondition(weight.shape[1] == input, "linear: x \(x.shape) against weight \(weight.shape)")
    var activations = x.values
    if emulatesGgmlHalfPrecision { GgmlPrecision.roundActivations(&activations, against: weight.storage) }
    var out = [Float](repeating: 0, count: n * output)
    CPUBackend.gemm(
      transposeB: true, m: n, n: output, k: input, a: activations, lda: input, b: weight.values, ldb: input, c: &out,
      ldc: output)
    if let bias {
      precondition(bias.count == output, "linear: bias \(bias.shape) for \(output) outputs")
      CPUBackend.addBroadcast(&out, bias.values)
    }
    return CPUTensor(shape: [n, output], values: out)
  }

  /// `ggml_norm`: per row subtract the mean, divide by sqrt(mean of squared deviations + epsilon) (the same vDSP
  /// calls ggml's Accelerate build makes), then `* weight + bias`.
  public func layerNorm(_ x: CPUTensor, weight: CPUTensor, bias: CPUTensor, epsilon: Float) -> CPUTensor {
    precondition(x.shape.count == 2, "layerNorm: x \(x.shape)")
    let n = x.shape[0], d = x.shape[1]
    precondition(weight.count == d && bias.count == d, "layerNorm: weight \(weight.shape), bias \(bias.shape) for \(d)")
    var out = [Float](repeating: 0, count: n * d)
    x.values.withUnsafeBufferPointer { xp in
      out.withUnsafeMutableBufferPointer { op in
        weight.values.withUnsafeBufferPointer { wp in
          bias.values.withUnsafeBufferPointer { bp in
            for row in 0..<n {
              let src = xp.baseAddress! + row * d
              let dst = op.baseAddress! + row * d
              var mean: Float = 0
              vDSP_meanv(src, 1, &mean, vDSP_Length(d))
              var negativeMean = -mean
              vDSP_vsadd(src, 1, &negativeMean, dst, 1, vDSP_Length(d))
              var variance: Float = 0
              vDSP_measqv(dst, 1, &variance, vDSP_Length(d))
              var scale = 1 / (variance + epsilon).squareRoot()
              vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(d))
              vDSP_vmul(dst, 1, wp.baseAddress!, 1, dst, 1, vDSP_Length(d))
              vDSP_vadd(dst, 1, bp.baseAddress!, 1, dst, 1, vDSP_Length(d))
            }
          }
        }
      }
    }
    return CPUTensor(shape: x.shape, values: out)
  }

  public func add(_ a: CPUTensor, _ b: CPUTensor) -> CPUTensor {
    precondition(
      b.shape.count <= a.shape.count && Array(a.shape.suffix(b.shape.count)) == b.shape,
      "add: \(b.shape) does not broadcast over \(a.shape)")
    var out = a.values
    CPUBackend.addBroadcast(&out, b.values)
    return CPUTensor(shape: a.shape, values: out)
  }

  /// `ggml_gelu`: 0.5 x (1 + tanh(sqrt(2 / pi) (x + 0.044715 x^3))), the formula (see the header for ggml's table).
  public func gelu(_ x: CPUTensor) -> CPUTensor {
    let n = x.count
    var inner = [Float](repeating: 0, count: n)
    var input = x.values
    if emulatesGgmlHalfPrecision {
      // ggml_vec_gelu_f32 with GGML_GELU_FP16: table[f16(x)] = f16(gelu(f16(x))), identity above 10, 0 below -10.
      GgmlPrecision.roundToHalf(&input)
    }
    input.withUnsafeBufferPointer { xp in
      inner.withUnsafeMutableBufferPointer { ip in
        // inner = x * (1 + coefA * x * x)
        vDSP_vsq(xp.baseAddress!, 1, ip.baseAddress!, 1, vDSP_Length(n))
        var coefA = CPUBackend.geluCoefA, one: Float = 1
        vDSP_vsmsa(ip.baseAddress!, 1, &coefA, &one, ip.baseAddress!, 1, vDSP_Length(n))
        vDSP_vmul(ip.baseAddress!, 1, xp.baseAddress!, 1, ip.baseAddress!, 1, vDSP_Length(n))
        var sqrt2OverPi = CPUBackend.sqrt2OverPi
        vDSP_vsmul(ip.baseAddress!, 1, &sqrt2OverPi, ip.baseAddress!, 1, vDSP_Length(n))
        var count = Int32(n)
        vvtanhf(ip.baseAddress!, ip.baseAddress!, &count)
        // out = 0.5 * x * (1 + tanh)
        var half: Float = 0.5
        vDSP_vsadd(ip.baseAddress!, 1, &one, ip.baseAddress!, 1, vDSP_Length(n))
        vDSP_vmul(ip.baseAddress!, 1, xp.baseAddress!, 1, ip.baseAddress!, 1, vDSP_Length(n))
        vDSP_vsmul(ip.baseAddress!, 1, &half, ip.baseAddress!, 1, vDSP_Length(n))
      }
    }
    if emulatesGgmlHalfPrecision {
      GgmlPrecision.roundToHalf(&inner)
      for i in 0..<n where input[i] <= -10 || input[i] >= 10 { inner[i] = input[i] >= 10 ? input[i] : 0 }
    }
    return CPUTensor(shape: x.shape, values: inner)
  }

  public func transpose(_ x: CPUTensor) -> CPUTensor {
    precondition(x.shape.count == 2, "transpose: \(x.shape)")
    let r = x.shape[0], c = x.shape[1]
    var out = [Float](repeating: 0, count: r * c)
    vDSP_mtrans(x.values, 1, &out, 1, vDSP_Length(c), vDSP_Length(r))
    return CPUTensor(shape: [c, r], values: out)
  }

  /// Per head: scores = scale * q k^T ([nq, nk]), softmax per row in f32 (max-subtracted, like `ggml_soft_max_ext`),
  /// times v. Causal: query i sees keys 0 ... i + nk - nq, the rows of whisper.cpp's `KQ_mask` for a batch at
  /// positions past ..< past + nq over a cache of past + nq entries.
  public func attention(query: CPUTensor, key: CPUTensor, value: CPUTensor, heads: Int, scale: Float, causal: Bool)
    -> CPUTensor
  {
    precondition(query.shape.count == 2 && key.shape.count == 2 && value.shape.count == 2)
    let nq = query.shape[0], d = query.shape[1], nk = key.shape[0]
    precondition(key.shape[1] == d && value.shape == key.shape, "attention: q \(query.shape), k \(key.shape), v \(value.shape)")
    precondition(d % heads == 0 && (!causal || nk >= nq), "attention: \(heads) heads over \(d), nq \(nq), nk \(nk)")
    let headDim = d / heads
    var out = [Float](repeating: 0, count: nq * d)
    var scores = [Float](repeating: 0, count: nq * nk)
    var q = query.values, k = key.values, v = value.values
    let emulate = emulatesGgmlHalfPrecision
    if emulate {
      GgmlPrecision.roundToHalf(&q)
      GgmlPrecision.roundToHalf(&k)
      GgmlPrecision.roundToHalf(&v)
    }
    q.withUnsafeBufferPointer { qp in
      k.withUnsafeBufferPointer { kp in
        v.withUnsafeBufferPointer { vp in
          out.withUnsafeMutableBufferPointer { op in
            scores.withUnsafeMutableBufferPointer { sp in
              for h in 0..<heads {
                let offset = h * headDim
                cblas_sgemm(
                  CblasRowMajor, CblasNoTrans, CblasTrans, Int32(nq), Int32(nk), Int32(headDim), scale,
                  qp.baseAddress! + offset, Int32(d), kp.baseAddress! + offset, Int32(d), 0, sp.baseAddress!, Int32(nk))
                for i in 0..<nq {
                  let row = sp.baseAddress! + i * nk
                  let visible = causal ? i + nk - nq + 1 : nk
                  var maximum: Float = 0
                  vDSP_maxv(row, 1, &maximum, vDSP_Length(visible))
                  var negativeMaximum = -maximum
                  vDSP_vsadd(row, 1, &negativeMaximum, row, 1, vDSP_Length(visible))
                  var count = Int32(visible)
                  vvexpf(row, row, &count)
                  var sum: Float = 0
                  vDSP_sve(row, 1, &sum, vDSP_Length(visible))
                  vDSP_vsdiv(row, 1, &sum, row, 1, vDSP_Length(visible))
                  if visible < nk { vDSP_vclr(row + visible, 1, vDSP_Length(nk - visible)) }
                }
                if emulate { GgmlPrecision.roundToHalf(sp.baseAddress!, count: nq * nk) }
                cblas_sgemm(
                  CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(nq), Int32(headDim), Int32(nk), 1,
                  sp.baseAddress!, Int32(nk), vp.baseAddress! + offset, Int32(d), 0, op.baseAddress! + offset, Int32(d))
              }
            }
          }
        }
      }
    }
    return CPUTensor(shape: [nq, d], values: out)
  }

  public func embedding(_ table: CPUTensor, ids: [Int32]) -> CPUTensor {
    precondition(table.shape.count == 2, "embedding: table \(table.shape)")
    let vocab = table.shape[0], d = table.shape[1]
    var out = [Float](repeating: 0, count: ids.count * d)
    table.values.withUnsafeBufferPointer { tp in
      out.withUnsafeMutableBufferPointer { op in
        for (i, id) in ids.enumerated() {
          let row = Int(id)
          precondition(row >= 0 && row < vocab, "embedding: id \(id) outside \(vocab)")
          (op.baseAddress! + i * d).update(from: tp.baseAddress! + row * d, count: d)
        }
      }
    }
    return CPUTensor(shape: [ids.count, d], values: out)
  }

  public func rows(_ x: CPUTensor, _ range: Range<Int>) -> CPUTensor {
    precondition(x.shape.count == 2 && range.lowerBound >= 0 && range.upperBound <= x.shape[0], "rows: \(range) of \(x.shape)")
    let d = x.shape[1]
    return CPUTensor(shape: [range.count, d], values: Array(x.values[range.lowerBound * d..<range.upperBound * d]))
  }

  public func cache(capacity: Int, width: Int) -> CPUTensor {
    CPUTensor(shape: [capacity, width], values: [Float](repeating: 0, count: capacity * width))
  }

  public func write(_ values: CPUTensor, into cache: CPUTensor, at offset: Int) {
    precondition(values.shape.count == 2 && values.shape[1] == cache.shape[1], "write: \(values.shape) into \(cache.shape)")
    let k = values.shape[0], width = cache.shape[1]
    precondition(offset >= 0 && offset + k <= cache.shape[0], "write: rows \(offset)..<\(offset + k) of \(cache.shape)")
    cache.values.replaceSubrange(offset * width..<(offset + k) * width, with: values.values)
  }

  // MARK: Helpers

  static let geluCoefA: Float = 0.044715
  static let sqrt2OverPi: Float = 0.79788456080286535587989211986876

  /// c[m, n] = a[m, k] * b (b is [k, n], or [n, k] read transposed), row-major.
  private static func gemm(
    transposeB: Bool, m: Int, n: Int, k: Int, a: [Float], lda: Int, b: [Float], ldb: Int, c: inout [Float], ldc: Int
  ) {
    a.withUnsafeBufferPointer { ap in
      b.withUnsafeBufferPointer { bp in
        c.withUnsafeMutableBufferPointer { cp in
          cblas_sgemm(
            CblasRowMajor, CblasNoTrans, transposeB ? CblasTrans : CblasNoTrans, Int32(m), Int32(n), Int32(k), 1,
            ap.baseAddress!, Int32(lda), bp.baseAddress!, Int32(ldb), 0, cp.baseAddress!, Int32(ldc))
        }
      }
    }
  }

  /// `a += b` with `b` repeated over `a` (b's length divides a's).
  private static func addBroadcast(_ a: inout [Float], _ b: [Float]) {
    let width = b.count
    precondition(width > 0 && a.count % width == 0, "add: \(b.count) values over \(a.count)")
    a.withUnsafeMutableBufferPointer { ap in
      b.withUnsafeBufferPointer { bp in
        var offset = 0
        while offset < ap.count {
          vDSP_vadd(ap.baseAddress! + offset, 1, bp.baseAddress!, 1, ap.baseAddress! + offset, 1, vDSP_Length(width))
          offset += width
        }
      }
    }
  }
}

/// The rounding ggml applies at its reduced-precision points (`CPUBackend.emulatesGgmlHalfPrecision`).
enum GgmlPrecision {
  static func roundToHalf(_ values: inout [Float]) {
    values.withUnsafeMutableBufferPointer { roundToHalf($0.baseAddress!, count: $0.count) }
  }

  static func roundToHalf(_ values: UnsafeMutablePointer<Float>, count: Int) {
    #if arch(arm64)
      for i in 0..<count { values[i] = Float(Float16(values[i])) }
    #else
      for i in 0..<count { values[i] = CPUDequantize.float(half: CPUDequantize.half(values[i])) }
    #endif
  }

  /// What ggml-cpu's `ggml_compute_forward_mul_mat` does to src1 before the dot products: converted to the weight's
  /// `vec_dot_type`, f16 for f16 weights and q8_0 blocks (`quantize_row_q8_0`) for q8_0 weights; f32 weights as is.
  static func roundActivations(_ values: inout [Float], against storage: WeightType?) {
    switch storage {
    case .f16:
      roundToHalf(&values)
    case .q8_0:
      precondition(values.count % 32 == 0)
      for block in stride(from: 0, to: values.count, by: 32) {
        var amax: Float = 0
        for i in block..<block + 32 { amax = max(amax, abs(values[i])) }
        let d = CPUDequantize.float(half: CPUDequantize.half(amax / 127))
        let id: Float = d != 0 ? 1 / d : 0
        for i in block..<block + 32 { values[i] = (values[i] * id).rounded(.toNearestOrAwayFromZero) * d }
      }
    case .f32, nil:
      break
    }
  }
}

/// Dequantization for the CPU backend (f32 as is, f16 widened, q8_0 scale * quant per 32-value block, the layout
/// `dequantize_row_q8_0` reads). Weights.swift's `WeightDecoding` does the same for the rest of the engine; the
/// backend keeps its own copy so it stands alone.
enum CPUDequantize {
  static func floats(of tensor: WeightTensor) -> [Float] {
    let count = tensor.elementCount
    return tensor.data.withUnsafeBytes { raw -> [Float] in
      switch tensor.type {
      case .f32:
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
          for i in 0..<count { buffer[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
          initialized = count
        }
      case .f16:
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
          for i in 0..<count { buffer[i] = float(half: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) }
          initialized = count
        }
      case .q8_0:
        precondition(count % 32 == 0, "q8_0 tensor \(tensor.name) has \(count) elements")
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
          for block in 0..<(count / 32) {
            let base = block * 34
            let scale = float(half: raw.loadUnaligned(fromByteOffset: base, as: UInt16.self))
            for j in 0..<32 {
              buffer[block * 32 + j] = scale * Float(raw.loadUnaligned(fromByteOffset: base + 2 + j, as: Int8.self))
            }
          }
          initialized = count
        }
      }
    }
  }

  /// IEEE binary16 bits to Float32 (exact; subnormals, infinities and NaNs included).
  static func float(half bits: UInt16) -> Float {
    let sign = UInt32(bits & 0x8000) << 16
    let exponent = Int((bits >> 10) & 0x1f)
    let mantissa = UInt32(bits & 0x3ff)
    switch exponent {
    case 0:
      // Zero or subnormal: mantissa * 2^-24.
      return Float(bitPattern: sign) + (sign == 0 ? 1 : -1) * Float(mantissa) * Float(bitPattern: 0x3380_0000)
    case 0x1f:
      return Float(bitPattern: sign | 0x7f80_0000 | (mantissa << 13))
    default:
      return Float(bitPattern: sign | UInt32(exponent + 127 - 15) << 23 | (mantissa << 13))
    }
  }

  /// Float32 to IEEE binary16 bits, round to nearest even (what `GGML_FP32_TO_FP16` does on hardware with f16).
  static func half(_ value: Float) -> UInt16 {
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exponent = Int((bits >> 23) & 0xff)
    let mantissa = bits & 0x7f_ffff
    if exponent == 0xff { return sign | 0x7c00 | (mantissa == 0 ? 0 : 0x200) }
    let unbiased = exponent - 127
    if unbiased > 15 { return sign | 0x7c00 }
    if unbiased < -25 { return sign }
    var full = mantissa | 0x80_0000  // 24-bit significand
    var shift = 13
    var halfExponent = unbiased + 15
    if halfExponent <= 0 {
      shift += 1 - halfExponent
      halfExponent = 0
    } else {
      full &= 0x7f_ffff
    }
    let truncated = full >> UInt32(shift)
    let remainder = full & ((1 << UInt32(shift)) - 1)
    let halfway: UInt32 = 1 << UInt32(shift - 1)
    var rounded = truncated
    if remainder > halfway || (remainder == halfway && truncated & 1 == 1) { rounded += 1 }
    // Rounding may carry into the exponent (including subnormal -> normal), which the bit layout handles.
    return sign | (UInt16(halfExponent) << 10 &+ UInt16(rounded))
  }
}
