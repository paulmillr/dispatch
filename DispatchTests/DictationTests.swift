import Dictation
import XCTest
@testable import DispatchApp

/// The Mac's dictation settings. The engine's own tests (text placement, Whisper's cleanup, the model store) are the
/// Dictation package's (Packages/Dictation, `swift test`).
@MainActor
final class DictationTests: XCTestCase {
    func testPreferencesDefaultToAppleAndKeepTheWhisperChoice() throws {
        let fresh = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(fresh.dictationEnabled, "Dictation is on by default")
        XCTAssertTrue(fresh.dictationRightCommand, "and so is holding right ⌘")
        XCTAssertTrue(fresh.dictationNavigation, "and “Dispatch, …” navigation")
        XCTAssertTrue(fresh.dictationReadReplies, "and reading replies in conversation mode")
        XCTAssertEqual(fresh.dictationWakeWords, ["dispatch", "captain"])
        XCTAssertEqual(fresh.dictationEngine, .apple)
        XCTAssertEqual(fresh.whisperModel, .small)
        var chosen = Preferences()
        chosen.dictationEnabled = false
        chosen.dictationRightCommand = false
        chosen.dictationNavigation = false
        chosen.dictationReadReplies = false
        chosen.dictationWakeWords = ["jarvis"]
        chosen.dictationEngine = .whisper
        chosen.whisperModel = .turbo
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen))
        XCTAssertFalse(decoded.dictationEnabled)
        XCTAssertFalse(decoded.dictationRightCommand)
        XCTAssertFalse(decoded.dictationNavigation)
        XCTAssertFalse(decoded.dictationReadReplies)
        XCTAssertEqual(decoded.dictationWakeWords, ["jarvis"])
        let unusable = #"{"dictationWakeWords": ["send", "two words"]}"#
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(unusable.utf8)).dictationWakeWords, ["dispatch", "captain"],
                       "a hand-edited list with no usable word keeps the defaults")
        XCTAssertEqual(decoded.dictationEngine, .whisper)
        XCTAssertEqual(decoded.whisperModel, .turbo)
        let unknown = #"{"dictationEngine": "unknown", "whisperModel": "unknown", "fontSize": 14}"#
        let fallback = try JSONDecoder().decode(Preferences.self, from: Data(unknown.utf8))
        XCTAssertEqual(fallback.dictationEngine, .apple)
        XCTAssertEqual(fallback.whisperModel, .small)
        XCTAssertEqual(fallback.fontSize, 14, "the other settings survive")
    }
}
