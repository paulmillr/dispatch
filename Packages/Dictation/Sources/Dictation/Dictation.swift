@preconcurrency import AVFoundation
import Foundation
import Observation

/// Chat dictation, one at a time: a composer starts it with its engine and a way to put the text in its draft, and
/// the same composer stops it (or another one's start cancels it). While it listens, it reports the level and,
/// with Apple's engine, what it has heard so far. Each app makes one, with its Whisper models.
@MainActor @Observable public final class Dictation {
    public enum Phase: Equatable {
        case idle
        /// Asking for the microphone, preparing the recognizer (Apple's may download the language's model first).
        case starting
        case listening
        case transcribing
    }

    public private(set) var phase = Phase.idle
    /// The composer dictating (or the last one, while `error` is its).
    private(set) var owner: AnyHashable?
    /// What the recognizer has heard so far (Apple's engine only).
    public private(set) var partial = ""
    /// 0 to 1.
    public private(set) var level: Float = 0
    /// Why the owner's last dictation failed, until it dictates again or dismisses it.
    private(set) var error: String?

    /// Where Whisper's models are.
    @ObservationIgnored private let models: WhisperModelStore
    @ObservationIgnored private var microphone: DictationMicrophone?
    @ObservationIgnored private var recognizer: DictationRecognizer?
    @ObservationIgnored private var deliver: ((String) -> Void)?
    @ObservationIgnored private var run = 0

    public init(models: WhisperModelStore) {
        self.models = models
    }

    public func active(_ owner: AnyHashable) -> Bool { phase != .idle && self.owner == owner }

    public func error(for owner: AnyHashable) -> String? { self.owner == owner ? error : nil }

    public func dismissError() { error = nil }

    /// Starts dictating for `owner`, or stops (and transcribes) its dictation.
    public func toggle(owner: AnyHashable, engine: DictationEngine, model: WhisperModel, deliver: @escaping (String) -> Void) {
        if active(owner) {
            phase == .listening ? stop() : cancel()
        } else {
            start(owner: owner, engine: engine, model: model, deliver: deliver)
        }
    }

    public func start(owner: AnyHashable, engine: DictationEngine, model: WhisperModel, deliver: @escaping (String) -> Void) {
        cancel()
        run += 1
        let token = run
        self.owner = owner
        self.deliver = deliver
        phase = .starting
        partial = ""
        level = 0
        error = nil
        Task {
            do {
                guard await DictationMicrophone.requestAccess() else { throw DictationError.microphoneDenied }
                guard token == run else { return }
                let microphone = DictationMicrophone()
                let format = try microphone.prepare()
                self.microphone = microphone
                let recognizer: DictationRecognizer
                switch engine {
                case .apple:
                    recognizer = try await AppleTranscriber.make(input: format, partial: reporter(token) { dictation, text in
                        dictation.partial = text
                    })
                case .whisper:
                    guard let file = models.installed(model) else { throw DictationError.modelMissing(model) }
                    recognizer = WhisperRecognizer(input: format, model: file)
                }
                guard token == run else {
                    recognizer.cancel()
                    microphone.stop()
                    return
                }
                self.recognizer = recognizer
                try microphone.start(Self.consumer(recognizer, level: reporter(token) { dictation, level in
                    dictation.level = level
                }))
                phase = .listening
            } catch {
                fail(error, token: token)
            }
        }
    }

    /// Stops listening and puts the transcript in the owner's draft.
    public func stop() {
        guard phase == .listening, let recognizer else { return cancel() }
        microphone?.stop()
        microphone = nil
        level = 0
        phase = .transcribing
        let token = run
        Task {
            do {
                let text = try await recognizer.finish()
                guard token == run else { return }
                let deliver = deliver
                reset()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { deliver?(text) }
            } catch {
                fail(error, token: token)
            }
        }
    }

    /// Stops without a transcript.
    public func cancel() {
        guard phase != .idle else { return }
        run += 1
        microphone?.stop()
        recognizer?.cancel()
        reset()
    }

    private func reset() {
        microphone = nil
        recognizer = nil
        deliver = nil
        phase = .idle
        partial = ""
        level = 0
    }

    private func fail(_ error: Error, token: Int) {
        guard token == run else { return }
        microphone?.stop()
        recognizer?.cancel()
        reset()
        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// A report from the audio or recognizer thread, applied on the main actor while `token`'s dictation lasts (and
    /// this dictation exists: the report doesn't keep it).
    nonisolated private func reporter<Value: Sendable>(_ token: Int, _ apply: @escaping @MainActor (Dictation, Value) -> Void)
        -> @Sendable (Value) -> Void {
        { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.run == token, self.phase != .idle else { return }
                apply(self, value)
            }
        }
    }

    nonisolated private static func consumer(_ recognizer: DictationRecognizer, level: @escaping @Sendable (Float) -> Void)
        -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in
            recognizer.append(buffer)
            level(DictationMicrophone.level(buffer))
        }
    }
}
