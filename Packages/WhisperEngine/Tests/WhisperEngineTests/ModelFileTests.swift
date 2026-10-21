import Foundation
import XCTest
@testable import WhisperEngine

final class ModelFileTests: XCTestCase {
  /// A fictional model small enough to check every byte: f32, f16 and q8_0 tensors in one to four dims. The
  /// hyperparameters are the smallest `WhisperHyperparameters.validate` accepts (an English-only vocabulary must
  /// reach past `beg` = 50363, a text context must leave room for a token, the filterbank must have 201 bins).
  static let hyperparameters = WhisperHyperparameters(
    nVocab: 50364, nAudioContext: 8, nAudioState: 4, nAudioHead: 2, nAudioLayer: 1, nTextContext: 16, nTextState: 4,
    nTextHead: 2, nTextLayer: 1, nMels: 2, ftype: 1)
  static let filters = MelFilters(
    nMel: 2, nFFT: 201, data: (0..<2 * 201).map { Float($0 % 7) * 0.25 - 0.5 })
  static let fileTokens: [[UInt8]] = [
    Array("!".utf8), Array(" the".utf8), [], Array(" Hello".utf8), Array(" world".utf8), [0xC3], [0xA9],
    Array("<|x|>".utf8), Array("a".utf8), Array("b".utf8),
  ]
  static let f32Values: [Float] = [1, -2, 3.5, 0.25, 100, -0.001]
  static let halfBits: [UInt16] = [Half.one, Half.minusTwo, Half.half, Half.pointOne]
  static let q8Blocks: [(scale: UInt16, quants: [Int8])] = [
    (Half.half, (0..<32).map { Int8($0 - 16) }),
    (Half.minusTwo, (0..<32).map { Int8(truncatingIfNeeded: $0 * 8 - 128) }),
  ]

  /// File offsets of the int32 fields before the tensors: the eleven hyperparameters, the filterbank's two counts
  /// and the vocabulary count.
  static let hyperparameterOffsets = (0..<11).map { 4 + 4 * $0 }
  static let filterCountOffsets = [48, 52]
  static let vocabularyCountOffset = 56 + 2 * 201 * 4

  static func header() -> ModelFileWriter {
    var writer = ModelFileWriter()
    writer.magic()
    writer.hyperparameters(hyperparameters)
    writer.filters(filters)
    writer.vocabulary(fileTokens)
    return writer
  }

  static func syntheticFile(rawFType: Int32? = nil) -> Data {
    var writer = ModelFileWriter()
    writer.magic()
    writer.hyperparameters(hyperparameters, rawFType: rawFType)
    writer.filters(filters)
    writer.vocabulary(fileTokens)
    writer.tensor(name: "encoder.conv1.weight", ne: [3, 2, 1], type: .f32, bytes: ModelFileWriter.f32Bytes(f32Values))
    writer.tensor(name: "encoder.ln_post.bias", ne: [4], type: .f16, bytes: ModelFileWriter.halfBytes(halfBits))
    writer.tensor(
      name: "decoder.token_embedding.weight", ne: [32, 2], type: .q8_0, bytes: ModelFileWriter.q8Bytes(blocks: q8Blocks))
    writer.tensor(name: "four.dims", ne: [2, 1, 3, 1], type: .f32, bytes: ModelFileWriter.f32Bytes(f32Values))
    return writer.data
  }

  /// `data` with the little-endian int32 at `offset` replaced.
  static func patched(_ data: Data, at offset: Int, _ value: Int32) -> Data {
    var copy = data
    withUnsafeBytes(of: value.littleEndian) { copy.replaceSubrange(offset..<offset + 4, with: $0) }
    return copy
  }

  func testSyntheticRoundTrip() throws {
    let file = try WhisperModelFile.parse(Self.syntheticFile())

    XCTAssertEqual(file.hyperparameters, Self.hyperparameters)
    XCTAssertEqual(file.filters.nMel, 2)
    XCTAssertEqual(file.filters.nFFT, 201)
    XCTAssertEqual(file.filters.data, Self.filters.data)

    // The vocabulary is padded to n_vocab: generic names below the special ids, whisper.cpp's names at them.
    XCTAssertEqual(file.vocabulary.tokens.count, 50364)
    XCTAssertEqual(Array(file.vocabulary.tokens[0..<10]), Self.fileTokens)
    XCTAssertEqual(file.vocabulary.tokens[10], Array("[_extra_token_10]".utf8))
    XCTAssertEqual(file.vocabulary.tokens[11], Array("[_extra_token_11]".utf8))
    XCTAssertEqual(file.vocabulary.tokens[50256], Array("[_EOT_]".utf8))
    XCTAssertEqual(file.vocabulary.tokens[50363], Array("[_BEG_]".utf8))
    XCTAssertFalse(file.vocabulary.isMultilingual)
    XCTAssertEqual(file.vocabulary.eot, 50256)
    XCTAssertEqual(file.vocabulary.beg, 50363)
    XCTAssertNoThrow(try file.validate())

    XCTAssertEqual(file.tensors.count, 4)
    let conv = try file.tensor("encoder.conv1.weight")
    XCTAssertEqual(conv.shape, [1, 2, 3])
    XCTAssertEqual(conv.type, .f32)
    XCTAssertEqual([UInt8](conv.data), ModelFileWriter.f32Bytes(Self.f32Values))
    XCTAssertEqual(conv.floats(), Self.f32Values)

    let bias = try file.tensor("encoder.ln_post.bias")
    XCTAssertEqual(bias.shape, [4])
    XCTAssertEqual(bias.type, .f16)
    XCTAssertEqual([UInt8](bias.data), ModelFileWriter.halfBytes(Self.halfBits))
    XCTAssertEqual(bias.floats(), [1, -2, 0.5, 0.0999755859375])

    let embedding = try file.tensor("decoder.token_embedding.weight")
    XCTAssertEqual(embedding.shape, [2, 32])
    XCTAssertEqual(embedding.type, .q8_0)
    XCTAssertEqual(embedding.data.count, 68)
    let firstBlock: [Float] = (0..<32).map { Float($0 - 16) * 0.5 }
    let secondBlock: [Float] = (0..<32).map { Float($0 * 8 - 128) * -2 }
    let expected = firstBlock + secondBlock
    XCTAssertEqual(embedding.floats(), expected)

    let four = try file.tensor("four.dims")
    XCTAssertEqual(four.shape, [1, 3, 1, 2])
    XCTAssertEqual(four.floats(), Self.f32Values)

    XCTAssertThrowsError(try file.tensor("missing")) { error in
      XCTAssertEqual(error as? WhisperError, .missingTensor("missing"))
    }
  }

  /// Tensor slices share the file's buffer: no copy, and their `startIndex` is the file offset.
  func testTensorDataIsASliceOfTheFile() throws {
    let data = Self.syntheticFile()
    let file = try WhisperModelFile.parse(data)
    let conv = try file.tensor("encoder.conv1.weight")
    XCTAssertNotEqual(conv.data.startIndex, 0)
    XCTAssertEqual(data[conv.data.startIndex..<conv.data.endIndex], conv.data)
    // Decoding a slice must respect its start, not the buffer's.
    XCTAssertEqual(WeightDecoding.floats(conv.data, count: 6), Self.f32Values)
  }

  func testLoadFromDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-engine-\(UUID().uuidString).bin")
    try Self.syntheticFile().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try WhisperModelFile.load(url)
    XCTAssertEqual(file.hyperparameters, Self.hyperparameters)
    XCTAssertEqual(try file.tensor("four.dims").floats(), Self.f32Values)

    XCTAssertThrowsError(try WhisperModelFile.load(url.appendingPathExtension("absent")))
  }

  /// The real files' hyperparameters, filterbank and tensors pass `validate`, and the conv biases carry the
  /// [n_state, 1] shape the graph flattens.
  func testRealTinyValidates() throws {
    let file = try WhisperModelFile.load(try Self.modelURL("ggml-tiny.bin"))
    XCTAssertNoThrow(try file.validate())
    XCTAssertNoThrow(try file.hyperparameters.validate())
    XCTAssertEqual(try file.tensor("encoder.conv1.bias").shape, [384, 1])
    XCTAssertEqual(try file.tensor("encoder.conv2.bias").shape, [384, 1])
    XCTAssertEqual(try file.tensor("decoder.blocks.0.cross_attn.key.weight").shape, [384, 384])
    XCTAssertEqual(file.vocabulary.largestSpecialToken, 50364)
  }

  /// whisper.cpp keeps `ftype % 1000` (the quantization version lives in the thousands).
  func testFTypeDropsQuantizationVersion() throws {
    let file = try WhisperModelFile.parse(Self.syntheticFile(rawFType: 2001))
    XCTAssertEqual(file.hyperparameters.ftype, 1)
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.syntheticFile(rawFType: 2))) { error in
      XCTAssertEqual(error as? WhisperError, .unsupportedWeightType(2, tensor: "hparams.ftype"))
    }
  }

  func testBadMagic() {
    var writer = ModelFileWriter()
    writer.magic(0x4655_4747)  // "GGUF"
    writer.hyperparameters(Self.hyperparameters)
    XCTAssertThrowsError(try WhisperModelFile.parse(writer.data)) { error in
      XCTAssertEqual(error as? WhisperError, .badMagic(0x4655_4747))
    }
  }

  /// Every prefix of the file that ends inside a record throws `truncated` rather than crashing or returning a
  /// partial model, except for whisper.cpp's EOF quirk: under 12 trailing bytes after the last tensor are ignored.
  func testTruncatedFilesThrow() throws {
    let full = Self.syntheticFile()
    // The record boundaries: after the vocabulary and after each tensor.
    let vocabEnd = Self.header().data.count
    let boundaries = Set([vocabEnd] + Self.tensorEnds(in: full, from: vocabEnd))

    for cut in stride(from: 0, to: full.count, by: 1) where !boundaries.contains(cut) {
      let prefix = full.prefix(cut)
      // A cut within 12 bytes after a tensor boundary looks like EOF to whisper.cpp and to us.
      let afterBoundary = boundaries.contains { cut > $0 && cut - $0 < 12 }
      if afterBoundary {
        XCTAssertNoThrow(try WhisperModelFile.parse(prefix), "cut at \(cut)")
        continue
      }
      XCTAssertThrowsError(try WhisperModelFile.parse(prefix), "cut at \(cut)") { error in
        guard case .truncated = error as? WhisperError else {
          return XCTFail("cut at \(cut): \(error)")
        }
      }
    }
    // Cutting exactly at a tensor boundary yields the tensors so far.
    for boundary in boundaries {
      let file = try WhisperModelFile.parse(full.prefix(boundary))
      XCTAssertEqual(file.tensors.count, Self.tensorEnds(in: full, from: vocabEnd).filter { $0 <= boundary }.count)
    }
    XCTAssertEqual(try WhisperModelFile.parse(full).tensors.count, 4)
  }

  func testInvalidTensorHeadersThrow() {
    func file(_ patch: (inout ModelFileWriter) -> Void) -> Data {
      var writer = ModelFileWriter()
      writer.magic()
      writer.hyperparameters(Self.hyperparameters)
      writer.filters(Self.filters)
      writer.vocabulary(Self.fileTokens)
      patch(&writer)
      return writer.data
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(file { $0.tensor(name: "w", ne: [2, 1, 1, 1, 1], type: .f32, bytes: []) })) {
      XCTAssertEqual($0 as? WhisperError, .shapeMismatch("tensor n_dims 5"))
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(file { $0.int32(1); $0.int32(1); $0.int32(2); $0.int32(32); $0.bytes([0x77]) })) {
      XCTAssertEqual($0 as? WhisperError, .unsupportedWeightType(2, tensor: "w"))
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(file { $0.tensor(name: "q", ne: [33], type: .q8_0, bytes: []) })) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(file { $0.int32(1); $0.int32(1); $0.int32(0); $0.int32(-4); $0.bytes([0x77]) })) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    // whisper never writes a 0-D record or an empty axis; both are rejected so every shape is non-empty.
    XCTAssertThrowsError(try WhisperModelFile.parse(file { $0.tensor(name: "scalar", ne: [], type: .f32, bytes: ModelFileWriter.f32Bytes([7])) })) {
      XCTAssertEqual($0 as? WhisperError, .shapeMismatch("tensor n_dims 0"))
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(file { $0.tensor(name: "empty", ne: [4, 0], type: .f32, bytes: []) })) {
      XCTAssertEqual($0 as? WhisperError, .shapeMismatch("tensor ne[1] 0"))
    }
  }

  // MARK: - Corrupted files

  /// Every int32 header field (the eleven hyperparameters, the filterbank counts, the vocabulary count) set to
  /// zero, negative, huge and random out-of-range values: `parse` throws or, for the few values that are legal,
  /// returns a model; it never traps or allocates in proportion to the bogus value. The valid file still loads.
  func testCorruptHeaderFieldsThrowInsteadOfTrapping() throws {
    let valid = Self.syntheticFile()
    XCTAssertNoThrow(try WhisperModelFile.parse(valid))

    var rng = LinearCongruential(seed: 7)
    // Out of every field's range: above 1 << 17 (the vocabulary limit, the largest bound) or below zero.
    var values: [Int32] = [0, -1, Int32.max, Int32.min, 1 << 30, 1 << 17 + 1, 200_000]
    for _ in 0..<6 { values.append(Int32(200_000 + rng.next() % UInt32(Int32.max - 200_000))) }
    for _ in 0..<4 { values.append(-2 - Int32(rng.next() % 1_000_000)) }

    let fields: [(name: String, offset: Int)] =
      zip(["n_vocab", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer", "n_text_ctx", "n_text_state",
           "n_text_head", "n_text_layer", "n_mels", "ftype"], Self.hyperparameterOffsets).map { ($0, $1) }
      + [("filters.n_mel", Self.filterCountOffsets[0]), ("filters.n_fft", Self.filterCountOffsets[1]),
         ("vocab.n_vocab", Self.vocabularyCountOffset)]
    for field in fields {
      for value in values {
        let data = Self.patched(valid, at: field.offset, value)
        // ftype is reduced modulo 1000 and the engine's three types are fine; an empty file vocabulary is legal
        // (every token is then whisper.cpp's generated name) though the bytes that follow it are not tensors.
        let legal = (field.name == "ftype" && [0, 1, 7].contains(value % 1000))
          || (field.name == "vocab.n_vocab" && value == 0)
        if legal { continue }
        XCTAssertThrowsError(try WhisperModelFile.parse(data), "\(field.name) = \(value)") { error in
          XCTAssertNotNil(error as? WhisperError, "\(field.name) = \(value): \(error)")
        }
      }
    }
    // The legal exceptions parse or throw a WhisperError; either way no trap.
    XCTAssertEqual(try WhisperModelFile.parse(Self.patched(valid, at: Self.hyperparameterOffsets[10], 7)).hyperparameters.ftype, 7)
    XCTAssertEqual(try WhisperModelFile.parse(Self.patched(valid, at: Self.hyperparameterOffsets[10], 2000)).hyperparameters.ftype, 0)
    do {
      _ = try WhisperModelFile.parse(Self.patched(valid, at: Self.vocabularyCountOffset, 0))
    } catch {
      XCTAssertNotNil(error as? WhisperError)
    }
  }

  /// The vocabulary limits: an English-only layout needs 50364 tokens (through `beg`), a multilingual layout places
  /// `beg` 1501 below n_vocab, and nothing above 1 << 17 is a whisper model.
  func testVocabularyBounds() throws {
    let valid = Self.syntheticFile()
    let offset = Self.hyperparameterOffsets[0]
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: offset, 50363))) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    XCTAssertEqual(try WhisperModelFile.parse(Self.patched(valid, at: offset, 50364)).vocabulary.tokens.count, 50364)
    let multilingual = try WhisperModelFile.parse(Self.patched(valid, at: offset, 51865))
    XCTAssertTrue(multilingual.vocabulary.isMultilingual)
    XCTAssertEqual(multilingual.vocabulary.beg, 50364)
    XCTAssertEqual(multilingual.vocabulary.tokens.count, 51865)
    XCTAssertEqual(try WhisperModelFile.parse(Self.patched(valid, at: offset, 1 << 17)).vocabulary.tokens.count, 1 << 17)
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: offset, 1 << 17 + 1)))
    // A file vocabulary larger than n_vocab leaves tokens without logits.
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: offset, 5))) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    // A vocabulary count above n_vocab is rejected before anything is reserved (shapeMismatch); one the file
    // cannot hold within n_vocab is truncated; one token too many eats the first tensor record and fails there.
    for count: Int32 in [Int32.max, 1 << 30, 50365] {
      XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: Self.vocabularyCountOffset, count))) {
        guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("count \(count): \($0)") }
      }
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: Self.vocabularyCountOffset, 50_000))) {
      XCTAssertEqual($0 as? WhisperError, .truncated("vocab"))
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: Self.vocabularyCountOffset, 11))) {
      XCTAssertNotNil($0 as? WhisperError, "\($0)")
    }
  }

  /// `SpecialTokens` for every n_vocab the loader accepts stays inside the vocabulary.
  func testSpecialTokensFitEveryAcceptedVocabulary() {
    XCTAssertEqual(Vocabulary.SpecialTokens(nVocab: 50364).largest, 50363)
    XCTAssertEqual(Vocabulary.SpecialTokens(nVocab: 51864).beg, 50363)
    XCTAssertEqual(Vocabulary.SpecialTokens(nVocab: 51865).beg, 50364)
    XCTAssertEqual(Vocabulary.SpecialTokens(nVocab: 51866).beg, 50365)
    XCTAssertEqual(Vocabulary.SpecialTokens(nVocab: 51866).largest, 50365)
    for nVocab in [50364, 51864, 51865, 51866, 60000, 1 << 17] {
      XCTAssertLessThan(Vocabulary.SpecialTokens(nVocab: nVocab).largest, nVocab, "\(nVocab)")
    }
    XCTAssertGreaterThanOrEqual(Vocabulary.SpecialTokens(nVocab: 50363).largest, 50363)
    // No value of nVocab traps here (the file reader bounds it before building a vocabulary).
    _ = Vocabulary.SpecialTokens(nVocab: Int.max)
    _ = Vocabulary.SpecialTokens(nVocab: Int.min)
    _ = Vocabulary.whisper(fileTokens: [], nVocab: Int.min)
  }

  /// A tensor whose four int32 extents multiply past Int, or whose byte count does, throws before anything is read.
  func testTensorElementCountOverflowThrows() {
    func file(ne: [Int32], type: WeightType) -> Data {
      var writer = Self.header()
      writer.int32(Int32(ne.count))
      writer.int32(1)
      writer.int32(type.rawValue)
      for extent in ne { writer.int32(extent) }
      writer.bytes([0x77])
      writer.bytes([UInt8](repeating: 0, count: 64))
      return writer.data
    }
    for (ne, type): ([Int32], WeightType) in [
      ([Int32.max, Int32.max, Int32.max, 2], .f32), ([Int32.max, Int32.max, Int32.max, Int32.max], .f16),
      ([1 << 30, 1 << 30, 1 << 30, 1 << 30], .q8_0), ([Int32.max, Int32.max, 2, 1], .f32),
      ([Int32.max, Int32.max, 4, 1], .f16), ([1 << 30, 1 << 30, 1 << 2, 1 << 1], .f32),
    ] {
      XCTAssertThrowsError(try WhisperModelFile.parse(file(ne: ne, type: type)), "\(ne) \(type)") {
        guard let error = $0 as? WhisperError else { return XCTFail("\($0)") }
        switch error {
        case .shapeMismatch, .truncated: break
        default: XCTFail("\(ne) \(type): \(error)")
        }
      }
    }
  }

  /// A 4-D tensor whose extents are fine individually but describe more bytes than the file holds throws
  /// `truncated`, from the element count alone, before the byte count is formed.
  func testTensorLargerThanTheFileThrows() {
    var writer = Self.header()
    writer.tensor(name: "big", ne: [1000, 1000, 1000, 1], type: .f32, bytes: [UInt8](repeating: 0, count: 4096))
    XCTAssertThrowsError(try WhisperModelFile.parse(writer.data)) {
      XCTAssertEqual($0 as? WhisperError, .truncated("big data"))
    }
    var halves = Self.header()
    halves.tensor(name: "big.f16", ne: [2048, 2048, 64, 1], type: .f16, bytes: [UInt8](repeating: 0, count: 4096))
    XCTAssertThrowsError(try WhisperModelFile.parse(halves.data)) {
      XCTAssertEqual($0 as? WhisperError, .truncated("big.f16 data"))
    }
  }

  /// The filterbank must be the model's `n_mels` x 201; a mismatch is a loader error, not a mel-time trap.
  func testFilterbankShapeIsChecked() {
    let valid = Self.syntheticFile()
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: Self.filterCountOffsets[1], 200))) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: Self.filterCountOffsets[0], 3))) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try WhisperModelFile.parse(Self.patched(valid, at: Self.hyperparameterOffsets[9], 3))) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
  }

  /// `validate` on a parsed file that was altered in memory: the hyperparameters, filterbank, vocabulary and every
  /// tensor's bytes are checked again.
  func testValidateRejectsInMemoryCorruption() throws {
    let file = try WhisperModelFile.parse(Self.syntheticFile())
    XCTAssertNoThrow(try file.validate())

    var heads = file
    heads.hyperparameters.nAudioHead = 0
    XCTAssertThrowsError(try heads.validate())
    heads.hyperparameters.nAudioHead = 3
    XCTAssertThrowsError(try heads.validate())
    var context = file
    context.hyperparameters.nTextContext = 8
    XCTAssertThrowsError(try context.validate())
    context.hyperparameters.nTextContext = 16
    context.hyperparameters.nAudioContext = 1501
    XCTAssertThrowsError(try context.validate())

    var filters = file
    filters.filters.data.removeLast()
    XCTAssertThrowsError(try filters.validate())

    var vocabulary = file
    vocabulary.vocabulary.tokens.removeLast()
    XCTAssertThrowsError(try vocabulary.validate())
    vocabulary = file
    vocabulary.vocabulary.beg = 50364
    XCTAssertThrowsError(try vocabulary.validate())

    var tensor = file
    tensor.tensors["encoder.conv1.weight"]!.shape = [1, 2, 4]
    XCTAssertThrowsError(try tensor.validate())
    tensor = file
    tensor.tensors["encoder.conv1.weight"]!.data = tensor.tensors["encoder.conv1.weight"]!.data.prefix(8)
    XCTAssertThrowsError(try tensor.validate())
    tensor = file
    tensor.tensors["decoder.token_embedding.weight"]!.shape = [2, 33]
    XCTAssertThrowsError(try tensor.validate())
    tensor = file
    tensor.tensors["four.dims"]!.shape = [1, 3, 1, 2, 1]
    XCTAssertThrowsError(try tensor.validate())
    tensor = file
    tensor.tensors["four.dims"]!.shape = [Int.max, 3, 1, 2]
    XCTAssertThrowsError(try tensor.validate())
  }

  /// Walks the tensor records of a complete file and returns the offset just past each one.
  static func tensorEnds(in data: Data, from start: Int) -> [Int] {
    var reader = ByteReader(data[start...])
    var ends = [Int]()
    while reader.remaining >= 12 {
      let nDims = Int(try! reader.int32(""))
      let nameLength = Int(try! reader.int32(""))
      let type = WeightType(rawValue: try! reader.int32(""))!
      var elements = 1
      for _ in 0..<nDims { elements *= Int(try! reader.int32("")) }
      _ = try! reader.bytes(nameLength, "")
      _ = try! reader.bytes(type.byteCount(elements: elements), "")
      ends.append(reader.offset)
    }
    return ends
  }

  // MARK: - Real models

  static func modelURL(_ name: String) throws -> URL {
    guard let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"] else {
      throw XCTSkip("DISPATCH_WHISPER_MODELS is unset")
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(url.path) is missing") }
    return url
  }

  func testRealTinyF16() throws {
    let file = try WhisperModelFile.load(try Self.modelURL("ggml-tiny.bin"))
    try checkTiny(file, ftype: 1)
    // ggml-tiny.bin is the f16 conversion: the big matrices are f16, biases and norms f32.
    XCTAssertEqual(try file.tensor("decoder.token_embedding.weight").type, .f16)
    XCTAssertEqual(try file.tensor("encoder.conv1.weight").type, .f16)
    XCTAssertEqual(try file.tensor("encoder.conv1.bias").type, .f32)
    let embedding = try file.tensor("decoder.token_embedding.weight").floats()
    XCTAssertEqual(embedding.count, 51865 * 384)
    XCTAssertTrue(embedding.allSatisfy(\.isFinite))
  }

  func testRealTinyQ8() throws {
    let file = try WhisperModelFile.load(try Self.modelURL("ggml-tiny-q8_0.bin"))
    try checkTiny(file, ftype: 7)
    let embedding = try file.tensor("decoder.token_embedding.weight")
    XCTAssertEqual(embedding.type, .q8_0)
    XCTAssertEqual(embedding.data.count, 51865 * 384 / 32 * 34)
    // The quantizer keeps convolutions in f16 (whisper.cpp's `vtype`) and 1-D tensors in f32.
    XCTAssertEqual(try file.tensor("encoder.conv1.weight").type, .f16)
    XCTAssertEqual(try file.tensor("encoder.conv1.bias").type, .f32)
    let values = embedding.floats()
    XCTAssertEqual(values.count, 51865 * 384)
    let sum = values.reduce(0, +)
    XCTAssertTrue(sum.isFinite, "sum \(sum)")
    XCTAssertNotEqual(sum, 0)
  }

  /// The q8_0 embedding is ggml's quantization of the f16 one: dequantizing must land within a block's step of it.
  func testRealTinyQ8MatchesF16() throws {
    let f16 = try WhisperModelFile.load(try Self.modelURL("ggml-tiny.bin"))
    let q8 = try WhisperModelFile.load(try Self.modelURL("ggml-tiny-q8_0.bin"))
    for name in ["decoder.token_embedding.weight", "encoder.blocks.0.attn.query.weight"] {
      let reference = try f16.tensor(name).floats()
      let quantized = try q8.tensor(name).floats()
      XCTAssertEqual(reference.count, quantized.count)
      var worst: Float = 0
      for block in stride(from: 0, to: reference.count, by: 32) {
        let amax = reference[block..<block + 32].map(abs).max()!
        let step = amax / 127
        for i in block..<block + 32 {
          worst = max(worst, abs(reference[i] - quantized[i]) / max(step, 1e-6))
        }
      }
      // Half a step of rounding, plus the half-precision scale's own rounding.
      XCTAssertLessThan(worst, 0.6, "\(name): worst error \(worst) quantization steps")
    }
  }

  func testRealTinyVocabularyText() throws {
    let file = try WhisperModelFile.load(try Self.modelURL("ggml-tiny.bin"))
    let vocabulary = file.vocabulary
    let hello = Int32(try XCTUnwrap(vocabulary.tokens.firstIndex(of: Array(" Hello".utf8))))
    let world = Int32(try XCTUnwrap(vocabulary.tokens.firstIndex(of: Array(" world".utf8))))
    // whisper.cpp keeps the token's leading space; the app's `clean` trims it afterwards.
    XCTAssertEqual(vocabulary.text([hello, world]), " Hello world")
    XCTAssertEqual(vocabulary.text([vocabulary.sot, vocabulary.sotLanguage, vocabulary.transcribe, vocabulary.not, hello, world, vocabulary.eot]), " Hello world")
    XCTAssertEqual(vocabulary.text([vocabulary.beg + 10, hello, vocabulary.beg + 20]), " Hello")
    XCTAssertEqual(WhisperText.token(vocabulary.sot, vocabulary: vocabulary), "[_SOT_]")
    XCTAssertEqual(vocabulary.languageToken("en"), 50259)
    XCTAssertEqual(vocabulary.languageCode(50259), "en")
    XCTAssertEqual(WhisperText.token(50259, vocabulary: vocabulary), "[_LANG_en]")
    XCTAssertEqual(WhisperText.token(vocabulary.beg + 1, vocabulary: vocabulary), "[_TT_1]")
  }

  private func checkTiny(_ file: WhisperModelFile, ftype: Int) throws {
    let h = file.hyperparameters
    XCTAssertEqual(
      h,
      WhisperHyperparameters(
        nVocab: 51865, nAudioContext: 1500, nAudioState: 384, nAudioHead: 6, nAudioLayer: 4, nTextContext: 448,
        nTextState: 384, nTextHead: 6, nTextLayer: 4, nMels: 80, ftype: ftype))
    XCTAssertTrue(h.isMultilingual)
    XCTAssertEqual(file.filters.nMel, 80)
    XCTAssertEqual(file.filters.nFFT, 201)
    XCTAssertEqual(file.filters.data.count, 80 * 201)
    XCTAssertTrue(file.filters.data.allSatisfy { $0.isFinite && $0 >= 0 })

    // 7 encoder + 15 per audio layer + 4 decoder + 24 per text layer.
    XCTAssertEqual(file.tensors.count, 7 + 15 * 4 + 4 + 24 * 4)
    XCTAssertEqual(try file.tensor("encoder.conv1.weight").shape, [384, 80, 3])
    XCTAssertEqual(try file.tensor("encoder.conv2.weight").shape, [384, 384, 3])
    XCTAssertEqual(try file.tensor("encoder.positional_embedding").shape, [1500, 384])
    XCTAssertEqual(try file.tensor("decoder.positional_embedding").shape, [448, 384])
    XCTAssertEqual(try file.tensor("decoder.token_embedding.weight").shape, [51865, 384])
    XCTAssertEqual(try file.tensor("decoder.blocks.3.cross_attn.value.weight").shape, [384, 384])
    XCTAssertEqual(try file.tensor("encoder.blocks.0.mlp.0.weight").shape, [1536, 384])
    XCTAssertEqual(try file.tensor("encoder.ln_post.bias").shape, [384])
    XCTAssertEqual(try file.tensor("encoder.positional_embedding").type, .f32)

    // The file stores 50257 words; whisper.cpp names the remaining 1608 itself, so eot is "[_EOT_]" rather than
    // "<|endoftext|>" (the file's word 50256 is empty).
    let vocabulary = file.vocabulary
    XCTAssertEqual(vocabulary.tokens.count, 51865)
    XCTAssertEqual(vocabulary.eot, 50257)
    XCTAssertEqual(vocabulary.sot, 50258)
    XCTAssertEqual(vocabulary.sotLanguage, 50259)
    XCTAssertEqual(vocabulary.translate, 50358)
    XCTAssertEqual(vocabulary.transcribe, 50359)
    XCTAssertEqual(vocabulary.solm, 50360)
    XCTAssertEqual(vocabulary.prev, 50361)
    XCTAssertEqual(vocabulary.nosp, 50362)
    XCTAssertEqual(vocabulary.not, 50363)
    XCTAssertEqual(vocabulary.beg, 50364)
    XCTAssertEqual(vocabulary.tokens[Int(vocabulary.eot)], Array("[_EOT_]".utf8))
    XCTAssertEqual(vocabulary.tokens[50256], [])
    XCTAssertEqual(vocabulary.tokens[220], [0x20])
    XCTAssertEqual(vocabulary.tokens[Int(vocabulary.beg)], Array("[_BEG_]".utf8))
    XCTAssertEqual(vocabulary.tokens[51864], Array("[_TT_1500]".utf8))
  }
}

/// A small deterministic generator for the corruption sweep (no dependence on the other test files' helpers).
struct LinearCongruential {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt32 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return UInt32(truncatingIfNeeded: state >> 33)
  }
}
