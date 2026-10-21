import Accelerate
import Foundation
import XCTest

@testable import WhisperEngine

// Every MetalBackend op against naive Swift loops on seeded random inputs, at small shapes and at whisper's (tiny
// model: d = 384, 6 heads, 1500 audio positions, 80 mels x 3000 frames). The backend is shared across the class:
// the kernel compile is the expensive part.

final class MetalBackendTests: XCTestCase {
  nonisolated(unsafe) private static var shared: Result<MetalBackend, Error>?

  private func backend() throws -> MetalBackend {
    if Self.shared == nil { Self.shared = Result { try MetalBackend() } }
    switch Self.shared! {
    case .success(let backend): return backend
    case .failure(let error):
      if case WhisperError.metalUnavailable = error { throw XCTSkip("no Metal device") }
      throw error
    }
  }

  // MARK: - Reference implementations

  /// Deterministic pseudo-random floats in [-1, 1) (SplitMix64).
  struct Seeded {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Float {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z ^= z >> 31
      return Float(z >> 40) / Float(1 << 23) - 1
    }
    mutating func floats(_ count: Int, scale: Float = 1) -> [Float] { (0..<count).map { _ in next() * scale } }
  }

  /// ggml's `quantize_row_q8_0_ref`: per block of 32, d = amax / 127 (stored as f16), q = round(x * (1 / d)).
  static func quantizeQ8(_ values: [Float]) -> (data: Data, dequantized: [Float]) {
    precondition(values.count % 32 == 0)
    var data = Data()
    var dequantized = [Float](repeating: 0, count: values.count)
    for block in 0..<(values.count / 32) {
      let slice = values[block * 32..<(block + 1) * 32]
      var amax: Float = 0
      for v in slice { amax = max(amax, abs(v)) }
      let d = amax / 127
      let id: Float = d != 0 ? 1 / d : 0
      let dBits = MetalHalf.fromFloat(d)
      let dStored = MetalHalf.toFloat(dBits)
      data.append(UInt8(dBits & 0xFF))
      data.append(UInt8(dBits >> 8))
      for (i, v) in slice.enumerated() {
        let q = Int8((v * id).rounded(.toNearestOrAwayFromZero))
        data.append(UInt8(bitPattern: q))
        dequantized[block * 32 + i] = dStored * Float(q)
      }
    }
    return (data, dequantized)
  }

  static func toHalf(_ values: [Float]) -> (data: Data, rounded: [Float]) {
    var data = Data(capacity: values.count * 2)
    var rounded = [Float](repeating: 0, count: values.count)
    for (i, v) in values.enumerated() {
      let bits = MetalHalf.fromFloat(v)
      data.append(UInt8(bits & 0xFF))
      data.append(UInt8(bits >> 8))
      rounded[i] = MetalHalf.toFloat(bits)
    }
    return (data, rounded)
  }

  static func f32Data(_ values: [Float]) -> Data { values.withUnsafeBytes { Data($0) } }

  /// C [m, n] = A [m, k] . B [n, k]^T (`transposed`) or A [m, k] . B [k, n], accumulated in double precision:
  /// naive loops for small products, `cblas_dgemm` beyond (the same arithmetic, minutes faster in a debug build).
  static func matmul(_ a: [Double], _ b: [Double], m: Int, n: Int, k: Int, transposed: Bool) -> [Double] {
    var c = [Double](repeating: 0, count: m * n)
    if m * n * k < 2_000_000 {
      for i in 0..<m {
        for j in 0..<n {
          var acc = 0.0
          for l in 0..<k { acc += a[i * k + l] * (transposed ? b[j * k + l] : b[l * n + j]) }
          c[i * n + j] = acc
        }
      }
      return c
    }
    var bRows = b  // vDSP_mmulD wants B as [k, n]
    if transposed {
      bRows = [Double](repeating: 0, count: k * n)
      vDSP_mtransD(b, 1, &bRows, 1, vDSP_Length(k), vDSP_Length(n))
    }
    vDSP_mmulD(a, 1, bRows, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
    return c
  }

  /// x [n, in] . w [out, in]^T + b: [n, out].
  static func referenceLinear(_ x: [Float], n: Int, inDim: Int, w: [Float], out: Int, bias: [Float]?) -> [Float] {
    let y = matmul(x.map(Double.init), w.map(Double.init), m: n, n: out, k: inDim, transposed: true)
    return (0..<n * out).map { Float(y[$0]) + (bias?[$0 % out] ?? 0) }
  }

  static func referenceConv1d(_ x: [Float], cin: Int, len: Int, w: [Float], cout: Int, k: Int, bias: [Float], stride: Int, padding: Int) -> [Float] {
    let outLen = (len + 2 * padding - k) / stride + 1
    // Patches [outLen, cin * k], then one matmul with w [cout, cin * k]: the textbook im2col formulation.
    var patches = [Double](repeating: 0, count: outLen * cin * k)
    for t in 0..<outLen {
      for c in 0..<cin {
        for j in 0..<k {
          let pos = t * stride + j - padding
          if pos < 0 || pos >= len { continue }
          patches[(t * cin + c) * k + j] = Double(x[c * len + pos])
        }
      }
    }
    let product = matmul(patches, w.map(Double.init), m: outLen, n: cout, k: cin * k, transposed: true)  // [outLen, cout]
    var y = [Float](repeating: 0, count: cout * outLen)
    for o in 0..<cout { for t in 0..<outLen { y[o * outLen + t] = Float(product[t * cout + o] + Double(bias[o])) } }
    return y
  }

  static func referenceLayerNorm(_ x: [Float], n: Int, d: Int, w: [Float], b: [Float], eps: Float) -> [Float] {
    var y = [Float](repeating: 0, count: n * d)
    for i in 0..<n {
      let row = x[i * d..<(i + 1) * d]
      let mean = row.reduce(0, +) / Float(d)
      let variance = row.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(d)
      let scale = 1 / (variance + eps).squareRoot()
      for j in 0..<d { y[i * d + j] = (x[i * d + j] - mean) * scale * w[j] + b[j] }
    }
    return y
  }

  static func referenceGelu(_ x: [Float]) -> [Float] {
    x.map { v in 0.5 * v * (1 + tanh(0.79788456080286535587989211986876 * v * (1 + 0.044715 * v * v))) }
  }

  static func referenceAttention(q: [Float], nq: Int, k: [Float], v: [Float], nk: Int, d: Int, heads: Int, scale: Float, causal: Bool) -> [Float] {
    let hd = d / heads
    var out = [Float](repeating: 0, count: nq * d)
    for h in 0..<heads {
      let slice = { (x: [Float], rows: Int) -> [Double] in
        (0..<rows * hd).map { Double(x[($0 / hd) * d + h * hd + $0 % hd]) }
      }
      let (qh, kh, vh) = (slice(q, nq), slice(k, nk), slice(v, nk))
      var scores = matmul(qh, kh, m: nq, n: nk, k: hd, transposed: true)
      for i in 0..<nq {
        for j in 0..<nk { scores[i * nk + j] = causal && j > i + nk - nq ? -.infinity : scores[i * nk + j] * Double(scale) }
        let row = scores[i * nk..<(i + 1) * nk]
        let m = row.max()!
        let exps = row.map { $0 == -.infinity ? 0 : exp($0 - m) }
        let sum = exps.reduce(0, +)
        for j in 0..<nk { scores[i * nk + j] = exps[j] / sum }
      }
      let mixed = matmul(scores, vh, m: nq, n: hd, k: nk, transposed: false)
      for i in 0..<nq { for e in 0..<hd { out[i * d + h * hd + e] = Float(mixed[i * hd + e]) } }
    }
    return out
  }

  /// Largest |a - b| / max(|b|, floor) over the arrays.
  static func maxRelativeError(_ a: [Float], _ b: [Float], floor: Float = 1) -> Float {
    precondition(a.count == b.count, "count \(a.count) vs \(b.count)")
    var worst: Float = 0
    for i in 0..<a.count {
      let error = abs(a[i] - b[i]) / max(abs(b[i]), floor)
      worst = max(worst, error)
    }
    return worst
  }

  private func assertClose(_ got: [Float], _ want: [Float], tolerance: Float, floor: Float = 1, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    let error = Self.maxRelativeError(got, want, floor: floor)
    XCTAssertLessThanOrEqual(error, tolerance, "\(label): max relative error \(error)", file: file, line: line)
    print("[metal] \(label): max relative error \(error) (tolerance \(tolerance))")
  }

  // MARK: - Uploads

  func testUploadReadRoundTrip() throws {
    let backend = try backend()
    var rng = Seeded(1)
    let values = rng.floats(96)
    XCTAssertEqual(backend.read(backend.tensor(values, shape: [3, 32])), values)

    let (halfData, halfRounded) = Self.toHalf(values)
    let f16 = try backend.weight(WeightTensor(name: "w16", shape: [3, 32], type: .f16, data: halfData))
    XCTAssertEqual(backend.read(f16), halfRounded)
    XCTAssertEqual(f16.type, .f16)

    let (q8Data, q8Dequantized) = Self.quantizeQ8(values)
    let q8 = try backend.weight(WeightTensor(name: "w8", shape: [3, 32], type: .q8_0, data: q8Data))
    XCTAssertEqual(backend.read(q8), q8Dequantized)
    XCTAssertEqual(q8.type, .q8_0)

    // A vector stays readable as f32 even when the file stores it as f16 (biases of f16 models).
    let bias = try backend.weight(WeightTensor(name: "b", shape: [32], type: .f16, data: Self.toHalf(Array(values[0..<32])).data))
    XCTAssertEqual(bias.type, .f32)
    XCTAssertEqual(backend.read(bias), Array(halfRounded[0..<32]))

    XCTAssertThrowsError(try backend.weight(WeightTensor(name: "short", shape: [3, 32], type: .f32, data: Data(count: 10))))
  }

  func testHalfConversionMatchesIEEE() throws {
    #if arch(arm64)
      for value: Float in [0, 1, -1, 0.1, 65504, 1e-5, 3.14159, -2.5e-6, 1e5, .infinity, 2049, 2051, 0.000061] {
        let bits = MetalHalf.fromFloat(value)
        XCTAssertEqual(bits, Float16(value).bitPattern, "\(value)")
        XCTAssertEqual(MetalHalf.toFloat(bits), Float(Float16(bitPattern: bits)), "\(value)")
      }
    #else
      throw XCTSkip("Float16 is only available on arm64")
    #endif
  }

  // MARK: - linear

  private func checkLinear(n: Int, inDim: Int, out: Int, type: WeightType, bias: Bool, tolerance: Float, seed: UInt64) throws {
    let backend = try backend()
    var rng = Seeded(seed)
    let x = rng.floats(n * inDim)
    let w = rng.floats(out * inDim, scale: 0.5)
    let b = bias ? rng.floats(out) : nil

    let weightTensor: WeightTensor
    let wEffective: [Float]
    switch type {
    case .f32:
      weightTensor = WeightTensor(name: "w", shape: [out, inDim], type: .f32, data: Self.f32Data(w))
      wEffective = w
    case .f16:
      let (data, rounded) = Self.toHalf(w)
      weightTensor = WeightTensor(name: "w", shape: [out, inDim], type: .f16, data: data)
      wEffective = rounded
    case .q8_0:
      let (data, dequantized) = Self.quantizeQ8(w)
      weightTensor = WeightTensor(name: "w", shape: [out, inDim], type: .q8_0, data: data)
      wEffective = dequantized
    }
    let want = Self.referenceLinear(x, n: n, inDim: inDim, w: wEffective, out: out, bias: b)
    let got = backend.read(backend.linear(backend.tensor(x, shape: [n, inDim]), weight: try backend.weight(weightTensor), bias: b.map { backend.tensor($0, shape: [out]) }))
    assertClose(got, want, tolerance: tolerance, "linear n=\(n) in=\(inDim) out=\(out) \(type) bias=\(bias)")
  }

  func testLinearSmall() throws {
    try checkLinear(n: 1, inDim: 64, out: 5, type: .f32, bias: true, tolerance: 1e-4, seed: 10)
    try checkLinear(n: 3, inDim: 64, out: 5, type: .f32, bias: false, tolerance: 1e-4, seed: 11)
    try checkLinear(n: 1, inDim: 32, out: 7, type: .q8_0, bias: true, tolerance: 1e-3, seed: 12)
    try checkLinear(n: 9, inDim: 64, out: 70, type: .f16, bias: true, tolerance: 2e-3, seed: 13)  // mul_mm, partial tiles
    try checkLinear(n: 9, inDim: 96, out: 66, type: .q8_0, bias: false, tolerance: 2e-3, seed: 14)  // mul_mm, bc_inp
    try checkLinear(n: 2, inDim: 20, out: 33, type: .f32, bias: true, tolerance: 1e-4, seed: 15)  // mul_mv _short
    try checkLinear(n: 5, inDim: 37, out: 34, type: .f16, bias: false, tolerance: 1e-3, seed: 16)  // mul_mv, odd ne00
  }

  func testLinearDecodeStepShapes() throws {
    try checkLinear(n: 1, inDim: 384, out: 1536, type: .q8_0, bias: true, tolerance: 1e-3, seed: 20)
    try checkLinear(n: 1, inDim: 1536, out: 384, type: .q8_0, bias: true, tolerance: 1e-3, seed: 21)
    try checkLinear(n: 1, inDim: 384, out: 1536, type: .f16, bias: true, tolerance: 1e-3, seed: 22)
    try checkLinear(n: 1, inDim: 1536, out: 384, type: .f16, bias: false, tolerance: 1e-3, seed: 23)
    try checkLinear(n: 4, inDim: 384, out: 384, type: .q8_0, bias: true, tolerance: 1e-3, seed: 24)  // prompt rows
  }

  func testLinearEncoderShapes() throws {
    try checkLinear(n: 1500, inDim: 384, out: 1536, type: .q8_0, bias: true, tolerance: 1e-2, seed: 30)
    try checkLinear(n: 1500, inDim: 1536, out: 384, type: .q8_0, bias: true, tolerance: 1e-2, seed: 31)
    try checkLinear(n: 1500, inDim: 384, out: 1536, type: .f16, bias: true, tolerance: 1e-2, seed: 32)
    try checkLinear(n: 1500, inDim: 1536, out: 384, type: .f16, bias: false, tolerance: 1e-2, seed: 33)
    try checkLinear(n: 1500, inDim: 384, out: 384, type: .f32, bias: true, tolerance: 1e-2, seed: 34)
  }

  // MARK: - conv1d

  private func checkConv(cin: Int, len: Int, cout: Int, k: Int, stride: Int, type: WeightType, tolerance: Float, seed: UInt64) throws {
    let backend = try backend()
    var rng = Seeded(seed)
    let x = rng.floats(cin * len)
    let w = rng.floats(cout * cin * k, scale: 0.2)
    let b = rng.floats(cout)
    let weightTensor: WeightTensor
    let wEffective: [Float]
    if type == .f16 {
      let (data, rounded) = Self.toHalf(w)
      weightTensor = WeightTensor(name: "conv", shape: [cout, cin, k], type: .f16, data: data)
      wEffective = rounded
    } else {
      weightTensor = WeightTensor(name: "conv", shape: [cout, cin, k], type: .f32, data: Self.f32Data(w))
      wEffective = w
    }
    // ggml's conv_1d rounds the input columns to f16 (im2col output); mirror that in the reference.
    let xHalf = Self.toHalf(x).rounded
    let want = Self.referenceConv1d(xHalf, cin: cin, len: len, w: wEffective, cout: cout, k: k, bias: b, stride: stride, padding: 1)
    let got = backend.read(backend.conv1d(backend.tensor(x, shape: [cin, len]), weight: try backend.weight(weightTensor), bias: backend.tensor(b, shape: [cout]), stride: stride, padding: 1))
    XCTAssertEqual(got.count, cout * ((len + 2 - k) / stride + 1))
    assertClose(got, want, tolerance: tolerance, "conv1d cin=\(cin) len=\(len) cout=\(cout) k=\(k) stride=\(stride) \(type)")
  }

  func testConv1dSmall() throws {
    try checkConv(cin: 4, len: 10, cout: 6, k: 3, stride: 1, type: .f32, tolerance: 1e-3, seed: 40)
    try checkConv(cin: 4, len: 11, cout: 6, k: 3, stride: 2, type: .f16, tolerance: 1e-3, seed: 41)
    try checkConv(cin: 24, len: 50, cout: 40, k: 3, stride: 1, type: .f16, tolerance: 2e-3, seed: 42)  // mul_mm
  }

  func testConv1dWhisperShapes() throws {
    try checkConv(cin: 80, len: 3000, cout: 384, k: 3, stride: 1, type: .f16, tolerance: 1e-2, seed: 43)
    try checkConv(cin: 384, len: 3000, cout: 384, k: 3, stride: 2, type: .f16, tolerance: 1e-2, seed: 44)
    try checkConv(cin: 80, len: 3000, cout: 384, k: 3, stride: 1, type: .f32, tolerance: 1e-2, seed: 45)
  }

  // MARK: - layerNorm, add, gelu, transpose

  func testLayerNorm() throws {
    let backend = try backend()
    for (n, d) in [(3, 8), (5, 37), (1500, 384), (1, 1536)] {
      var rng = Seeded(UInt64(50 + n + d))
      let x = rng.floats(n * d, scale: 3)
      let w = rng.floats(d)
      let b = rng.floats(d)
      let want = Self.referenceLayerNorm(x, n: n, d: d, w: w, b: b, eps: 1e-5)
      let got = backend.read(backend.layerNorm(backend.tensor(x, shape: [n, d]), weight: backend.tensor(w, shape: [d]), bias: backend.tensor(b, shape: [d]), epsilon: 1e-5))
      assertClose(got, want, tolerance: 1e-4, "layerNorm n=\(n) d=\(d)")
    }
    // f16 parameters (as an f16 model file stores them) are converted on upload.
    var rng = Seeded(60)
    let (x, w, b) = (rng.floats(4 * 32), rng.floats(32), rng.floats(32))
    let wHalf = Self.toHalf(w)
    let bHalf = Self.toHalf(b)
    let want = Self.referenceLayerNorm(x, n: 4, d: 32, w: wHalf.rounded, b: bHalf.rounded, eps: 1e-5)
    let got = backend.read(backend.layerNorm(backend.tensor(x, shape: [4, 32]), weight: try backend.weight(WeightTensor(name: "w", shape: [32], type: .f16, data: wHalf.data)), bias: try backend.weight(WeightTensor(name: "b", shape: [32], type: .f16, data: bHalf.data)), epsilon: 1e-5))
    assertClose(got, want, tolerance: 1e-4, "layerNorm f16 params")
  }

  func testAddBroadcast() throws {
    let backend = try backend()
    for (n, d) in [(3, 8), (7, 37), (1500, 384), (1, 51865)] {
      var rng = Seeded(UInt64(70 + n + d))
      let a = rng.floats(n * d)
      let full = rng.floats(n * d)
      let row = rng.floats(d)
      let got = backend.read(backend.add(backend.tensor(a, shape: [n, d]), backend.tensor(full, shape: [n, d])))
      assertClose(got, zip(a, full).map(+), tolerance: 1e-6, "add same shape n=\(n) d=\(d)")
      let gotRow = backend.read(backend.add(backend.tensor(a, shape: [n, d]), backend.tensor(row, shape: [d])))
      assertClose(gotRow, (0..<n * d).map { a[$0] + row[$0 % d] }, tolerance: 1e-6, "add row broadcast n=\(n) d=\(d)")
    }
    // A 3-D activation plus a 2-D suffix (position embeddings added per batch).
    var rng = Seeded(80)
    let a = rng.floats(2 * 5 * 8)
    let pe = rng.floats(5 * 8)
    let got = backend.read(backend.add(backend.tensor(a, shape: [2, 5, 8]), backend.tensor(pe, shape: [5, 8])))
    assertClose(got, (0..<80).map { a[$0] + pe[$0 % 40] }, tolerance: 1e-6, "add 3-D suffix")
  }

  func testGelu() throws {
    let backend = try backend()
    for (n, d) in [(3, 8), (5, 37), (1500, 1536), (1, 1536)] {
      var rng = Seeded(UInt64(90 + n + d))
      let x = rng.floats(n * d, scale: 4)
      let got = backend.read(backend.gelu(backend.tensor(x, shape: [n, d])))
      assertClose(got, Self.referenceGelu(x), tolerance: 1e-4, "gelu n=\(n) d=\(d)")
    }
  }

  func testTranspose() throws {
    let backend = try backend()
    for (r, c) in [(3, 5), (1, 7), (37, 384), (384, 1500)] {
      var rng = Seeded(UInt64(100 + r + c))
      let x = rng.floats(r * c)
      let t = backend.transpose(backend.tensor(x, shape: [r, c]))
      XCTAssertEqual(t.shape, [c, r])
      let got = backend.read(t)
      var want = [Float](repeating: 0, count: r * c)
      for i in 0..<r { for j in 0..<c { want[j * r + i] = x[i * c + j] } }
      XCTAssertEqual(got, want, "transpose \(r)x\(c)")
    }
  }

  // MARK: - attention

  private func checkAttention(nq: Int, nk: Int, d: Int, heads: Int, causal: Bool, tolerance: Float, seed: UInt64) throws {
    let backend = try backend()
    var rng = Seeded(seed)
    let q = rng.floats(nq * d)
    let k = rng.floats(nk * d)
    let v = rng.floats(nk * d)
    let scale = Float(pow(Double(d / heads), -0.5))
    let want = Self.referenceAttention(q: q, nq: nq, k: k, v: v, nk: nk, d: d, heads: heads, scale: scale, causal: causal)
    let got = backend.read(backend.attention(query: backend.tensor(q, shape: [nq, d]), key: backend.tensor(k, shape: [nk, d]), value: backend.tensor(v, shape: [nk, d]), heads: heads, scale: scale, causal: causal))
    assertClose(got, want, tolerance: tolerance, floor: 0.1, "attention nq=\(nq) nk=\(nk) d=\(d) heads=\(heads) causal=\(causal)")
  }

  func testAttentionSmall() throws {
    try checkAttention(nq: 4, nk: 4, d: 8, heads: 2, causal: true, tolerance: 1e-4, seed: 110)
    try checkAttention(nq: 3, nk: 9, d: 16, heads: 2, causal: true, tolerance: 1e-4, seed: 111)
    try checkAttention(nq: 5, nk: 7, d: 12, heads: 3, causal: false, tolerance: 1e-4, seed: 112)
    try checkAttention(nq: 1, nk: 6, d: 8, heads: 2, causal: true, tolerance: 1e-4, seed: 113)
    try checkAttention(nq: 12, nk: 70, d: 128, heads: 2, causal: false, tolerance: 2e-3, seed: 114)  // mul_mm path
    try checkAttention(nq: 9, nk: 9, d: 128, heads: 2, causal: true, tolerance: 2e-3, seed: 115)  // composed (mul_mm), causal mask
    try checkAttention(nq: 8, nk: 9, d: 128, heads: 2, causal: true, tolerance: 1e-4, seed: 116)  // fused, causal with past
    try checkAttention(nq: 3, nk: 1500, d: 384, heads: 6, causal: false, tolerance: 1e-4, seed: 117)  // split-K, 11 partitions
    try checkAttention(nq: 2, nk: 300, d: 128, heads: 2, causal: true, tolerance: 1e-4, seed: 118)  // split-K, causal, empty tail partitions
    try checkAttention(nq: 20, nk: 64, d: 128, heads: 2, causal: false, tolerance: 2e-3, seed: 119)  // flash attention, partial query block
  }

  func testAttentionWhisperShapes() throws {
    try checkAttention(nq: 1, nk: 37, d: 384, heads: 6, causal: true, tolerance: 1e-4, seed: 120)
    try checkAttention(nq: 4, nk: 37, d: 384, heads: 6, causal: true, tolerance: 1e-4, seed: 121)
    try checkAttention(nq: 37, nk: 37, d: 384, heads: 6, causal: true, tolerance: 1e-2, seed: 122)
    try checkAttention(nq: 1500, nk: 1500, d: 384, heads: 6, causal: false, tolerance: 1e-2, seed: 123)
    try checkAttention(nq: 1, nk: 1500, d: 384, heads: 6, causal: false, tolerance: 1e-4, seed: 124)  // cross-attention
    try checkAttention(nq: 1500, nk: 1536, d: 384, heads: 6, causal: false, tolerance: 1e-2, seed: 125)  // flash attention (padded keys)
    try checkAttention(nq: 1500, nk: 1536, d: 768, heads: 12, causal: false, tolerance: 1e-2, seed: 126)  // flash attention, small model
    try checkAttention(nq: 4, nk: 1536, d: 768, heads: 12, causal: false, tolerance: 1e-4, seed: 127)  // split-K cross-attention, prompt
  }

  // MARK: - embedding, rows, cache

  func testEmbedding() throws {
    let backend = try backend()
    var rng = Seeded(130)
    let (vocab, d) = (50, 64)
    let table = rng.floats(vocab * d)
    let ids: [Int32] = [3, 0, 49, 3, 17]
    let gather = { (values: [Float]) -> [Float] in ids.flatMap { Array(values[Int($0) * d..<(Int($0) + 1) * d]) } }

    let f32 = try backend.weight(WeightTensor(name: "e", shape: [vocab, d], type: .f32, data: Self.f32Data(table)))
    XCTAssertEqual(backend.read(backend.embedding(f32, ids: ids)), gather(table))
    let half = Self.toHalf(table)
    let f16 = try backend.weight(WeightTensor(name: "e", shape: [vocab, d], type: .f16, data: half.data))
    XCTAssertEqual(backend.read(backend.embedding(f16, ids: ids)), gather(half.rounded))
    let q8 = Self.quantizeQ8(table)
    let q8Table = try backend.weight(WeightTensor(name: "e", shape: [vocab, d], type: .q8_0, data: q8.data))
    XCTAssertEqual(backend.read(backend.embedding(q8Table, ids: ids)), gather(q8.dequantized))
    XCTAssertEqual(backend.embedding(q8Table, ids: []).shape, [0, d])
  }

  func testRowsAndCache() throws {
    let backend = try backend()
    var rng = Seeded(140)
    let x = rng.floats(10 * 8)
    let tensor = backend.tensor(x, shape: [10, 8])
    let view = backend.rows(tensor, 3..<7)
    XCTAssertEqual(view.shape, [4, 8])
    XCTAssertEqual(backend.read(view), Array(x[24..<56]))

    let cache = backend.cache(capacity: 12, width: 8)
    XCTAssertEqual(backend.read(cache), [Float](repeating: 0, count: 96))
    backend.write(view, into: cache, at: 5)
    backend.write(backend.rows(tensor, 0..<1), into: cache, at: 11)
    var want = [Float](repeating: 0, count: 96)
    want.replaceSubrange(40..<72, with: x[24..<56])
    want.replaceSubrange(88..<96, with: x[0..<8])
    XCTAssertEqual(backend.read(cache), want)

    // Ops read views and caches like any tensor: attention over the written rows.
    let q = rng.floats(8)
    let got = backend.read(backend.attention(query: backend.tensor(q, shape: [1, 8]), key: backend.rows(cache, 5..<9), value: backend.rows(cache, 5..<9), heads: 2, scale: 0.5, causal: true))
    let wantAttention = Self.referenceAttention(q: q, nq: 1, k: Array(x[24..<56]), v: Array(x[24..<56]), nk: 4, d: 8, heads: 2, scale: 0.5, causal: true)
    assertClose(got, wantAttention, tolerance: 1e-4, floor: 0.1, "attention over cache rows")
  }

  // MARK: - Batching and compile time

  func testManyOpsBatchCorrectly() throws {
    // Enough ops to cross the flush threshold mid-chain; each result feeds the next.
    let backend = try backend()
    var rng = Seeded(150)
    let x = rng.floats(4 * 32)
    let one = backend.tensor([Float](repeating: 1, count: 32), shape: [32])
    var t = backend.tensor(x, shape: [4, 32])
    var want = x
    for _ in 0..<300 {
      t = backend.add(t, one)
      want = want.map { $0 + 1 }  // the same sequence of float roundings
    }
    XCTAssertEqual(backend.read(t), want)
  }

  func testKernelCompileTime() throws {
    let backend = try backend()
    print("[metal] MetalBackend init in this process: makeLibrary took \(backend.compileSeconds) s")

    // Metal caches compiled sources on disk by their text (so the init above is only cold the first time this
    // machine sees the sources); a unique comment forces a cold compile, compiling again hits the cache.
    let nonce = "cold-compile \(UUID().uuidString)"
    let cold = try MetalKernelLibrary.compile(on: backend.device, tensorAPI: backend.usesTensorAPI, cacheBuster: nonce)
    let warm = try MetalKernelLibrary.compile(on: backend.device, tensorAPI: backend.usesTensorAPI, cacheBuster: nonce)
    print("[metal] tensor API in use: \(backend.usesTensorAPI)")
    print("[metal] cold makeLibrary \(cold.seconds) s, warm (same source again) \(warm.seconds) s")
    XCTAssertLessThan(warm.seconds, cold.seconds)
    XCTAssertLessThan(cold.seconds, 60, "kernel compile should take seconds, not minutes")

    // makeLibrary(source:) is the front end only; the GPU back end runs per pipeline (also cached by Metal).
    let pipelines = MetalPipelineCache(device: backend.device, library: cold.library)
    for key in [
      PipelineKey("kernel_mul_mm_q8_0_f32", [.bool(700, false), .bool(701, true), .short(702, 1), .short(703, 1), .short(704, 1), .short(705, 1)]),
      PipelineKey("kernel_mul_mv_q8_0_f32", [.short(600, 4), .short(602, 1), .short(603, 1), .short(604, 1), .bool(605, false)]),
      PipelineKey("kernel_soft_max_f32_4"),
      PipelineKey("kernel_norm_mul_add_f32_4", [.bool(1700, false)]),
    ] {
      let start = Date()
      _ = try pipelines.pipeline(key)
      print("[metal] cold pipeline \(key.name): \(Date().timeIntervalSince(start)) s")
    }

    // The whole graph set from the cold library: how long a first run on a machine spends in init's pipeline
    // build (if Metal's pipeline cache keys by function rather than by library this is warm too; the print says).
    let coldSet = MetalPipelineCache(device: backend.device, library: cold.library)
    let coldStart = Date()
    try coldSet.build(MetalBackend.graphPipelineKeys())
    print("[metal] all \(coldSet.count) graph pipelines from the cold library: \(Date().timeIntervalSince(coldStart)) s")

    // Every graph pipeline is built in init (and cached by Metal after the first run on a machine).
    let start = Date()
    let second = try MetalBackend()
    _ = second.read(second.gelu(second.tensor([1, 2, 3, 4], shape: [1, 4])))
    print("[metal] another init plus one gelu: \(Date().timeIntervalSince(start)) s")
  }

  // MARK: - Hardening: init, failures, pool, command buffer split

  func testInitBuildsEveryPipelineAndSmokeTests() throws {
    let first = try backend()  // the shared one: the library compile is paid for (cold when this machine's Metal cache is empty)
    print(
      "[metal] first init in this process: makeLibrary \(first.compileSeconds) s, \(first.pipelineCount) pipelines in "
        + "\(first.pipelineSeconds) s, smoke test \(first.smokeTestSeconds) s")
    let start = Date()
    let fresh = try MetalBackend()
    let seconds = Date().timeIntervalSince(start)
    print(
      "[metal] warm init \(seconds) s: makeLibrary \(fresh.compileSeconds) s, \(fresh.pipelineCount) pipelines in "
        + "\(fresh.pipelineSeconds) s, smoke test \(fresh.smokeTestSeconds) s")
    XCTAssertLessThan(seconds, 1, "a warm init (Metal's caches populated) should take well under a second")
    XCTAssertGreaterThanOrEqual(fresh.pipelineCount, 80, "the graph's pipelines are built up front")
    XCTAssertNil(fresh.lastError, "the smoke test leaves no failure behind")
    XCTAssertNil(fresh.takeFailure())
    // The key set covers what the ops ask for: the dispatch code's own key builders are in it.
    let keys = Set(MetalBackend.graphPipelineKeys())
    XCTAssertTrue(keys.contains(MetalBackend.matrixKey(src0: "q8_0", src1: "f32", bcInp: false, bcOut: true, ne12: 1, ne13: 1, r2: 1, r3: 1)))
    XCTAssertTrue(keys.contains(MetalBackend.vectorKey(src0: "f16", src1: "f32", suffix: "_4", nsg: 3, ne12: 1, r2: 1, r3: 1)))
    XCTAssertTrue(keys.contains(MetalBackend.flashAttentionKey(d: 768, nsg: 4)))
    XCTAssertTrue(keys.contains(MetalBackend.addKey(vector4: false, rb: true, cb: true)))
    XCTAssertGreaterThan(fresh.smokeTestSeconds, 0, "the smoke test ran")
    XCTAssertEqual(fresh.statistics.dispatches, 0, "init's own work is not in the caller's statistics")
  }

  func testKernelSourcesAreLocatedWithoutBundleModule() throws {
    let directory = try MetalKernelLibrary.kernelDirectory()
    for name in MetalKernelLibrary.sourceFiles {
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
    }
    XCTAssertFalse(MetalKernelLibrary.kernelDirectoryCandidates().isEmpty)
    XCTAssertFalse(try MetalKernelLibrary.source().isEmpty)
  }

  func testRecordedFailureSurfacesOnceAndSkipsDispatches() throws {
    let backend = try MetalBackend()  // private: the shared backend must not carry a failure into other cases
    let x = backend.tensor([1, 2, 3, 4], shape: [4])
    let one = backend.tensor([1, 1, 1, 1], shape: [4])
    XCTAssertEqual(backend.read(backend.add(x, one)), [2, 3, 4, 5])

    let before = backend.statistics.dispatches
    backend.recordFailure(MetalBackendFailure.injected("first"))
    backend.recordFailure(MetalBackendFailure.injected("second"))  // the first failure is the one reported
    let skipped = backend.add(x, one)
    XCTAssertEqual(skipped.shape, [4], "ops keep returning tensors of the right shape")
    XCTAssertEqual(backend.statistics.dispatches, before, "no dispatch is encoded while a failure is recorded")
    _ = backend.read(skipped)  // reaches the read without trapping; contents undefined
    XCTAssertEqual(backend.takeFailure() as? MetalBackendFailure, .injected("first"))
    XCTAssertNil(backend.takeFailure(), "taken once")
    XCTAssertEqual(backend.read(backend.add(x, one)), [2, 3, 4, 5], "the backend works again")

    // A failed allocation's placeholder: readable as zeros, never bound to a dispatch.
    let placeholder = backend.placeholderTensor(shape: [3, 5], type: .f32)
    XCTAssertFalse(placeholder.holdsData)
    XCTAssertEqual(backend.read(placeholder), [Float](repeating: 0, count: 15))
    let dispatches = backend.statistics.dispatches
    let sum = backend.add(placeholder, backend.tensor([Float](repeating: 1, count: 5), shape: [5]))
    XCTAssertEqual(sum.shape, [3, 5])
    XCTAssertEqual(backend.statistics.dispatches, dispatches)
    XCTAssertEqual(backend.takeFailure() as? MetalBackendFailure, .placeholderInUse)
    XCTAssertEqual(backend.rows(placeholder, 1..<2).shape, [1, 5], "views of a placeholder are placeholders")
    XCTAssertFalse(backend.rows(placeholder, 1..<2).holdsData)
  }

  /// Carries a tensor to the releasing thread; the pool is what makes a cross-thread release safe.
  private struct Handoff: @unchecked Sendable { let tensor: MetalTensor }

  /// Tensors dropped from another thread while the graph thread keeps allocating: the pool is locked, the
  /// counts stay consistent, and nothing freed early reaches the CPU.
  func testPoolSurvivesBackgroundRelease() throws {
    for split in [nil, 8] as [Int?] {
      let backend = try MetalBackend()
      backend.commandBufferSplit = split
      let pool = backend.pool
      let baseOutstanding = pool.outstanding
      let releases = DispatchQueue(label: "whisper.test.release")
      let group = DispatchGroup()
      var rng = Seeded(160)
      let x = rng.floats(4 * 32)
      let one = backend.tensor([Float](repeating: 1, count: 32), shape: [32])
      var t = backend.tensor(x, shape: [4, 32])
      var want = x
      for i in 0..<400 {
        let next = backend.add(t, one)
        let previous = t
        t = next
        want = want.map { $0 + 1 }
        // Hand the previous tensor to the background thread, which drops it at its own pace.
        group.enter()
        let handoff = Handoff(tensor: previous)
        releases.async {
          withExtendedLifetime(handoff.tensor) {}
          group.leave()
        }
        if i % 97 == 96 {
          XCTAssertEqual(backend.read(t), want, "split \(String(describing: split)) step \(i)")
        }
      }
      XCTAssertEqual(backend.read(t), want)
      group.wait()
      if let split {
        XCTAssertGreaterThanOrEqual(backend.statistics.commandBuffers, 400 / split, "the pass was split into command buffers")
      } else {
        XCTAssertEqual(backend.statistics.commandBuffers, 5, "one command buffer per read on macOS")
      }
      // Everything is settled: no command buffer is open or in flight, so nothing waits in `pending`; the live
      // tensors (t, one) account for every outstanding buffer; the rest is free.
      XCTAssertEqual(pool.pendingCount, 0)
      XCTAssertEqual(pool.outstanding - baseOutstanding, 2)
      XCTAssertEqual(pool.freeCount + pool.outstanding, pool.allocations)
      XCTAssertNil(backend.takeFailure())
    }
  }

  /// With the command buffer split on, uploads (CPU writes) in the middle of a pass must only take buffers that
  /// no in-flight command buffer can read: a buffer released into `pending` while its reader was still running
  /// must not be reused for a CPU write before that reader completes.
  func testCommandBufferSplitKeepsUploadsSafe() throws {
    let backend = try MetalBackend()
    backend.commandBufferSplit = 4
    var rng = Seeded(170)
    let x = rng.floats(64 * 64)
    var t = backend.tensor(x, shape: [64, 64])
    var want = x
    for step in 0..<64 {
      let delta = rng.floats(64)
      let d = backend.tensor(delta, shape: [64])  // a fresh upload per step; the previous one is released below
      t = backend.add(t, d)
      want = (0..<want.count).map { want[$0] + delta[$0 % 64] }
      if step % 7 == 6 {
        XCTAssertEqual(backend.read(t), want, "step \(step)")
      }
    }
    XCTAssertEqual(backend.read(t), want)
    XCTAssertGreaterThan(backend.statistics.commandBuffers, 10)
    XCTAssertEqual(backend.pool.pendingCount, 0)
    XCTAssertNil(backend.takeFailure())
  }
}
