import Accelerate
import Foundation
import XCTest

@testable import WhisperEngine

// The reference here is whisper.cpp's `log_mel_spectrogram` transcribed as plain loops (pad, window, naive float
// DFT, power, mel dot in groups of four into a double, log, clamp, normalise), sharing no code or tables with
// Mel.swift, so a drift in either the transform or the bookkeeping shows up as a numeric difference. The signal is
// synthetic: a few sines over seeded noise, loud enough that every mel band sits well above the 80 dB clamp, where a
// float transform's rounding noise would otherwise dominate a comparison.
final class MelTests: XCTestCase {
  private let sampleRate = MelSpectrogram.sampleRate

  // MARK: - Reference (whisper.cpp 1.9.5, straight loops)

  private static let referenceHann: [Float] = (0..<400).map { i in
    Float(0.5 * (1.0 - Double(cosf(Float((2.0 * Double.pi * Double(i)) / 400.0)))))
  }
  private static let referenceSin: [Float] = (0..<400).map { sinf(Float((2.0 * Double.pi * Double($0)) / 400.0)) }
  private static let referenceCos: [Float] = (0..<400).map { cosf(Float((2.0 * Double.pi * Double($0)) / 400.0)) }

  /// whisper.cpp's `dft()` for N = 400: float accumulation against the shared float table.
  private static func referenceDFT(_ input: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: 800)
    for k in 0..<400 {
      var re: Float = 0
      var im: Float = 0
      for n in 0..<400 {
        let index = (k * n) % 400
        re += input[n] * referenceCos[index]
        im -= input[n] * referenceSin[index]
      }
      out[2 * k] = re
      out[2 * k + 1] = im
    }
    return out
  }

  private static func referenceLogMel(samples: [Float], filters: MelFilters) -> MelSpectrogram {
    let frameSize = 400
    let frameStep = 160
    let nSamples = samples.count
    let stage1Pad = 16_000 * 30
    let stage2Pad = frameSize / 2
    var padded = [Float](repeating: 0, count: nSamples + stage1Pad + stage2Pad * 2)
    for i in 0..<nSamples { padded[stage2Pad + i] = samples[i] }
    let nReflect = min(stage2Pad, max(0, nSamples - 1))
    // std::reverse_copy(samples + 1, samples + 1 + n_reflect, padded.begin() + (stage_2_pad - n_reflect))
    for t in 0..<nReflect { padded[stage2Pad - 1 - t] = samples[1 + t] }

    let nMel = filters.nMel
    let nFFT = filters.nFFT
    let nLen = (padded.count - frameSize) / frameStep
    var data = [Float](repeating: 0, count: nMel * nLen)
    let audio = nSamples + stage2Pad
    var i = 0
    while i < min(audio / frameStep + 1, nLen) {
      let offset = i * frameStep
      var fftIn = [Float](repeating: 0, count: frameSize)
      for j in 0..<min(frameSize, audio - offset) { fftIn[j] = referenceHann[j] * padded[offset + j] }
      let fftOut = referenceDFT(fftIn)
      var power = [Float](repeating: 0, count: nFFT)
      for j in 0..<nFFT { power[j] = fftOut[2 * j] * fftOut[2 * j] + fftOut[2 * j + 1] * fftOut[2 * j + 1] }
      for j in 0..<nMel {
        var sum = 0.0
        var k = 0
        while k < nFFT - 3 {
          let group: Float =
            power[k] * filters.data[j * nFFT + k] + power[k + 1] * filters.data[j * nFFT + k + 1]
            + power[k + 2] * filters.data[j * nFFT + k + 2] + power[k + 3] * filters.data[j * nFFT + k + 3]
          sum += Double(group)
          k += 4
        }
        while k < nFFT {
          sum += Double(power[k] * filters.data[j * nFFT + k])
          k += 1
        }
        data[j * nLen + i] = Float(log10(max(sum, 1e-10)))
      }
      i += 1
    }
    let silent = Float(log10(1e-10))
    while i < nLen {
      for j in 0..<nMel { data[j * nLen + i] = silent }
      i += 1
    }

    var mmax = -1e20
    for value in data where Double(value) > mmax { mmax = Double(value) }
    mmax -= 8.0
    for index in data.indices {
      if Double(data[index]) < mmax { data[index] = Float(mmax) }
      data[index] = Float((Double(data[index]) + 4.0) / 4.0)
    }
    return MelSpectrogram(nMel: nMel, nLen: nLen, data: data)
  }

  // MARK: - Fixtures

  /// Sines at 440, 1000 and 3200 Hz over seeded LCG noise at -26 dB of the loudest sine; deterministic, no audio file.
  private func syntheticSignal(seconds: Double) -> [Float] {
    let count = Int(seconds * Double(sampleRate))
    var state: UInt32 = 0x2545_F491
    return (0..<count).map { n in
      let t = Double(n) / Double(sampleRate)
      state = state &* 1_664_525 &+ 1_013_904_223
      let noise = (Double(state >> 8) / Double(1 << 24)) * 2 - 1
      let tone = 0.3 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 1000 * t) + 0.1 * sin(2 * .pi * 3200 * t)
      return Float(tone + 0.05 * noise)
    }
  }

  /// 80 triangular filters on an HTK mel scale between 0 and 8 kHz, area-normalised like librosa's "slaney" norm. Not
  /// Whisper's bank (that lives in the model file), but the same shape: sparse, non-negative, a few bins wide.
  private func syntheticFilters(nMel: Int = 80) -> MelFilters {
    let nFFT = 201
    func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
    func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
    let top = mel(8000)
    let points = (0..<(nMel + 2)).map { hz(top * Double($0) / Double(nMel + 1)) }
    var data = [Float](repeating: 0, count: nMel * nFFT)
    for m in 0..<nMel {
      let (lower, centre, upper) = (points[m], points[m + 1], points[m + 2])
      let norm = 2 / (upper - lower)
      for k in 0..<nFFT {
        let f = Double(k) * Double(sampleRate) / 400
        let rising = (f - lower) / (centre - lower)
        let falling = (upper - f) / (upper - centre)
        data[m * nFFT + k] = Float(max(0, min(rising, falling)) * norm)
      }
    }
    return MelFilters(nMel: nMel, nFFT: nFFT, data: data)
  }

  // MARK: - Shape

  func testFrameCountsMatchWhisperCpp() {
    // 30 s: n_len = (480000 + 480000 + 400 - 400) / 160 = 6000, n_len_org = 1 + (480000 + 200 - 400) / 160 = 2999.
    XCTAssertEqual(MelSpectrogram.frameCount(samples: 30 * sampleRate), 2999)
    let thirty = MelSpectrogram.compute(samples: [Float](repeating: 0, count: 30 * sampleRate), filters: syntheticFilters())
    XCTAssertEqual(thirty.nLen, 6000)
    XCTAssertEqual(thirty.nMel, 80)
    XCTAssertEqual(thirty.data.count, 80 * 6000)
    // C's truncating division: inputs shorter than 200 samples have no audio frame.
    XCTAssertEqual(MelSpectrogram.frameCount(samples: 0), 0)
    XCTAssertEqual(MelSpectrogram.frameCount(samples: 199), 1)
    XCTAssertEqual(MelSpectrogram.frameCount(samples: 16_000), 99)
    let empty = MelSpectrogram.compute(samples: [], filters: syntheticFilters())
    XCTAssertEqual(empty.nLen, 3000)
    XCTAssertEqual(Set(empty.data), [-1.5])
  }

  // MARK: - Numerics

  func testMatchesNaiveReferenceOnSyntheticSignal() {
    let filters = syntheticFilters()
    let samples = syntheticSignal(seconds: 1.5)
    let expected = Self.referenceLogMel(samples: samples, filters: filters)
    let actual = MelSpectrogram.compute(samples: samples, filters: filters)
    XCTAssertEqual(actual.nMel, expected.nMel)
    XCTAssertEqual(actual.nLen, expected.nLen)
    XCTAssertEqual(actual.nLen, 3150)
    XCTAssertEqual(actual.data.count, expected.data.count)
    var worst: Float = 0
    var worstIndex = 0
    for index in expected.data.indices {
      let difference = abs(actual.data[index] - expected.data[index])
      if difference > worst {
        worst = difference
        worstIndex = index
      }
    }
    print("mel: max |swift - reference| = \(worst) at mel \(worstIndex / expected.nLen) frame \(worstIndex % expected.nLen)")
    XCTAssertLessThan(worst, 1e-4)
    // The spectrogram's loudest value normalises to a real number and the trailing silence to the clamp floor.
    let maximum = actual.data.max()!
    XCTAssertEqual(actual.data[actual.nLen - 1], (maximum * 4 - 4 - 8 + 4) / 4, accuracy: 1e-6)
  }

  func testShortInputsReflectOnlyWhatExists() {
    // Shorter than the reflection pad: whisper.cpp clamps the reflected count to n_samples - 1.
    let filters = syntheticFilters()
    for count in [1, 2, 150, 201, 399, 560] {
      let samples = Array(syntheticSignal(seconds: 0.1).prefix(count))
      let expected = Self.referenceLogMel(samples: samples, filters: filters)
      let actual = MelSpectrogram.compute(samples: samples, filters: filters)
      XCTAssertEqual(actual.nLen, expected.nLen, "n_len for \(count) samples")
      let worst = zip(actual.data, expected.data).map { abs($0 - $1) }.max() ?? 0
      XCTAssertLessThan(worst, 1e-4, "\(count) samples")
    }
  }

  // MARK: - Chunking

  /// The previous implementation: the same twiddle-matrix DFT over every frame at once, with full-length scratch
  /// arrays (a 30-minute dictation needed 900 MB of them). Kept here as the oracle for the chunked path, which must
  /// produce the same floats, not merely close ones.
  private static func wholeArrayLogMel(samples: [Float], filters: MelFilters) -> MelSpectrogram {
    let (fftSize, hopLength, binCount, reflectPad) = (400, 160, 201, 200)
    let nMel = filters.nMel
    let paddedCount = samples.count + 16_000 * 30 + 2 * reflectPad
    let nLen = (paddedCount - fftSize) / hopLength
    let audioEnd = samples.count + reflectPad
    let computedFrames = min(audioEnd / hopLength + 1, nLen)
    var padded = [Float](repeating: 0, count: (computedFrames - 1) * hopLength + fftSize)
    for t in 0..<min(reflectPad, max(0, samples.count - 1)) { padded[reflectPad - 1 - t] = samples[1 + t] }
    for i in 0..<samples.count { padded[reflectPad + i] = samples[i] }
    var twiddles = [Float](repeating: 0, count: 2 * binCount * fftSize)
    for k in 0..<binCount {
      for j in 0..<fftSize {
        twiddles[k * fftSize + j] = referenceCos[(k * j) % fftSize]
        twiddles[(binCount + k) * fftSize + j] = -referenceSin[(k * j) % fftSize]
      }
    }
    var frames = [Float](repeating: 0, count: computedFrames * fftSize)
    for frame in 0..<computedFrames {
      vDSP_vmul(
        Array(padded[(frame * hopLength)..<(frame * hopLength + fftSize)]), 1, referenceHann, 1,
        &frames[frame * fftSize], 1, vDSP_Length(fftSize))
    }
    var spectrum = [Float](repeating: 0, count: 2 * binCount * computedFrames)
    cblas_sgemm(
      CblasRowMajor, CblasNoTrans, CblasTrans, Int32(2 * binCount), Int32(computedFrames), Int32(fftSize), 1, twiddles,
      Int32(fftSize), frames, Int32(fftSize), 0, &spectrum, Int32(computedFrames))
    let half = binCount * computedFrames
    vDSP_vsq(spectrum, 1, &spectrum, 1, vDSP_Length(2 * half))
    var power = [Float](repeating: 0, count: half)
    vDSP_vadd(spectrum, 1, Array(spectrum[half...]), 1, &power, 1, vDSP_Length(half))
    var data = [Float](repeating: 0, count: nMel * nLen)
    cblas_sgemm(
      CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(nMel), Int32(computedFrames), Int32(binCount), 1, filters.data,
      Int32(binCount), power, Int32(computedFrames), 0, &data, Int32(nLen))
    let count = nMel * nLen
    var wide = [Double](repeating: 0, count: count)
    vDSP_vspdp(data, 1, &wide, 1, vDSP_Length(count))
    var floor = 1e-10
    vDSP_vthrD(wide, 1, &floor, &wide, 1, vDSP_Length(count))
    var n = Int32(count)
    vvlog10(&wide, wide, &n)
    vDSP_vdpsp(wide, 1, &data, 1, vDSP_Length(count))
    var maximum: Float = 0
    vDSP_maxv(data, 1, &maximum, vDSP_Length(count))
    var clamp = Float(Double(maximum) - 8.0)
    vDSP_vthr(data, 1, &clamp, &data, 1, vDSP_Length(count))
    var scale: Float = 0.25
    var offset: Float = 1
    vDSP_vsmsa(data, 1, &scale, &offset, &data, 1, vDSP_Length(count))
    return MelSpectrogram(nMel: nMel, nLen: nLen, data: data)
  }

  func testChunkedPathMatchesWholeArrayPath() {
    // 90 s is 9002 transformed frames: eight full chunks of 1024 and a partial one of 810, so chunk boundaries fall at
    // multiples of 1024 frames, which is not a multiple of anything in the signal (the tones are not periodic in
    // 1024 frames). The two paths must agree bit for bit: the same windowing, the same per-element DFT and mel dot
    // products (sgemm accumulates along K per output element, independent of how many columns a call covers),
    // the same log and the same final pass.
    let filters = syntheticFilters()
    let samples = syntheticSignal(seconds: 90)
    let expected = Self.wholeArrayLogMel(samples: samples, filters: filters)
    let actual = MelSpectrogram.compute(samples: samples, filters: filters)
    XCTAssertEqual(actual.nLen, expected.nLen)
    XCTAssertEqual(actual.nLen, (90 * sampleRate + 30 * sampleRate) / 160)
    XCTAssertEqual(actual.nMel, expected.nMel)
    var mismatches = 0
    var worst: Float = 0
    for index in expected.data.indices where actual.data[index] != expected.data[index] {
      mismatches += 1
      worst = max(worst, abs(actual.data[index] - expected.data[index]))
    }
    print("mel: chunked vs whole-array on 90 s: \(mismatches) differing values, max difference \(worst)")
    XCTAssertEqual(mismatches, 0, "max difference \(worst)")
    // The first two frames (reflection) and the frames crossing the end of the audio take the gather path.
    for frame in [0, 1, 2, 9000, 9001] {
      XCTAssertEqual(actual.data[frame], expected.data[frame], "frame \(frame)")
    }
  }

  // MARK: - Real filterbank (needs DISPATCH_WHISPER_MODELS)

  /// Reads just the filterbank from a ggml Whisper file: magic, 11 int32 hyperparameters, n_mel, n_fft, floats.
  private func modelFilters() throws -> MelFilters {
    guard let directory = ProcessInfo.processInfo.environment["DISPATCH_WHISPER_MODELS"] else {
      throw XCTSkip("DISPATCH_WHISPER_MODELS is not set")
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent("ggml-tiny.bin")
    guard let handle = try? FileHandle(forReadingFrom: url) else { throw XCTSkip("no ggml-tiny.bin in \(directory)") }
    defer { try? handle.close() }
    let header = try XCTUnwrap(handle.read(upToCount: 4 + 11 * 4 + 8))
    XCTAssertEqual(header.count, 56)
    func int32(at offset: Int) -> Int32 { header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) } }
    XCTAssertEqual(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 0x6767_6d6c, "ggml magic")
    let nMel = Int(int32(at: 48))
    let nFFT = Int(int32(at: 52))
    XCTAssertEqual(nMel, Int(int32(at: 40)), "the filterbank matches hparams.n_mels")
    XCTAssertEqual(nFFT, 201)
    let bytes = try XCTUnwrap(handle.read(upToCount: nMel * nFFT * 4))
    XCTAssertEqual(bytes.count, nMel * nFFT * 4)
    let data = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    return MelFilters(nMel: nMel, nFFT: nFFT, data: data)
  }

  func testSilenceWithModelFiltersIsMinusOnePointFive() throws {
    // Every energy is 0, so every value is log10(1e-10) = -10; the maximum is -10, nothing is below -18, and
    // (-10 + 4) / 4 = -1.5 everywhere, including the padding frames.
    let filters = try modelFilters()
    let mel = MelSpectrogram.compute(samples: [Float](repeating: 0, count: 2 * sampleRate), filters: filters)
    XCTAssertEqual(mel.nMel, 80)
    XCTAssertEqual(mel.nLen, (2 * sampleRate + 30 * sampleRate) / 160)
    XCTAssertEqual(Set(mel.data), [-1.5])
  }

  func testToneWithModelFiltersPeaksInTheRightBand() throws {
    let filters = try modelFilters()
    let count = 2 * sampleRate
    let tone = (0..<count).map { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / Double(sampleRate))) }
    let mel = MelSpectrogram.compute(samples: tone, filters: filters)
    // 1 kHz is FFT bin 25 (16000 / 400 = 40 Hz per bin); the band that weights that bin most is where the tone
    // should land. On Whisper's slaney-scale bank that is band 26 (1 kHz is mel 15 of 45.2, 82 edges).
    let bandOfBin25 = (0..<filters.nMel).max { filters.data[$0 * 201 + 25] < filters.data[$1 * 201 + 25] }!
    XCTAssertEqual(bandOfBin25, 26)
    for frame in [10, 100, 150] {
      let column = (0..<mel.nMel).map { mel.data[$0 * mel.nLen + frame] }
      let peak = column.indices.max { column[$0] < column[$1] }!
      XCTAssertEqual(peak, bandOfBin25, "frame \(frame)")
      // Bands away from the tone sit on the clamp floor, 8 / 4 = 2 below the peak.
      XCTAssertEqual(column[70], column[peak] - 2, accuracy: 1e-5, "frame \(frame)")
    }
    // The trailing silence is on the floor too, and n_len_org points at the last frame that covers audio.
    XCTAssertEqual(MelSpectrogram.frameCount(samples: count), 199)
    XCTAssertEqual(mel.data[mel.nLen - 1], mel.data.max()! - 2, accuracy: 1e-5)
  }

  // MARK: - Performance

  func testThirtySecondWindowPerformance() {
    let filters = syntheticFilters()
    let samples = syntheticSignal(seconds: 30)
    _ = MelSpectrogram.compute(samples: samples, filters: filters)  // warm the tables
    let start = Date()
    let mel = MelSpectrogram.compute(samples: samples, filters: filters)
    let elapsed = Date().timeIntervalSince(start)
    print("mel: 30 s window (\(mel.nLen) frames) in \(String(format: "%.2f", elapsed * 1000)) ms")
    XCTAssertLessThan(elapsed, 0.1, "30 s of audio should take well under 100 ms")
    measure {
      _ = MelSpectrogram.compute(samples: samples, filters: filters)
    }
  }
}
