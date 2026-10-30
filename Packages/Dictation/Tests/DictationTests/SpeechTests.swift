#if os(macOS)
@preconcurrency import AVFoundation
import Speech
import XCTest
@testable import Dictation

/// Every engine transcribes a recording of `say` reading a sentence, fed to their recognizers in microphone-sized
/// buffers as dictation does. Each skips where its engine can't run without a download or a permission prompt.
@MainActor
final class SpeechTests: XCTestCase {
    /// Words a recognizer doesn't guess by accident.
    static let sentence = "Please ask the purple giraffe to carry the lanterns to the canoe."
    static let words = ["purple", "giraffe", "lanterns", "canoe"]

    func testAppleTranscribesSpeech() async throws {
        guard Locale.current.language.languageCode == .english else {
            throw XCTSkip("Apple's engine follows the system language, \(Locale.current.identifier), and the sentence is English")
        }
        if #available(macOS 26, *) {
            // SpeechAnalyzer needs no permission; its model must be on the Mac already: the test doesn't download it.
            let status = try await AppleTranscriber.assetStatus()
            let module = SpeechTranscriber.isAvailable ? "SpeechTranscriber" : "DictationTranscriber"
            print("Apple speech asset (\(module), \(Locale.current.identifier)): \(status.map { String(describing: $0) } ?? "unsupported")")
            guard status == .installed else {
                throw XCTSkip("Apple's speech model for \(Locale.current.identifier) isn't installed (\(String(describing: status)))")
            }
        } else {
            // SFSpeechRecognizer: without authorization, asking would prompt.
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                throw XCTSkip("Speech recognition isn't authorized for this process")
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.supportsOnDeviceRecognition,
                  recognizer.isAvailable else {
                throw XCTSkip("On-device speech recognition isn't available for \(Locale.current.identifier)")
            }
        }
        let audio = try recording()
        let recognizer = try await AppleTranscriber.make(input: audio.format, partial: { _ in })
        let transcript = try await transcribe(audio, with: recognizer, timeout: 120)
        print("Apple transcript: \(transcript)")
        assertHeard(transcript)
    }

    func testWhisperTranscribesSpeech() async throws {
        let model = try whisperModel()
        let audio = try recording()
        let recognizer = StretchRecognizer(input: audio.format, transcriber: WhisperTranscriber.shared, model: model)
        let transcript = try await transcribe(audio, with: recognizer, timeout: 180)
        print("Whisper transcript: \(transcript)")
        assertHeard(transcript)
    }

    func testParakeetTranscribesSpeech() async throws {
        let model = try parakeetModel()
        let audio = try recording()
        let recognizer = StretchRecognizer(input: audio.format, transcriber: ParakeetTranscriber.shared, model: model)
        // The first load compiles the models for the Neural Engine.
        let transcript = try await transcribe(audio, with: recognizer, timeout: 180)
        print("Parakeet transcript: \(transcript)")
        assertHeard(transcript)
    }

    /// Whisper settles a stretch the speaker paused after while the recording goes on: the text is there before the
    /// user stops, and the transcript keeps it.
    func testWhisperSettlesWhatWasSaidBeforeAPause() async throws {
        try await settlesBeforeAPause(WhisperTranscriber.shared, model: try whisperModel())
    }

    func testParakeetSettlesWhatWasSaidBeforeAPause() async throws {
        try await settlesBeforeAPause(ParakeetTranscriber.shared, model: try parakeetModel())
    }

    private func settlesBeforeAPause(_ transcriber: any StretchTranscriber, model: URL) async throws {
        let audio = try recording("Please ask the purple giraffe to carry the lanterns. [[slnc 1500]] Then paddle the canoe home.")
        let heard = Outcome()
        let settled = expectation(description: "the first sentence before stopping")
        let recognizer = StretchRecognizer(input: audio.format, transcriber: transcriber, model: model) { text in
            heard.set(.success(text))
            if text.lowercased().contains("giraffe") { settled.fulfill() }
        }
        settled.assertForOverFulfill = false
        for buffer in audio.buffers { recognizer.append(buffer) }
        await fulfillment(of: [settled], timeout: 120)
        let transcript = try await recognizer.finish()
        print("\(type(of: transcriber)) streamed: \(transcript)")
        assertHeard(transcript)
    }

    /// Conversation mode end to end, with each engine: a recording with two pauses comes out as two utterances and,
    /// once stopped, the last one; in order, none lost.
    func testConversationWithWhisper() async throws {
        let model = try whisperModel()
        let store = DictationModelStore(whisper: model.deletingLastPathComponent(), parakeet: Self.noModels)
        try await converse(engine: .whisper, store: store)
    }

    func testConversationWithParakeet() async throws {
        let model = try parakeetModel()
        let store = DictationModelStore(whisper: Self.noModels, parakeet: model.deletingLastPathComponent())
        try await converse(engine: .parakeet, store: store)
    }

    func testConversationWithApple() async throws {
        guard Locale.current.language.languageCode == .english else { throw XCTSkip("the sentences are English") }
        if #available(macOS 26, *) {
            guard try await AppleTranscriber.assetStatus() == .installed else { throw XCTSkip("Apple's speech model isn't installed") }
        } else {
            throw XCTSkip("conversation mode is checked with SpeechAnalyzer")
        }
        let store = DictationModelStore(whisper: Self.noModels, parakeet: Self.noModels)
        try await converse(engine: .apple, store: store)
    }

    private func converse(engine: DictationEngine, store: DictationModelStore) async throws {
        let audio = try recording("Please ask the purple giraffe to carry the lanterns. [[slnc 1500]] Dispatch, send. "
                                  + "[[slnc 1500]] Then paddle the canoe home. [[slnc 400]]")
        let dictation = Dictation(models: store)
        let played = Played()
        dictation.access = { true }
        dictation.input = { RecordingInput(audio, played: played) }
        var updates: [DictationUpdate] = []
        dictation.start(owner: "test", engine: engine, model: .small, continuous: true) { updates.append($0) }
        let utterances = { updates.compactMap { if case .utterance(let text) = $0 { text } else { nil } } }
        let deadline = Date().addingTimeInterval(120)
        while (utterances().count < 2 || !played.done) && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(utterances().count, 2, "two pauses, two utterances: \(updates)")
        dictation.stop()
        while dictation.phase != .idle && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        print("\(engine) conversation: \(updates.filter { if case .heard = $0 { false } else { true } })")
        guard utterances().count == 2, case .finished(let last)? = updates.last else { return XCTFail("\(updates)") }
        assertHeard(utterances()[0], words: ["purple", "giraffe", "lanterns"])
        XCTAssertEqual(VoiceCommand.read(utterances()[1]), .command(.send), utterances()[1])
        assertHeard(last, words: ["canoe", "home"])
        XCTAssertTrue(updates.contains { if case .heard = $0 { true } else { false } }, "words show while they are said")
    }

    // MARK: - Helpers

    private static let noModels = FileManager.default.temporaryDirectory.appendingPathComponent("no-models")

    /// Parakeet's folder, from $DISPATCH_PARAKEET_MODELS (the directory holding it) or the app's folder; its files
    /// as published (sizes checked here; hashing 630 MB is the store's job).
    private func parakeetModel() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["DISPATCH_PARAKEET_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dispatch/Parakeet")
        let folder = directory.appendingPathComponent(ParakeetModel.folder)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw XCTSkip("No \(ParakeetModel.folder) in \(directory.path) (set DISPATCH_PARAKEET_MODELS)")
        }
        for file in ParakeetModel.files {
            let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.path).path)[.size] as? Int64
            XCTAssertEqual(size, file.bytes, "\(file.path) isn't the published file")
        }
        return folder
    }

    /// Whisper Small, from $DISPATCH_WHISPER_MODELS or the app's folder.
    private func whisperModel() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dispatch/Whisper")
        let model = directory.appendingPathComponent(WhisperModel.small.fileName)
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw XCTSkip("No \(WhisperModel.small.fileName) in \(directory.path) (set DISPATCH_WHISPER_MODELS)")
        }
        let size = try FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int64
        XCTAssertEqual(size, WhisperModel.small.bytes, "\(model.path) isn't the published model")
        return model
    }

    /// `say`'s recording of the sentence, in microphone-sized buffers of its own format.
    private func recording(_ text: String = SpeechTests.sentence) throws -> Recording {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).aiff")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say couldn't record speech (\(say.terminationStatus))") }
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        var buffers: [AVAudioPCMBuffer] = []
        while audio.framePosition < audio.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            try audio.read(into: buffer)
            if buffer.frameLength == 0 { break }
            buffers.append(buffer)
        }
        XCTAssertGreaterThan(Double(audio.length) / format.sampleRate, 2, "a few seconds of speech")
        return Recording(format: format, buffers: buffers)
    }

    /// Feeds the recording to `recognizer` and waits up to `timeout` seconds for its transcript (failing, not hanging,
    /// past that).
    private func transcribe(_ audio: Recording, with recognizer: DictationRecognizer,
                            timeout: TimeInterval) async throws -> String {
        let outcome = Outcome()
        let done = expectation(description: "transcript")
        Task.detached {
            for buffer in audio.buffers { recognizer.append(buffer) }
            do { outcome.set(.success(try await recognizer.finish())) } catch { outcome.set(.failure(error)) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        guard let result = outcome.result else {
            // The expectation has failed the test.
            recognizer.cancel()
            throw TimedOut()
        }
        return try result.get()
    }

    private func assertHeard(_ transcript: String, words: [String] = SpeechTests.words, file: StaticString = #filePath,
                             line: UInt = #line) {
        let heard = Set(transcript.lowercased().components(separatedBy: CharacterSet.letters.inverted))
        for word in words {
            XCTAssertTrue(heard.contains(word), "“\(word)” in “\(transcript)”", file: file, line: line)
        }
    }
}

private struct TimedOut: Error {}

/// A recording played as the microphone would: its buffers, in order, on another thread, a little faster than real
/// time.
private final class RecordingInput: DictationInput, @unchecked Sendable {
    private let audio: Recording
    private let played: Played
    private let lock = NSLock()
    private var stopped = false

    init(_ audio: Recording, played: Played) {
        self.audio = audio
        self.played = played
    }

    func prepare() throws -> AVAudioFormat { audio.format }

    func start(_ consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let audio = audio, played = played
        Thread.detachNewThread { [self] in
            for buffer in audio.buffers {
                if lock.withLock({ stopped }) { return }
                consume(buffer)
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / buffer.format.sampleRate / 4)
            }
            played.finish()
        }
    }

    func stop() { lock.withLock { stopped = true } }
}

private final class Played: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var done: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}

/// A recording, read once and then only passed to the recognizer's thread.
private struct Recording: @unchecked Sendable {
    let format: AVAudioFormat
    let buffers: [AVAudioPCMBuffer]
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<String, Error>?

    var result: Result<String, Error>? { lock.withLock { stored } }
    func set(_ result: Result<String, Error>) { lock.withLock { stored = result } }
}
#endif
