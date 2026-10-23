import Foundation
import XCTest
@testable import WhisperEngine

final class VocabularyTests: XCTestCase {
  /// The file tokens whisper.cpp's converter writes for a fictional tiny vocabulary: the padding logic only looks
  /// at ids, so a handful of real words suffice.
  static let words: [[UInt8]] = [Array("!".utf8), Array(" Hello".utf8), Array(" world".utf8), [0xE2, 0x82], [0xAC]]

  func testEnglishOnlySpecialTokens() {
    let v = Vocabulary.whisper(fileTokens: Self.words, nVocab: 51864)
    XCTAssertFalse(v.isMultilingual)
    XCTAssertEqual(v.eot, 50256)
    XCTAssertEqual(v.sot, 50257)
    XCTAssertEqual(v.sotLanguage, 50258)
    XCTAssertEqual(v.translate, 50357)
    XCTAssertEqual(v.transcribe, 50358)
    XCTAssertEqual(v.solm, 50359)
    XCTAssertEqual(v.prev, 50360)
    XCTAssertEqual(v.nosp, 50361)
    XCTAssertEqual(v.not, 50362)
    XCTAssertEqual(v.beg, 50363)
    XCTAssertEqual(v.tokens.count, 51864)
    XCTAssertEqual(String(decoding: v.tokens[50256], as: UTF8.self), "[_EOT_]")
    XCTAssertEqual(String(decoding: v.tokens[50257], as: UTF8.self), "[_SOT_]")
    // English-only models still get language names for the ids between sot and translate (num_languages is 99).
    XCTAssertEqual(String(decoding: v.tokens[50258], as: UTF8.self), "[_LANG_en]")
    XCTAssertEqual(String(decoding: v.tokens[50356], as: UTF8.self), "[_LANG_su]")
    XCTAssertEqual(String(decoding: v.tokens[50357], as: UTF8.self), "[_TRANSLATE_]")
    XCTAssertEqual(String(decoding: v.tokens[50363], as: UTF8.self), "[_BEG_]")
    XCTAssertEqual(String(decoding: v.tokens[50364], as: UTF8.self), "[_TT_1]")
    XCTAssertEqual(String(decoding: v.tokens[51863], as: UTF8.self), "[_TT_1500]")
    XCTAssertEqual(String(decoding: v.tokens[5], as: UTF8.self), "[_extra_token_5]")
  }

  func testMultilingualSpecialTokens() {
    let v = Vocabulary.whisper(fileTokens: Self.words, nVocab: 51865)
    XCTAssertTrue(v.isMultilingual)
    XCTAssertEqual(v.eot, 50257)
    XCTAssertEqual(v.sot, 50258)
    XCTAssertEqual(v.sotLanguage, 50259)
    XCTAssertEqual(v.translate, 50358)
    XCTAssertEqual(v.transcribe, 50359)
    XCTAssertEqual(v.solm, 50360)
    XCTAssertEqual(v.prev, 50361)
    XCTAssertEqual(v.nosp, 50362)
    XCTAssertEqual(v.not, 50363)
    XCTAssertEqual(v.beg, 50364)
    XCTAssertEqual(v.tokens.count, 51865)
    XCTAssertEqual(String(decoding: v.tokens[50259], as: UTF8.self), "[_LANG_en]")
    XCTAssertEqual(String(decoding: v.tokens[50357], as: UTF8.self), "[_LANG_su]")
    XCTAssertEqual(String(decoding: v.tokens[50358], as: UTF8.self), "[_TRANSLATE_]")
    XCTAssertEqual(String(decoding: v.tokens[51864], as: UTF8.self), "[_TT_1500]")
  }

  /// large-v3: 100 languages shift the task tokens by two.
  func testLargeV3SpecialTokens() {
    let v = Vocabulary.whisper(fileTokens: Self.words, nVocab: 51866)
    XCTAssertEqual(v.eot, 50257)
    XCTAssertEqual(v.sot, 50258)
    XCTAssertEqual(v.sotLanguage, 50259)
    XCTAssertEqual(v.translate, 50359)
    XCTAssertEqual(v.transcribe, 50360)
    XCTAssertEqual(v.solm, 50361)
    XCTAssertEqual(v.prev, 50362)
    XCTAssertEqual(v.nosp, 50363)
    XCTAssertEqual(v.not, 50364)
    XCTAssertEqual(v.beg, 50365)
    XCTAssertEqual(v.tokens.count, 51866)
    XCTAssertEqual(String(decoding: v.tokens[50358], as: UTF8.self), "[_LANG_yue]")
    XCTAssertEqual(String(decoding: v.tokens[50359], as: UTF8.self), "[_TRANSLATE_]")
    XCTAssertEqual(String(decoding: v.tokens[51865], as: UTF8.self), "[_TT_1500]")
    XCTAssertEqual(v.languageToken("yue"), 50358)
    XCTAssertEqual(v.languageCode(50358), "yue")
  }

  /// A file with at least n_vocab words is taken as is.
  func testNoPaddingWhenFileIsComplete() {
    let v = Vocabulary.whisper(fileTokens: Self.words, nVocab: 3)
    XCTAssertEqual(v.tokens.count, 5)
    XCTAssertEqual(v.tokens, Self.words)
  }

  func testDecodeSkipsSpecialTokensAndKeepsSpaces() {
    let v = Vocabulary.whisper(fileTokens: Self.words, nVocab: 51865)
    XCTAssertEqual(v.text([1, 2]), " Hello world")
    XCTAssertEqual(v.text([v.sot, v.sotLanguage, v.transcribe, v.not, 1, 2, v.beg + 5, v.eot]), " Hello world")
    XCTAssertEqual(v.text([]), "")
    XCTAssertEqual(v.text([v.eot]), "")
    // The euro sign split across two tokens joins into one character.
    XCTAssertEqual(v.text([3, 4]), "\u{20AC}")
    XCTAssertEqual(v.text([1, 3, 4, 0]), " Hello\u{20AC}!")
  }

  func testDecodeIsSafeOnBadInput() {
    let v = Vocabulary.whisper(fileTokens: Self.words, nVocab: 51865)
    // A lone continuation byte becomes U+FFFD; a negative or out-of-range id is dropped.
    XCTAssertEqual(v.text([4, 1]), "\u{FFFD} Hello")
    XCTAssertEqual(v.text([-1, 1, 60000, Int32.max, Int32.min]), " Hello")
    XCTAssertEqual(v.text([3]), "\u{FFFD}")
    let short = Vocabulary.whisper(fileTokens: Self.words, nVocab: 3)
    XCTAssertEqual(short.text([1, 7]), " Hello")
    XCTAssertNil(WhisperText.token(7, vocabulary: short))
    XCTAssertNil(WhisperText.token(-1, vocabulary: short))
    XCTAssertEqual(WhisperText.token(2, vocabulary: short), " world")
  }
}
