import Foundation
import XCTest
@testable import WhisperEngine

final class LanguagesTests: XCTestCase {
  func testTableMatchesWhisperCpp() {
    XCTAssertEqual(WhisperLanguages.all.count, 100)
    for (index, language) in WhisperLanguages.all.enumerated() { XCTAssertEqual(language.id, index) }
    XCTAssertEqual(Set(WhisperLanguages.codes).count, 100)
    XCTAssertEqual(WhisperLanguages.codes.prefix(10), ["en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr"])
    XCTAssertEqual(WhisperLanguages.codes.suffix(3), ["jw", "su", "yue"])
    XCTAssertEqual(WhisperLanguages.name("en"), "english")
    XCTAssertEqual(WhisperLanguages.name("ht"), "haitian creole")
    XCTAssertEqual(WhisperLanguages.name("yue"), "cantonese")
    XCTAssertNil(WhisperLanguages.name("xx"))
    XCTAssertEqual(WhisperLanguages.id("de"), 2)
    XCTAssertEqual(WhisperLanguages.id("german"), 2)
    XCTAssertEqual(WhisperLanguages.id("haw"), 93)
    XCTAssertNil(WhisperLanguages.id("German"))
    XCTAssertEqual(WhisperLanguages.code(id: 99), "yue")
    XCTAssertNil(WhisperLanguages.code(id: 100))
    XCTAssertNil(WhisperLanguages.code(id: -1))
  }

  func testTokensFollowSot() {
    let v = Vocabulary.whisper(fileTokens: [], nVocab: 51865)
    XCTAssertEqual(WhisperLanguages.token("en", vocabulary: v), 50259)
    XCTAssertEqual(WhisperLanguages.token("english", vocabulary: v), 50259)
    XCTAssertEqual(WhisperLanguages.token("zh", vocabulary: v), 50260)
    XCTAssertEqual(WhisperLanguages.token("su", vocabulary: v), 50357)
    XCTAssertNil(WhisperLanguages.token("klingon", vocabulary: v))
    for language in WhisperLanguages.all {
      let token = try! XCTUnwrap(v.languageToken(language.code))
      XCTAssertEqual(v.languageCode(token), language.code)
      XCTAssertEqual(token, v.sot + 1 + Int32(language.id))
    }
    XCTAssertNil(v.languageCode(v.sot))
    XCTAssertNil(v.languageCode(v.translate + 1))
    XCTAssertNil(v.languageCode(v.eot))
    XCTAssertNil(v.languageCode(0))

    let english = Vocabulary.whisper(fileTokens: [], nVocab: 51864)
    XCTAssertEqual(english.languageToken("en"), 50258)
  }
}
