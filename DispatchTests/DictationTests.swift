import Dictation
import XCTest
@testable import DispatchApp

/// The Mac's dictation settings. The engine's own tests (text placement, Whisper's cleanup, the model store) are the
/// Dictation package's (Packages/Dictation, `swift test`).
@MainActor
final class DictationTests: XCTestCase {
    func testPreferencesDefaultToAppleAndKeepTheWhisperChoice() throws {
        let fresh = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.dictationEngine, .apple)
        XCTAssertEqual(fresh.whisperModel, .small)
        var chosen = Preferences()
        chosen.dictationEngine = .whisper
        chosen.whisperModel = .medium
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(decoded.dictationEngine, .whisper)
        XCTAssertEqual(decoded.whisperModel, .medium)
        let unknown = #"{"dictationEngine": "unknown", "whisperModel": "unknown", "fontSize": 14}"#
        let fallback = try JSONDecoder().decode(Preferences.self, from: Data(unknown.utf8))
        XCTAssertEqual(fallback.dictationEngine, .apple)
        XCTAssertEqual(fallback.whisperModel, .small)
        XCTAssertEqual(fallback.fontSize, 14, "the other settings survive")
    }
}
