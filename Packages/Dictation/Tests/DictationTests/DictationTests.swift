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

    /// Parakeet's download: the Core ML models FluidAudio loads for v3, from one revision, every file checked.
    func testParakeetIsAPinnedFolderOfVerifiedFiles() {
        let files = ParakeetModel.files
        XCTAssertEqual(Set(files.map { $0.path.split(separator: "/").first.map(String.init) ?? "" }),
                       ["Preprocessor.mlmodelc", "Encoder_v2.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
                        "parakeet_vocab.json"])
        XCTAssertEqual(Set(files.map(\.path)).count, files.count)
        for file in files {
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertGreaterThan(file.bytes, 0, file.path)
            XCTAssertEqual(file.url.absoluteString,
                           "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(ParakeetModel.revision)/\(file.path)")
        }
        XCTAssertEqual(DictationModel.parakeet.bytes, 632_169_729)
        XCTAssertEqual(DictationModel.all, [.whisper(.small), .whisper(.turbo), .parakeet])
    }

    func testEnginesNameTheirModels() {
        XCTAssertEqual(DictationEngine.allCases, [.apple, .whisper, .parakeet])
        XCTAssertNil(DictationEngine.apple.model(whisper: .turbo))
        XCTAssertEqual(DictationEngine.whisper.model(whisper: .turbo), .whisper(.turbo))
        XCTAssertEqual(DictationEngine.parakeet.model(whisper: .turbo), .parakeet, "Parakeet has one model")
        XCTAssertEqual(DictationEngine.whisper.label(whisper: .small), "Whisper Small")
        XCTAssertEqual(DictationEngine.parakeet.label(whisper: .small), "Parakeet")
        XCTAssertEqual(DictationError.modelMissing(.parakeet).errorDescription,
                       "Download the Parakeet model in Settings to dictate with it.")
    }

    func testParakeetTextJoinsPiecesAndDropsSpecialTokens() throws {
        var pieces = ["<unk>", "<|nospeech|>", "▁Hel", "lo", ",", "▁wor", "ld", "."]
        pieces += Array(repeating: "", count: 8192 - pieces.count)
        let json = Dictionary(uniqueKeysWithValues: pieces.enumerated().map { (String($0.offset), $0.element) })
        let vocabulary = try ParakeetTranscriber.vocabulary(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(vocabulary.count, 8192, "every id below the blank")
        XCTAssertEqual(ParakeetTranscriber.text([1, 2, 3, 4, 0, 5, 6, 7], vocabulary: vocabulary), "Hello, world.")
        XCTAssertEqual(ParakeetTranscriber.text([], vocabulary: vocabulary), "")
        XCTAssertEqual(ParakeetTranscriber.text([8192, 9000], vocabulary: vocabulary), "", "the blank and beyond are no text")
    }

    func testDictationRestsIdleUntilStarted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-" + UUID().uuidString)
        let dictation = Dictation(models: DictationModelStore(whisper: directory, parakeet: directory))
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
