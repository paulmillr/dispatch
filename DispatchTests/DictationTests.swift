import AppKit
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
        XCTAssertEqual(fresh.dictationKey, .rightCommand, "and so is holding right ⌘")
        XCTAssertTrue(fresh.dictationNavigation, "and “Dispatch, …” navigation")
        XCTAssertTrue(fresh.dictationReadReplies, "and reading replies in conversation mode")
        XCTAssertEqual(fresh.dictationWakeWords, ["dispatch", "captain"])
        XCTAssertEqual(fresh.dictationEngine, .apple)
        XCTAssertEqual(fresh.whisperModel, .small)
        var chosen = Preferences()
        chosen.dictationEnabled = false
        chosen.dictationKey = .rightOption
        chosen.dictationNavigation = false
        chosen.dictationReadReplies = false
        chosen.dictationWakeWords = ["jarvis"]
        chosen.dictationEngine = .whisper
        chosen.whisperModel = .turbo
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen))
        XCTAssertFalse(decoded.dictationEnabled)
        XCTAssertEqual(decoded.dictationKey, .rightOption)
        let switchedOff = #"{"dictationRightCommand": false}"#
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(switchedOff.utf8)).dictationKey, .off,
                       "the right ⌘ switch saved off before the key could be chosen stays off")
        XCTAssertFalse(decoded.dictationNavigation)
        XCTAssertFalse(decoded.dictationReadReplies)
        XCTAssertEqual(decoded.dictationWakeWords, ["jarvis"])
        let unusable = #"{"dictationWakeWords": ["send", "two words"]}"#
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(unusable.utf8)).dictationWakeWords, ["dispatch", "captain"],
                       "a hand-edited list with no usable word keeps the defaults")
        XCTAssertEqual(decoded.dictationEngine, .whisper)
        XCTAssertEqual(decoded.whisperModel, .turbo)
        let unknown = #"{"dictationEngine": "unknown", "whisperModel": "unknown", "dictationKey": "unknown", "fontSize": 14}"#
        let fallback = try JSONDecoder().decode(Preferences.self, from: Data(unknown.utf8))
        XCTAssertEqual(fallback.dictationEngine, .apple)
        XCTAssertEqual(fallback.whisperModel, .small)
        XCTAssertEqual(fallback.dictationKey, .rightCommand)
        XCTAssertEqual(fallback.fontSize, 14, "the other settings survive")
    }

    /// Each voice key by its own device bit, alone only without any other modifier (the other side's included).
    func testVoiceKeysMatchTheirOwnKeyAlone() {
        func flags(_ device: UInt, _ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
            NSEvent.ModifierFlags(rawValue: modifiers.rawValue | device)
        }
        let rightCommand = flags(0x10, .command), leftCommand = flags(0x08, .command)
        let rightOption = flags(0x40, .option), leftOption = flags(0x20, .option)
        XCTAssertEqual(VoiceKey.allCases.map(\.keyCode), [54, 61, 63, nil])
        XCTAssertTrue(VoiceKey.rightCommand.isDown(rightCommand) && VoiceKey.rightCommand.alone(rightCommand))
        XCTAssertFalse(VoiceKey.rightCommand.isDown(leftCommand), "left ⌘ is not the voice key")
        XCTAssertFalse(VoiceKey.rightCommand.alone(flags(0x18, .command)), "both ⌘ keys are a chord")
        XCTAssertFalse(VoiceKey.rightCommand.alone(flags(0x10, [.command, .shift])))
        XCTAssertTrue(VoiceKey.rightOption.isDown(rightOption) && VoiceKey.rightOption.alone(rightOption))
        XCTAssertFalse(VoiceKey.rightOption.isDown(leftOption))
        XCTAssertFalse(VoiceKey.rightOption.alone(flags(0x60, .option)))
        XCTAssertFalse(VoiceKey.rightOption.isDown(rightCommand))
        XCTAssertTrue(VoiceKey.function.isDown(.function) && VoiceKey.function.alone(.function))
        XCTAssertFalse(VoiceKey.function.alone([.function, .command]))
        XCTAssertFalse(VoiceKey.off.isDown(rightCommand) || VoiceKey.off.alone(rightCommand))
    }
}

extension DictationTests {
    /// Parakeet is saved like the other engines, and the Whisper model chosen before stays for a switch back.
    func testPreferencesKeepParakeetAndTheWhisperModel() throws {
        var chosen = Preferences()
        chosen.whisperModel = .turbo
        chosen.dictationEngine = .parakeet
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(decoded.dictationEngine, .parakeet)
        XCTAssertEqual(decoded.whisperModel, .turbo)
        XCTAssertEqual(decoded.dictationEngine.label(whisper: decoded.whisperModel), "Parakeet", "what the microphone's help names")
    }
}
