import Accelerate
import Foundation

// whisper.cpp's `log_mel_spectrogram` (1.9.5), kept numerically faithful rather than merely equivalent: the parity
// tests compare against the C++ output, and whisper's decoder is sensitive to the spectrogram it was trained on.
// What whisper.cpp does, in order, and what this file reproduces:
//
// 1. Padding. 200 samples (n_fft / 2) of reflection at the front (`samples[1...200]` reversed, clamped for very short
//    input, zeros before that), then the audio, then 30 s of zeros plus 200 more zeros at the end (the end is NOT
//    reflected despite the comment in whisper.cpp). `nLen` is `(padded - 400) / 160`: PyTorch's frame count with the
//    last frame dropped, so a 30 s input yields 6000 frames, half of them silence; the encoder reads 3000-frame
//    windows past the audio and `frameCount(samples:)` gives the audio-only count whisper.cpp seeks within.
// 2. Per frame: periodic Hann window (`fill_hann_window(..., periodic: true)`, denominator 400, computed with `cosf`),
//    a 400-point DFT, power `re² + im²` of bins 0...200 only. There is no folding or doubling of the mirrored half.
// 3. Mel energy: the filterbank (nMel rows of 201) dotted with the 201 powers, then `log10(max(energy, 1e-10))`.
//    Frames whose window starts past the audio are assigned `log10(1e-10)` directly; the value is the same as
//    computing them, so this file simply does not build them.
// 4. A second pass over the whole spectrogram: clamp below `max - 8` (80 dB of dynamic range), then `(x + 4) / 4`.
//
// The DFT: vDSP's real DFT rejects length 400 (it wants 2^n times 1, 3, 5 or 15, and 400 = 16 * 25), and zero-padding
// to 512 would change the result. whisper.cpp's own transform is a radix-2 recursion down to 25-point naive DFTs, all
// drawing twiddles from one 400-entry float sin/cos table. Mathematically that equals one 400-point DFT with the
// twiddle `table[(k * n) % 400]`, which is exactly what whisper.cpp's `dft()` would compute for N = 400, so here the
// transform is a matrix product of that table against the windowed frames (`cblas_sgemm`, 402 x 400 x frames), run
// over chunks of frames so the scratch memory does not grow with the recording: 30 s of audio takes a few
// milliseconds on an M1, no threads to manage, and the only differences from the C++ are float rounding order (about
// 1e-6 on the normalised output).

extension MelSpectrogram {
  /// The 400-sample analysis window covers 200 samples each side of its centre; whisper.cpp names it `stage_2_pad`.
  private static let reflectPad = fftSize / 2
  /// whisper.cpp pads every input with 30 s of silence (`stage_1_pad`) so the encoder's last window is complete.
  private static let trailingPad = sampleRate * 30
  /// Bins 0...nyquist: the number of coefficients per mel filter.
  private static let binCount = fftSize / 2 + 1

  /// whisper.cpp's `mel.n_len_org`: the frames that cover the audio itself (`1 + (samples + 200 - 400) / 160`,
  /// truncating like C, so 0 for inputs shorter than 200 samples). `nLen` of the computed spectrogram is larger: it
  /// includes the 30 s of silence whisper.cpp appends, which the encoder reads when its window runs past the audio.
  /// `whisper_full` seeks within this count, and a 30 s input gives 2999, not 3000.
  public static func frameCount(samples: Int) -> Int {
    1 + (samples + reflectPad - fftSize) / hopLength
  }

  /// Frames per pass. The scratch (windowed frames, spectrum, powers, double energies) is sized for one chunk, about
  /// 6 MB at this size, whatever the recording length: a dictation can run for an hour and the app keeps all of it,
  /// which on a phone with a model resident must not cost hundreds of megabytes at the end. Measured on an M1, 512 to
  /// 4096 frames per chunk all take the same time (sgemm is already efficient at 1024 columns).
  private static let chunkFrames = 1024

  /// `log_mel_spectrogram` for 16 kHz mono `samples`, with the model file's `filters` (`nFFT` must be 201).
  public static func compute(samples: [Float], filters: MelFilters) -> MelSpectrogram {
    precondition(filters.nFFT == binCount, "mel filters need \(binCount) coefficients per row, got \(filters.nFFT)")
    precondition(filters.data.count == filters.nMel * filters.nFFT, "mel filter data does not match its shape")
    let nMel = filters.nMel
    let sampleCount = samples.count
    let paddedCount = sampleCount + trailingPad + 2 * reflectPad
    let nLen = (paddedCount - fftSize) / hopLength
    guard nMel > 0, nLen > 0 else { return MelSpectrogram(nMel: nMel, nLen: nLen, data: []) }

    // whisper.cpp's worker only transforms frames whose window starts within the audio plus the front pad
    // (`n_samples / frame_step + 1` of them); the rest are all zeros and get log10(1e-10) without a transform.
    let audioEnd = sampleCount + reflectPad
    let computedFrames = min(audioEnd / hopLength + 1, nLen)
    let reflectCount = min(reflectPad, max(0, sampleCount - 1))

    var data = [Float](repeating: 0, count: nMel * nLen)
    let chunk = min(chunkFrames, computedFrames)
    let scratch = Scratch(nMel: nMel, frames: chunk)
    defer { scratch.release() }

    data.withUnsafeMutableBufferPointer { out in
      samples.withUnsafeBufferPointer { audio in
        var start = 0
        while start < computedFrames {
          let count = min(chunk, computedFrames - start)
          windowFrames(audio, reflectCount: reflectCount, from: start, count: count, into: scratch.frames)
          transform(scratch, count: count)
          // 3. Mel energies straight into the output layout, [nMel x nLen] with the row stride nLen; this chunk's
          // columns start at `start`.
          filters.data.withUnsafeBufferPointer { bank in
            cblas_sgemm(
              CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(nMel), Int32(count), Int32(binCount), 1,
              bank.baseAddress!, Int32(binCount), scratch.power, Int32(count), 0, out.baseAddress! + start, Int32(nLen))
          }
          logEnergies(out.baseAddress! + start, rowStride: nLen, nMel: nMel, count: count, scratch: scratch)
          start += count
        }

        // The frames past the audio: whisper.cpp assigns `log10(1e-10)` to them, which is -10 exactly once stored
        // as float (its double is within 1e-16 of -10), the same value the transform path yields for a zero frame.
        var silent = Float(log10(1e-10))
        for mel in 0..<nMel where computedFrames < nLen {
          vDSP_vfill(&silent, out.baseAddress! + mel * nLen + computedFrames, 1, vDSP_Length(nLen - computedFrames))
        }

        // 4. The global pass: `mmax` is the float maximum read as double, minus 8; a value below it becomes that
        // double rounded to float (`max(x, Float(mmax))` gives the same float as the C++ compare-and-assign), and
        // (x + 4) / 4 in double rounded to float equals x * 0.25 + 1 in float, since scaling by a power of two
        // commutes with rounding.
        let count = nMel * nLen
        var maximum: Float = 0
        vDSP_maxv(out.baseAddress!, 1, &maximum, vDSP_Length(count))
        var floor = Float(Double(maximum) - 8.0)
        vDSP_vthr(out.baseAddress!, 1, &floor, out.baseAddress!, 1, vDSP_Length(count))
        var scale: Float = 0.25
        var offset: Float = 1
        vDSP_vsmsa(out.baseAddress!, 1, &scale, &offset, out.baseAddress!, 1, vDSP_Length(count))
      }
    }

    return MelSpectrogram(nMel: nMel, nLen: nLen, data: data)
  }

  /// One chunk's working memory, allocated once per `compute`.
  private struct Scratch {
    /// Windowed frames, [frames x 400].
    let frames: UnsafeMutablePointer<Float>
    /// The DFT, [402 x frames]: rows 0..<201 real parts, rows 201..<402 imaginary parts.
    let spectrum: UnsafeMutablePointer<Float>
    /// `re² + im²` for bins 0...200, [201 x frames].
    let power: UnsafeMutablePointer<Float>
    /// Energies as double for the log, [nMel x frames].
    let energies: UnsafeMutablePointer<Double>

    init(nMel: Int, frames count: Int) {
      frames = .allocate(capacity: count * MelSpectrogram.fftSize)
      spectrum = .allocate(capacity: 2 * MelSpectrogram.binCount * count)
      power = .allocate(capacity: MelSpectrogram.binCount * count)
      energies = .allocate(capacity: nMel * count)
    }

    func release() {
      frames.deallocate()
      spectrum.deallocate()
      power.deallocate()
      energies.deallocate()
    }
  }

  /// 1 + 2. The padded signal is never materialised: a frame's 400 samples are the audio shifted by 200, except
  /// for the first two frames (which reach into the front reflection) and the last few (which run into the zeros).
  /// Those gather their samples one by one; every other frame is one `vDSP_vmul` against the window, the same
  /// `hann[j] * samples[offset + j]` float product as the C++.
  private static func windowFrames(
    _ audio: UnsafeBufferPointer<Float>, reflectCount: Int, from start: Int, count: Int,
    into frames: UnsafeMutablePointer<Float>
  ) {
    MelTables.hann.withUnsafeBufferPointer { hann in
      for index in 0..<count {
        let destination = frames + index * fftSize
        let first = (start + index) * hopLength - reflectPad  // the frame's first sample, in audio coordinates
        if first >= 0, first + fftSize <= audio.count {
          vDSP_vmul(audio.baseAddress! + first, 1, hann.baseAddress!, 1, destination, 1, vDSP_Length(fftSize))
          continue
        }
        for j in 0..<fftSize {
          let position = first + j
          let sample: Float
          if position >= 0 {
            sample = position < audio.count ? audio[position] : 0
          } else {
            // Reflection: padded[199 - t] = samples[1 + t] for t < reflectCount, zero before that.
            let t = -position - 1
            sample = t < reflectCount ? audio[1 + t] : 0
          }
          destination[j] = hann[j] * sample
        }
      }
    }
  }

  /// The DFT as one product: spectrum [402 x count] = twiddles [402 x 400] x frames^T, then the power `re² + im²`
  /// of bins 0...200 only, [201 x count]; whisper.cpp never folds in the mirrored bins.
  private static func transform(_ scratch: Scratch, count: Int) {
    MelTables.twiddles.withUnsafeBufferPointer { twiddles in
      cblas_sgemm(
        CblasRowMajor, CblasNoTrans, CblasTrans, Int32(2 * binCount), Int32(count), Int32(fftSize), 1,
        twiddles.baseAddress!, Int32(fftSize), scratch.frames, Int32(fftSize), 0, scratch.spectrum, Int32(count))
    }
    let half = binCount * count
    vDSP_vsq(scratch.spectrum, 1, scratch.spectrum, 1, vDSP_Length(2 * half))
    vDSP_vadd(scratch.spectrum, 1, scratch.spectrum + half, 1, scratch.power, 1, vDSP_Length(half))
  }

  /// `log10(std::max(sum, 1e-10))` happens in double and is stored as float; the double detour keeps the rounding of
  /// the C++ (vvlog10f would differ by an ulp here and there). `energies` points at the chunk's columns inside the
  /// [nMel x nLen] output, so each row is converted separately.
  private static func logEnergies(
    _ energies: UnsafeMutablePointer<Float>, rowStride: Int, nMel: Int, count: Int, scratch: Scratch
  ) {
    for mel in 0..<nMel {
      vDSP_vspdp(energies + mel * rowStride, 1, scratch.energies + mel * count, 1, vDSP_Length(count))
    }
    let total = nMel * count
    var floor = 1e-10
    vDSP_vthrD(scratch.energies, 1, &floor, scratch.energies, 1, vDSP_Length(total))
    var n = Int32(total)
    vvlog10(scratch.energies, scratch.energies, &n)
    for mel in 0..<nMel {
      vDSP_vdpsp(scratch.energies + mel * count, 1, energies + mel * rowStride, 1, vDSP_Length(count))
    }
  }
}

/// whisper.cpp's `whisper_global_cache`: the window and the sin/cos table, built once with the same float calls, so the
/// twiddles carry the same single-precision rounding as the C++ rather than correctly rounded values.
private enum MelTables {
  /// `0.5 * (1.0 - cosf((2.0 * M_PI * i) / 400))`: the periodic Hann window (torch.hann_window's default, which
  /// Whisper's audio.py uses), with the cosine in single precision and the rest in double, stored as float.
  static let hann: [Float] = (0..<MelSpectrogram.fftSize).map { i in
    let angle = Float((2.0 * Double.pi * Double(i)) / Double(MelSpectrogram.fftSize))
    return Float(0.5 * (1.0 - Double(cosf(angle))))
  }

  /// The DFT matrix as whisper.cpp's `dft()` indexes it: row k (0...200) holds `cos_vals[(k * n) % 400]` for n in
  /// 0..<400, row 201 + k holds `-sin_vals[(k * n) % 400]`, where the tables are `sinf`/`cosf` of `2 * M_PI * i / 400`
  /// narrowed to float before the call.
  static let twiddles: [Float] = {
    let n = MelSpectrogram.fftSize
    let bins = n / 2 + 1
    var sines = [Float](repeating: 0, count: n)
    var cosines = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let theta = Float((2.0 * Double.pi * Double(i)) / Double(n))
      sines[i] = sinf(theta)
      cosines[i] = cosf(theta)
    }
    var table = [Float](repeating: 0, count: 2 * bins * n)
    for k in 0..<bins {
      for j in 0..<n {
        let index = (k * j) % n
        table[k * n + j] = cosines[index]
        table[(bins + k) * n + j] = -sines[index]
      }
    }
    return table
  }()
}
