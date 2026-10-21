#if os(macOS)
@preconcurrency import AVFoundation
import Speech
import XCTest
@testable import Dictation

/// Both engines transcribe a recording of `say` reading a sentence, fed to their recognizers in microphone-sized
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
        let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dispatch/Whisper")
        let model = directory.appendingPathComponent(WhisperModel.small.fileName)
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw XCTSkip("No \(WhisperModel.small.fileName) in \(directory.path) (set DISPATCH_WHISPER_MODELS)")
        }
        let size = try FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int64
        XCTAssertEqual(size, WhisperModel.small.bytes, "\(model.path) isn't the published model")
        let audio = try recording()
        let recognizer = WhisperRecognizer(input: audio.format, model: model)
        let transcript = try await transcribe(audio, with: recognizer, timeout: 180)
        print("Whisper transcript: \(transcript)")
        assertHeard(transcript)
    }

    // MARK: - Helpers

    /// `say`'s recording of the sentence, in microphone-sized buffers of its own format.
    private func recording() throws -> Recording {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).aiff")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, Self.sentence]
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

    private func assertHeard(_ transcript: String, file: StaticString = #filePath, line: UInt = #line) {
        let heard = Set(transcript.lowercased().components(separatedBy: CharacterSet.letters.inverted))
        for word in Self.words {
            XCTAssertTrue(heard.contains(word), "“\(word)” in “\(transcript)”", file: file, line: line)
        }
    }
}

private struct TimedOut: Error {}

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
