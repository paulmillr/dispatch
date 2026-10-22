@preconcurrency import AVFoundation
import Foundation
import Observation

/// What a dictation tells its composer.
public enum DictationUpdate: Equatable, Sendable {
    /// Everything heard so far of the utterance being spoken: what the recognizer has settled, then its guess at what
    /// follows.
    case heard(String)
    /// A continuous dictation's utterance, ended by a pause: its transcript. Listening goes on.
    case utterance(String)
    /// The transcript (of the last utterance, when continuous), once the user stopped; empty when nothing was said.
    case finished(String)
    /// Cancelled, or failed (`error` says why): nothing more to insert, and what `heard` showed is withdrawn.
    case ended
}

/// Chat dictation, one at a time: a composer starts it with its engine and a way to show what it hears in its draft,
/// and the same composer stops it (or another one's start cancels it). The microphone records from the start: what is
/// said while the recognizer still loads waits for it. While it listens, it reports the level and what it has heard
/// so far. A continuous dictation goes on until stopped, cut into utterances at the speaker's pauses: each gets a
/// recognizer of its own, and its transcript is reported as soon as that recognizer has it. Each app makes one, with
/// its Whisper models.
@MainActor @Observable public final class Dictation {
    public enum Phase: Equatable {
        case idle
        /// Asking for the microphone and starting it.
        case starting
        /// Recording; the recognizer may still be loading (Apple's may download the language's model first).
        case listening
        case transcribing
    }

    /// A pause this long ends a continuous dictation's utterance.
    nonisolated public static let utterancePause: TimeInterval = 0.8
    /// A continuous dictation that hears no speech for this long stops.
    nonisolated public static let idleLimit: TimeInterval = 300

    public private(set) var phase = Phase.idle
    /// The composer dictating (or the last one, while `error` is its).
    public private(set) var owner: AnyHashable?
    public private(set) var continuous = false
    /// What has been heard so far of the utterance being spoken.
    public private(set) var partial = ""
    /// 0 to 1.
    public private(set) var level: Float = 0
    /// Ignoring the microphone (while the app speaks, so it never hears itself).
    public private(set) var muted = false
    /// Why the owner's last dictation failed, until it dictates again or dismisses it.
    private(set) var error: String?

    /// Where Whisper's models are.
    @ObservationIgnored private let models: WhisperModelStore
    @ObservationIgnored private var microphone: DictationInput?
    /// The microphone, and asking for it; tests play recordings instead.
    @ObservationIgnored var input: () -> DictationInput = { DictationMicrophone() }
    @ObservationIgnored var access: () async -> Bool = { await DictationMicrophone.requestAccess() }
    @ObservationIgnored private var tap: DictationTap?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var whisper: URL?
    @ObservationIgnored private var update: ((DictationUpdate) -> Void)?
    /// The utterance being spoken, and the transcripts of earlier ones still to report, in order.
    @ObservationIgnored private var current: Utterance?
    @ObservationIgnored private var reported: Task<Void, Never>?
    /// The utterances before the one being spoken that are not reported yet: its words wait for them.
    @ObservationIgnored private var unreported = 0
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var utterances = 0

    /// One utterance's audio and recognizer.
    private final class Utterance {
        let number: Int
        let feed: DictationFeed
        var recognizer: Task<DictationRecognizer, Error>?
        /// Heard while earlier utterances were still being transcribed.
        var waiting: String?

        init(number: Int, feed: DictationFeed) {
            self.number = number
            self.feed = feed
        }
    }

    public init(models: WhisperModelStore) {
        self.models = models
    }

    public func active(_ owner: AnyHashable) -> Bool { phase != .idle && self.owner == owner }

    public func error(for owner: AnyHashable) -> String? { self.owner == owner ? error : nil }

    public func dismissError() { error = nil }

    /// Gets ready for a dictation that may follow (a held shortcut): loads Whisper's model if it is the engine.
    public func prepare(engine: DictationEngine, model: WhisperModel) {
        guard engine == .whisper, let file = models.installed(model) else { return }
        WhisperTranscriber.shared.preload(file)
    }

    /// Starts dictating for `owner`, or stops (and transcribes) its dictation.
    public func toggle(owner: AnyHashable, engine: DictationEngine, model: WhisperModel,
                       update: @escaping (DictationUpdate) -> Void) {
        if active(owner) {
            phase == .listening ? stop() : cancel()
        } else {
            start(owner: owner, engine: engine, model: model, update: update)
        }
    }

    public func start(owner: AnyHashable, engine: DictationEngine, model: WhisperModel, continuous: Bool = false,
                      update: @escaping (DictationUpdate) -> Void) {
        cancel()
        run += 1
        let token = run
        self.owner = owner
        self.update = update
        self.continuous = continuous
        phase = .starting
        partial = ""
        level = 0
        muted = false
        error = nil
        Task {
            do {
                guard await access() else { throw DictationError.microphoneDenied }
                guard token == run else { return }
                // Whisper's model must be there before anything is recorded for it.
                whisper = engine == .whisper ? models.installed(model) : nil
                if engine == .whisper, whisper == nil { throw DictationError.modelMissing(model) }
                let microphone = input()
                let format = try microphone.prepare()
                self.format = format
                let first = next(DictationFeed(), token: token)
                let tap = DictationTap(feed: first.feed, input: format, pause: continuous ? Self.utterancePause : nil,
                                       cut: reporter(token) { dictation, feeds in dictation.cut(feeds.0, feeds.1, token: token) },
                                       idle: reporter(token) { dictation, _ in dictation.stop() },
                                       level: reporter(token) { dictation, level in dictation.level = level })
                self.microphone = microphone
                self.tap = tap
                try microphone.start(Self.consumer(tap))
                phase = .listening
            } catch {
                fail(error, token: token)
            }
        }
    }

    /// Hands the dictation to another owner (a continuous one following the user to another chat).
    public func transfer(to owner: AnyHashable) {
        guard phase != .idle else { return }
        self.owner = owner
    }

    /// Ignores the microphone, or listens to it again; an utterance cut short by it is kept.
    public func mute(_ muted: Bool) {
        guard phase != .idle, muted != self.muted else { return }
        self.muted = muted
        tap?.mute(muted)
        if muted { level = 0 }
    }

    /// The utterance after a cut: its own feed (already receiving), and a recognizer that loads meanwhile.
    private func next(_ feed: DictationFeed, token: Int) -> Utterance {
        utterances += 1
        let utterance = Utterance(number: utterances, feed: feed)
        let number = utterance.number
        let heard = reporter(token) { (dictation: Dictation, text: String) in dictation.heard(text, utterance: number) }
        let whisper = whisper
        guard let format else { fatalError("the microphone's format comes first") }
        utterance.recognizer = Task {
            let recognizer: DictationRecognizer
            if let whisper {
                recognizer = WhisperRecognizer(input: format, model: whisper, heard: heard)
            } else {
                recognizer = try await AppleTranscriber.make(input: format, partial: heard)
            }
            feed.attach(recognizer)
            return recognizer
        }
        current = utterance
        return utterance
    }

    private func heard(_ text: String, utterance number: Int) {
        guard let current, current.number == number else { return }
        if unreported > 0 { current.waiting = text; return }
        partial = text
        update?(.heard(text))
    }

    /// A pause ended `old`'s utterance; `new` already has what followed.
    private func cut(_ old: DictationFeed, _ new: DictationFeed, token: Int) {
        // After a stop the last utterance is already being reported.
        guard token == run, phase == .listening, let ended = current, ended.feed === old else { return }
        let following = next(new, token: token)
        unreported += 1
        report(ended, token: token) { [weak self] text in
            guard let self else { return }
            self.unreported -= 1
            if !text.isEmpty { self.update?(.utterance(text)) }
            self.partial = ""
            // What the next utterance heard meanwhile, now that the text before it is in.
            if self.unreported == 0, self.current === following, let waiting = following.waiting {
                following.waiting = nil
                self.heard(waiting, utterance: following.number)
            }
        }
    }

    /// Reports `utterance`'s transcript after every earlier one.
    private func report(_ utterance: Utterance, token: Int, _ deliver: @escaping @MainActor (String) -> Void) {
        let previous = reported
        reported = Task {
            await previous?.value
            do {
                guard let recognizer = try await utterance.recognizer?.value else { return }
                let text = try await recognizer.finish().trimmingCharacters(in: .whitespacesAndNewlines)
                guard token == run else { return }
                deliver(text)
            } catch {
                fail(error, token: token)
            }
        }
    }

    /// Stops listening and puts the transcript (the last utterance's, when continuous) in the owner's draft, once the
    /// recognizer has it.
    public func stop() {
        guard phase == .listening else { return cancel() }
        microphone?.stop()
        microphone = nil
        tap?.close()
        level = 0
        phase = .transcribing
        guard let last = current else { return cancel() }
        let token = run
        report(last, token: token) { [weak self] text in
            guard let self else { return }
            let update = self.update
            self.reset()
            update?(.finished(text))
        }
    }

    /// Stops without a transcript.
    public func cancel() {
        guard phase != .idle else { return }
        run += 1
        microphone?.stop()
        tap?.close()
        let utterance = current
        let update = update
        reset()
        Task { try? await utterance?.recognizer?.value.cancel() }
        update?(.ended)
    }

    private func reset() {
        microphone = nil
        tap = nil
        current = nil
        reported = nil
        unreported = 0
        update = nil
        format = nil
        whisper = nil
        continuous = false
        muted = false
        phase = .idle
        partial = ""
        level = 0
    }

    private func fail(_ error: Error, token: Int) {
        guard token == run else { return }
        cancel()
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

    nonisolated private static func consumer(_ tap: DictationTap) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in tap.append(buffer) }
    }
}

/// The microphone's side of a dictation, on the audio thread: passes each buffer to the utterance's feed and reports
/// its level; when continuous, also finds the pauses (`SpeechStretches` on a 16 kHz copy) and at each one switches to a
/// fresh feed for the next utterance before the next buffer.
final class DictationTap: @unchecked Sendable {
    private let lock = NSLock()
    private var feed: DictationFeed
    private var stretches: SpeechStretches?
    private let converter: DictationConverter?
    private let cut: @Sendable ((DictationFeed, DictationFeed)) -> Void
    private let idle: @Sendable (Void) -> Void
    private let level: @Sendable (Float) -> Void
    private var muted = false
    private var closed = false
    private var idleReported = false

    init(feed: DictationFeed, input: AVAudioFormat, pause: TimeInterval?,
         cut: @escaping @Sendable ((DictationFeed, DictationFeed)) -> Void, idle: @escaping @Sendable (Void) -> Void,
         level: @escaping @Sendable (Float) -> Void) {
        self.feed = feed
        self.cut = cut
        self.idle = idle
        self.level = level
        if let pause {
            stretches = SpeechStretches(pause: Int(pause * Double(SpeechStretches.rate)), longest: nil)
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperTranscriber.sampleRate, channels: 1,
                                     interleaved: false)!
            converter = DictationConverter(from: input, to: mono)
        } else {
            converter = nil
        }
    }

    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let (target, ended, quiet): (DictationFeed?, (DictationFeed, DictationFeed)?, Bool) = lock.withLock {
            guard !closed, !muted else { return (nil, nil, false) }
            guard var stretches, let converted = converter?.convert(buffer), let channel = converted.floatChannelData?[0] else {
                return (feed, nil, false)
            }
            let cuts = stretches.add(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            var ended: (DictationFeed, DictationFeed)?
            if !cuts.isEmpty {
                let next = DictationFeed()
                feed.close()
                ended = (feed, next)
                feed = next
            }
            let quiet = !idleReported && Double(stretches.silence) / Double(SpeechStretches.rate) >= Dictation.idleLimit
            if quiet { idleReported = true }
            self.stretches = stretches
            return (feed, ended, quiet)
        }
        target?.append(buffer)
        if let ended { cut(ended) }
        if quiet { idle(()) }
        if target != nil { level(DictationMicrophone.level(buffer)) }
    }

    func mute(_ muted: Bool) {
        lock.withLock { self.muted = muted }
    }

    func close() {
        let feed = lock.withLock {
            closed = true
            return self.feed
        }
        feed.close()
    }
}

/// The microphone's buffers on their way to the recognizer: kept (copied, in order) while it loads, then handed to it
/// first, and passed straight through after that.
final class DictationFeed: @unchecked Sendable {
    /// A minute of audio at most waits for a recognizer (Apple's may be downloading its model).
    private static let limit: TimeInterval = 60

    private let lock = NSLock()
    private var recognizer: DictationRecognizer?
    private var waiting: [AVAudioPCMBuffer] = []
    private var waitingSeconds: TimeInterval = 0
    private var closed = false

    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !closed else { return }
            if let recognizer { return recognizer.append(buffer) }
            // The engine may reuse the tap's buffer once the tap returns.
            guard waitingSeconds < Self.limit, let copy = Self.copy(buffer) else { return }
            waiting.append(copy)
            waitingSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    /// Gives `recognizer` what was recorded so far, then everything after it.
    func attach(_ recognizer: DictationRecognizer) {
        lock.withLock {
            for buffer in waiting { recognizer.append(buffer) }
            waiting = []
            self.recognizer = recognizer
        }
    }

    /// Takes nothing more from the microphone (what waits stays for `attach`).
    func close() {
        lock.withLock { closed = true }
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let data = from.mData, let destination = to.mData else { continue }
            memcpy(destination, data, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
