@preconcurrency import AVFoundation
import Foundation

/// The microphone while dictating. Its buffers arrive on the audio thread, in the input's own format.
final class DictationMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()

    /// The microphone's format, once the iPhone's audio session is set up for recording (`stop` ends it).
    func prepare() throws -> AVAudioFormat {
        #if os(iOS)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .default)
        try audio.setActive(true)
        #endif
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noMicrophone }
        return format
    }

    /// Starts listening; `consume` gets each buffer on the audio thread.
    func start(_ consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0), block: Self.tap(consume))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Made outside any actor: a closure written in a main actor method would be isolated to it, and Swift traps when
    /// the audio thread calls it.
    private static func tap(_ consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in consume(buffer) }
    }

    /// Asks for the microphone; false once the user has refused.
    static func requestAccess() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    /// The loudness of a buffer, 0 (silence) to 1, for the listening indicator.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // -50 dB to 0 dB.
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// Converts the microphone's buffers to the format a recognizer wants (Whisper: 16 kHz mono float).
final class DictationConverter: @unchecked Sendable {
    let output: AVAudioFormat
    private let converter: AVAudioConverter?

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.output = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return converted
    }
}

public enum DictationError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    case speechDenied
    case appleUnavailable
    case languageUnsupported
    case modelMissing(WhisperModel)
    case whisperFailed

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            #if os(iOS)
            "Dispatch can’t use the microphone. Allow it in Settings › Apps › Dispatch."
            #else
            "Dispatch can’t use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            #endif
        case .noMicrophone: "No microphone is available."
        case .speechDenied:
            "Speech recognition isn’t allowed. Allow it in System Settings › Privacy & Security › Speech Recognition."
        case .appleUnavailable: "Apple’s on-device dictation isn’t available here. Try Whisper in Settings."
        case .languageUnsupported: "Apple’s on-device dictation doesn’t support your language. Try Whisper in Settings."
        case .modelMissing(let model): "Download the Whisper \(model.title) model in Settings to dictate with it."
        case .whisperFailed: "Whisper couldn’t transcribe the recording."
        }
    }
}
