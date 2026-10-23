import Foundation
@testable import WhisperEngine

/// Writes whisper ggml model files the way whisper.cpp's converter does (little-endian, unaligned), so the tests can
/// build small fictional models and check the reader field by field.
struct ModelFileWriter {
  var data = Data()

  mutating func uint32(_ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func int32(_ value: Int32) { uint32(UInt32(bitPattern: value)) }

  mutating func float(_ value: Float) { uint32(value.bitPattern) }

  mutating func half(_ bits: UInt16) {
    withUnsafeBytes(of: bits.littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func bytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }

  mutating func magic(_ value: UInt32 = WhisperModelFile.magic) { uint32(value) }

  mutating func hyperparameters(_ h: WhisperHyperparameters, rawFType: Int32? = nil) {
    for value in [
      h.nVocab, h.nAudioContext, h.nAudioState, h.nAudioHead, h.nAudioLayer, h.nTextContext, h.nTextState,
      h.nTextHead, h.nTextLayer, h.nMels,
    ] {
      int32(Int32(value))
    }
    int32(rawFType ?? Int32(h.ftype))
  }

  mutating func filters(_ filters: MelFilters) {
    int32(Int32(filters.nMel))
    int32(Int32(filters.nFFT))
    for value in filters.data { float(value) }
  }

  mutating func vocabulary(_ tokens: [[UInt8]]) {
    int32(Int32(tokens.count))
    for token in tokens {
      uint32(UInt32(token.count))
      bytes(token)
    }
  }

  /// A tensor record: `ne` in ggml order (ne[0] contiguous), then the raw bytes.
  mutating func tensor(name: String, ne: [Int], type: WeightType, bytes payload: [UInt8]) {
    int32(Int32(ne.count))
    int32(Int32(name.utf8.count))
    int32(type.rawValue)
    for extent in ne { int32(Int32(extent)) }
    bytes(Array(name.utf8))
    bytes(payload)
  }

  static func f32Bytes(_ values: [Float]) -> [UInt8] {
    var out = [UInt8]()
    for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
    return out
  }

  static func halfBytes(_ bits: [UInt16]) -> [UInt8] {
    var out = [UInt8]()
    for value in bits { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
    return out
  }

  /// q8_0 blocks: a half scale then 32 signed quants each.
  static func q8Bytes(blocks: [(scale: UInt16, quants: [Int8])]) -> [UInt8] {
    var out = [UInt8]()
    for block in blocks {
      precondition(block.quants.count == 32)
      out.append(contentsOf: halfBytes([block.scale]))
      out.append(contentsOf: block.quants.map { UInt8(bitPattern: $0) })
    }
    return out
  }
}

/// IEEE half bit patterns used by the tests, written out so no test depends on `Float16` (unavailable on x86_64 macOS).
enum Half {
  static let one: UInt16 = 0x3C00
  static let half: UInt16 = 0x3800
  static let minusTwo: UInt16 = 0xC000
  static let pointOne: UInt16 = 0x2E66  // 0.0999755859375
  static let infinity: UInt16 = 0x7C00
  static let smallestSubnormal: UInt16 = 0x0001  // 2^-24
  static let zero: UInt16 = 0x0000
  static let minusZero: UInt16 = 0x8000
}
