import Foundation

// The vocabulary as whisper.cpp builds it in `whisper_model_load` and reads it back in `whisper_token_to_str`.
// The file stores each token's bytes already decoded (the converter maps GPT-2's byte-to-unicode alphabet back to
// raw bytes before writing, and 1.9.5 reads the bytes straight into `id_to_token` with no further processing), so a
// token is a UTF-8 fragment that may end mid-character; text is the concatenation of fragments decoded once.

extension Vocabulary {
  /// The special token ids `whisper_vocab` derives from `nVocab`, computed in `Int` so no value of `nVocab` can
  /// trap. The defaults are the English-only ids; multilingual models (nVocab >= 51865) shift eot and sot by one and
  /// the task tokens onward by the number of extra languages (`num_languages() - 98`: 1 for the 99-language v1/v2
  /// files, 2 for large-v3's 100 languages, nVocab 51866). `largest` is what a vocabulary must exceed in size for
  /// the transcription loop to index its logits safely: `beg` always, since every other id lies below it.
  public struct SpecialTokens: Sendable, Equatable {
    public let isMultilingual: Bool
    /// `whisper_vocab::num_languages`: the ids between sot and translate.
    public let numLanguages: Int
    public let eot: Int
    public let sot: Int
    public let translate: Int
    public let transcribe: Int
    public let solm: Int
    public let prev: Int
    public let nosp: Int
    public let not: Int
    public let beg: Int

    /// `nVocab` is clamped to the `Int32` id range first (the file stores it as int32; `validate` bounds it far
    /// lower), so the arithmetic cannot overflow for any argument.
    public init(nVocab: Int) {
      let nVocab = min(max(nVocab, 0), Int(Int32.max))
      isMultilingual = nVocab >= 51865
      numLanguages = nVocab - 51765 - (isMultilingual ? 1 : 0)
      let dt = isMultilingual ? numLanguages - 98 : 0
      eot = 50256 + (isMultilingual ? 1 : 0)
      sot = 50257 + (isMultilingual ? 1 : 0)
      translate = 50357 + dt
      transcribe = 50358 + dt
      solm = 50359 + dt
      prev = 50360 + dt
      nosp = 50361 + dt
      not = 50362 + dt
      beg = 50363 + dt
    }

    /// The largest id the loop addresses directly: `beg`, which exceeds the other control tokens and the 100
    /// language tokens (`sot + 1 ... sot + 100`, below `translate`).
    public var largest: Int { max(beg, sot + WhisperLanguages.all.count) }
  }

  /// The largest special id of this vocabulary (see `SpecialTokens.largest`); `tokens.count` must exceed it.
  public var largestSpecialToken: Int {
    max(Int(eot), Int(sot), Int(sotLanguage) + WhisperLanguages.all.count - 1, Int(translate), Int(transcribe),
        Int(solm), Int(prev), Int(nosp), Int(not), Int(beg))
  }

  /// whisper.cpp's vocabulary setup: the file's tokens, padded to `nVocab` with whisper.cpp's generated names, and
  /// the special token ids `whisper_vocab` derives from `nVocab` (`SpecialTokens`).
  ///
  /// The padding allocates `nVocab` entries, so callers must have bounded `nVocab` first: the model file reader
  /// validates it (`WhisperHyperparameters.validate`, at most 1 << 17) before calling this. Ids are stored as
  /// `Int32` with clamping, so an absurd `nVocab` still cannot trap here, only produce a vocabulary `validate`
  /// rejects.
  public static func whisper(fileTokens: [[UInt8]], nVocab: Int) -> Vocabulary {
    let special = SpecialTokens(nVocab: nVocab)
    let eot = Int32(clamping: special.eot)
    let sot = Int32(clamping: special.sot)
    let translate = Int32(clamping: special.translate)
    let transcribe = Int32(clamping: special.transcribe)
    let solm = Int32(clamping: special.solm)
    let prev = Int32(clamping: special.prev)
    let nosp = Int32(clamping: special.nosp)
    let not = Int32(clamping: special.not)
    let beg = Int32(clamping: special.beg)

    var tokens = fileTokens
    if tokens.count < nVocab {
      tokens.reserveCapacity(nVocab)
      for i in tokens.count..<nVocab {
        let word: String
        if i > special.beg {
          word = "[_TT_\(i - special.beg)]"
        } else if i == special.eot {
          word = "[_EOT_]"
        } else if i == special.sot {
          word = "[_SOT_]"
        } else if i == special.translate {
          word = "[_TRANSLATE_]"
        } else if i == special.transcribe {
          word = "[_TRANSCRIBE_]"
        } else if i == special.solm {
          word = "[_SOLM_]"
        } else if i == special.prev {
          word = "[_PREV_]"
        } else if i == special.nosp {
          word = "[_NOSP_]"
        } else if i == special.not {
          word = "[_NOT_]"
        } else if i == special.beg {
          word = "[_BEG_]"
        } else if i > special.sot, i <= special.sot + special.numLanguages,
          let code = WhisperLanguages.code(id: i - special.sot - 1)
        {
          // whisper.cpp calls whisper_lang_str here, which has no answer past the table (undefined behaviour in
          // C++); a file that large would need a language we do not know, so fall through to the generic name.
          word = "[_LANG_\(code)]"
        } else {
          word = "[_extra_token_\(i)]"
        }
        tokens.append(Array(word.utf8))
      }
    }

    return Vocabulary(
      tokens: tokens, isMultilingual: special.isMultilingual, eot: eot, sot: sot, sotLanguage: sot &+ 1,
      translate: translate, transcribe: transcribe, solm: solm, prev: prev, nosp: nosp, not: not, beg: beg)
  }
}

extension WhisperText {
  /// The text whisper.cpp assembles for a segment from `ids` with `print_special` off (`whisper_full_with_state`):
  /// every token below `eot` contributes its bytes, every special token (eot and up: sot, languages, tasks,
  /// timestamps) is dropped. Ids outside the vocabulary are dropped too (whisper.cpp would throw from `map::at`).
  /// The joined bytes decode as UTF-8 with U+FFFD for malformed sequences, so valid text round-trips exactly and bad
  /// bytes never crash. Nothing is trimmed: a token's leading space (" Hello") stays, as in whisper.cpp; callers trim.
  public static func decode(_ ids: [Int32], vocabulary: Vocabulary) -> String {
    var bytes = [UInt8]()
    for id in ids where id >= 0 && id < vocabulary.eot && Int(id) < vocabulary.tokens.count {
      bytes.append(contentsOf: vocabulary.tokens[Int(id)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// One token's bytes as text (`whisper_token_to_str`), special tokens included; nil for an id outside the vocabulary.
  public static func token(_ id: Int32, vocabulary: Vocabulary) -> String? {
    guard id >= 0, Int(id) < vocabulary.tokens.count else { return nil }
    return String(decoding: vocabulary.tokens[Int(id)], as: UTF8.self)
  }
}
