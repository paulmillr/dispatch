import Foundation

// Whisper's encoder and decoder as whisper.cpp 1.9.5 builds them (`whisper_build_graph_conv`, `_encoder`, `_cross`,
// `_decoder` and the input handling in `whisper_encode_internal` / `whisper_decode_internal`), expressed over the
// `WhisperBackend` op set. The graph is the same for every backend; only the ops differ.
//
// Scaling, as in whisper.cpp. With hd = nState / nHead and Kscale = pow(hd, -0.25):
// - encoder self-attention: q and k unscaled, softmax(KQ * 1/sqrt(hd));
// - decoder self-attention: q and k each scaled by Kscale before the cache, softmax(KQ * 1.0);
// - cross-attention: K scaled by Kscale when the encoder runs (`whisper_build_graph_cross`), softmax(KQ * Kscale).
// All three are softmax(q k^T / sqrt(hd)); the op set has no scale op, so every attention gets
// `scale = 1 / sqrt(hd)` on the product and the keys are cached unscaled (equal up to Float32 rounding).
//
// Biases: query, value, out and both MLP matmuls have one, key never does (`// note: no bias for Key`). Layer norms:
// attn_ln, cross_attn_ln, mlp_ln per block, encoder.ln_post and decoder.ln at the end, all with weight and bias,
// eps = 1e-5 (`whisper_hparams::eps`).
//
// Attention padding. whisper.cpp runs with flash attention by default (`whisper_context_default_params`), and that
// path attends over keys padded to a multiple of 256 with no mask: the encoder's self-attention reads `kv_pad`
// (GGML_PAD(n_ctx, 256) = 1536 rows for 1500) and the decoder's cross-attention reads `kv_cross` with
// `n_audio_ctx_pad` rows per layer. The buffers are zero-cleared, so each padding key scores 0 and takes softmax
// mass, diluting every attention output a little; through whisper's large residual channels that is ~10% of the
// encoder output and up to 0.6 rms on tiny's logits, far above whisper.cpp's own CPU-vs-Metal noise. The decoder's
// self-attention is masked and unaffected. `attentionPadding` reproduces it (256, the default: what the app's
// whisper.cpp computes) or turns it off (1: the exact attention, whisper.cpp with `flash_attn = false`).

/// The encoder/decoder over a backend. Not thread-safe (one graph at a time, like the backend); `@unchecked Sendable`
/// so the transcription driver can own it from a task.
public final class WhisperModel<Backend: WhisperBackend>: WhisperInference, @unchecked Sendable {
  public let hyperparameters: WhisperHyperparameters
  public let vocabulary: Vocabulary
  public let backend: Backend
  /// Keys and values of the encoder self-attention and the cross-attention are zero-padded to a multiple of this
  /// (header). 256 matches whisper.cpp's flash-attention path; 1 is the exact attention.
  public let attentionPadding: Int

  /// whisper.cpp's `whisper_hparams::eps`.
  public static var layerNormEpsilon: Float { 1e-5 }

  private struct EncoderLayer {
    var attnLnW, attnLnB: Backend.Tensor
    var qW, qB, kW, vW, vB, outW, outB: Backend.Tensor
    var mlpLnW, mlpLnB, mlp0W, mlp0B, mlp1W, mlp1B: Backend.Tensor
  }

  private struct DecoderLayer {
    var attnLnW, attnLnB: Backend.Tensor
    var qW, qB, kW, vW, vB, outW, outB: Backend.Tensor
    var crossLnW, crossLnB: Backend.Tensor
    var crossQW, crossQB, crossKW, crossVW, crossVB, crossOutW, crossOutB: Backend.Tensor
    var mlpLnW, mlpLnB, mlp0W, mlp0B, mlp1W, mlp1B: Backend.Tensor
  }

  private let positionalEmbedding: Backend.Tensor  // encoder.positional_embedding [nAudioContext, nState]
  private let conv1W, conv1B, conv2W, conv2B: Backend.Tensor
  private let encoderLnW, encoderLnB: Backend.Tensor  // encoder.ln_post
  private let encoderLayers: [EncoderLayer]
  private let tokenEmbedding: Backend.Tensor  // decoder.token_embedding.weight [nVocab, nState]; also the logits matrix
  private let decoderPositionalEmbedding: Backend.Tensor  // decoder.positional_embedding [nTextContext, nState]
  private let decoderLnW, decoderLnB: Backend.Tensor  // decoder.ln
  private let decoderLayers: [DecoderLayer]

  /// The last `encode`'s output after `ln_post`, [encoderContext, nAudioState] row-major (for parity tests). Read
  /// from the backend on demand: reading inside `encode` would wait for the GPU before the cross-attention
  /// projections are queued.
  public var encoderOutput: [Float]? { encoderTensor.map { backend.read($0) } }
  private var encoderTensor: Backend.Tensor?
  /// The audio context of the last `encode` (the number of encoder positions, 1500 unless limited).
  public private(set) var encoderContext = 0

  // Per decoder layer. Cross keys/values are [encoderContext, nState]; the self caches hold nTextContext rows.
  private var crossKeys: [Backend.Tensor] = []
  private var crossValues: [Backend.Tensor] = []
  private var selfKeys: [Backend.Tensor] = []
  private var selfValues: [Backend.Tensor] = []

  /// Uploads every weight `whisper_model_load` maps (by its ggml name) to `backend`, after checking that the
  /// hyperparameters are runnable (`WhisperHyperparameters.validate`) and that every tensor has exactly the shape
  /// the graph derives from them (whisper.cpp's `ggml_nelements` check per tensor, made exact). A wrong shape
  /// throws `WhisperError.shapeMismatch` here rather than tripping a backend precondition mid-graph; a missing
  /// tensor throws `.missingTensor`.
  public init(file: WhisperModelFile, backend: Backend, attentionPadding: Int = 256) throws {
    precondition(attentionPadding >= 1, "attentionPadding must be positive")
    try file.hyperparameters.validate()
    self.hyperparameters = file.hyperparameters
    self.vocabulary = file.vocabulary
    self.backend = backend
    self.attentionPadding = attentionPadding
    let h = file.hyperparameters

    /// The named tensor, checked against `shape` and against its own byte count (so a tensor altered in memory
    /// cannot reach a backend with less data than its shape claims).
    func expect(_ name: String, _ shape: [Int]) throws -> WeightTensor {
      let tensor = try file.tensor(name)
      guard tensor.shape == shape else {
        throw WhisperError.shapeMismatch("\(name): \(tensor.shape), expected \(shape)")
      }
      guard let elements = WhisperModelFile.elementCount(shape),
        tensor.type != .q8_0 || elements % 32 == 0,
        let bytes = WhisperModelFile.byteCount(tensor.type, elements: elements), tensor.data.count == bytes
      else {
        throw WhisperError.shapeMismatch("\(name): \(tensor.data.count) bytes for shape \(shape) \(tensor.type)")
      }
      return tensor
    }
    func upload(_ name: String, _ shape: [Int]) throws -> Backend.Tensor { try backend.weight(try expect(name, shape)) }
    /// Conv biases are stored as ne = [1, n_state] (shape [nState, 1]); the op wants [cout].
    func uploadFlat(_ name: String, _ count: Int) throws -> Backend.Tensor {
      var tensor = try expect(name, [count, 1])
      tensor.shape = [count]
      return try backend.weight(tensor)
    }

    let audio = h.nAudioState
    let text = h.nTextState
    positionalEmbedding = try upload("encoder.positional_embedding", [h.nAudioContext, audio])
    conv1W = try upload("encoder.conv1.weight", [audio, h.nMels, 3])
    conv1B = try uploadFlat("encoder.conv1.bias", audio)
    conv2W = try upload("encoder.conv2.weight", [audio, audio, 3])
    conv2B = try uploadFlat("encoder.conv2.bias", audio)
    encoderLnW = try upload("encoder.ln_post.weight", [audio])
    encoderLnB = try upload("encoder.ln_post.bias", [audio])
    encoderLayers = try (0..<h.nAudioLayer).map { i in
      let p = "encoder.blocks.\(i)."
      return EncoderLayer(
        attnLnW: try upload(p + "attn_ln.weight", [audio]), attnLnB: try upload(p + "attn_ln.bias", [audio]),
        qW: try upload(p + "attn.query.weight", [audio, audio]), qB: try upload(p + "attn.query.bias", [audio]),
        kW: try upload(p + "attn.key.weight", [audio, audio]),
        vW: try upload(p + "attn.value.weight", [audio, audio]), vB: try upload(p + "attn.value.bias", [audio]),
        outW: try upload(p + "attn.out.weight", [audio, audio]), outB: try upload(p + "attn.out.bias", [audio]),
        mlpLnW: try upload(p + "mlp_ln.weight", [audio]), mlpLnB: try upload(p + "mlp_ln.bias", [audio]),
        mlp0W: try upload(p + "mlp.0.weight", [4 * audio, audio]), mlp0B: try upload(p + "mlp.0.bias", [4 * audio]),
        mlp1W: try upload(p + "mlp.2.weight", [audio, 4 * audio]), mlp1B: try upload(p + "mlp.2.bias", [audio]))
    }

    tokenEmbedding = try upload("decoder.token_embedding.weight", [h.nVocab, text])
    decoderPositionalEmbedding = try upload("decoder.positional_embedding", [h.nTextContext, text])
    decoderLnW = try upload("decoder.ln.weight", [text])
    decoderLnB = try upload("decoder.ln.bias", [text])
    decoderLayers = try (0..<h.nTextLayer).map { i in
      let p = "decoder.blocks.\(i)."
      return DecoderLayer(
        attnLnW: try upload(p + "attn_ln.weight", [text]), attnLnB: try upload(p + "attn_ln.bias", [text]),
        qW: try upload(p + "attn.query.weight", [text, text]), qB: try upload(p + "attn.query.bias", [text]),
        kW: try upload(p + "attn.key.weight", [text, text]),
        vW: try upload(p + "attn.value.weight", [text, text]), vB: try upload(p + "attn.value.bias", [text]),
        outW: try upload(p + "attn.out.weight", [text, text]), outB: try upload(p + "attn.out.bias", [text]),
        crossLnW: try upload(p + "cross_attn_ln.weight", [text]), crossLnB: try upload(p + "cross_attn_ln.bias", [text]),
        crossQW: try upload(p + "cross_attn.query.weight", [text, text]),
        crossQB: try upload(p + "cross_attn.query.bias", [text]),
        // Cross-attention projects the encoder's output, so its key/value weights are [text, audio].
        crossKW: try upload(p + "cross_attn.key.weight", [text, audio]),
        crossVW: try upload(p + "cross_attn.value.weight", [text, audio]),
        crossVB: try upload(p + "cross_attn.value.bias", [text]),
        crossOutW: try upload(p + "cross_attn.out.weight", [text, text]),
        crossOutB: try upload(p + "cross_attn.out.bias", [text]),
        mlpLnW: try upload(p + "mlp_ln.weight", [text]), mlpLnB: try upload(p + "mlp_ln.bias", [text]),
        mlp0W: try upload(p + "mlp.0.weight", [4 * text, text]), mlp0B: try upload(p + "mlp.0.bias", [4 * text]),
        mlp1W: try upload(p + "mlp.2.weight", [text, 4 * text]), mlp1B: try upload(p + "mlp.2.bias", [text]))
    }
  }

  // MARK: Encoder

  /// `whisper_encode_internal`: the mel window is `2 * nCtx` frames from `offset` (zero past the end of `mel`),
  /// nCtx = `audioContext` or the model's 1500. Conv1 (k 3, s 1, p 1) + gelu, conv2 (k 3, s 2, p 1) + gelu give
  /// [nState, nCtx]; transposed and added to the first nCtx rows of `encoder.positional_embedding` (whisper.cpp views
  /// the table at offset `n_ctx * iter` with `iter` always 0). Then the transformer, `ln_post`, and the cross-attention
  /// keys/values of every decoder layer; the self-attention caches are reset.
  public func encode(mel: MelSpectrogram, offset: Int, audioContext: Int) throws {
    let h = hyperparameters
    guard mel.nMel == h.nMels else { throw WhisperError.shapeMismatch("mel has \(mel.nMel) bands, model \(h.nMels)") }
    guard mel.data.count == mel.nMel * mel.nLen else {
      throw WhisperError.shapeMismatch("mel: \(mel.data.count) values for \(mel.nMel) x \(mel.nLen)")
    }
    guard audioContext >= 0 && audioContext <= h.nAudioContext else {
      throw WhisperError.shapeMismatch("audioContext \(audioContext) is larger than the maximum allowed \(h.nAudioContext)")
    }
    guard offset >= 0 else { throw WhisperError.shapeMismatch("negative mel offset \(offset)") }
    let nCtx = audioContext > 0 ? audioContext : h.nAudioContext
    let nFrames = 2 * nCtx

    // Input window, [nMels, 2 * nCtx], `whisper_encode_internal`'s copy loop.
    var window = [Float](repeating: 0, count: h.nMels * nFrames)
    let i0 = min(offset, mel.nLen)
    let i1 = min(offset + nFrames, mel.nLen)
    if i1 > i0 {
      for band in 0..<h.nMels {
        let src = band * mel.nLen
        let dst = band * nFrames
        for i in i0..<i1 { window[dst + (i - i0)] = mel.data[src + i] }
      }
    }

    let b = backend
    var cur = b.tensor(window, shape: [h.nMels, nFrames])
    cur = b.gelu(b.conv1d(cur, weight: conv1W, bias: conv1B, stride: 1, padding: 1))  // [nState, 2 nCtx]
    cur = b.gelu(b.conv1d(cur, weight: conv2W, bias: conv2B, stride: 2, padding: 1))  // [nState, nCtx]
    cur = b.add(b.transpose(cur), b.rows(positionalEmbedding, 0..<nCtx))  // [nCtx, nState]

    let scale = Self.attentionScale(state: h.nAudioState, heads: h.nAudioHead)
    let eps = Self.layerNormEpsilon
    for layer in encoderLayers {
      let residual = cur
      var x = b.layerNorm(residual, weight: layer.attnLnW, bias: layer.attnLnB, epsilon: eps)
      let q = b.linear(x, weight: layer.qW, bias: layer.qB)
      let k = padded(b.linear(x, weight: layer.kW, bias: nil))
      let v = padded(b.linear(x, weight: layer.vW, bias: layer.vB))
      x = b.attention(query: q, key: k, value: v, heads: h.nAudioHead, scale: scale, causal: false)
      x = b.linear(x, weight: layer.outW, bias: layer.outB)
      let mlpInput = b.add(x, residual)
      x = b.layerNorm(mlpInput, weight: layer.mlpLnW, bias: layer.mlpLnB, epsilon: eps)
      x = b.gelu(b.linear(x, weight: layer.mlp0W, bias: layer.mlp0B))
      x = b.linear(x, weight: layer.mlp1W, bias: layer.mlp1B)
      cur = b.add(x, mlpInput)
    }
    cur = b.layerNorm(cur, weight: encoderLnW, bias: encoderLnB, epsilon: eps)

    encoderTensor = cur
    encoderContext = nCtx

    // `whisper_build_graph_cross`: K without bias (whisper.cpp scales it by Kscale here; see the header), V with bias,
    // zero-padded like whisper.cpp's `kv_cross` (header).
    crossKeys = decoderLayers.map { padded(b.linear(cur, weight: $0.crossKW, bias: nil)) }
    crossValues = decoderLayers.map { padded(b.linear(cur, weight: $0.crossVW, bias: $0.crossVB)) }
    resetCache()
  }

  /// Empties the decoder's self-attention caches (whisper.cpp's `kv_self` clear); `encode` does this itself.
  public func resetCache() {
    let h = hyperparameters
    selfKeys = decoderLayers.map { _ in backend.cache(capacity: h.nTextContext, width: h.nTextState) }
    selfValues = decoderLayers.map { _ in backend.cache(capacity: h.nTextContext, width: h.nTextState) }
  }

  // MARK: Decoder

  /// `whisper_build_graph_decoder` for a batch at positions past ..< past + n: token embedding rows plus
  /// `decoder.positional_embedding` rows [past, past + n); per layer self-attention over the cache (keys and values
  /// of this batch written at `past`, query i attending cache entries 0 ... past + i, whisper.cpp's `KQ_mask`),
  /// cross-attention over the encoder's keys/values, MLP; `decoder.ln`; logits = x @ token_embedding^T for every
  /// token of the batch (whisper.cpp keeps the commented-out last-row view off too).
  public func decode(tokens: [Int32], past: Int) throws -> [Float] {
    let h = hyperparameters
    guard !crossKeys.isEmpty, encoderContext > 0 else { throw WhisperError.decodeFailed("decode before encode") }
    guard !tokens.isEmpty else { throw WhisperError.decodeFailed("empty token batch") }
    guard past >= 0, past + tokens.count <= h.nTextContext else {
      throw WhisperError.decodeFailed("positions \(past)..<\(past + tokens.count) exceed the text context \(h.nTextContext)")
    }
    for token in tokens where token < 0 || Int(token) >= h.nVocab {
      throw WhisperError.decodeFailed("token \(token) outside the vocabulary")
    }

    let b = backend
    let n = tokens.count
    let scale = Self.attentionScale(state: h.nTextState, heads: h.nTextHead)
    let eps = Self.layerNormEpsilon
    var cur = b.add(b.embedding(tokenEmbedding, ids: tokens), b.rows(decoderPositionalEmbedding, past..<past + n))

    for (i, layer) in decoderLayers.enumerated() {
      let residual = cur
      var x = b.layerNorm(residual, weight: layer.attnLnW, bias: layer.attnLnB, epsilon: eps)
      let q = b.linear(x, weight: layer.qW, bias: layer.qB)
      let k = b.linear(x, weight: layer.kW, bias: nil)
      let v = b.linear(x, weight: layer.vW, bias: layer.vB)
      b.write(k, into: selfKeys[i], at: past)
      b.write(v, into: selfValues[i], at: past)
      let keys = b.rows(selfKeys[i], 0..<past + n)
      let values = b.rows(selfValues[i], 0..<past + n)
      x = b.attention(query: q, key: keys, value: values, heads: h.nTextHead, scale: scale, causal: true)
      x = b.linear(x, weight: layer.outW, bias: layer.outB)
      let crossInput = b.add(x, residual)

      x = b.layerNorm(crossInput, weight: layer.crossLnW, bias: layer.crossLnB, epsilon: eps)
      let crossQ = b.linear(x, weight: layer.crossQW, bias: layer.crossQB)
      x = b.attention(
        query: crossQ, key: crossKeys[i], value: crossValues[i], heads: h.nTextHead, scale: scale, causal: false)
      x = b.linear(x, weight: layer.crossOutW, bias: layer.crossOutB)
      let mlpInput = b.add(x, crossInput)

      x = b.layerNorm(mlpInput, weight: layer.mlpLnW, bias: layer.mlpLnB, epsilon: eps)
      x = b.gelu(b.linear(x, weight: layer.mlp0W, bias: layer.mlp0B))
      x = b.linear(x, weight: layer.mlp1W, bias: layer.mlp1B)
      cur = b.add(x, mlpInput)
    }

    cur = b.layerNorm(cur, weight: decoderLnW, bias: decoderLnB, epsilon: eps)
    let logits = b.linear(cur, weight: tokenEmbedding, bias: nil)  // [n, nVocab]
    let values = b.read(logits)
    if let failure = b.takeFailure() { throw WhisperError.decodeFailed("device: \(failure)") }
    return values
  }

  /// `x` [n, d] with zero rows appended up to a multiple of `attentionPadding` (whisper.cpp's `GGML_PAD(n, 256)`
  /// buffers, zero-cleared); `x` itself when already aligned.
  private func padded(_ x: Backend.Tensor) -> Backend.Tensor {
    let n = x.shape[0]
    let target = (n + attentionPadding - 1) / attentionPadding * attentionPadding
    if target == n { return x }
    let buffer = backend.cache(capacity: target, width: x.shape[1])
    backend.write(x, into: buffer, at: 0)
    return buffer
  }

  /// 1 / sqrt(nState / nHead), the product of whisper.cpp's two Kscale factors (header).
  private static func attentionScale(state: Int, heads: Int) -> Float {
    1 / Float(state / heads).squareRoot()
  }
}
