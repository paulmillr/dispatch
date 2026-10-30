import CoreML
import Foundation

/// Runs Parakeet TDT 0.6B v3 (`ParakeetModel`'s Core ML files) on its own queue: the preprocessor turns 15 s of audio
/// into its mel spectrogram on the CPU, the FastConformer encoder runs on the Neural Engine, and a greedy TDT decode
/// (the LSTM prediction network and the joint, a step at a time) reads the tokens and how many frames each one skips.
/// Loading compiles the models for the Neural Engine the first time (seconds; the system keeps the result), so the
/// models stay loaded for a few minutes after a transcript, and are freed after that.
final class ParakeetTranscriber: StretchTranscriber, @unchecked Sendable {
    static let shared = ParakeetTranscriber()

    /// The encoder's fixed input: 15 s of 16 kHz audio.
    static let window = 240_000
    /// The encoder's output: 1024 values for each 80 ms frame.
    private static let hidden = 1024
    private static let blank = 8192
    /// The joint's duration choices, in frames.
    private static let durations = [0, 1, 2, 3, 4]
    /// Tokens read at one frame before the decode moves on regardless.
    private static let symbolsPerFrame = 10

    /// A stretch fits the window with a second to spare (a stretch ends at the quietest moment near `longest`).
    let longest = Int(WhisperTranscriber.sampleRate) * 14

    private let queue = DispatchQueue(label: "yachts.dispatch.parakeet", qos: .userInitiated)
    // Only touched on the queue: every load, transcript and unload runs here.
    private var loaded: (url: URL, models: Models)?
    private var generation = 0
    private let idle: TimeInterval

    init(idle: TimeInterval = 180) {
        self.idle = idle
    }

    private struct Models {
        let preprocessor, encoder, decoder, joint: MLModel
        /// Each token's SentencePiece piece, by id, up to the blank.
        let vocabulary: [String]
    }

    func preload(_ model: URL) {
        queue.async { [self] in
            _ = try? models(for: model)
            scheduleUnload()
        }
    }

    func transcribe(_ samples: [Float], model: URL, language: String? = nil) async throws -> (text: String, language: String?) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { (try run(samples, model: model), nil) })
            }
        }
    }

    /// Frees the models now (Settings deleted them).
    func unload() {
        queue.async { [self] in loaded = nil }
    }

    private func run(_ samples: [Float], model: URL) throws -> String {
        let models = try models(for: model)
        defer { scheduleUnload() }
        // A quarter second is too little for a word.
        let least = Int(WhisperTranscriber.sampleRate) / 4
        guard samples.count >= least else { return "" }
        // A stretch longer than the window (rare: the recognizer cuts them before) goes a window at a time.
        var text = ""
        for start in stride(from: 0, to: samples.count, by: Self.window) {
            let piece = samples[start..<min(start + Self.window, samples.count)]
            guard piece.count >= least else { break }
            do {
                text = TranscriptJoin.join(text, try transcribe(piece, models: models))
            } catch {
                throw DictationError.parakeetFailed
            }
        }
        return text
    }

    private func transcribe(_ samples: ArraySlice<Float>, models: Models) throws -> String {
        let signal = try MLMultiArray(shape: [1, NSNumber(value: Self.window)], dataType: .float32)
        let pointer = signal.dataPointer.assumingMemoryBound(to: Float.self)
        pointer.initialize(repeating: 0, count: Self.window)
        _ = UnsafeMutableBufferPointer(start: pointer, count: samples.count).initialize(from: samples)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: samples.count)
        let mel = try models.preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": signal, "audio_length": length,
        ]))
        let encoded = try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": try Self.output(mel, "mel"), "mel_length": try Self.output(mel, "mel_length"),
        ]))
        let tokens = try decode(try Self.output(encoded, "encoder"),
                                frames: try Self.output(encoded, "encoder_length")[0].intValue, models: models)
        return Self.text(tokens, vocabulary: models.vocabulary)
    }

    /// Greedy TDT: at each frame the joint picks a token (or blank) and how many frames to move on; a token also steps
    /// the prediction network.
    private func decode(_ encoder: MLMultiArray, frames: Int, models: Models) throws -> [Int] {
        // [1, 1024, frames], strided as Core ML laid it out.
        guard encoder.dataType == .float32, encoder.shape.count == 3, encoder.shape[1].intValue == Self.hidden else {
            throw DictationError.parakeetFailed
        }
        let frames = min(frames, encoder.shape[2].intValue)
        let (channelStride, frameStride) = (encoder.strides[1].intValue, encoder.strides[2].intValue)
        let source = encoder.dataPointer.assumingMemoryBound(to: Float.self)
        let step = try MLMultiArray(shape: [1, NSNumber(value: Self.hidden), 1], dataType: .float32)
        let stepPointer = step.dataPointer.assumingMemoryBound(to: Float.self)
        let stepStride = step.strides[1].intValue

        var hidden = try Self.zeros([2, 1, 640])
        var cell = try Self.zeros([2, 1, 640])
        let target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1
        /// The prediction network after `token` (the blank starts it).
        func predict(_ token: Int) throws -> MLMultiArray {
            target[0] = NSNumber(value: token)
            let out = try models.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "targets": target, "target_length": targetLength, "h_in": hidden, "c_in": cell,
            ]))
            hidden = try Self.output(out, "h_out")
            cell = try Self.output(out, "c_out")
            return try Self.output(out, "decoder")
        }

        var prediction = try predict(Self.blank)
        var tokens: [Int] = []
        var frame = 0
        var symbols = 0
        while frame < frames {
            for channel in 0..<Self.hidden {
                stepPointer[channel * stepStride] = source[channel * channelStride + frame * frameStride]
            }
            let decision = try models.joint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "encoder_step": step, "decoder_step": prediction,
            ]))
            let token = try Self.output(decision, "token_id")[0].intValue
            let bin = try Self.output(decision, "duration")[0].intValue
            guard Self.durations.indices.contains(bin), (0...Self.blank).contains(token) else { throw DictationError.parakeetFailed }
            var skip = Self.durations[bin]
            if token == Self.blank {
                skip = max(skip, 1)
            } else {
                tokens.append(token)
                prediction = try predict(token)
                symbols += 1
                if symbols >= Self.symbolsPerFrame { skip = max(skip, 1) }
            }
            if skip > 0 { symbols = 0 }
            frame += skip
        }
        return tokens
    }

    /// The tokens' pieces, "▁" marking where a word starts; special tokens ("<unk>", "<|nospeech|>") are no text.
    static func text(_ tokens: [Int], vocabulary: [String]) -> String {
        let pieces = tokens.compactMap { token -> String? in
            guard vocabulary.indices.contains(token) else { return nil }
            let piece = vocabulary[token]
            return piece.hasPrefix("<") && piece.hasSuffix(">") ? nil : piece
        }
        return pieces.joined().replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `parakeet_vocab.json`: `{"0": "<unk>", …}`, every id below the blank.
    static func vocabulary(_ data: Data) throws -> [String] {
        guard let pieces = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw DictationError.parakeetFailed
        }
        var vocabulary = [String](repeating: "", count: blank)
        for (key, piece) in pieces {
            guard let id = Int(key), vocabulary.indices.contains(id) else { continue }
            vocabulary[id] = piece
        }
        return vocabulary
    }

    /// The models in `folder`, loading them (and dropping others) when they aren't the ones in memory.
    private func models(for folder: URL) throws -> Models {
        if let loaded, loaded.url == folder { return loaded.models }
        loaded = nil
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appendingPathComponent(name), configuration: configuration)
        }
        let models: Models
        do {
            // The preprocessor's operations are CPU ones; the rest suit the Neural Engine (the GPU or CPU where
            // there is none).
            models = Models(preprocessor: try load("Preprocessor.mlmodelc", .cpuOnly),
                            encoder: try load("Encoder_v2.mlmodelc", .cpuAndNeuralEngine),
                            decoder: try load("Decoder.mlmodelc", .cpuAndNeuralEngine),
                            joint: try load("JointDecisionv3.mlmodelc", .cpuAndNeuralEngine),
                            vocabulary: try Self.vocabulary(Data(contentsOf: folder.appendingPathComponent("parakeet_vocab.json"))))
        } catch {
            throw DictationError.parakeetFailed
        }
        loaded = (folder, models)
        return models
    }

    private func scheduleUnload() {
        generation += 1
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + idle) { [self] in
            if generation == scheduled { loaded = nil }
        }
    }

    private static func output(_ features: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let array = features.featureValue(for: name)?.multiArrayValue else { throw DictationError.parakeetFailed }
        return array
    }

    private static func zeros(_ shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        array.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: array.count)
        return array
    }
}
