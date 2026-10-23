import XCTest
@testable import Dictation

/// Dictation's text placement, Whisper's transcript cleanup, the models it offers and the dictation's resting state.
@MainActor
final class DictationTests: XCTestCase {
    func testInsertIntoEmptyDraft() {
        let result = DictationText.insert("  Run the tests.  ", into: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result.text, "Run the tests.")
        XCTAssertEqual(result.selection, NSRange(location: 14, length: 0))
    }

    func testInsertSpacesAfterAWordAndBeforeTheNext() {
        let result = DictationText.insert("the failing", into: "Fix tests", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(result.text, "Fix the failing tests")
        XCTAssertEqual(result.selection, NSRange(location: 15, length: 0))
    }

    func testInsertReplacesTheSelection() {
        let result = DictationText.insert("Linux", into: "Build for macOS now", selection: NSRange(location: 10, length: 5))
        XCTAssertEqual(result.text, "Build for Linux now")
        XCTAssertEqual(result.selection, NSRange(location: 15, length: 0))
    }

    func testInsertKeepsPunctuationAttached() {
        XCTAssertEqual(DictationText.insert(", please", into: "Deploy", selection: NSRange(location: 6, length: 0)).text,
                       "Deploy, please")
        XCTAssertEqual(DictationText.insert("Deploy", into: "?", selection: NSRange(location: 0, length: 0)).text, "Deploy?")
        XCTAssertEqual(DictationText.insert("again", into: "Try \n", selection: NSRange(location: 4, length: 0)).text, "Try again\n")
    }

    func testInsertClampsAStaleSelection() {
        let result = DictationText.insert("done", into: "All", selection: NSRange(location: 40, length: 3))
        XCTAssertEqual(result.text, "All done")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 0))
    }

    func testInsertOfNothingLeavesTheDraft() {
        let result = DictationText.insert(" \n", into: "Keep", selection: NSRange(location: 2, length: 1))
        XCTAssertEqual(result.text, "Keep")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 1))
    }

    func testWhisperCleanupDropsMarkers() {
        XCTAssertEqual(WhisperTranscriber.clean(" [BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperTranscriber.clean(" (music)"), "")
        XCTAssertEqual(WhisperTranscriber.clean(" Open the  logs [inaudible] now.\n"), "Open the logs now.")
        XCTAssertEqual(WhisperTranscriber.clean(" Rename it (the old one) later."), "Rename it (the old one) later.")
    }

    func testWhisperModelsAreDistinctVerifiedFiles() {
        let models = WhisperModel.allCases
        XCTAssertEqual(models.map(\.title), ["Small", "Large v3 Turbo"])
        XCTAssertEqual(Set(models.map(\.fileName)).count, models.count)
        for model in models {
            XCTAssertEqual(model.sha256.count, 64, model.title)
            XCTAssertEqual(model.url.host, "huggingface.co")
            XCTAssertTrue(model.url.path.hasSuffix("/" + model.fileName))
            XCTAssertGreaterThan(model.bytes, 100_000_000)
        }
    }

    func testDictationRestsIdleUntilStarted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-" + UUID().uuidString)
        let dictation = Dictation(models: WhisperModelStore(directory: directory))
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertFalse(dictation.active("composer"))
        XCTAssertNil(dictation.error(for: "composer"))
        // Stopping or cancelling nothing is harmless.
        dictation.stop()
        dictation.cancel()
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertNil(dictation.owner)
        XCTAssertEqual(dictation.partial, "")
        XCTAssertEqual(dictation.level, 0)
    }
}
