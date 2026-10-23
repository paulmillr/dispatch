import Foundation

// The sampling half of whisper.cpp's transcription loop: the probability bookkeeping behind `whisper_process_logits`
// (`whisper_compute_logprobs`, `whisper_compute_probs`), `whisper_sample_token` in both of its modes, the sequence
// score (`whisper_sequence_score`) and the random generator the fallback path draws from. Everything here mirrors the
// C++ arithmetic step for step (Float accumulation where whisper.cpp accumulates in float, Double where it uses
// double, scalar `expf`) so a transcript matches the CWhisper build to the last token, not just in spirit. The loops
// run over raw pointers with `while` because a debug build pays about 7 ms per 51865-element pass through array
// subscripts and range iterators, which at several passes per token is longer than the decoder itself.

/// A token the decoder picked, with whisper.cpp's `whisper_token_data` fields the greedy path needs: its probability
/// and log-probability under the filtered distribution it was drawn from.
struct SampledToken: Equatable, Sendable {
  var id: Int32
  var p: Float
  var plog: Float
}

/// One logits row after the filters: the row itself, its log-softmax and softmax (`decoder.logits`, `logprobs`,
/// `probs` in whisper.cpp). Suppressed tokens hold -infinity in `logits` and `logprobs` and 0 in `probs`.
struct TokenDistribution: Sendable {
  var logits: [Float]
  var logprobs: [Float]
  var probs: [Float]

  /// `whisper_compute_logprobs` then `whisper_compute_probs` over `logits`.
  init(logits: [Float]) {
    self.logits = logits
    logprobs = Self.logprobs(of: logits)
    probs = Self.probs(logits: logits, logprobs: logprobs)
  }

  /// `whisper_compute_logprobs`: a log-softmax in Float, summing exp(logit - max) sequentially like the C++ loop.
  static func logprobs(of logits: [Float]) -> [Float] {
    let count = logits.count
    return [Float](unsafeUninitializedCapacity: count) { out, initialized in
      logits.withUnsafeBufferPointer { logits in
        guard let x = logits.baseAddress, let y = out.baseAddress else { return }
        var logitMax = -Float.infinity
        var i = 0
        while i < count {
          if x[i] > logitMax { logitMax = x[i] }
          i += 1
        }
        var logsumexp: Float = 0
        i = 0
        while i < count {
          if x[i] > -Float.infinity { logsumexp += expf(x[i] - logitMax) }
          i += 1
        }
        logsumexp = logf(logsumexp) + logitMax
        i = 0
        while i < count {
          y[i] = x[i] > -Float.infinity ? x[i] - logsumexp : -Float.infinity
          i += 1
        }
      }
      initialized = count
    }
  }

  /// `whisper_compute_probs`: exp of the logprob, 0 where the logit was suppressed.
  static func probs(logits: [Float], logprobs: [Float]) -> [Float] {
    let count = logits.count
    return [Float](unsafeUninitializedCapacity: count) { out, initialized in
      logits.withUnsafeBufferPointer { logits in
        logprobs.withUnsafeBufferPointer { logprobs in
          guard let x = logits.baseAddress, let l = logprobs.baseAddress, let y = out.baseAddress else { return }
          var i = 0
          while i < count {
            y[i] = x[i] == -Float.infinity ? 0 : expf(l[i])
            i += 1
          }
        }
      }
      initialized = count
    }
  }

  /// `whisper_sample_token(best: true)`: the first token whose probability strictly exceeds every earlier one, so ties
  /// go to the lowest id, and the comparison runs on `probs` (not the logits) exactly as the C++ does.
  func best() -> SampledToken {
    var result = SampledToken(id: 0, p: 0, plog: 0)
    probs.withUnsafeBufferPointer { probs in
      guard let p = probs.baseAddress else { return }
      var i = 0
      while i < probs.count {
        if result.p < p[i] { result = SampledToken(id: Int32(i), p: p[i], plog: logprobs[i]) }
        i += 1
      }
    }
    return result
  }

  /// `whisper_sample_token(best: false)`: `std::discrete_distribution<>(probs)` evaluated with `generator`.
  func draw(_ generator: inout MersenneTwister) -> SampledToken {
    let id = Self.draw(weights: probs, generator: &generator)
    return SampledToken(id: Int32(id), p: probs[id], plog: logprobs[id])
  }

  /// One draw of `std::discrete_distribution<>(weights)`, following libc++ (what the CWhisper build links on Apple
  /// platforms): the weights are normalised in Double by their sequential sum, the cumulative sums of all but the
  /// last weight form the table, and the result is `upper_bound(table, generate_canonical<double, 53>(rng))`.
  static func draw(weights: [Float], generator: inout MersenneTwister) -> Int {
    let count = weights.count
    let tableCount = max(count - 1, 0)
    let u = generator.canonical()
    return weights.withUnsafeBufferPointer { weights in
      guard let w = weights.baseAddress else { return 0 }
      var sum: Double = 0
      var i = 0
      while i < count {
        sum += Double(w[i])
        i += 1
      }
      let cumulative = [Double](unsafeUninitializedCapacity: tableCount) { out, initialized in
        guard let c = out.baseAddress else { return }
        var running: Double = 0
        var i = 0
        while i < tableCount {
          running += Double(w[i]) / sum
          c[i] = running
          i += 1
        }
        initialized = tableCount
      }
      // upper_bound: the count of table entries <= u.
      var low = 0
      var high = tableCount
      while low < high {
        let mid = (low + high) / 2
        if cumulative[mid] <= u { low = mid + 1 } else { high = mid }
      }
      return low
    }
  }
}

/// `std::mt19937`, seeded the way whisper.cpp seeds its decoders (`std::mt19937(j)`). Only the fallback path (a
/// temperature above zero) ever draws from it; the greedy path is deterministic without it.
struct MersenneTwister: Sendable {
  private static let n = 624
  private static let m = 397
  private var state: [UInt32]
  private var index: Int

  init(seed: UInt32) {
    var state = [UInt32](repeating: 0, count: Self.n)
    state[0] = seed
    for i in 1..<Self.n {
      state[i] = 1_812_433_253 &* (state[i - 1] ^ (state[i - 1] >> 30)) &+ UInt32(i)
    }
    self.state = state
    index = Self.n
  }

  mutating func next() -> UInt32 {
    if index >= Self.n { twist() }
    var y = state[index]
    index += 1
    y ^= y >> 11
    y ^= (y << 7) & 0x9D2C_5680
    y ^= (y << 15) & 0xEFC6_0000
    y ^= y >> 18
    return y
  }

  private mutating func twist() {
    for i in 0..<Self.n {
      let y = (state[i] & 0x8000_0000) | (state[(i + 1) % Self.n] & 0x7FFF_FFFF)
      var next = state[(i + Self.m) % Self.n] ^ (y >> 1)
      if y & 1 != 0 { next ^= 0x9908_B0DF }
      state[i] = next
    }
    index = 0
  }

  /// libc++'s `generate_canonical<double, 53>` over a 32-bit generator: two draws, `(x0 + x1 * 2^32) / 2^64`, which
  /// is also what `uniform_real_distribution<double>(0, 1)` returns.
  mutating func canonical() -> Double {
    let base = 4_294_967_296.0
    let x0 = Double(next())
    let x1 = Double(next())
    return (x0 + x1 * base) / (base * base)
  }
}

/// A decoder's sequence in whisper.cpp (`whisper_sequence`): the tokens it produced this window and the statistics
/// `whisper_sequence_score` derives from the first `resultLength` of them.
struct DecoderSequence: Sendable {
  var tokens: [SampledToken] = []
  var resultLength = 0
  var sumLogprobsAll: Double = 0
  var sumLogprobs = -Double.infinity
  var avgLogprobs = -Double.infinity
  var entropy: Double = 0
  var score = -Double.infinity

  /// `whisper_sequence_score` with the default `length_penalty` (-1, so the score is the mean log-probability) and
  /// the entropy of the token counts over the last 32 tokens, which the fallback uses to spot repetition loops.
  mutating func computeScore() {
    guard resultLength > 0 else { return }
    var sum: Double = 0
    for i in 0..<resultLength { sum += Double(tokens[i].plog) }
    sumLogprobs = sum
    avgLogprobs = sum / Double(resultLength)
    score = sum / Double(resultLength)

    var counts: [Int32: Int] = [:]
    let window = max(0, resultLength - 32)..<resultLength
    for i in window { counts[tokens[i].id, default: 0] += 1 }
    var entropy: Double = 0
    // whisper.cpp walks a std::map, so the terms add in ascending token order.
    for id in counts.keys.sorted() {
      let p = Double(counts[id]!) / Double(window.count)
      entropy -= p * log(p)
    }
    self.entropy = entropy
  }
}
