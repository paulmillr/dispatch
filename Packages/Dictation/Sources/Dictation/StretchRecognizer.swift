@preconcurrency import AVFoundation
import Foundation

/// An engine that transcribes a whole stretch of 16 kHz mono audio at a time and has no partial results of its own:
/// Whisper, Parakeet.
protocol StretchTranscriber: Sendable {
    /// The longest stretch it takes, in samples: a stretch without a pause is cut before it.
    var longest: Int { get }
    /// Loads the model ahead of a transcript (dictation starts it while the user speaks).
    func preload(_ model: URL)
    /// The text it hears in `samples`, and the language it heard when it tells (nil when it heard nothing).
    func transcribe(_ samples: [Float], model: URL, language: String?) async throws -> (text: String, language: String?)
}

/// A dictation for an engine without partial results (`StretchTranscriber`): the recording, kept at 16 kHz mono, is cut
/// at the speaker's pauses, and each stretch is transcribed (settled) as soon as it ends, while the user goes on
/// talking. The stretch being spoken is transcribed again every second or so for a guess at it, so text appears as it
/// is said and stopping waits only for the last stretch. Loads the model while the user speaks.
final class StretchRecognizer: DictationRecognizer, @unchecked Sendable {
    private static let rate = Int(WhisperTranscriber.sampleRate)

    private let transcriber: any StretchTranscriber
    private let model: URL
    private let converter: DictationConverter
    private let heard: @Sendable (String) -> Void
    private let wake: AsyncStream<Void>.Continuation
    private var worker: Task<String, Error>?

    private let lock = NSLock()
    // Under the lock, from here.
    private var samples: [Float] = []
    private var stretches: SpeechStretches
    /// Ends of the stretches the pauses closed that are not transcribed yet.
    private var cuts: [Int] = []
    /// How much of the recording `settled` covers.
    private var settledEnd = 0
    private var settled = ""
    /// The latest guess at the stretch after `settledEnd`.
    private var guess = ""
    /// The language of the first stretch Whisper heard, kept for the rest: a short stretch alone can sound like another.
    private var language: String?
    private var guessedAt = 0
    /// Samples of audio between guesses: twice what the last guess took, so a slow model never falls behind.
    private var guessGap = rate
    private var finishing = false
    private var finished = false

    init(input: AVAudioFormat, transcriber: any StretchTranscriber, model: URL,
         heard: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transcriber = transcriber
        self.model = model
        self.heard = heard
        stretches = SpeechStretches(longest: transcriber.longest)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: WhisperTranscriber.sampleRate, channels: 1,
                                 interleaved: false)!
        converter = DictationConverter(from: input, to: mono)
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wake = wake
        transcriber.preload(model)
        worker = Task { [self] in try await work(wakes) }
    }

    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        lock.withLock {
            guard !finishing else { return }
            samples.append(contentsOf: chunk)
            cuts += stretches.scan(samples)
        }
        wake.yield()
    }

    func finish() async throws -> String {
        let worker = lock.withLock {
            finishing = true
            return self.worker
        }
        wake.yield()
        return try await worker?.value ?? ""
    }

    func cancel() {
        lock.withLock {
            finishing = true
            finished = true
            samples = []
        }
        wake.finish()
        worker?.cancel()
    }

    private enum Job {
        case settle, guess, last
    }

    private func work(_ wakes: AsyncStream<Void>) async throws -> String {
        for await _ in wakes {
            while let stretch = next() {
                let (job, range, audio, language) = stretch
                let started = ContinuousClock.now
                let text: String
                let heardLanguage: String?
                do {
                    (text, heardLanguage) = try await transcriber.transcribe(audio, model: model, language: language)
                } catch {
                    // A guess that fails is only a guess; the transcript itself must not be lost silently.
                    if job == .guess { continue }
                    throw error
                }
                let took = started.duration(to: .now)
                if let done = apply(job, range: range, text: text, language: heardLanguage, took: took) { return done }
            }
        }
        return lock.withLock { settled }
    }

    /// The next stretch to transcribe: one a pause closed, else the end once the user stopped, else a guess at the
    /// stretch being spoken when one is due.
    private func next() -> (Job, Range<Int>, [Float], String?)? {
        lock.withLock {
            guard !finished else { return nil }
            if !cuts.isEmpty {
                let range = settledEnd..<cuts.removeFirst()
                settledEnd = range.upperBound
                return (.settle, range, Array(samples[range]), language)
            }
            let open = settledEnd..<samples.count
            if finishing {
                finished = true
                // After a settled stretch, a tail without speech is the pause before stopping: Whisper would make up a
                // phrase for it. With nothing settled the whole recording goes, whatever the pauses made of it.
                let audio = settled.isEmpty || stretches.hasSpeech ? Array(samples[open]) : []
                return (.last, open, audio, language)
            }
            guard stretches.hasSpeech, open.count >= Self.rate, samples.count - guessedAt >= guessGap else { return nil }
            guessedAt = samples.count
            return (.guess, open, Array(samples[open]), language)
        }
    }

    /// Takes a transcript in; the whole one once the last stretch is in.
    private func apply(_ job: Job, range: Range<Int>, text: String, language heardLanguage: String?, took: Duration) -> String? {
        let (display, done): (String?, String?) = lock.withLock {
            switch job {
            case .settle:
                settled = TranscriptJoin.join(settled, text)
                guess = ""
                if language == nil { language = heardLanguage }
                return (settled, nil)
            case .guess:
                let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
                guessGap = max(Self.rate, Int(2 * seconds * Double(Self.rate)))
                // A stretch settled since: the guess is about audio that is already text.
                guard range.lowerBound == settledEnd, !finishing else { return (nil, nil) }
                guess = text
                return (TranscriptJoin.join(settled, guess), nil)
            case .last:
                settled = TranscriptJoin.join(settled, text)
                return (nil, settled)
            }
        }
        if let display { heard(display) }
        return done
    }
}

/// Finds the pauses in a 16 kHz recording, 20 ms at a time: a frame is speech when it is well above the quietest the
/// microphone has been lately. A stretch of speech ends `pause` into a pause (cut a quarter second in), or, without
/// one and with a `longest`, near it at its quietest moment of the last 3 s (Whisper hears 30 s at a time, Parakeet
/// 15 s).
struct SpeechStretches {
    static let rate = Int(WhisperTranscriber.sampleRate)
    static let frame = rate / 50
    /// Frames of speech that make a stretch worth transcribing: a cough or a click is less.
    static let speechFrames = 10
    static let tail = rate / 4
    static let lookback = rate * 3

    let pause: Int
    let longest: Int?

    /// Where the open stretch starts.
    private(set) var start = 0
    /// Samples scanned so far.
    private(set) var scanned = 0
    /// The samples `scan` has been given (its whole-recording form).
    private var received = 0
    /// Less than a frame, waiting for the rest.
    private var pending: [Float] = []
    private var floor: Float?
    private var speech = 0
    private var lastSpeechEnd = 0
    /// The last 3 s of frames: (end, loudness, speech).
    private var recent: [(end: Int, decibels: Float, speech: Bool)] = []

    /// 0.6 s pauses, and Whisper's 28 s at most.
    init(pause: Int = rate * 6 / 10, longest: Int? = rate * 28) {
        self.pause = pause
        self.longest = longest
    }

    /// Whether the open stretch has speech in it.
    var hasSpeech: Bool { speech >= Self.speechFrames }

    /// Samples since the last speech (all of them before any).
    var silence: Int { scanned - lastSpeechEnd }

    /// Scans what was added to `samples` (the whole recording so far) since the last call; returns where stretches
    /// ended.
    mutating func scan(_ samples: [Float]) -> [Int] {
        defer { received = samples.count }
        return add(samples[min(received, samples.count)...])
    }

    /// Scans the next samples of the recording; returns where stretches ended.
    mutating func add<Samples: Collection<Float>>(_ chunk: Samples) -> [Int] {
        pending.append(contentsOf: chunk)
        var cuts: [Int] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            if let cut = frame(pending[offset..<offset + Self.frame]) { cuts.append(cut) }
            offset += Self.frame
        }
        pending.removeFirst(offset)
        return cuts
    }

    private mutating func frame(_ samples: ArraySlice<Float>) -> Int? {
        let decibels = Self.decibels(samples)
        scanned += Self.frame
        // The floor follows quiet down at once and noise up slowly (0.5 dB a second).
        let quiet = min(floor ?? decibels, decibels)
        floor = decibels > quiet ? quiet + 0.01 : quiet
        let isSpeech = decibels > max(quiet + 15, -55)
        if isSpeech {
            speech += 1
            lastSpeechEnd = scanned
        }
        recent.append((scanned, decibels, isSpeech))
        if let first = recent.first, scanned - first.end > Self.lookback { recent.removeFirst() }
        if hasSpeech, scanned - lastSpeechEnd >= pause {
            return close(at: lastSpeechEnd + min(Self.tail, pause))
        } else if let longest, scanned - start >= longest, let quietest = recent.min(by: { $0.decibels < $1.decibels }) {
            return close(at: quietest.end)
        }
        return nil
    }

    private mutating func close(at cut: Int) -> Int {
        start = cut
        // What follows the cut belongs to the next stretch.
        recent.removeAll { $0.end <= cut }
        speech = recent.filter(\.speech).count
        return cut
    }

    static func decibels(_ frame: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        return 20 * log10(max((sum / Float(max(1, frame.count))).squareRoot(), 1e-6))
    }
}

/// Joins pieces of a transcript with a space.
enum TranscriptJoin {
    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines), b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
