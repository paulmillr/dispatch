import Foundation

// whisper.cpp's `g_lang` table: language code, id and English name, in id order. The id is the language's position
// among the language tokens, which follow sot: `whisper_token_lang(ctx, id) = sot + 1 + id`. Models before
// large-v3 know the first 99 (ids 0...98); large-v3 adds Cantonese (99). The table is the same for every model, so
// a token outside the model's range is a valid lookup that the model never produces.

extension WhisperLanguages {
  /// One `g_lang` entry.
  public struct Language: Sendable, Equatable {
    public let code: String
    public let id: Int
    public let name: String
  }

  /// All languages in id order.
  public static let all: [Language] = [
    Language(code: "en", id: 0, name: "english"),
    Language(code: "zh", id: 1, name: "chinese"),
    Language(code: "de", id: 2, name: "german"),
    Language(code: "es", id: 3, name: "spanish"),
    Language(code: "ru", id: 4, name: "russian"),
    Language(code: "ko", id: 5, name: "korean"),
    Language(code: "fr", id: 6, name: "french"),
    Language(code: "ja", id: 7, name: "japanese"),
    Language(code: "pt", id: 8, name: "portuguese"),
    Language(code: "tr", id: 9, name: "turkish"),
    Language(code: "pl", id: 10, name: "polish"),
    Language(code: "ca", id: 11, name: "catalan"),
    Language(code: "nl", id: 12, name: "dutch"),
    Language(code: "ar", id: 13, name: "arabic"),
    Language(code: "sv", id: 14, name: "swedish"),
    Language(code: "it", id: 15, name: "italian"),
    Language(code: "id", id: 16, name: "indonesian"),
    Language(code: "hi", id: 17, name: "hindi"),
    Language(code: "fi", id: 18, name: "finnish"),
    Language(code: "vi", id: 19, name: "vietnamese"),
    Language(code: "he", id: 20, name: "hebrew"),
    Language(code: "uk", id: 21, name: "ukrainian"),
    Language(code: "el", id: 22, name: "greek"),
    Language(code: "ms", id: 23, name: "malay"),
    Language(code: "cs", id: 24, name: "czech"),
    Language(code: "ro", id: 25, name: "romanian"),
    Language(code: "da", id: 26, name: "danish"),
    Language(code: "hu", id: 27, name: "hungarian"),
    Language(code: "ta", id: 28, name: "tamil"),
    Language(code: "no", id: 29, name: "norwegian"),
    Language(code: "th", id: 30, name: "thai"),
    Language(code: "ur", id: 31, name: "urdu"),
    Language(code: "hr", id: 32, name: "croatian"),
    Language(code: "bg", id: 33, name: "bulgarian"),
    Language(code: "lt", id: 34, name: "lithuanian"),
    Language(code: "la", id: 35, name: "latin"),
    Language(code: "mi", id: 36, name: "maori"),
    Language(code: "ml", id: 37, name: "malayalam"),
    Language(code: "cy", id: 38, name: "welsh"),
    Language(code: "sk", id: 39, name: "slovak"),
    Language(code: "te", id: 40, name: "telugu"),
    Language(code: "fa", id: 41, name: "persian"),
    Language(code: "lv", id: 42, name: "latvian"),
    Language(code: "bn", id: 43, name: "bengali"),
    Language(code: "sr", id: 44, name: "serbian"),
    Language(code: "az", id: 45, name: "azerbaijani"),
    Language(code: "sl", id: 46, name: "slovenian"),
    Language(code: "kn", id: 47, name: "kannada"),
    Language(code: "et", id: 48, name: "estonian"),
    Language(code: "mk", id: 49, name: "macedonian"),
    Language(code: "br", id: 50, name: "breton"),
    Language(code: "eu", id: 51, name: "basque"),
    Language(code: "is", id: 52, name: "icelandic"),
    Language(code: "hy", id: 53, name: "armenian"),
    Language(code: "ne", id: 54, name: "nepali"),
    Language(code: "mn", id: 55, name: "mongolian"),
    Language(code: "bs", id: 56, name: "bosnian"),
    Language(code: "kk", id: 57, name: "kazakh"),
    Language(code: "sq", id: 58, name: "albanian"),
    Language(code: "sw", id: 59, name: "swahili"),
    Language(code: "gl", id: 60, name: "galician"),
    Language(code: "mr", id: 61, name: "marathi"),
    Language(code: "pa", id: 62, name: "punjabi"),
    Language(code: "si", id: 63, name: "sinhala"),
    Language(code: "km", id: 64, name: "khmer"),
    Language(code: "sn", id: 65, name: "shona"),
    Language(code: "yo", id: 66, name: "yoruba"),
    Language(code: "so", id: 67, name: "somali"),
    Language(code: "af", id: 68, name: "afrikaans"),
    Language(code: "oc", id: 69, name: "occitan"),
    Language(code: "ka", id: 70, name: "georgian"),
    Language(code: "be", id: 71, name: "belarusian"),
    Language(code: "tg", id: 72, name: "tajik"),
    Language(code: "sd", id: 73, name: "sindhi"),
    Language(code: "gu", id: 74, name: "gujarati"),
    Language(code: "am", id: 75, name: "amharic"),
    Language(code: "yi", id: 76, name: "yiddish"),
    Language(code: "lo", id: 77, name: "lao"),
    Language(code: "uz", id: 78, name: "uzbek"),
    Language(code: "fo", id: 79, name: "faroese"),
    Language(code: "ht", id: 80, name: "haitian creole"),
    Language(code: "ps", id: 81, name: "pashto"),
    Language(code: "tk", id: 82, name: "turkmen"),
    Language(code: "nn", id: 83, name: "nynorsk"),
    Language(code: "mt", id: 84, name: "maltese"),
    Language(code: "sa", id: 85, name: "sanskrit"),
    Language(code: "lb", id: 86, name: "luxembourgish"),
    Language(code: "my", id: 87, name: "myanmar"),
    Language(code: "bo", id: 88, name: "tibetan"),
    Language(code: "tl", id: 89, name: "tagalog"),
    Language(code: "mg", id: 90, name: "malagasy"),
    Language(code: "as", id: 91, name: "assamese"),
    Language(code: "tt", id: 92, name: "tatar"),
    Language(code: "haw", id: 93, name: "hawaiian"),
    Language(code: "ln", id: 94, name: "lingala"),
    Language(code: "ha", id: 95, name: "hausa"),
    Language(code: "ba", id: 96, name: "bashkir"),
    Language(code: "jw", id: 97, name: "javanese"),
    Language(code: "su", id: 98, name: "sundanese"),
    Language(code: "yue", id: 99, name: "cantonese"),
  ]

  /// Language codes in id order (`"en"`, `"zh"`, ...).
  public static var codes: [String] { all.map(\.code) }

  private static let byCode: [String: Language] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
  private static let byName: [String: Language] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

  /// The English name of a language code, nil when unknown.
  public static func name(_ code: String) -> String? { byCode[code]?.name }

  /// `whisper_lang_id`: the id of a code, or of a full English name ("english"), nil when unknown.
  public static func id(_ codeOrName: String) -> Int? { (byCode[codeOrName] ?? byName[codeOrName])?.id }

  /// `whisper_lang_str`: the code of an id, nil past the table.
  public static func code(id: Int) -> String? { all.indices.contains(id) ? all[id].code : nil }

  /// `whisper_token_lang` for a code (or English name): `sot + 1 + id`. The token is computed for any table entry,
  /// as in whisper.cpp; a model with fewer languages simply never emits the last ones.
  /// The arithmetic runs in `Int`, so a vocabulary with ids near the `Int32` limits yields nil rather than a trap.
  public static func token(_ code: String, vocabulary: Vocabulary) -> Int32? {
    guard let id = id(code) else { return nil }
    return Int32(exactly: Int(vocabulary.sotLanguage) + id)
  }

  /// The code of a language token (`sot + 1 ... sot + table size`), nil for any other token.
  public static func code(_ token: Int32, vocabulary: Vocabulary) -> String? {
    let id = Int(token) - Int(vocabulary.sotLanguage)
    return code(id: id)
  }
}
