import Foundation
import XCTest

@testable import WhisperEngine

/// `WhisperModel` over the CPU backend on the real tiny models. Needs `DISPATCH_WHISPER_MODELS` (a directory holding
/// `ggml-tiny.bin` and `ggml-tiny-q8_0.bin`); skipped otherwise. Parity with whisper.cpp itself is checked in
/// Packages/Dictation's `WhisperParityTests`.
final class ModelTests: XCTestCase {
  private static let modelCache = ModelCache()

  private func loadTiny(_ name: String = "ggml-tiny.bin") throws -> WhisperModelFile {
    guard let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"] else {
      throw XCTSkip("DISPATCH_WHISPER_MODELS is not set")
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(url.path) is missing") }
    return try Self.modelCache.file(at: url)
  }

  /// A deterministic mel in whisper's normalised range (log-mel clamped to [max - 8, max], then (x + 4) / 4, so
  /// roughly [-1, 1]): a seeded pattern with some band structure, 80 x 3000.
  private func syntheticMel(frames: Int = 3000) -> MelSpectrogram {
    var rng = SeededRandom(seed: 99)
    var data = [Float](repeating: 0, count: 80 * frames)
    for band in 0..<80 {
      for frame in 0..<frames {
        let tone = 0.5 * sin(Float(frame) / 37 + Float(band) / 11) * exp(-Float(band) / 60)
        data[band * frames + frame] = max(-1, min(1, tone + rng.uniform(-0.3, 0.3) - 0.4))
      }
    }
    return MelSpectrogram(nMel: 80, nLen: frames, data: data)
  }

  func testEncodeProducesFiniteOutputOfTheRightShape() throws {
    let file = try loadTiny()
    let model = try WhisperModel(file: file, backend: CPUBackend())
    XCTAssertNil(model.encoderOutput)
    let start = Date()
    try model.encode(mel: syntheticMel(), offset: 0, audioContext: 0)
    let seconds = Date().timeIntervalSince(start)
    let output = try XCTUnwrap(model.encoderOutput)
    XCTAssertEqual(model.encoderContext, 1500)
    XCTAssertEqual(output.count, 1500 * 384)
    XCTAssertTrue(output.allSatisfy(\.isFinite))
    let magnitude = output.map { abs($0) }.reduce(0, +) / Float(output.count)
    XCTAssertGreaterThan(magnitude, 0.01, "the encoder output is not degenerate")
    XCTAssertLessThan(seconds, 30, "tiny encode took \(seconds) s")
    print("ModelTests: tiny encode on the CPU backend took \(Int(seconds * 1000)) ms")
  }

  func testEncodeHonoursAudioContextAndOffset() throws {
    let file = try loadTiny()
    let model = try WhisperModel(file: file, backend: CPUBackend())
    let mel = syntheticMel(frames: 1200)
    // audio_ctx 500: a 1000-frame window, [500, 384] output, and the mel past its end is zero.
    try model.encode(mel: mel, offset: 0, audioContext: 500)
    XCTAssertEqual(model.encoderContext, 500)
    XCTAssertEqual(model.encoderOutput?.count, 500 * 384)
    let logitsShort = try model.decode(tokens: [file.vocabulary.sot], past: 0)
    XCTAssertEqual(logitsShort.count, 51865)
    XCTAssertTrue(logitsShort.allSatisfy(\.isFinite))

    // Offsets past the end leave an all-zero window, which still encodes to something finite.
    try model.encode(mel: mel, offset: 1100, audioContext: 0)
    XCTAssertEqual(model.encoderContext, 1500)
    XCTAssertTrue(try XCTUnwrap(model.encoderOutput).allSatisfy(\.isFinite))
    try model.encode(mel: mel, offset: 5000, audioContext: 0)
    XCTAssertTrue(try XCTUnwrap(model.encoderOutput).allSatisfy(\.isFinite))

    // Encoding the same frames through a larger spectrogram at an offset gives the same output.
    let padded = MelSpectrogram(
      nMel: 80, nLen: 1300, data: (0..<80).flatMap { band in [Float](repeating: 0.25, count: 100) + mel.data[band * 1200..<(band + 1) * 1200] })
    try model.encode(mel: mel, offset: 0, audioContext: 0)
    let direct = try XCTUnwrap(model.encoderOutput)
    try model.encode(mel: padded, offset: 100, audioContext: 0)
    XCTAssertEqual(try XCTUnwrap(model.encoderOutput), direct)

    XCTAssertThrowsError(try model.encode(mel: mel, offset: 0, audioContext: 1501))
    XCTAssertThrowsError(try model.encode(mel: MelSpectrogram(nMel: 40, nLen: 10, data: [Float](repeating: 0, count: 400)), offset: 0, audioContext: 0))
  }

  func testDecodeLogitsShapeFinitenessAndLanguageArgmax() throws {
    let file = try loadTiny()
    let model = try WhisperModel(file: file, backend: CPUBackend())
    XCTAssertThrowsError(try model.decode(tokens: [file.vocabulary.sot], past: 0), "decode before encode")
    try model.encode(mel: syntheticMel(), offset: 0, audioContext: 0)

    let start = Date()
    let first = try model.decode(tokens: [file.vocabulary.sot], past: 0)
    let seconds = Date().timeIntervalSince(start)
    XCTAssertEqual(first.count, 1 * 51865)
    XCTAssertTrue(first.allSatisfy(\.isFinite))
    let argmax = first.indices.max { first[$0] < first[$1] }!
    // After <|startoftranscript|> whisper predicts a language token (ids sot + 1 ... sot + 99) or, for audio that
    // is not speech (this synthetic mel is noise), <|nospeech|>; never a text token.
    XCTAssertTrue((50259...50357).contains(argmax) || argmax == Int(file.vocabulary.nosp), "argmax after sot is \(argmax)")
    let bestText = first[0..<Int(file.vocabulary.eot)].max()!
    let bestLanguage = first[50259...50357].max()!
    XCTAssertGreaterThan(bestLanguage, bestText, "a language token outscores every text token after sot")
    XCTAssertLessThan(seconds, 0.1, "tiny decode step took \(seconds) s")
    print("ModelTests: tiny decode step on the CPU backend took \(Int(seconds * 1000)) ms")

    let second = try model.decode(tokens: [50259], past: 1)
    XCTAssertEqual(second.count, 51865)
    XCTAssertTrue(second.allSatisfy(\.isFinite))

    XCTAssertThrowsError(try model.decode(tokens: [], past: 2))
    XCTAssertThrowsError(try model.decode(tokens: [51865], past: 2))
    XCTAssertThrowsError(try model.decode(tokens: [1, 2], past: 447))
  }

  func testIncrementalDecodeMatchesBatchDecode() throws {
    let file = try loadTiny()
    let model = try WhisperModel(file: file, backend: CPUBackend())
    try model.encode(mel: syntheticMel(), offset: 0, audioContext: 0)
    let sot = file.vocabulary.sot
    let tokens: [Int32] = [sot, 50259, file.vocabulary.transcribe, file.vocabulary.not, 1770]

    // One batch at past 0: logits for every token.
    let batch = try model.decode(tokens: tokens, past: 0)
    XCTAssertEqual(batch.count, tokens.count * 51865)

    // Token by token through the cache, then two at once at past 3: every row must agree.
    model.resetCache()
    var incremental = [[Float]]()
    for (i, token) in tokens.prefix(3).enumerated() { incremental.append(try model.decode(tokens: [token], past: i)) }
    let pair = try model.decode(tokens: Array(tokens[3...]), past: 3)
    incremental.append(Array(pair[0..<51865]))
    incremental.append(Array(pair[51865...]))
    for (i, row) in incremental.enumerated() {
      let batchRow = Array(batch[i * 51865..<(i + 1) * 51865])
      var worst: Float = 0
      for (a, b) in zip(row, batchRow) { worst = max(worst, abs(a - b)) }
      XCTAssertLessThan(worst, 1e-3, "row \(i) differs by \(worst)")
    }

    // The cache is positional: the same token at a different past gives different logits.
    model.resetCache()
    _ = try model.decode(tokens: [sot], past: 0)
    let atOne = try model.decode(tokens: [50259], past: 1)
    model.resetCache()
    _ = try model.decode(tokens: [sot, sot], past: 0)
    let atTwo = try model.decode(tokens: [50259], past: 2)
    XCTAssertNotEqual(atOne, atTwo)

    // Encoding again resets the cache: decoding at past 0 afterwards equals the batch's first row (to sgemm's
    // rounding, which differs between a 1-row and a 5-row batch).
    try model.encode(mel: syntheticMel(), offset: 0, audioContext: 0)
    let fresh = try model.decode(tokens: [sot], past: 0)
    var worstFresh: Float = 0
    for (a, b) in zip(fresh, batch[0..<51865]) { worstFresh = max(worstFresh, abs(a - b)) }
    XCTAssertLessThan(worstFresh, 1e-3, "after a new encode the first row differs by \(worstFresh)")
  }
}

extension ModelTests {
  /// The q8_0 file through the same loader and graph: its weights are the f16 model's quantized, so the encoder
  /// output and the logits must stay close to the f16 model's.
  func testQ8ModelAgreesWithF16Model() throws {
    let f16 = try WhisperModel(file: try loadTiny(), backend: CPUBackend())
    let q8 = try WhisperModel(file: try loadTiny("ggml-tiny-q8_0.bin"), backend: CPUBackend())
    // whisper's quantizer leaves the 3-D conv weights in f16 and quantizes the 2-D matrices.
    XCTAssertEqual(try loadTiny("ggml-tiny-q8_0.bin").tensor("encoder.conv2.weight").type, .f16)
    XCTAssertEqual(try loadTiny("ggml-tiny-q8_0.bin").tensor("encoder.blocks.0.mlp.0.weight").type, .q8_0)
    XCTAssertEqual(try loadTiny("ggml-tiny-q8_0.bin").hyperparameters.ftype, 7)
    let mel = syntheticMel()
    try f16.encode(mel: mel, offset: 0, audioContext: 0)
    try q8.encode(mel: mel, offset: 0, audioContext: 0)
    let a = try XCTUnwrap(f16.encoderOutput), b = try XCTUnwrap(q8.encoderOutput)
    let encoderError = relativeRMS(a, b)
    XCTAssertLessThan(encoderError, 0.1, "encoder outputs differ by \(encoderError) relative RMS")
    let tokens: [Int32] = [f16.vocabulary.sot, 50259, f16.vocabulary.transcribe, f16.vocabulary.not]
    let la = try f16.decode(tokens: tokens, past: 0), lb = try q8.decode(tokens: tokens, past: 0)
    let logitsError = relativeRMS(la, lb)
    XCTAssertLessThan(logitsError, 0.1, "logits differ by \(logitsError) relative RMS")
    print("ModelTests: q8_0 vs f16 relative RMS: encoder \(encoderError), logits \(logitsError)")
  }

  /// whisper.cpp's flash-attention padding (Model.swift's header): the default pads the encoder self-attention and
  /// cross-attention keys to 1536 rows and changes the output slightly; 1 is the exact attention; an audio context
  /// that is already a multiple of 256 pads nothing.
  func testAttentionPaddingReproducesWhisperCppAndCanBeTurnedOff() throws {
    let file = try loadTiny()
    let padded = try WhisperModel(file: file, backend: CPUBackend())
    let exact = try WhisperModel(file: file, backend: CPUBackend(), attentionPadding: 1)
    XCTAssertEqual(padded.attentionPadding, 256)
    let mel = syntheticMel()
    try padded.encode(mel: mel, offset: 0, audioContext: 0)
    try exact.encode(mel: mel, offset: 0, audioContext: 0)
    let a = try XCTUnwrap(padded.encoderOutput), b = try XCTUnwrap(exact.encoderOutput)
    let difference = relativeRMS(a, b)
    XCTAssertGreaterThan(difference, 0.01, "padding to 1536 keys dilutes the attention measurably (\(difference))")
    XCTAssertLessThan(difference, 0.5, "but only a little (\(difference))")
    let tokens: [Int32] = [file.vocabulary.sot, 50259, file.vocabulary.transcribe, file.vocabulary.not]
    let la = try padded.decode(tokens: tokens, past: 0), lb = try exact.decode(tokens: tokens, past: 0)
    XCTAssertGreaterThan(relativeRMS(la, lb), 0.001)
    XCTAssertTrue(la.allSatisfy(\.isFinite) && lb.allSatisfy(\.isFinite))

    // 512 positions: 1024 mel frames, nothing to pad, so both models agree exactly.
    try padded.encode(mel: mel, offset: 0, audioContext: 512)
    try exact.encode(mel: mel, offset: 0, audioContext: 512)
    XCTAssertEqual(padded.encoderOutput, exact.encoderOutput)
    XCTAssertEqual(try padded.decode(tokens: [file.vocabulary.sot], past: 0), try exact.decode(tokens: [file.vocabulary.sot], past: 0))
  }

  /// A real file whose tensors were altered in memory after parsing: every shape the graph relies on is checked in
  /// `init`, so a wrong one throws `shapeMismatch` rather than tripping a backend precondition later.
  func testAlteredTensorShapeThrowsShapeMismatch() throws {
    let file = try loadTiny()
    XCTAssertNoThrow(try WhisperModel(file: file, backend: CPUBackend()))

    func altered(_ name: String, _ change: (inout WeightTensor) -> Void) -> WhisperModelFile {
      var copy = file
      change(&copy.tensors[name]!)
      return copy
    }
    func expectShapeMismatch(_ file: WhisperModelFile, _ prefix: String, line: UInt = #line) {
      XCTAssertThrowsError(try WhisperModel(file: file, backend: CPUBackend()), prefix, line: line) { error in
        guard case .shapeMismatch(let message) = error as? WhisperError else {
          return XCTFail("\(prefix): \(error)", line: line)
        }
        XCTAssertTrue(message.hasPrefix(prefix), message, line: line)
      }
    }

    // The same element count in the other order: whisper.cpp's nelements check would pass this.
    expectShapeMismatch(altered("encoder.positional_embedding") { $0.shape = [384, 1500] }, "encoder.positional_embedding")
    expectShapeMismatch(altered("encoder.conv1.weight") { $0.shape = [80, 384, 3] }, "encoder.conv1.weight")
    // A flattened conv bias, a matrix with an extra column, a vector with a missing entry.
    expectShapeMismatch(altered("encoder.conv2.bias") { $0.shape = [384] }, "encoder.conv2.bias")
    expectShapeMismatch(altered("decoder.blocks.3.cross_attn.key.weight") { $0.shape = [384, 385] }, "decoder.blocks.3.cross_attn.key.weight")
    expectShapeMismatch(altered("decoder.blocks.0.mlp.0.bias") { $0.shape = [1535] }, "decoder.blocks.0.mlp.0.bias")
    expectShapeMismatch(altered("decoder.token_embedding.weight") { $0.shape = [51864, 384] }, "decoder.token_embedding.weight")
    expectShapeMismatch(altered("decoder.ln.weight") { $0.shape = [384, 1] }, "decoder.ln.weight")
    // The right shape over too few bytes.
    expectShapeMismatch(altered("encoder.blocks.0.attn.query.weight") { $0.data = $0.data.prefix(1000) }, "encoder.blocks.0.attn.query.weight")
    // A dropped tensor, and hyperparameters the graph cannot divide by.
    var missing = file
    missing.tensors["decoder.blocks.2.attn.key.weight"] = nil
    XCTAssertThrowsError(try WhisperModel(file: missing, backend: CPUBackend())) {
      XCTAssertEqual($0 as? WhisperError, .missingTensor("decoder.blocks.2.attn.key.weight"))
    }
    var heads = file
    heads.hyperparameters.nAudioHead = 0
    expectShapeMismatch(heads, "hparams")
    heads.hyperparameters.nAudioHead = 5
    expectShapeMismatch(heads, "hparams")
    var layers = file
    layers.hyperparameters.nTextLayer = 5
    XCTAssertThrowsError(try WhisperModel(file: layers, backend: CPUBackend())) {
      XCTAssertEqual($0 as? WhisperError, .missingTensor("decoder.blocks.4.attn_ln.weight"))
    }
  }

  private func relativeRMS(_ a: [Float], _ b: [Float]) -> Float {
    var difference: Double = 0, magnitude: Double = 0
    for (x, y) in zip(a, b) {
      difference += Double(x - y) * Double(x - y)
      magnitude += Double(x) * Double(x)
    }
    return Float((difference / magnitude).squareRoot())
  }
}

/// Keeps parsed files between tests (reading 78 MB per test is slow).
private final class ModelCache: @unchecked Sendable {
  private let lock = NSLock()
  private var files: [URL: WhisperModelFile] = [:]

  func file(at url: URL) throws -> WhisperModelFile {
    lock.lock()
    defer { lock.unlock() }
    if let file = files[url] { return file }
    let file = try WhisperModelFile.load(url)
    files[url] = file
    return file
  }
}
