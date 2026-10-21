import Foundation
import XCTest

@testable import WhisperEngine

/// Every CPU op against a naive loop on small seeded inputs. The loops are the spec (`Contracts.swift`'s wording);
/// the backend's Accelerate calls must agree to Float32 rounding.
final class CPUBackendTests: XCTestCase {
  private let backend = CPUBackend()

  // MARK: Upload

  func testWeightUploadDecodesF32F16AndQ8() throws {
    var rng = SeededRandom(seed: 11)
    let values = (0..<64).map { _ in rng.uniform(-3, 3) }
    let f32 = WeightTensor(name: "w", shape: [2, 32], type: .f32, data: floatData(values))
    XCTAssertEqual(try backend.read(backend.weight(f32)), values)

    let halves = values.map { CPUDequantize.half($0) }
    let f16 = WeightTensor(name: "w", shape: [2, 32], type: .f16, data: Data(halves.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }))
    let decoded = try backend.read(backend.weight(f16))
    for (a, b) in zip(decoded, values) { XCTAssertEqual(a, b, accuracy: 3 * abs(b) / 1024) }

    let (q8, dequantized) = quantizeQ8(values)
    let q = WeightTensor(name: "w", shape: [2, 32], type: .q8_0, data: q8)
    XCTAssertEqual(try backend.read(backend.weight(q)), dequantized)
    for (a, b) in zip(dequantized, values) { XCTAssertEqual(a, b, accuracy: 0.02) }

    let short = WeightTensor(name: "w", shape: [2, 32], type: .q8_0, data: q8.prefix(40))
    XCTAssertThrowsError(try backend.weight(short))
  }

  func testHalfConversionRoundTripsAndRoundsToNearestEven() {
    for bits in stride(from: UInt16(0), through: 0x7bff, by: 7) {
      let value = CPUDequantize.float(half: bits)
      XCTAssertEqual(CPUDequantize.half(value), bits)
      XCTAssertEqual(CPUDequantize.half(-value), bits | 0x8000)
    }
    XCTAssertEqual(CPUDequantize.float(half: 0x3c00), 1)
    XCTAssertEqual(CPUDequantize.float(half: 0x0001), Float(bitPattern: 0x3380_0000))  // smallest subnormal, 2^-24
    XCTAssertEqual(CPUDequantize.float(half: 0x7c00), .infinity)
    XCTAssertTrue(CPUDequantize.float(half: 0x7e00).isNaN)
    XCTAssertEqual(CPUDequantize.half(1 + 1.0 / 2048), 0x3c00)  // tie -> even
    XCTAssertEqual(CPUDequantize.half(1 + 3.0 / 2048), 0x3c02)  // tie -> even
    XCTAssertEqual(CPUDequantize.half(1 + 1.1 / 2048), 0x3c01)
    XCTAssertEqual(CPUDequantize.half(70000), 0x7c00)
    XCTAssertEqual(CPUDequantize.half(1e-9), 0)
    #if arch(arm64)
      var rng = SeededRandom(seed: 5)
      for _ in 0..<2000 {
        let v = rng.uniform(-1, 1) * Float(rng.uniform(0, 1) < 0.5 ? 1 : 1e-4)
        XCTAssertEqual(CPUDequantize.half(v), Float16(v).bitPattern, "\(v)")
      }
    #endif
  }

  // MARK: Ops

  func testConv1dStride1And2() {
    var rng = SeededRandom(seed: 1)
    let cin = 5, len = 11, cout = 4, kernel = 3
    let x = rng.array(cin * len), w = rng.array(cout * cin * kernel), bias = rng.array(cout)
    let xt = backend.tensor(x, shape: [cin, len])
    let wt = backend.tensor(w, shape: [cout, cin, kernel])
    let bt = backend.tensor(bias, shape: [cout])
    for (stride, padding) in [(1, 1), (2, 1), (2, 0), (3, 2)] {
      let out = backend.conv1d(xt, weight: wt, bias: bt, stride: stride, padding: padding)
      let outLen = (len + 2 * padding - kernel) / stride + 1
      XCTAssertEqual(out.shape, [cout, outLen])
      var expected = [Float](repeating: 0, count: cout * outLen)
      for c in 0..<cout {
        for o in 0..<outLen {
          var sum = bias[c]
          for ci in 0..<cin {
            for t in 0..<kernel {
              let i = o * stride + t - padding
              if i >= 0 && i < len { sum += w[(c * cin + ci) * kernel + t] * x[ci * len + i] }
            }
          }
          expected[c * outLen + o] = sum
        }
      }
      assertClose(backend.read(out), expected, "stride \(stride) padding \(padding)")
    }
  }

  func testLinearWithAndWithoutBias() {
    var rng = SeededRandom(seed: 2)
    let n = 7, input = 6, output = 5
    let x = rng.array(n * input), w = rng.array(output * input), bias = rng.array(output)
    let xt = backend.tensor(x, shape: [n, input]), wt = backend.tensor(w, shape: [output, input])
    var expected = [Float](repeating: 0, count: n * output)
    for i in 0..<n {
      for o in 0..<output {
        var sum: Float = 0
        for k in 0..<input { sum += x[i * input + k] * w[o * input + k] }
        expected[i * output + o] = sum
      }
    }
    let plain = backend.linear(xt, weight: wt, bias: nil)
    XCTAssertEqual(plain.shape, [n, output])
    assertClose(backend.read(plain), expected)
    let biased = backend.linear(xt, weight: wt, bias: backend.tensor(bias, shape: [output]))
    assertClose(backend.read(biased), expected.enumerated().map { $1 + bias[$0 % output] })
  }

  func testLayerNormMatchesGgmlNorm() {
    var rng = SeededRandom(seed: 3)
    let n = 4, d = 9, eps: Float = 1e-5
    let x = rng.array(n * d).map { $0 * 4 + 1 }, w = rng.array(d), b = rng.array(d)
    let out = backend.layerNorm(
      backend.tensor(x, shape: [n, d]), weight: backend.tensor(w, shape: [d]), bias: backend.tensor(b, shape: [d]),
      epsilon: eps)
    XCTAssertEqual(out.shape, [n, d])
    var expected = [Float](repeating: 0, count: n * d)
    for i in 0..<n {
      let row = Array(x[i * d..<(i + 1) * d])
      let mean = row.reduce(0, +) / Float(d)
      let variance = row.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(d)
      let scale = 1 / (variance + eps).squareRoot()
      for j in 0..<d { expected[i * d + j] = (row[j] - mean) * scale * w[j] + b[j] }
    }
    assertClose(backend.read(out), expected)
  }

  func testAddBroadcastsSuffixShapes() {
    var rng = SeededRandom(seed: 4)
    let a = rng.array(2 * 3 * 4)
    let at = backend.tensor(a, shape: [2, 3, 4])
    let same = rng.array(a.count)
    assertClose(backend.read(backend.add(at, backend.tensor(same, shape: [2, 3, 4]))), zip(a, same).map(+))
    let row = rng.array(4)
    assertClose(backend.read(backend.add(at, backend.tensor(row, shape: [4]))), a.enumerated().map { $1 + row[$0 % 4] })
    let plane = rng.array(12)
    assertClose(backend.read(backend.add(at, backend.tensor(plane, shape: [3, 4]))), a.enumerated().map { $1 + plane[$0 % 12] })
    XCTAssertEqual(backend.add(at, backend.tensor(row, shape: [4])).shape, [2, 3, 4])
  }

  func testGeluIsGgmlTanhApproximation() {
    let xs: [Float] = [-12, -4, -1.5, -0.5, -1e-3, 0, 1e-3, 0.5, 1.5, 4, 12]
    let out = backend.read(backend.gelu(backend.tensor(xs, shape: [xs.count])))
    for (x, y) in zip(xs, out) {
      let inner = 0.7978845608028654 * (Double(x) + 0.044715 * Double(x) * Double(x) * Double(x))
      let expected = Float(0.5 * Double(x) * (1 + tanh(inner)))
      XCTAssertEqual(y, expected, accuracy: 1e-5 + abs(expected) * 2e-6, "gelu(\(x))")
    }
    XCTAssertEqual(out[0], 0)
    XCTAssertEqual(out.last, 12)
  }

  func testTranspose() {
    let x: [Float] = [1, 2, 3, 4, 5, 6]
    let t = backend.transpose(backend.tensor(x, shape: [2, 3]))
    XCTAssertEqual(t.shape, [3, 2])
    XCTAssertEqual(backend.read(t), [1, 4, 2, 5, 3, 6])
  }

  func testAttentionNonCausalAndCausalWithPast() {
    var rng = SeededRandom(seed: 6)
    let heads = 2, d = 8, nq = 3
    for (nk, causal) in [(3, false), (7, false), (7, true), (3, true)] {
      let q = rng.array(nq * d), k = rng.array(nk * d), v = rng.array(nk * d)
      let scale: Float = 0.7
      let out = backend.attention(
        query: backend.tensor(q, shape: [nq, d]), key: backend.tensor(k, shape: [nk, d]),
        value: backend.tensor(v, shape: [nk, d]), heads: heads, scale: scale, causal: causal)
      XCTAssertEqual(out.shape, [nq, d])
      assertClose(backend.read(out), naiveAttention(q: q, k: k, v: v, nq: nq, nk: nk, d: d, heads: heads, scale: scale, causal: causal), "nk \(nk) causal \(causal)")
    }
  }

  func testCausalAttentionMaskEqualsWhisperKQMask() {
    // Query i at absolute position past + i sees keys 0 ... past + i: the output of the batch must equal what the
    // same queries get when the later keys are not there at all.
    var rng = SeededRandom(seed: 7)
    let heads = 2, d = 4, past = 4, nq = 3, nk = past + nq
    let q = rng.array(nq * d), k = rng.array(nk * d), v = rng.array(nk * d)
    let batch = backend.read(
      backend.attention(
        query: backend.tensor(q, shape: [nq, d]), key: backend.tensor(k, shape: [nk, d]),
        value: backend.tensor(v, shape: [nk, d]), heads: heads, scale: 1, causal: true))
    for i in 0..<nq {
      let visible = past + i + 1
      let single = backend.read(
        backend.attention(
          query: backend.tensor(Array(q[i * d..<(i + 1) * d]), shape: [1, d]),
          key: backend.tensor(Array(k[0..<visible * d]), shape: [visible, d]),
          value: backend.tensor(Array(v[0..<visible * d]), shape: [visible, d]), heads: heads, scale: 1, causal: false))
      assertClose(Array(batch[i * d..<(i + 1) * d]), single, "query \(i)")
    }
  }

  func testEmbeddingFromQ8Table() throws {
    var rng = SeededRandom(seed: 8)
    let vocab = 6, d = 64
    let values = rng.array(vocab * d).map { $0 * 2 }
    let (q8, dequantized) = quantizeQ8(values)
    let table = try backend.weight(WeightTensor(name: "decoder.token_embedding.weight", shape: [vocab, d], type: .q8_0, data: q8))
    let ids: [Int32] = [5, 0, 2, 2]
    let out = backend.embedding(table, ids: ids)
    XCTAssertEqual(out.shape, [ids.count, d])
    XCTAssertEqual(backend.read(out), ids.flatMap { Array(dequantized[Int($0) * d..<(Int($0) + 1) * d]) })
  }

  func testRowsAndCacheWrite() {
    let x = backend.tensor((0..<12).map(Float.init), shape: [4, 3])
    let slice = backend.rows(x, 1..<3)
    XCTAssertEqual(slice.shape, [2, 3])
    XCTAssertEqual(backend.read(slice), [3, 4, 5, 6, 7, 8])

    let cache = backend.cache(capacity: 5, width: 3)
    XCTAssertEqual(cache.shape, [5, 3])
    XCTAssertEqual(backend.read(cache), [Float](repeating: 0, count: 15))
    backend.write(slice, into: cache, at: 2)
    XCTAssertEqual(backend.read(cache), [0, 0, 0, 0, 0, 0, 3, 4, 5, 6, 7, 8, 0, 0, 0])
    backend.write(backend.tensor([9, 9, 9], shape: [1, 3]), into: cache, at: 0)
    XCTAssertEqual(backend.read(backend.rows(cache, 0..<1)), [9, 9, 9])
    XCTAssertEqual(backend.read(slice), [3, 4, 5, 6, 7, 8], "writing into the cache leaves the source alone")
  }

  // MARK: Helpers

  private func naiveAttention(q: [Float], k: [Float], v: [Float], nq: Int, nk: Int, d: Int, heads: Int, scale: Float, causal: Bool) -> [Float] {
    let hd = d / heads
    var out = [Float](repeating: 0, count: nq * d)
    for h in 0..<heads {
      for i in 0..<nq {
        var scores = [Float](repeating: -.infinity, count: nk)
        for j in 0..<nk where !causal || j <= i + nk - nq {
          var dot: Float = 0
          for c in 0..<hd { dot += q[i * d + h * hd + c] * k[j * d + h * hd + c] }
          scores[j] = dot * scale
        }
        let maximum = scores.max()!
        let weights = scores.map { exp($0 - maximum) }
        let sum = weights.reduce(0, +)
        for c in 0..<hd {
          var acc: Float = 0
          for j in 0..<nk { acc += weights[j] / sum * v[j * d + h * hd + c] }
          out[i * d + h * hd + c] = acc
        }
      }
    }
    return out
  }

  private func assertClose(_ got: [Float], _ expected: [Float], _ label: String = "", tolerance: Float = 1e-5, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(got.count, expected.count, label, file: file, line: line)
    for (i, (a, b)) in zip(got, expected).enumerated() {
      XCTAssertEqual(a, b, accuracy: tolerance + abs(b) * tolerance, "\(label) [\(i)]", file: file, line: line)
    }
  }
}

// MARK: - Shared test helpers

/// SplitMix64: a small deterministic generator so every test input is reproducible.
struct SeededRandom {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }

  mutating func uniform(_ low: Float, _ high: Float) -> Float {
    low + (high - low) * Float(next() >> 40) / Float(1 << 24)
  }

  mutating func array(_ count: Int, _ low: Float = -1, _ high: Float = 1) -> [Float] {
    (0..<count).map { _ in uniform(low, high) }
  }
}

func floatData(_ values: [Float]) -> Data {
  values.withUnsafeBufferPointer { Data(buffer: $0) }
}

/// `quantize_row_q8_0_ref`: per 32-value block d = amax / 127 (stored as f16), q = round(x / d). Returns the bytes and
/// what `dequantize_row_q8_0` gives back for them (using the f16-rounded scale, as ggml does).
func quantizeQ8(_ values: [Float]) -> (Data, [Float]) {
  precondition(values.count % 32 == 0)
  var bytes = [UInt8]()
  var dequantized = [Float]()
  for block in stride(from: 0, to: values.count, by: 32) {
    let chunk = values[block..<block + 32]
    let amax = chunk.map { abs($0) }.max()!
    let d = amax / 127
    let id: Float = d != 0 ? 1 / d : 0
    let half = CPUDequantize.half(d)
    bytes.append(UInt8(half & 0xff))
    bytes.append(UInt8(half >> 8))
    let scale = CPUDequantize.float(half: half)
    for x in chunk {
      let q = Int8((x * id).rounded(.toNearestOrAwayFromZero))
      bytes.append(UInt8(bitPattern: q))
      dequantized.append(Float(q) * scale)
    }
  }
  return (Data(bytes), dequantized)
}
