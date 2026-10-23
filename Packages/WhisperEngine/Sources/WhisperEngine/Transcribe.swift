import Foundation

// whisper.cpp's `whisper_full_with_state` for the one configuration the app uses: greedy sampling with the default
// `best_of` 5 and temperature fallback, `no_timestamps`, `no_context`, `suppress_blank`, a language code or "auto",
// and the text of every segment. Beam search, timestamp tokens, the rolling prompt (`prompt_past`), initial prompts,
// token-level timestamps, grammars, VAD and the callbacks are not ported; the few rules of the general loop that are
// no-ops under this configuration are called out below rather than carried along.

/// A transcript: `text` is every segment's text concatenated without separators (the app appends
/// `whisper_full_get_segment_text` per segment), `language` the code used for the prompt (detected or given).
public struct WhisperResult: Sendable, Equatable {
  /// One of whisper.cpp's `result_all` entries: the window's tokens (specials included, so the trailing `eot`) and
  /// the text of the non-special ones. With no timestamps a window yields at most one segment.
  public struct Segment: Sendable, Equatable {
    public var tokens: [Int32]
    public var text: String

    public init(tokens: [Int32], text: String) {
      self.tokens = tokens
      self.text = text
    }
  }

  public var text: String
  public var language: String
  public var segments: [Segment]

  public init(text: String, language: String, segments: [Segment]) {
    self.text = text
    self.language = language
    self.segments = segments
  }
}

/// Runs whisper's transcription loop over a `WhisperInference`. One session serves one model; `transcribe` is
/// synchronous and blocks for the whole run, so call it off the main thread. Not thread-safe: the inference's caches
/// belong to the call in progress.
public final class WhisperSession {
  /// whisper.cpp's `whisper_full_params` fields this port honours, at `whisper_full_default_params(GREEDY)` plus the
  /// app's overrides. They are constants, not options: the loop below is only correct for these values.
  enum Parameters {
    static let bestOf = 5
    static let temperature: Float = 0
    static let temperatureIncrement: Float = 0.2
    static let entropyThreshold: Double = 2.4
    static let logprobThreshold: Double = -1.0
    static let noSpeechThreshold: Float = 0.6
    /// `audio_ctx` 0: the encoder's full context.
    static let audioContext = 0
    /// `WHISPER_MAX_DECODERS`.
    static let maxDecoders = 8
  }

  /// Mel frames per encoder window (`100 * WHISPER_CHUNK_SIZE`).
  static let windowFrames = 100 * 30
  /// `delta_min`: whisper.cpp ignores a tail of under 100 ms (10 frames).
  static let minimumFrames = 10
  /// `g_lang.size()`: the language tokens are `sot + 1 ..< sot + 1 + languageCount` (`whisper_token_lang`).
  static let languageCount = 100

  private let inference: any WhisperInference
  private let filters: MelFilters
  private let languageToken: (String) -> Int32?
  private let languageCode: (Int32) -> String?
  private let text: ([Int32]) -> String
  private let mel: ([Float]) -> MelSpectrogram
  private let vocabulary: Vocabulary
  /// The id of the token whose text is a single space, which `suppress_blank` masks at a window's first position
  /// (`vocab.token_to_id.at(" ")`; whisper.cpp keeps the last id for a repeated string). Nil when the vocabulary has
  /// none, where whisper.cpp would throw out of `at`.
  private let spaceToken: Int32?

  /// - Parameters:
  ///   - inference: the encoder/decoder.
  ///   - filters: the model file's mel filterbank.
  ///   - languageToken: a language code to its token (defaults to `Vocabulary.languageToken`).
  ///   - languageCode: a language token to its code (defaults to `Vocabulary.languageCode`).
  ///   - text: token ids to text (defaults to `Vocabulary.text`).
  ///   - mel: the log-mel spectrogram of 16 kHz samples (defaults to `MelSpectrogram.compute`).
  public init(
    inference: any WhisperInference, filters: MelFilters, languageToken: ((String) -> Int32?)? = nil,
    languageCode: ((Int32) -> String?)? = nil, text: (([Int32]) -> String)? = nil,
    mel: (([Float]) -> MelSpectrogram)? = nil
  ) {
    self.inference = inference
    self.filters = filters
    let vocabulary = inference.vocabulary
    self.vocabulary = vocabulary
    self.languageToken = languageToken ?? { vocabulary.languageToken($0) }
    self.languageCode = languageCode ?? { vocabulary.languageCode($0) }
    self.text = text ?? { vocabulary.text($0) }
    self.mel = mel ?? { MelSpectrogram.compute(samples: $0, filters: filters) }
    spaceToken = vocabulary.tokens.lastIndex(of: [0x20]).map(Int32.init)
  }

  /// Transcribes 16 kHz mono `samples`. `language` is a whisper.cpp code (`"en"`), or nil / `"auto"` to detect it on
  /// the first window. `threads` is the app's `n_threads`; the mel and the backends choose their own parallelism, so
  /// this port only carries it for parity with the call it replaces.
  public func transcribe(samples: [Float], language: String?, threads: Int) throws -> WhisperResult {
    try checkVocabulary()

    // whisper.cpp bounds the loop by the spectrogram's unpadded length (`mel.n_len_org` in `log_mel_spectrogram`:
    // 1 + (n_samples + 200 - 400) / 160, integer division truncating toward zero like C), not by the 30 s padded
    // length the encoder reads, so it is derived from the sample count here rather than from the mel.
    let seekEnd = Self.originalFrames(sampleCount: samples.count)

    var spectrogram: MelSpectrogram?
    if !samples.isEmpty { spectrogram = mel(samples) }

    // Language. Detection decodes `[sot]` over the first window before the main loop (`whisper_lang_auto_detect`)
    // and fails when the audio has no frame to look at. English-only models have no language tokens, so detection
    // is skipped for them and the prompt carries no language or task token (`whisper_is_multilingual`).
    let multilingual = vocabulary.isMultilingual
    var languageToken: Int32?
    var languageName: String
    let requested = (language ?? "auto")
    if multilingual {
      if requested.isEmpty || requested == "auto" {
        guard seekEnd > 0, let spectrogram else {
          throw WhisperError.decodeFailed("language detection: the audio is shorter than one mel frame")
        }
        let token = try detectLanguage(spectrogram)
        languageToken = token
        languageName = languageCode(token) ?? ""
      } else {
        guard let token = self.languageToken(requested) else {
          throw WhisperError.decodeFailed("unknown language '\(requested)'")
        }
        languageToken = token
        languageName = requested
      }
    } else {
      languageName = "en"
    }

    // "if length of spectrogram is less than 100ms (10 frames), then return": no segments, not an error.
    guard seekEnd >= Self.minimumFrames, let spectrogram else {
      return WhisperResult(text: "", language: languageName, segments: [])
    }

    // The prompt every window starts from (`prompt_init`): sot, language and task for multilingual models, then
    // `not` since the app asks for no timestamps. With `no_context` there is never a `prev` + history prefix.
    var prompt = [vocabulary.sot]
    if let languageToken {
      prompt.append(languageToken)
      prompt.append(vocabulary.transcribe)
    }
    prompt.append(vocabulary.not)

    // The temperatures to try: t0, t0 + inc, ... while < 1 + 1e-6, in Float like the C++ loop (so 1.0000001 counts).
    var temperatures: [Float] = []
    var t = Parameters.temperature
    while t < 1.0 + 1e-6 {
      temperatures.append(t)
      t += Parameters.temperatureIncrement
    }
    // Decoder 0 is reseeded with 0 per call, decoder j with j; the generators then carry across windows and
    // temperatures within the call.
    var generators = (0..<Parameters.bestOf).map { MersenneTwister(seed: UInt32($0)) }

    var segments: [WhisperResult.Segment] = []
    var seek = 0
    while true {
      // "if only 100ms left, then stop".
      if seek + Self.minimumFrames >= seekEnd { break }
      try inference.encode(mel: spectrogram, offset: seek, audioContext: Parameters.audioContext)

      // whisper.cpp keeps `best_decoder_id` across the temperature iterations of a window: when every decoder of the
      // last temperature fails, the index chosen at an earlier temperature picks which (failed) decoder is output.
      var bestDecoder = 0
      var decoders: [DecoderSequence] = []
      var noSpeechProbability: Float = 0
      for (iteration, temperature) in temperatures.enumerated() {
        let decoderCount = temperature > 0 ? Parameters.bestOf : 1
        decoders = Array(repeating: DecoderSequence(), count: decoderCount)

        // The prompt is decoded from an empty self-attention cache for each temperature. The "no speech"
        // probability comes from the unfiltered logits of its last position; the decoders then all start from the
        // same filtered distribution (whisper.cpp copies decoder 0's into the others).
        let promptLogits = try decodeRow(prompt, past: 0)
        noSpeechProbability = TokenDistribution(logits: promptLogits).probs[Int(vocabulary.nosp)]
        let initial = filtered(promptLogits, initial: true, temperature: temperature)

        for j in 0..<decoderCount {
          // The decoders run one after another here: each has its own token sequence, cache and generator, so the
          // result is the one whisper.cpp gets from batching them. A later decoder restarts the cache by decoding
          // the prompt at position 0 again; its logits are the same row and are discarded.
          if j > 0 { _ = try decodeRow(prompt, past: 0) }
          try run(decoder: &decoders[j], from: initial, temperature: temperature, generator: &generators[j],
                  promptLength: prompt.count)
        }

        // Rank the sequences: a decoder fails when its last 32 tokens are too repetitive (entropy below the
        // threshold once it has more than 32), and the best score (mean log-probability) wins, lowest index on ties.
        var bestScore = -Double.infinity
        for j in 0..<decoderCount where !decoders[j].failed {
          decoders[j].sequence.tokens.removeLast(decoders[j].sequence.tokens.count - decoders[j].sequence.resultLength)
          decoders[j].sequence.computeScore()
          if decoders[j].sequence.resultLength > 32, decoders[j].sequence.entropy < Parameters.entropyThreshold {
            decoders[j].failed = true
            continue
          }
          if bestScore < decoders[j].sequence.score {
            bestScore = decoders[j].sequence.score
            bestDecoder = j
          }
        }

        // Fall back to the next temperature when the best decoder failed, or spoke too uncertainly without the
        // window looking like silence. The last temperature is taken as it is.
        if iteration != temperatures.count - 1 {
          let best = decoders[bestDecoder]
          if best.failed
            || (best.sequence.avgLogprobs < Parameters.logprobThreshold
              && noSpeechProbability < Parameters.noSpeechThreshold)
          {
            continue
          }
        }
        break
      }

      // The window's segment. A likely-silent window whose transcript is also improbable is dropped altogether.
      // Without timestamps the window is one segment: the text of its non-special tokens (`id < eot`), kept only
      // when non-empty, with every token (specials included) attached, as `result_all` records them.
      let best = decoders[bestDecoder]
      let isNoSpeech = noSpeechProbability > Parameters.noSpeechThreshold
        && best.sequence.avgLogprobs < Parameters.logprobThreshold
      if !best.sequence.tokens.isEmpty, !isNoSpeech {
        let ids = best.sequence.tokens.map(\.id)
        let text = self.text(ids.filter { $0 < vocabulary.eot })
        if !text.isEmpty { segments.append(WhisperResult.Segment(tokens: ids, text: text)) }
      }

      // With no timestamps `seek_delta` is always the full window (the decoder resets it on completion and the
      // initial value is the same), so the loop advances 30 s whatever happened.
      seek += Self.windowFrames
    }

    return WhisperResult(text: segments.map(\.text).joined(), language: languageName, segments: segments)
  }

  /// The invariant the loop indexes logits under: every logits row has `nVocab` entries (`decodeRow` checks each
  /// decode), the vocabulary has as many tokens, and every special id (`eot`, `sot`, the task and control tokens,
  /// `beg`) lies inside it. A model file that passed `WhisperModelFile.validate` guarantees this; an inference built
  /// by hand may not, so it is checked once per call rather than at every subscript.
  private func checkVocabulary() throws {
    let nVocab = inference.hyperparameters.nVocab
    guard nVocab >= 1, vocabulary.tokens.count == nVocab else {
      throw WhisperError.shapeMismatch("vocabulary has \(vocabulary.tokens.count) tokens, n_vocab is \(nVocab)")
    }
    let specials = [
      vocabulary.eot, vocabulary.sot, vocabulary.sotLanguage, vocabulary.translate, vocabulary.transcribe,
      vocabulary.solm, vocabulary.prev, vocabulary.nosp, vocabulary.not, vocabulary.beg,
    ]
    guard specials.allSatisfy({ $0 >= 0 && Int($0) < nVocab }) else {
      throw WhisperError.shapeMismatch("special token ids \(specials) outside the vocabulary of \(nVocab)")
    }
    guard Self.maxTokens(textContext: inference.hyperparameters.nTextContext) >= 1 else {
      throw WhisperError.decodeFailed("n_text_ctx \(inference.hyperparameters.nTextContext) leaves no room for a token")
    }
  }

  /// `n_max` in whisper.cpp's token loop: `n_text_ctx / 2 - 4` (C division, truncating toward zero).
  static func maxTokens(textContext: Int) -> Int { textContext / 2 - 4 }

  /// whisper.cpp's `mel.n_len_org` for `sampleCount` samples: the frames of the audio before the 30 s padding.
  static func originalFrames(sampleCount: Int) -> Int {
    1 + (sampleCount + MelSpectrogram.fftSize / 2 - MelSpectrogram.fftSize) / MelSpectrogram.hopLength
  }

  /// The decoder state whisper.cpp keeps per decoder besides the sequence (`whisper_decoder`).
  private struct DecoderSequence {
    var sequence = WhisperEngine.DecoderSequence()
    var failed = false
    var completed = false
  }

  /// The per-window token loop for one decoder (`for (int i = 0, n_max = n_text_ctx/2 - 4; ...)`): sample, stop at
  /// `eot`, otherwise decode the token for the next distribution. Running out of positions without `eot` is a
  /// failure (the "repetition loop" rule; with no timestamps `result_len` stays 0 until completion, so the rule
  /// always fires there), and the failed decoder keeps every token it produced. On completion the sequence's
  /// `result_len` covers the tokens through `eot`, which is what the output then prints.
  private func run(
    decoder: inout DecoderSequence, from initial: TokenDistribution, temperature: Float,
    generator: inout MersenneTwister, promptLength: Int
  ) throws {
    let maxTokens = Self.maxTokens(textContext: inference.hyperparameters.nTextContext)
    guard maxTokens >= 1 else {
      throw WhisperError.decodeFailed("n_text_ctx \(inference.hyperparameters.nTextContext) leaves no room for a token")
    }
    var distribution = initial
    for i in 0..<maxTokens {
      let token = temperature < 1e-6 ? distribution.best() : distribution.draw(&generator)
      decoder.sequence.tokens.append(token)
      decoder.sequence.sumLogprobsAll += Double(token.plog)

      if token.id == vocabulary.eot {
        decoder.sequence.resultLength = i + 1
        decoder.completed = true
        return
      }
      if i == maxTokens - 1 {
        decoder.failed = true
        return
      }
      let logits = try decodeRow([token.id], past: promptLength + i)
      distribution = filtered(logits, initial: false, temperature: temperature)
    }
  }

  /// `whisper_process_logits` under the app's parameters. Beyond what is here, the C++ function's timestamp rules
  /// (pairing, `max_initial_ts`, increasing timestamps, the timestamp-vs-text logsumexp) only touch tokens from
  /// `beg` up, which `no_timestamps` has already set to -infinity, and the `max_tokens`, regex, non-speech, grammar
  /// and callback filters are off.
  ///
  /// `row` has `nVocab` entries and every special id is below that (`checkVocabulary`, `decodeRow`), so the direct
  /// subscripts here cannot go out of range; the language and timestamp loops bound themselves because they run to
  /// fixed counts a smaller vocabulary may not reach.
  private func filtered(_ row: [Float], initial: Bool, temperature: Float) -> TokenDistribution {
    var logits = row
    if temperature > 0 {
      // Over a raw pointer: see Sampling.swift on debug-build loop cost.
      logits.withUnsafeMutableBufferPointer { logits in
        guard let x = logits.baseAddress else { return }
        var i = 0
        while i < logits.count {
          x[i] /= temperature
          i += 1
        }
      }
    }
    // suppress_blank: no `eot` and no " " as the first token of a window.
    if initial {
      logits[Int(vocabulary.eot)] = -.infinity
      if let spaceToken { logits[Int(spaceToken)] = -.infinity }
    }
    // `<|notimestamps|>` is never produced; with no_timestamps neither is any timestamp token.
    logits[Int(vocabulary.not)] = -.infinity
    logits.withUnsafeMutableBufferPointer { logits in
      guard let x = logits.baseAddress else { return }
      var i = Int(vocabulary.beg)
      while i < logits.count {
        x[i] = -.infinity
        i += 1
      }
    }
    // sot, nosp, solm (tinydiarize off), the task tokens, prev, and every language token.
    logits[Int(vocabulary.sot)] = -.infinity
    logits[Int(vocabulary.nosp)] = -.infinity
    logits[Int(vocabulary.solm)] = -.infinity
    logits[Int(vocabulary.translate)] = -.infinity
    logits[Int(vocabulary.transcribe)] = -.infinity
    logits[Int(vocabulary.prev)] = -.infinity
    for id in 0..<Self.languageCount {
      let token = Int(vocabulary.sot) + 1 + id
      if token < logits.count { logits[token] = -.infinity }
    }
    return TokenDistribution(logits: logits)
  }

  /// `whisper_lang_auto_detect_internal` at offset 0: encode the first window, decode `[sot]`, and take the language
  /// token with the highest logit (the softmax over the language tokens that whisper.cpp reports as probabilities
  /// does not change the winner; ties go to the lowest id, the order the C++ sorts in before a stable choice).
  private func detectLanguage(_ spectrogram: MelSpectrogram) throws -> Int32 {
    try inference.encode(mel: spectrogram, offset: 0, audioContext: Parameters.audioContext)
    let logits = try decodeRow([vocabulary.sot], past: 0)
    var best: (token: Int32, logit: Float)?
    for id in 0..<Self.languageCount {
      let token = Int(vocabulary.sot) + 1 + id
      guard token < logits.count else { break }
      if best == nil || logits[token] > best!.logit { best = (Int32(token), logits[token]) }
    }
    guard let best else { throw WhisperError.decodeFailed("language detection: no language tokens") }
    return best.token
  }

  /// Decodes `tokens` and returns the logits of the last one. The one per-decode check: the row is `nVocab` wide,
  /// which with `checkVocabulary` is what every subscript in the loop relies on.
  private func decodeRow(_ tokens: [Int32], past: Int) throws -> [Float] {
    let nVocab = inference.hyperparameters.nVocab
    let logits = try inference.decode(tokens: tokens, past: past)
    guard logits.count == tokens.count * nVocab, nVocab == vocabulary.tokens.count else {
      throw WhisperError.shapeMismatch(
        "decoder logits: \(logits.count) values for \(tokens.count) tokens, vocabulary \(vocabulary.tokens.count)")
    }
    return Array(logits[(tokens.count - 1) * nVocab..<tokens.count * nVocab])
  }
}
