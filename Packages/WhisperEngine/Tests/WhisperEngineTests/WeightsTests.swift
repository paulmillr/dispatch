import Foundation
import XCTest
@testable import WhisperEngine

final class WeightsTests: XCTestCase {
  func testHalfToFloat() {
    let bits: [UInt16] = [
      Half.one, Half.minusTwo, Half.half, Half.pointOne, Half.infinity, Half.smallestSubnormal, Half.zero,
      Half.minusZero, 0x3555, 0x7BFF,
    ]
    let floats = WeightDecoding.halfToFloat(Data(ModelFileWriter.halfBytes(bits)), count: bits.count)
    XCTAssertEqual(floats[0], 1)
    XCTAssertEqual(floats[1], -2)
    XCTAssertEqual(floats[2], 0.5)
    XCTAssertEqual(floats[3], 0.0999755859375)
    XCTAssertEqual(floats[4], .infinity)
    XCTAssertEqual(floats[5], 5.960464477539063e-08)
    XCTAssertEqual(floats[6], 0)
    XCTAssertEqual(floats[7], 0)
    XCTAssertEqual(floats[7].sign, .minus)
    XCTAssertEqual(floats[8], 0.333251953125)
    XCTAssertEqual(floats[9], 65504)
    XCTAssertEqual(WeightDecoding.halfToFloat(Data(), count: 0), [])
  }

  /// A NaN half decodes to a NaN float.
  func testHalfNaN() {
    let floats = WeightDecoding.halfToFloat(Data(ModelFileWriter.halfBytes([0x7E00])), count: 1)
    XCTAssertTrue(floats[0].isNaN)
  }

  func testDequantizeQ8_0() {
    let quants: [Int8] = (0..<32).map { Int8(truncatingIfNeeded: $0 * 8 - 127) }
    let bytes = ModelFileWriter.q8Bytes(blocks: [(Half.pointOne, quants), (Half.minusTwo, [Int8](repeating: 127, count: 32))])
    let floats = WeightDecoding.dequantizeQ8_0(Data(bytes), count: 64)
    XCTAssertEqual(floats.count, 64)
    for i in 0..<32 {
      XCTAssertEqual(floats[i], 0.0999755859375 * Float(quants[i]), accuracy: 1e-7)
    }
    XCTAssertEqual(Array(floats[32..<64]), [Float](repeating: -254, count: 32))
  }

  /// Decoding reads from a slice's own start, and from odd byte offsets (the file never aligns tensor data).
  func testDecodesUnalignedSlices() {
    var data = Data([0xFF])
    data.append(contentsOf: ModelFileWriter.f32Bytes([1.5, -3]))
    data.append(contentsOf: ModelFileWriter.halfBytes([Half.one, Half.half]))
    data.append(contentsOf: ModelFileWriter.q8Bytes(blocks: [(Half.one, (0..<32).map { Int8($0) })]))
    let f32 = data[1..<9]
    let f16 = data[9..<13]
    let q8 = data[13..<47]
    XCTAssertEqual(WeightDecoding.floats(f32, count: 2), [1.5, -3])
    XCTAssertEqual(WeightDecoding.halfToFloat(f16, count: 2), [1, 0.5])
    XCTAssertEqual(WeightDecoding.dequantizeQ8_0(q8, count: 32), (0..<32).map(Float.init))
    XCTAssertEqual(
      WeightTensor(name: "q", shape: [32], type: .q8_0, data: q8).floats(), (0..<32).map(Float.init))
    XCTAssertEqual(WeightTensor(name: "h", shape: [2], type: .f16, data: f16).floats(), [1, 0.5])
    XCTAssertEqual(WeightTensor(name: "f", shape: [2], type: .f32, data: f32).floats(), [1.5, -3])
  }

  /// A larger f16 and q8_0 run, to exercise whatever vector path vImage takes past a few elements.
  func testLongRuns() {
    let count = 32 * 300 + 0
    let bits = (0..<count).map { UInt16(0x3C00 + ($0 % 1024)) }
    let floats = WeightDecoding.halfToFloat(Data(ModelFileWriter.halfBytes(bits)), count: count)
    XCTAssertEqual(floats.count, count)
    XCTAssertEqual(floats[0], 1)
    XCTAssertEqual(floats[1024], 1)
    XCTAssertEqual(floats[512], 1.5)
    let blocks = (0..<300).map { block in (Half.half, (0..<32).map { Int8(truncatingIfNeeded: block + $0 - 64) }) }
    let q = WeightDecoding.dequantizeQ8_0(Data(ModelFileWriter.q8Bytes(blocks: blocks)), count: count)
    XCTAssertEqual(q.count, count)
    for block in 0..<300 {
      for i in 0..<32 {
        XCTAssertEqual(q[block * 32 + i], 0.5 * Float(Int8(truncatingIfNeeded: block + i - 64)))
      }
    }
  }
}
