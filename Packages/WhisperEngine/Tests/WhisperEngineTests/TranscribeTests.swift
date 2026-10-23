import XCTest
@testable import WhisperEngine

// The transcription loop against a scripted decoder: every test states which logits row the "model" answers with
// for a given token sequence and checks what whisper.cpp's rules make of it. No model file, mel or backend is
// involved; the vocabulary is built by hand in whisper's multilingual layout.

/// Whisper's multilingual special-token layout relative to `base` (the real one has base 50257, so eot 50257,
/// sot 50258, languages from 50259, the task and control tokens from 50358, timestamps from 50364, 51865 tokens in
/// all). The same shape with a small base gives a vocabulary that a debug build can decode thousands of times
/// quickly; the rules under test do not depend on the row length.
private struct Layout {
  static let whisper = Layout(base: 50257)
  static let small = Layout(base: 2000)

  let base: Int32
  var count: Int { Int(base) + 1608 }
  var eot: Int32 { base }
  var sot: Int32 { base + 1 }
  var english: Int32 { base + 2 }
  var chinese: Int32 { base + 3 }
  var german: Int32 { base + 4 }
  var translate: Int32 { base + 101 }
  var transcribe: Int32 { base + 102 }
  var solm: Int32 { base + 103 }
  var prev: Int32 { base + 104 }
  var nosp: Int32 { base + 105 }
  var not: Int32 { base + 106 }
  var beg: Int32 { base + 107 }

  // Text tokens with fictional ids (below either base) and strings.
  static let space: Int32 = 220
  static let hello: Int32 = 1496
  static let world: Int32 = 995
  static let again: Int32 = 1234
  static let la: Int32 = 434
  static let names: [Int32: String] = [space: " ", hello: "Hello", world: " world", again: " again", la: " la"]
  /// Forty distinct words, " w0" ... " w39", for transcripts long enough to meet the entropy rule.
  static func word(_ i: Int) -> Int32 { Int32(1500 + i) }

  var languages: [String: Int32] { ["en": english, "zh": chinese, "de": german] }

  var vocabulary: Vocabulary {
    var tokens = [[UInt8]](repeating: [], count: count)
    for (id, name) in Self.names { tokens[Int(id)] = Array(name.utf8) }
    for i in 0..<40 { tokens[Int(Self.word(i))] = Array(" w\(i)".utf8) }
    return Vocabulary(
      tokens: tokens, isMultilingual: true, eot: eot, sot: sot, sotLanguage: english, translate: translate,
      transcribe: transcribe, solm: solm, prev: prev, nosp: nosp, not: not, beg: beg)
  }

  /// A logits row of zeros with `peaks` raised; a 20-point peak makes the token near-certain (log-probability about
  /// -1e-4), well inside whisper's `logprob_thold` so no fallback triggers unless a test wants one.
  func row(_ peaks: [(Int32, Float)]) -> [Float] {
    var row = [Float](repeating: 0, count: count)
    for (id, logit) in peaks { row[Int(id)] = logit }
    return row
  }

  /// A script that emits `tokens` in order (keyed by how many tokens follow the 4-token prompt) and then `eot`.
  func sequence(_ tokens: [Int32]) -> (Int, [Int32]) -> [Float] {
    { _, sequence in
      let position = sequence.count - 4
      return row([(position < tokens.count ? tokens[position] : eot, 20)])
    }
  }
}

/// A `WhisperInference` that records its calls and answers `decode` from a script keyed by the current encode
/// offset and the token sequence so far (prompt included; a decode at `past` 0 restarts the sequence, as the real
/// cache does). Only the last row of a decode carries the scripted logits; earlier rows are zeros.
private final class ScriptedInference: WhisperInference {
  let hyperparameters: WhisperHyperparameters
  let vocabulary: Vocabulary
  let script: (_ offset: Int, _ sequence: [Int32]) -> [Float]
  private(set) var encodes: [(offset: Int, audioContext: Int, nLen: Int)] = []
  private(set) var decodes: [(tokens: [Int32], past: Int)] = []
  private var sequence: [Int32] = []
  private var offset = 0

  init(
    _ layout: Layout, nTextContext: Int = 448, vocabulary: Vocabulary? = nil,
    script: @escaping (_ offset: Int, _ sequence: [Int32]) -> [Float]
  ) {
    self.vocabulary = vocabulary ?? layout.vocabulary
    self.script = script
    hyperparameters = WhisperHyperparameters(
      nVocab: layout.count, nAudioContext: 1500, nAudioState: 384, nAudioHead: 6, nAudioLayer: 4,
      nTextContext: nTextContext, nTextState: 384, nTextHead: 6, nTextLayer: 4, nMels: 80, ftype: 1)
  }

  func encode(mel: MelSpectrogram, offset: Int, audioContext: Int) throws {
    encodes.append((offset, audioContext, mel.nLen))
    self.offset = offset
    sequence = []
  }

  func decode(tokens: [Int32], past: Int) throws -> [Float] {
    sequence = Array(sequence.prefix(past)) + tokens
    decodes.append((tokens, past))
    let nVocab = hyperparameters.nVocab
    var rows = [Float](repeating: 0, count: tokens.count * nVocab)
    let last = script(offset, sequence)
    precondition(last.count == nVocab)
    rows.replaceSubrange((tokens.count - 1) * nVocab..<tokens.count * nVocab, with: last)
    return rows
  }

  /// Decodes without the prompt: the tokens the loop generated this window.
  var generatedDecodes: [(tokens: [Int32], past: Int)] { decodes.filter { $0.past > 0 } }
  var promptDecodes: [(tokens: [Int32], past: Int)] { decodes.filter { $0.past == 0 } }
}

final class TranscribeTests: XCTestCase {
  /// `WhisperSession` over `inference` with the test seams: `layout`'s language table, byte-concatenating text
  /// decoding that shows a token without text as `<id>` (so a sampled fallback still yields a segment), and a mel of
  /// the right padded length whose content nothing reads.
  private func session(_ inference: ScriptedInference, _ layout: Layout, melCalls: (([Float]) -> Void)? = nil)
    -> WhisperSession
  {
    WhisperSession(
      inference: inference, filters: MelFilters(nMel: 80, nFFT: 201, data: []),
      languageToken: { layout.languages[$0] },
      languageCode: { token in layout.languages.first { $0.value == token }?.key },
      text: { ids in
        ids.map { id in
          let bytes = inference.vocabulary.tokens[Int(id)]
          return bytes.isEmpty ? "<\(id)>" : String(decoding: bytes, as: UTF8.self)
        }.joined()
      },
      mel: { samples in
        melCalls?(samples)
        return MelSpectrogram(
          nMel: 80, nLen: (samples.count + 30 * MelSpectrogram.sampleRate) / MelSpectrogram.hopLength, data: [])
      })
  }

  static func seconds(_ s: Double) -> [Float] {
    [Float](repeating: 0, count: Int(s * Double(MelSpectrogram.sampleRate)))
  }

  func testPromptForEnglishWithoutTimestampsAndStopAtEot() throws {
    let w = Layout.whisper
    let inference = ScriptedInference(w, script: w.sequence([Layout.hello, Layout.world]))
    let result = try session(inference, w).transcribe(samples: Self.seconds(2), language: "en", threads: 4)

    XCTAssertEqual(inference.encodes.map(\.offset), [0])
    XCTAssertEqual(inference.encodes.map(\.audioContext), [0])
    XCTAssertEqual(inference.decodes[0].tokens, [50258, 50259, 50359, 50363])
    XCTAssertEqual(inference.decodes[0].tokens, [w.sot, w.english, w.transcribe, w.not])
    XCTAssertEqual(inference.decodes[0].past, 0)
    // One decode per generated token, each at the next position; nothing after eot.
    XCTAssertEqual(inference.generatedDecodes.map(\.tokens), [[Layout.hello], [Layout.world]])
    XCTAssertEqual(inference.generatedDecodes.map(\.past), [4, 5])
    XCTAssertEqual(result.text, "Hello world")
    XCTAssertEqual(result.language, "en")
    XCTAssertEqual(result.segments, [.init(tokens: [Layout.hello, Layout.world, w.eot], text: "Hello world")])
  }

  func testSuppressBlankMasksEotAndSpaceOnlyAtTheFirstPosition() throws {
    let w = Layout.whisper
    // First position: eot would win, then " ", then "Hello". Second position: " " wins outright, then eot.
    let inference = ScriptedInference(w) { _, sequence in
      switch sequence.count - 4 {
      case 0: w.row([(w.eot, 30), (Layout.space, 25), (Layout.hello, 20)])
      case 1: w.row([(Layout.space, 30), (Layout.hello, 20)])
      default: w.row([(w.eot, 20)])
      }
    }
    let result = try session(inference, w).transcribe(samples: Self.seconds(2), language: "en", threads: 1)
    XCTAssertEqual(result.segments.map(\.tokens), [[Layout.hello, Layout.space, w.eot]])
    XCTAssertEqual(result.text, "Hello ")
  }

  func testTimestampAndControlTokensAreNeverChosen() throws {
    let w = Layout.whisper
    // Each position's loudest token is one the filters remove; the text token behind it must win every time.
    let suppressed: [Int32] = [w.beg + 5, w.not, w.sot, w.nosp, w.solm, w.translate, w.transcribe, w.prev, w.german,
                               Int32(w.count - 1)]
    let inference = ScriptedInference(w) { _, sequence in
      let position = sequence.count - 4
      guard position < suppressed.count else { return w.row([(w.eot, 20)]) }
      return w.row([(suppressed[position], 40), (Layout.la, 20)])
    }
    let result = try session(inference, w).transcribe(samples: Self.seconds(2), language: "en", threads: 1)
    XCTAssertEqual(result.segments.map(\.tokens), [[Int32](repeating: Layout.la, count: suppressed.count) + [w.eot]])
    XCTAssertEqual(result.text, String(repeating: " la", count: suppressed.count))
  }

  func testLanguageDetectionDecodesSotAndPromptsWithTheWinner() throws {
    let w = Layout.whisper
    let inference = ScriptedInference(w) { _, sequence in
      if sequence == [w.sot] {
        // German wins among the language tokens even though a text token is louder still.
        return w.row([(Layout.hello, 9), (w.english, 3), (w.german, 7), (w.chinese, 5)])
      }
      return w.sequence([Layout.hello])(0, sequence)
    }
    let result = try session(inference, w).transcribe(samples: Self.seconds(2), language: nil, threads: 1)

    // Detection encodes the first window and decodes [sot] alone; the main loop then encodes it again.
    XCTAssertEqual(inference.encodes.map(\.offset), [0, 0])
    XCTAssertEqual(inference.decodes[0].tokens, [w.sot])
    XCTAssertEqual(inference.decodes[0].past, 0)
    XCTAssertEqual(inference.decodes[1].tokens, [w.sot, w.german, w.transcribe, w.not])
    XCTAssertEqual(result.language, "de")
    XCTAssertEqual(result.text, "Hello")
  }

  func testAutoIsDetectionAndUnknownCodeFails() throws {
    let w = Layout.whisper
    let inference = ScriptedInference(w) { _, sequence in
      sequence == [w.sot] ? w.row([(w.chinese, 7)]) : w.sequence([Layout.hello])(0, sequence)
    }
    XCTAssertEqual(
      try session(inference, w).transcribe(samples: Self.seconds(2), language: "auto", threads: 1).language, "zh")
    XCTAssertThrowsError(try session(inference, w).transcribe(samples: Self.seconds(2), language: "xx", threads: 1)) {
      XCTAssertEqual($0 as? WhisperError, .decodeFailed("unknown language 'xx'"))
    }
  }

  func testSeventySecondsRunsThreeWindowsAndConcatenatesText() throws {
    let w = Layout.whisper
    let inference = ScriptedInference(w) { offset, sequence in
      switch offset {
      case 0: w.sequence([Layout.hello])(0, sequence)
      case 3000: w.sequence([Layout.world])(0, sequence)
      default: w.sequence([Layout.again])(0, sequence)
      }
    }
    var melSamples = 0
    let result = try session(inference, w) { melSamples = $0.count }
      .transcribe(samples: Self.seconds(70), language: "en", threads: 1)

    // 70 s is 6999 unpadded frames: windows at 0, 3000 and 6000 (6010 < 6999), none at 9000.
    XCTAssertEqual(melSamples, 70 * 16_000)
    XCTAssertEqual(inference.encodes.map(\.offset), [0, 3000, 6000])
    XCTAssertEqual(inference.promptDecodes.count, 3)
    XCTAssertEqual(result.segments.map(\.text), ["Hello", " world", " again"])
    XCTAssertEqual(result.text, "Hello world again")
  }

  func testAudioUnderOneHundredMillisecondsYieldsNoSegments() throws {
    let w = Layout.whisper
    let inference = ScriptedInference(w, script: w.sequence([Layout.hello]))
    // 1000 samples: 1 + (1000 - 200) / 160 = 6 frames, under whisper's 10-frame minimum.
    let short = [Float](repeating: 0, count: 1000)
    XCTAssertEqual(
      try session(inference, w).transcribe(samples: short, language: "en", threads: 1),
      WhisperResult(text: "", language: "en", segments: []))
    XCTAssertTrue(inference.encodes.isEmpty)
    // Exactly 10 frames (1760 samples) passes the minimum but leaves no window to decode.
    XCTAssertEqual(WhisperSession.originalFrames(sampleCount: 1760), 10)
    let ten = [Float](repeating: 0, count: 1760)
    XCTAssertTrue(try session(inference, w).transcribe(samples: ten, language: "en", threads: 1).segments.isEmpty)
    XCTAssertTrue(inference.encodes.isEmpty)
    XCTAssertEqual(WhisperSession.originalFrames(sampleCount: 70 * 16_000), 6999)
  }

  func testMaximumTokensPerWindowIsEnforced() throws {
    // A decoder that never emits eot: 220 positions (n_text_ctx / 2 - 4), then the window fails. The fallback tries
    // every temperature with five sampling decoders, all of which repeat the same near-certain token and fail too,
    // so the output is decoder 0's full run from the last temperature.
    let s = Layout.small
    let inference = ScriptedInference(s) { _, _ in s.row([(Layout.la, 20)]) }
    let result = try session(inference, s).transcribe(samples: Self.seconds(2), language: "en", threads: 1)

    XCTAssertEqual(result.segments.count, 1)
    XCTAssertEqual(result.segments[0].tokens.count, 220)
    XCTAssertEqual(result.text, String(repeating: " la", count: 220))
    // The 220th token is sampled from the logits decoded at position 4 + 218; a failed decoder decodes no further.
    XCTAssertEqual(inference.decodes.map(\.past).max(), 4 + 218)
    // Temperatures 0, 0.2, 0.4, 0.6, 0.8, 1.0: one greedy decoder, then five sampling decoders per temperature,
    // each restarting from the prompt.
    XCTAssertEqual(inference.promptDecodes.count, 1 + 5 * 5)
  }

  func testRepetitiveLongTranscriptFailsOnEntropyAndFallsBack() throws {
    // 40 copies of one token then eot: over the last 32 tokens the entropy is far below 2.4, so the greedy decoder
    // fails; the sampling decoders see the same near-certain rows and fail the same way. The last temperature's
    // decoder 0 is printed as it stands (trimmed to its result length, so without eot in the text).
    let s = Layout.small
    let inference = ScriptedInference(s, script: s.sequence([Int32](repeating: Layout.la, count: 40)))
    let result = try session(inference, s).transcribe(samples: Self.seconds(2), language: "en", threads: 1)
    XCTAssertEqual(inference.promptDecodes.count, 1 + 5 * 5)
    XCTAssertEqual(result.segments.map(\.tokens.count), [41])
    XCTAssertEqual(result.text, String(repeating: " la", count: 40))
  }

  func testLongVariedTranscriptNeverFallsBack() throws {
    // A 40-word transcript of distinct words: long enough for the entropy rule to apply (over 32 tokens), with the
    // entropy of its last 32 tokens at ln 32, above the 2.4 threshold. (Three words cycling would fail it: 2.4 nats
    // needs about eleven distinct tokens in the window.)
    let w = Layout.whisper
    let inference = ScriptedInference(w, script: w.sequence((0..<40).map(Layout.word)))
    let result = try session(inference, w).transcribe(samples: Self.seconds(2), language: "en", threads: 1)
    XCTAssertEqual(inference.promptDecodes.count, 1)
    XCTAssertEqual(result.segments.map(\.tokens.count), [41])
    XCTAssertEqual(result.text, (0..<40).map { " w\($0)" }.joined())
  }

  func testUncertainTranscriptFallsBackUnlessTheWindowLooksSilent() throws {
    let s = Layout.small
    // First position barely prefers "Hello" (log-probability about -8), then eot is certain: the mean falls under
    // logprob_thold. With a low no-speech probability that means a fallback through every temperature.
    let uncertain = ScriptedInference(s) { _, sequence in
      sequence.count == 4 ? s.row([(Layout.hello, 1)]) : s.row([(s.eot, 30)])
    }
    let fallen = try session(uncertain, s).transcribe(samples: Self.seconds(2), language: "en", threads: 1)
    XCTAssertEqual(uncertain.promptDecodes.count, 1 + 5 * 5)
    // The output is the last temperature's best decoder: a sampled first token (whatever it is) and eot.
    XCTAssertEqual(fallen.segments.map(\.tokens.count), [2])
    XCTAssertEqual(fallen.segments.first?.tokens.last, s.eot)
    XCTAssertFalse(fallen.text.isEmpty)

    // The same rows with a dominant no-speech logit at the prompt: no fallback (the window looks silent), and the
    // improbable transcript is dropped, so there is no segment at all.
    let silent = ScriptedInference(s) { _, sequence in
      sequence.count == 4 ? s.row([(Layout.hello, 1), (s.nosp, 30)]) : s.row([(s.eot, 30)])
    }
    let dropped = try session(silent, s).transcribe(samples: Self.seconds(2), language: "en", threads: 1)
    XCTAssertEqual(silent.promptDecodes.count, 1)
    XCTAssertEqual(dropped, WhisperResult(text: "", language: "en", segments: []))
  }

  /// An inference whose vocabulary or text context the loop cannot index safely is refused up front (a model file
  /// cannot produce one, `WhisperModelFile.validate` rejects it; a hand-built inference can).
  func testInconsistentInferenceIsRefusedBeforeDecoding() throws {
    let w = Layout.whisper
    // n_text_ctx 8 leaves `8 / 2 - 4 = 0` tokens per window.
    let cramped = ScriptedInference(w, nTextContext: 8, script: w.sequence([Layout.hello]))
    XCTAssertThrowsError(try session(cramped, w).transcribe(samples: Self.seconds(2), language: "en", threads: 1)) {
      guard case .decodeFailed = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    XCTAssertTrue(cramped.decodes.isEmpty)
    XCTAssertEqual(WhisperSession.maxTokens(textContext: 448), 220)
    XCTAssertEqual(WhisperSession.maxTokens(textContext: 16), 4)
    XCTAssertEqual(WhisperSession.maxTokens(textContext: 9), 0)
    XCTAssertEqual(WhisperSession.maxTokens(textContext: 1), -4)

    // Special ids past the vocabulary (here: `beg` and `not` at the row's end), or a vocabulary shorter than
    // n_vocab: shapeMismatch, not an out-of-range subscript on the first decode.
    var shifted = w.vocabulary
    shifted.not = Int32(w.count)
    shifted.beg = Int32(w.count + 1)
    let bad = ScriptedInference(w, vocabulary: shifted, script: w.sequence([Layout.hello]))
    XCTAssertThrowsError(try session(bad, w).transcribe(samples: Self.seconds(2), language: "en", threads: 1)) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    XCTAssertTrue(bad.decodes.isEmpty)
    var short = w.vocabulary
    short.tokens.removeLast()
    let shortInference = ScriptedInference(w, vocabulary: short, script: w.sequence([Layout.hello]))
    XCTAssertThrowsError(try session(shortInference, w).transcribe(samples: Self.seconds(2), language: "en", threads: 1)) {
      guard case .shapeMismatch = $0 as? WhisperError else { return XCTFail("\($0)") }
    }
    // The checks run before anything else, so even audio too short to transcribe reports them.
    XCTAssertThrowsError(try session(bad, w).transcribe(samples: [], language: "en", threads: 1))
  }

  func testSamplingMatchesLibcxxDiscreteDistribution() {
    // Reference values from a C++ run against libc++ (`std::mt19937 g(seed); g()`, `uniform_real_distribution<double>`
    // and `discrete_distribution<>` over the same float weights).
    var zero = MersenneTwister(seed: 0)
    XCTAssertEqual(zero.next(), 2_357_136_044)
    XCTAssertEqual(zero.next(), 2_546_248_239)
    var five = MersenneTwister(seed: 5)
    XCTAssertEqual(five.next(), 953_453_411)
    var standard = MersenneTwister(seed: 5489)
    for _ in 0..<9999 { _ = standard.next() }
    XCTAssertEqual(standard.next(), 4_123_659_995)

    var canonical = MersenneTwister(seed: 0)
    XCTAssertEqual(canonical.canonical(), 0.59284461651668263)
    XCTAssertEqual(canonical.canonical(), 0.84426574425659828)
    XCTAssertEqual(canonical.canonical(), 0.85794561998982988)

    var g = MersenneTwister(seed: 3)
    let small: [Float] = [0.1, 0.0, 0.3, 0.6, 0.05]
    let draws = (0..<20).map { _ in TokenDistribution.draw(weights: small, generator: &g) }
    XCTAssertEqual(draws, [0, 3, 2, 3, 3, 0, 0, 2, 0, 3, 2, 3, 2, 2, 3, 3, 3, 4, 3, 3])

    var g2 = MersenneTwister(seed: 1)
    let large = (0..<51865).map { expf(-Float($0 % 97) * 0.1) }
    let draws2 = (0..<20).map { _ in TokenDistribution.draw(weights: large, generator: &g2) }
    XCTAssertEqual(draws2, [51707, 48330, 6603, 51804, 12225, 20565, 20086, 34729, 48507, 43858, 16208, 27170, 22991,
                            11851, 27669, 47370, 23677, 22315, 48699, 40357])

    // Suppressed tokens carry no mass and are never drawn.
    let masked = TokenDistribution(logits: [-.infinity, 0, -.infinity])
    var c = MersenneTwister(seed: 3)
    for _ in 0..<50 { XCTAssertEqual(masked.draw(&c).id, 1) }
  }

  func testGreedyPicksTheLowestIdOnTiesAndIgnoresSuppressedTokens() {
    let distribution = TokenDistribution(logits: [-.infinity, 2, 2, -.infinity, 1])
    XCTAssertEqual(distribution.best().id, 1)
    XCTAssertEqual(distribution.probs[0], 0)
    XCTAssertEqual(distribution.logprobs[3], -.infinity)
    XCTAssertEqual(distribution.probs.reduce(0, +), 1, accuracy: 1e-6)
  }

  func testSequenceScoreMatchesWhisperSequenceScore() {
    var sequence = DecoderSequence()
    sequence.tokens = [SampledToken(id: 1, p: 0.5, plog: -0.5), SampledToken(id: 2, p: 0.25, plog: -1.5),
                       SampledToken(id: 1, p: 1, plog: 0)]
    sequence.resultLength = 3
    sequence.computeScore()
    XCTAssertEqual(sequence.sumLogprobs, -2.0, accuracy: 1e-9)
    XCTAssertEqual(sequence.avgLogprobs, -2.0 / 3, accuracy: 1e-9)
    XCTAssertEqual(sequence.score, sequence.avgLogprobs)
    // Counts 2 and 1 over 3 tokens.
    let expected = -(2.0 / 3 * log(2.0 / 3) + 1.0 / 3 * log(1.0 / 3))
    XCTAssertEqual(sequence.entropy, expected, accuracy: 1e-12)
  }
}
