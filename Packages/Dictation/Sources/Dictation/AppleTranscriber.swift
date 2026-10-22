@preconcurrency import AVFoundation
import Foundation
import Speech

/// One dictation's recognizer: it gets the microphone's buffers as they come, reports what it has heard so far (when
/// it can), and gives the transcript once the user stops.
protocol DictationRecognizer: AnyObject, Sendable {
    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel()
}

/// Apple's on-device recognizers. On macOS and iOS 26, SpeechAnalyzer: SpeechTranscriber where the device has it,
/// else DictationTranscriber (the keyboard's), downloading the language's model through the system once. On older
/// Macs, SFSpeechRecognizer, held to on-device recognition: no audio ever leaves the device.
public enum AppleTranscriber {
    static func make(input: AVAudioFormat, partial: @escaping @Sendable (String) -> Void) async throws -> DictationRecognizer {
        if #available(macOS 26, iOS 26, *) {
            return try await AnalyzerRecognizer.make(input: input, partial: partial)
        }
        #if os(macOS)
        return try await LegacyRecognizer.make(partial: partial)
        #else
        throw DictationError.appleUnavailable
        #endif
    }

    /// Settings' line about Apple's engine on this device.
    public static var summary: String {
        if #available(macOS 26, iOS 26, *) {
            return SpeechTranscriber.isAvailable ? "On-device SpeechAnalyzer, your language’s model managed by the system"
                : "On-device dictation model, managed by the system"
        }
        return "On-device speech recognition (needs your language’s Siri voice model)"
    }

    /// Whether the analyzer's module for this device and language is installed, downloading or needs a download,
    /// without starting one (tests); nil when it doesn't support the language. Models are reserved per app: one the
    /// system already has reads as supported until this process asks for it, as dictation's first start does (an
    /// installation request with nothing to download).
    @available(macOS 26, iOS 26, *)
    static func assetStatus() async throws -> AssetInventory.Status? {
        guard let module = await AnalyzerRecognizer.module() else { return nil }
        if await AssetInventory.status(forModules: [module]) == .supported {
            _ = try await AssetInventory.assetInstallationRequest(supporting: [module])
        }
        return await AssetInventory.status(forModules: [module])
    }
}

/// The finalized and volatile text of an analyzer session, kept apart: volatile text is replaced as it changes.
private struct TranscriptParts: Sendable {
    var finalized = ""
    var volatile = ""

    mutating func add(_ text: AttributedString, final: Bool) {
        let piece = String(text.characters)
        if final {
            finalized = TranscriptJoin.join(finalized, piece)
            volatile = ""
        } else {
            volatile = piece
        }
    }

    var display: String { TranscriptJoin.join(finalized, volatile) }
}

@available(macOS 26, iOS 26, *)
private final class AnalyzerRecognizer: DictationRecognizer, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let converter: DictationConverter
    private let stream: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<String, Error>

    private init(analyzer: SpeechAnalyzer, converter: DictationConverter, stream: AsyncStream<AnalyzerInput>.Continuation,
                 results: Task<String, Error>) {
        self.analyzer = analyzer
        self.converter = converter
        self.stream = stream
        self.results = results
    }

    /// SpeechTranscriber where the device has it, else DictationTranscriber; nil when neither supports the language.
    static func module() async -> (any SpeechModule)? {
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                     reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults], attributeOptions: [])
        }
        return nil
    }

    static func make(input: AVAudioFormat, partial: @escaping @Sendable (String) -> Void) async throws -> AnalyzerRecognizer {
        guard let module = await Self.module() else { throw DictationError.languageUnsupported }
        let results: Task<String, Error>
        if let transcriber = module as? SpeechTranscriber {
            results = Task {
                var parts = TranscriptParts()
                for try await result in transcriber.results {
                    parts.add(result.text, final: result.isFinal)
                    partial(parts.display)
                }
                return parts.finalized
            }
        } else if let transcriber = module as? DictationTranscriber {
            results = Task {
                var parts = TranscriptParts()
                for try await result in transcriber.results {
                    parts.add(result.text, final: result.isFinal)
                    partial(parts.display)
                }
                return parts.finalized
            }
        } else {
            throw DictationError.languageUnsupported
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: input) else {
                throw DictationError.appleUnavailable
            }
            let (inputs, stream) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputs)
            return AnalyzerRecognizer(analyzer: analyzer, converter: DictationConverter(from: input, to: format),
                                      stream: stream, results: results)
        } catch {
            results.cancel()
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if let converted = converter.convert(buffer) { stream.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async throws -> String {
        stream.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    func cancel() {
        stream.finish()
        results.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

#if os(macOS)
/// macOS 14 and 15: SFSpeechRecognizer, on-device only.
private final class LegacyRecognizer: DictationRecognizer, @unchecked Sendable {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var ended: CheckedContinuation<String, Error>?
    private var outcome: Result<String, Error>?

    static func make(partial: @escaping @Sendable (String) -> Void) async throws -> LegacyRecognizer {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw DictationError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else { throw DictationError.languageUnsupported }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw DictationError.appleUnavailable }
        let session = LegacyRecognizer()
        session.request.requiresOnDeviceRecognition = true
        session.request.shouldReportPartialResults = true
        session.request.addsPunctuation = true
        session.task = recognizer.recognitionTask(with: session.request, resultHandler: Self.handler(session, partial: partial))
        return session
    }

    /// Outside any actor, like the microphone's tap: the recognizer calls it on its own queue.
    private static func handler(_ session: LegacyRecognizer, partial: @escaping @Sendable (String) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak session] result, error in
            guard let session else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                partial(text)
                session.lock.withLock { session.transcript = text }
                if result.isFinal { session.end(.success(text)) }
            } else if let error {
                // Ending the audio before any speech is "No speech detected" (1110): nothing was said.
                let heard = session.lock.withLock { session.transcript }
                session.end((error as NSError).code == 1110 || !heard.isEmpty ? .success(heard) : .failure(error))
            }
        }
    }

    private func end(_ result: Result<String, Error>) {
        let waiting: CheckedContinuation<String, Error>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { ended = nil }
            return ended
        }
        waiting?.resume(with: result)
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

    func finish() async throws -> String {
        request.endAudio()
        let text = try await withCheckedThrowingContinuation { continuation in
            let done: Result<String, Error>? = lock.withLock {
                if let outcome { return outcome }
                ended = continuation
                return nil
            }
            if let done { continuation.resume(with: done) }
        }
        return text
    }

    func cancel() {
        task?.cancel()
        end(.success(""))
    }
}
#endif
