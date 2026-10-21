@preconcurrency import AVFoundation
import Foundation
import WhisperEngine

/// Runs Whisper (WhisperEngine, Packages/WhisperEngine: whisper.cpp in Swift) on its own queue: loading a model and
/// transcribing block for up to seconds. The last model stays loaded for a few minutes after a transcript, so
/// dictating again starts at once, and is freed after that (a model takes 0.3 to 1 GB).
final class WhisperTranscriber: @unchecked Sendable {
    static let shared = WhisperTranscriber()

    /// Whisper's input: 16 kHz mono float samples.
    static let sampleRate = 16_000.0

    private let queue = DispatchQueue(label: "yachts.dispatch.whisper", qos: .userInitiated)
    // Only touched on the queue: the session, its model and the Metal or CPU backend behind it are not thread-safe,
    // and every load, transcript and unload runs here.
    private var loaded: (url: URL, session: WhisperSession)?
    private var generation = 0
    private let idle: TimeInterval

    init(idle: TimeInterval = 180) {
        self.idle = idle
    }

    /// Loads the model ahead of a transcript (dictation starts it while the user speaks).
    func preload(_ model: URL) {
        queue.async { [self] in
            _ = try? session(for: model)
            scheduleUnload()
        }
    }

    /// The text Whisper hears in `samples` (16 kHz mono).
    func transcribe(_ samples: [Float], model: URL, language: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try run(samples, model: model, language: language) })
            }
        }
    }

    private func run(_ samples: [Float], model: URL, language: String?) throws -> String {
        let session = try session(for: model)
        defer { scheduleUnload() }
        // Under a second of audio is noise to Whisper (it hallucinates a phrase): nothing was said.
        guard samples.count >= Int(Self.sampleRate) / 2 else { return "" }
        // Greedy sampling, no timestamps, no context, blanks suppressed: the session's one configuration. A nil
        // language is detected from the first window ("auto").
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let result: WhisperResult
        do {
            result = try session.transcribe(samples: samples, language: language, threads: threads)
        } catch {
            throw DictationError.whisperFailed
        }
        // Every segment's text, concatenated.
        return Self.clean(result.text)
    }

    /// Whisper marks what it heard but couldn't transcribe as "[BLANK_AUDIO]", and a recording of no speech as
    /// "(music)" and the like.
    static func clean(_ text: String) -> String {
        let words = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return words.range(of: #"^\([^()]*\)$"#, options: .regularExpression) != nil ? "" : words
    }

    /// The session for `model`, loading it (and dropping any other model) when it isn't the one in memory. The
    /// model runs on Metal; a machine without a GPU gets the CPU backend.
    private func session(for model: URL) throws -> WhisperSession {
        if let loaded, loaded.url == model { return loaded.session }
        unload()
        let session: WhisperSession
        do {
            let file = try WhisperModelFile.load(model)
            // Metal when the device has it and its kernels compile. The CPU backend (Accelerate) holds every
            // weight as Float32, about four times the q8_0 file (small 1 GB, turbo 3 GB): a fallback on the Mac,
            // past the memory an iPhone app may use.
            let inference: any WhisperInference
            if let backend = try? MetalBackend() {
                inference = try WhisperEngine.WhisperModel(file: file, backend: backend)
            } else {
                #if os(iOS)
                throw DictationError.whisperFailed
                #else
                inference = try WhisperEngine.WhisperModel(file: file, backend: CPUBackend())
                #endif
            }
            session = WhisperSession(inference: inference, filters: file.filters)
        } catch {
            throw DictationError.whisperFailed
        }
        loaded = (model, session)
        return session
    }

    private func unload() {
        loaded = nil
    }

    private func scheduleUnload() {
        generation += 1
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + idle) { [self] in
            if generation == scheduled { unload() }
        }
    }
}

/// A dictation for Whisper: the recording, kept at 16 kHz mono and transcribed when the user stops (Whisper has no
/// partial results). Loads the model while the user speaks.
final class WhisperRecognizer: DictationRecognizer, @unchecked Sendable {
    private let model: URL
    private let converter: DictationConverter
    private let lock = NSLock()
    private var samples: [Float] = []

    init(input: AVAudioFormat, model: URL) {
        self.model = model
        let whisper = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperTranscriber.sampleRate, channels: 1,
                                    interleaved: false)!
        converter = DictationConverter(from: input, to: whisper)
        WhisperTranscriber.shared.preload(model)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func finish() async throws -> String {
        let recording = lock.withLock { samples }
        return try await WhisperTranscriber.shared.transcribe(recording, model: model)
    }

    func cancel() { lock.withLock { samples = [] } }
}
