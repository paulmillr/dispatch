@preconcurrency import AVFoundation
import XCTest
@testable import Dictation

/// What makes dictation feel immediate: Whisper's recording cut at the speaker's pauses (so stretches are transcribed
/// while the user talks), and the microphone's first buffers kept for a recognizer that is still loading.
final class StreamingTests: XCTestCase {
    private static let rate = SpeechStretches.rate

    /// A 220 Hz tone (speech, as far as loudness goes) or near silence, `seconds` long.
    static func sound(_ seconds: Double, loud: Bool) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in
            loud ? 0.1 * sin(2 * .pi * 220 * Float(index) / Float(rate)) : (index % 2 == 0 ? 1e-4 : -1e-4)
        }
    }

    func testAPauseClosesAStretchAndOnlyAPause() {
        var stretches = SpeechStretches()
        var recording = Self.sound(1, loud: false) + Self.sound(1.5, loud: true)
        XCTAssertEqual(stretches.scan(recording), [], "speech still going")
        XCTAssertTrue(stretches.hasSpeech)
        recording += Self.sound(0.3, loud: false)
        XCTAssertEqual(stretches.scan(recording), [], "a breath is not a pause")
        recording += Self.sound(0.5, loud: false)
        let cuts = stretches.scan(recording)
        XCTAssertEqual(cuts.count, 1)
        // A quarter second after the speech, give or take a frame.
        XCTAssertEqual(Double(cuts[0]) / Double(Self.rate), 2.75, accuracy: 0.03)
        XCTAssertFalse(stretches.hasSpeech, "the pause after the cut is not speech")
        recording += Self.sound(2, loud: false)
        XCTAssertEqual(stretches.scan(recording), [], "silence alone never closes a stretch")
        recording += Self.sound(1, loud: true) + Self.sound(0.7, loud: false)
        XCTAssertEqual(stretches.scan(recording).count, 1)
    }

    func testAClickIsNotSpeech() {
        var stretches = SpeechStretches()
        let recording = Self.sound(1, loud: false) + Self.sound(0.1, loud: true) + Self.sound(1.5, loud: false)
        XCTAssertEqual(stretches.scan(recording), [])
        XCTAssertFalse(stretches.hasSpeech)
    }

    func testSpeechWithoutAPauseIsCutAtItsQuietestBeforeWhispersWindow() {
        var stretches = SpeechStretches()
        // A dip too short to be a pause at 26 s.
        let recording = Self.sound(26, loud: true) + Self.sound(0.1, loud: false) + Self.sound(4, loud: true)
        let cuts = stretches.scan(recording)
        XCTAssertEqual(cuts.count, 1)
        // Inside the dip.
        XCTAssertEqual(Double(cuts[0]) / Double(Self.rate), 26.05, accuracy: 0.05)
        XCTAssertTrue(stretches.hasSpeech, "the speech after the cut is the next stretch's")
    }

    func testTheFeedKeepsEarlyAudioInOrderForALateRecognizer() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        func buffer(_ value: Float) throws -> AVAudioPCMBuffer {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            for index in 0..<480 { buffer.floatChannelData![0][index] = value }
            return buffer
        }
        let feed = DictationFeed()
        let early = try buffer(1)
        feed.append(early)
        // The tap's buffer is the engine's to reuse: the feed must have copied it.
        early.floatChannelData![0][0] = 9
        feed.append(try buffer(2))
        let recognizer = Collector()
        feed.attach(recognizer)
        feed.append(try buffer(3))
        feed.close()
        feed.append(try buffer(4))
        XCTAssertEqual(recognizer.firsts, [1, 2, 3])
    }
}

extension StreamingTests {
    /// A continuous dictation's tap: at a pause it switches to a new feed, and what follows goes there.
    func testTheTapStartsANewUtteranceAtAPause() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let cuts = Cuts()
        let first = DictationFeed()
        let tap = DictationTap(feed: first, input: format, pause: 0.8, cut: { cuts.add($0) }, idle: { _ in }, level: { _ in })
        let early = Collector()
        first.attach(early)
        func play(_ samples: [Float]) throws {
            for start in stride(from: 0, to: samples.count, by: 1_600) {
                let chunk = samples[start..<min(samples.count, start + 1_600)]
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)))
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                for (index, sample) in chunk.enumerated() { buffer.floatChannelData![0][index] = sample }
                tap.append(buffer)
            }
        }
        try play(Self.sound(0.5, loud: false) + Self.sound(1, loud: true) + Self.sound(0.6, loud: false))
        XCTAssertEqual(cuts.count, 0, "0.6 s is not a pause in conversation")
        try play(Self.sound(0.4, loud: false))
        XCTAssertEqual(cuts.count, 1)
        let next = try XCTUnwrap(cuts.last?.1)
        XCTAssertTrue(cuts.last?.0 === first)
        let late = Collector()
        next.attach(late)
        let before = (early.firsts.count, late.firsts.count)
        XCTAssertGreaterThan(before.1, 0, "the rest of the pause already went to the next utterance")
        try play(Self.sound(0.5, loud: true))
        XCTAssertEqual(early.firsts.count, before.0, "the ended utterance gets nothing more")
        XCTAssertEqual(late.firsts.count, before.1 + 5)
        tap.mute(true)
        try play(Self.sound(0.5, loud: true))
        XCTAssertEqual(late.firsts.count, before.1 + 5, "muted, the microphone goes nowhere")
    }
}

private final class Cuts: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(DictationFeed, DictationFeed)] = []
    var count: Int { lock.withLock { all.count } }
    var last: (DictationFeed, DictationFeed)? { lock.withLock { all.last } }
    func add(_ cut: (DictationFeed, DictationFeed)) { lock.withLock { all.append(cut) } }
}

/// A recognizer that notes the first sample of each buffer.
private final class Collector: DictationRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []
    var firsts: [Float] { lock.withLock { values } }

    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { values.append(buffer.floatChannelData![0][0]) } }
    func finish() async throws -> String { "" }
    func cancel() {}
}
