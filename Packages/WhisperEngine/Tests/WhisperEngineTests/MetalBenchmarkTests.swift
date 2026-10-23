import Foundation
import XCTest

@testable import WhisperEngine

// Wall-clock timings of `WhisperModel<MetalBackend>` on the real models (encode of one 30 s window, a 4-token prompt
// decode, 20 single-token decodes), with the backend's submission statistics. Needs `DISPATCH_WHISPER_MODELS`; run
// in release: `swift test -c release --filter MetalBenchmarkTests`. The numbers are printed, not asserted.

final class MetalBenchmarkTests: XCTestCase {
  private func model(_ name: String) throws -> WhisperModel<MetalBackend> {
    guard let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"] else {
      throw XCTSkip("DISPATCH_WHISPER_MODELS is not set")
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) is missing") }
    let backend: MetalBackend
    do { backend = try MetalBackend() } catch WhisperError.metalUnavailable { throw XCTSkip("no Metal device") }
    let file = try WhisperModelFile.load(url)
    let start = Date()
    let model = try WhisperModel(file: file, backend: backend)
    print("[bench] \(name): weights uploaded in \(Date().timeIntervalSince(start)) s")
    return model
  }

  private func timed(_ label: String, backend: MetalBackend, repeats: Int = 1, _ body: () throws -> Void) rethrows {
    var best = Double.infinity
    var stats = MetalBackend.Statistics()
    for _ in 0..<repeats {
      backend.resetStatistics()
      let start = Date()
      try body()
      best = min(best, Date().timeIntervalSince(start))
      stats = backend.statistics
    }
    let s = stats
    print(
      "[bench] \(label): \(String(format: "%.4f", best)) s (gpu \(String(format: "%.4f", s.gpuSeconds)) s, waited "
        + "\(String(format: "%.4f", s.waitSeconds)) s); \(s.dispatches) dispatches, \(s.commandBuffers) command buffers, "
        + "\(s.encoders) encoders, \(s.buffersAllocated) buffers (\(s.bytesAllocated / 1_000_000) MB) allocated")
  }

  private func benchmark(_ name: String) throws {
    let model = try model(name)
    let backend = model.backend
    var rng = MetalBackendTests.Seeded(7)
    let mel = MelSpectrogram(nMel: model.hyperparameters.nMels, nLen: 3000, data: rng.floats(model.hyperparameters.nMels * 3000))
    let v = model.vocabulary

    // `encode` queues the work and returns; `flush` waits for it, as the first decode would.
    try timed("\(name) encode (first, includes pipeline specialisation)", backend: backend) {
      try model.encode(mel: mel, offset: 0, audioContext: 0)
      backend.flush()
    }
    try timed("\(name) encode", backend: backend, repeats: 3) {
      try model.encode(mel: mel, offset: 0, audioContext: 0)
      backend.flush()
    }

    let prompt = [v.sot, v.sotLanguage + 1, v.transcribe, v.not]
    try timed("\(name) prompt decode (4 tokens)", backend: backend, repeats: 3) {
      model.resetCache()
      _ = try model.decode(tokens: prompt, past: 0)
    }
    var token = v.sotLanguage + 50
    try timed("\(name) 20 single-token decodes", backend: backend) {
      for i in 0..<20 {
        let logits = try model.decode(tokens: [token], past: prompt.count + i)
        token = Int32(logits[0..<Int(v.eot)].enumerated().max { $0.element < $1.element }!.offset)
      }
    }
    try timed("\(name) one single-token decode", backend: backend, repeats: 3) {
      _ = try model.decode(tokens: [token], past: prompt.count + 20)
    }
  }

  /// Per-kernel GPU time for one encode and one single-token decode of the small model.
  func testSmallQ8Profile() throws {
    let model = try model("ggml-small-q8_0.bin")
    let backend = model.backend
    var rng = MetalBackendTests.Seeded(7)
    let mel = MelSpectrogram(nMel: model.hyperparameters.nMels, nLen: 3000, data: rng.floats(model.hyperparameters.nMels * 3000))
    try model.encode(mel: mel, offset: 0, audioContext: 0)  // warm up pipelines
    let prompt = [model.vocabulary.sot, model.vocabulary.sotLanguage + 1, model.vocabulary.transcribe, model.vocabulary.not]
    _ = try model.decode(tokens: prompt, past: 0)
    backend.profiling = true
    backend.resetProfile()
    try model.encode(mel: mel, offset: 0, audioContext: 0)
    backend.flush()
    print("[profile] encode:")
    for (name, entry) in backend.profile.sorted(by: { $0.value.seconds > $1.value.seconds }) {
      print(String(format: "[profile]   %8.3f ms  %4d x  %@", entry.seconds * 1000, entry.count, name))
    }
    backend.resetProfile()
    _ = try model.decode(tokens: prompt, past: 0)
    _ = try model.decode(tokens: [model.vocabulary.sotLanguage + 50], past: 4)
    backend.resetProfile()
    _ = try model.decode(tokens: [model.vocabulary.sotLanguage + 51], past: 5)
    print("[profile] one single-token decode:")
    for (name, entry) in backend.profile.sorted(by: { $0.value.seconds > $1.value.seconds }) {
      print(String(format: "[profile]   %8.3f ms  %4d x  %@", entry.seconds * 1000, entry.count, name))
    }
    backend.profiling = false
  }

  /// The Metal graph against the CPU graph on the real models: encoder output and the logits of a prompt decode
  /// plus three single-token steps. whisper.cpp's own CPU-vs-Metal spread is ~0.05-0.3 rms on tiny's logits.
  func testMatchesCPUBackend() throws {
    guard let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"] else {
      throw XCTSkip("DISPATCH_WHISPER_MODELS is not set")
    }
    for name in ["ggml-tiny.bin", "ggml-tiny-q8_0.bin"] {
      let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let file = try WhisperModelFile.load(url)
      let metal = try WhisperModel(file: file, backend: try model(name).backend)
      let cpu = try WhisperModel(file: file, backend: CPUBackend())
      var rng = MetalBackendTests.Seeded(11)
      let mel = MelSpectrogram(nMel: file.hyperparameters.nMels, nLen: 3000, data: rng.floats(file.hyperparameters.nMels * 3000, scale: 2))
      try metal.encode(mel: mel, offset: 0, audioContext: 0)
      try cpu.encode(mel: mel, offset: 0, audioContext: 0)
      let encoderError = MetalBackendTests.maxRelativeError(metal.encoderOutput!, cpu.encoderOutput!)
      print("[parity] \(name) encoder output: max relative error \(encoderError)")
      XCTAssertLessThan(encoderError, 0.1, "\(name) encoder")

      let v = file.vocabulary
      var tokens = [v.sot, v.sotLanguage + 1, v.transcribe, v.not]
      var past = 0
      for step in 0..<4 {
        let a = try metal.decode(tokens: tokens, past: past)
        let b = try cpu.decode(tokens: tokens, past: past)
        let n = tokens.count
        let rows = (0..<n).map { i in Array(a[i * Int(file.hyperparameters.nVocab)..<(i + 1) * Int(file.hyperparameters.nVocab)]) }
        let rowsB = (0..<n).map { i in Array(b[i * Int(file.hyperparameters.nVocab)..<(i + 1) * Int(file.hyperparameters.nVocab)]) }
        var maxDelta: Float = 0
        var sum: Double = 0
        for (x, y) in zip(a, b) {
          maxDelta = max(maxDelta, abs(x - y))
          sum += Double((x - y) * (x - y))
        }
        let rms = (sum / Double(a.count)).squareRoot()
        let argmaxA = rows.last!.enumerated().max { $0.element < $1.element }!.offset
        let argmaxB = rowsB.last!.enumerated().max { $0.element < $1.element }!.offset
        print("[parity] \(name) step \(step): logits max |delta| \(maxDelta), rms \(rms), argmax \(argmaxA) vs \(argmaxB)")
        XCTAssertLessThan(rms, 0.1, "\(name) step \(step)")
        XCTAssertEqual(argmaxA, argmaxB, "\(name) step \(step) argmax")
        past += n
        tokens = [Int32(argmaxA)]
      }
    }
  }

  func testTinyF16() throws { try benchmark("ggml-tiny.bin") }
  func testTinyQ8() throws { try benchmark("ggml-tiny-q8_0.bin") }
  func testSmallQ8() throws { try benchmark("ggml-small-q8_0.bin") }
}
