import Foundation

// The engine's shared types and seams. Every module (model file, mel, backends, the model graph, transcription)
// compiles against this file only; keep it small and change it deliberately, since the modules are written in
// parallel. Conventions: activations are Float32, row-major, with a `shape` whose last element is the contiguous
// dimension (a [rows, cols] matrix has `cols` contiguous). Weights keep the model file's storage type until a backend
// consumes them. Shapes are written in Swift order ([rows, cols]), the reverse of ggml's `ne` ([ne0 = cols, ne1 = rows]).

// MARK: - Model file

/// A tensor's storage type in a ggml model file. Whisper's files use these three.
public enum WeightType: Int32, Sendable {
  case f32 = 0
  case f16 = 1
  /// Blocks of 32 values: a Float16 scale then 32 Int8 quants (34 bytes per block); value = scale * quant.
  case q8_0 = 8

  /// Bytes for `count` elements of this type (`count` is a multiple of 32 for q8_0).
  public func byteCount(elements count: Int) -> Int {
    switch self {
    case .f32: count * 4
    case .f16: count * 2
    case .q8_0: count / 32 * 34
    }
  }
}

/// One weight as stored in the model file: `shape` in Swift order (the last dimension contiguous), `data` the file's
/// bytes for `type` (little-endian). A ggml tensor with `ne = [a, b, c]` has `shape = [c, b, a]`.
public struct WeightTensor: Sendable {
  public var name: String
  public var shape: [Int]
  public var type: WeightType
  public var data: Data

  public init(name: String, shape: [Int], type: WeightType, data: Data) {
    self.name = name
    self.shape = shape
    self.type = type
    self.data = data
  }

  public var elementCount: Int { shape.reduce(1, *) }

  /// The weight as Float32 (dequantized), row-major in `shape`.
  public func floats() -> [Float] { WeightDecoding.floats(of: self) }
}

/// whisper.cpp's `whisper_hparams`, in the model file's order.
public struct WhisperHyperparameters: Sendable, Equatable {
  public var nVocab: Int
  public var nAudioContext: Int
  public var nAudioState: Int
  public var nAudioHead: Int
  public var nAudioLayer: Int
  public var nTextContext: Int
  public var nTextState: Int
  public var nTextHead: Int
  public var nTextLayer: Int
  public var nMels: Int
  /// The file's `ftype` (whisper.cpp: 0 f32, 1 f16, 2.. quantized; the model's default weight type).
  public var ftype: Int

  public init(
    nVocab: Int, nAudioContext: Int, nAudioState: Int, nAudioHead: Int, nAudioLayer: Int, nTextContext: Int,
    nTextState: Int, nTextHead: Int, nTextLayer: Int, nMels: Int, ftype: Int
  ) {
    self.nVocab = nVocab
    self.nAudioContext = nAudioContext
    self.nAudioState = nAudioState
    self.nAudioHead = nAudioHead
    self.nAudioLayer = nAudioLayer
    self.nTextContext = nTextContext
    self.nTextState = nTextState
    self.nTextHead = nTextHead
    self.nTextLayer = nTextLayer
    self.nMels = nMels
    self.ftype = ftype
  }

  /// Whisper's model families by `nAudioState`: 384 tiny, 512 base, 768 small, 1024 medium, 1280 large.
  public var isMultilingual: Bool { nVocab >= 51865 }
}

/// The mel filterbank stored in the model file: `nMel` rows of `nFFT` coefficients (nFFT = 201 for Whisper).
public struct MelFilters: Sendable {
  public var nMel: Int
  public var nFFT: Int
  public var data: [Float]

  public init(nMel: Int, nFFT: Int, data: [Float]) {
    self.nMel = nMel
    self.nFFT = nFFT
    self.data = data
  }
}

/// The token vocabulary and the special token ids whisper.cpp derives from `nVocab` (`whisper_vocab`).
public struct Vocabulary: Sendable {
  /// Token id -> the token's bytes (byte-level BPE: pieces are raw UTF-8 fragments, joined before decoding to text).
  public var tokens: [[UInt8]]
  public var isMultilingual: Bool
  public var eot: Int32
  public var sot: Int32
  public var sotLanguage: Int32
  public var translate: Int32
  public var transcribe: Int32
  public var solm: Int32
  public var prev: Int32
  public var nosp: Int32
  public var not: Int32
  /// First timestamp token (`<|0.00|>`); ids from here up are timestamps.
  public var beg: Int32

  public init(
    tokens: [[UInt8]], isMultilingual: Bool, eot: Int32, sot: Int32, sotLanguage: Int32, translate: Int32,
    transcribe: Int32, solm: Int32, prev: Int32, nosp: Int32, not: Int32, beg: Int32
  ) {
    self.tokens = tokens
    self.isMultilingual = isMultilingual
    self.eot = eot
    self.sot = sot
    self.sotLanguage = sotLanguage
    self.translate = translate
    self.transcribe = transcribe
    self.solm = solm
    self.prev = prev
    self.nosp = nosp
    self.not = not
    self.beg = beg
  }

  /// The language token for a whisper.cpp language code (`"en"`, `"de"`, ...), nil when unknown.
  public func languageToken(_ code: String) -> Int32? { WhisperLanguages.token(code, vocabulary: self) }
  /// The language code of a language token, nil for other tokens.
  public func languageCode(_ token: Int32) -> String? { WhisperLanguages.code(token, vocabulary: self) }
  /// The text of a token sequence (byte-level BPE pieces concatenated, then decoded as UTF-8; lossy on bad bytes).
  public func text(_ ids: [Int32]) -> String { WhisperText.decode(ids, vocabulary: self) }
}

/// A loaded ggml model file (whisper.cpp's `whisper_model_load`, the parsing part).
public struct WhisperModelFile: Sendable {
  public var hyperparameters: WhisperHyperparameters
  public var filters: MelFilters
  public var vocabulary: Vocabulary
  /// Tensors by their ggml name (`"encoder.conv1.weight"`, `"decoder.blocks.0.attn.query.weight"`, ...).
  public var tensors: [String: WeightTensor]

  public init(
    hyperparameters: WhisperHyperparameters, filters: MelFilters, vocabulary: Vocabulary,
    tensors: [String: WeightTensor]
  ) {
    self.hyperparameters = hyperparameters
    self.filters = filters
    self.vocabulary = vocabulary
    self.tensors = tensors
  }

  public func tensor(_ name: String) throws -> WeightTensor {
    guard let tensor = tensors[name] else { throw WhisperError.missingTensor(name) }
    return tensor
  }
}

// MARK: - Audio

/// A log-mel spectrogram as whisper.cpp computes it: `nMel` rows of `nLen` frames, row-major (`data[mel * nLen + frame]`).
/// 16 kHz input, 400-sample FFT, hop 160, so 100 frames per second; one encoder window is 3000 frames (30 s).
public struct MelSpectrogram: Sendable {
  public var nMel: Int
  public var nLen: Int
  public var data: [Float]

  public init(nMel: Int, nLen: Int, data: [Float]) {
    self.nMel = nMel
    self.nLen = nLen
    self.data = data
  }

  public static let sampleRate = 16_000
  public static let fftSize = 400
  public static let hopLength = 160
  /// Frames per encoder window (30 s).
  public static let framesPerWindow = 3000
}

// MARK: - Compute backends

/// A device tensor: Float32 activations or a weight in its storage type. Backends subclass or wrap this.
public protocol DeviceTensor: AnyObject {
  var shape: [Int] { get }
}

/// The op set the model graph needs, implemented once on the CPU (the reference, Accelerate) and once on Metal.
/// Activations are Float32 and row-major. Weights come in as `WeightTensor` and the backend keeps whatever storage
/// it likes (the CPU backend may dequantize; Metal keeps f16/q8_0 for its matmul kernels). Every op returns a new
/// tensor except the cache ops. Backends are single-threaded from the caller's point of view: one graph runs at a time.
public protocol WhisperBackend: AnyObject {
  associatedtype Tensor: DeviceTensor

  /// Uploads a model weight.
  func weight(_ tensor: WeightTensor) throws -> Tensor
  /// Uploads Float32 activations.
  func tensor(_ values: [Float], shape: [Int]) -> Tensor
  /// Reads a tensor back as Float32 (dequantizing a weight if asked).
  func read(_ tensor: Tensor) -> [Float]
  /// The first failure of the device since the last call (a faulted or timed-out GPU command buffer, an allocation
  /// that failed), cleared by the call; nil when every op ran. The graph throws it after the reads it depends on.
  func takeFailure() -> Error?

  /// 1-D convolution as whisper's encoder uses it: `x` [cin, len], `weight` [cout, cin, kernel], `bias` [cout];
  /// returns [cout, (len + 2 * padding - kernel) / stride + 1].
  func conv1d(_ x: Tensor, weight: Tensor, bias: Tensor, stride: Int, padding: Int) -> Tensor
  /// `x` [n, in] times `weight` [out, in] transposed, plus `bias` [out] when given: [n, out].
  func linear(_ x: Tensor, weight: Tensor, bias: Tensor?) -> Tensor
  /// Layer norm over the last dimension of `x` [n, d] with `weight`, `bias` [d] and `epsilon` (whisper.cpp: 1e-5).
  func layerNorm(_ x: Tensor, weight: Tensor, bias: Tensor, epsilon: Float) -> Tensor
  /// `a + b`, `b` broadcast over `a`'s leading dimensions when its shape is a suffix of `a`'s.
  func add(_ a: Tensor, _ b: Tensor) -> Tensor
  /// GELU as ggml computes it (the tanh approximation, `ggml_gelu`).
  func gelu(_ x: Tensor) -> Tensor
  /// Transposes a matrix [r, c] -> [c, r].
  func transpose(_ x: Tensor) -> Tensor
  /// Multi-head attention: `query` [nq, d], `key` and `value` [nk, d], `heads` heads of d / heads each, softmax of
  /// `scale * q k^T` (causal: query i attends keys 0...i + nk - nq), times v: [nq, d]. whisper.cpp scales q and k by
  /// pow(headDim, -0.25) each; callers pass `scale` for the product.
  func attention(query: Tensor, key: Tensor, value: Tensor, heads: Int, scale: Float, causal: Bool) -> Tensor
  /// Rows of `table` ([vocab, d], any weight type) at `ids`: [ids.count, d].
  func embedding(_ table: Tensor, ids: [Int32]) -> Tensor
  /// Rows `range` of `x` [n, d]: [range.count, d]. May be a view.
  func rows(_ x: Tensor, _ range: Range<Int>) -> Tensor

  /// A cache for `capacity` rows of `width` values (decoder self-attention keys and values), zeroed.
  func cache(capacity: Int, width: Int) -> Tensor
  /// Writes `values` [k, width] into `cache` at row `offset`.
  func write(_ values: Tensor, into cache: Tensor, at offset: Int)
}

// MARK: - Inference

/// Whisper's encoder and decoder over a backend. `encode` runs the audio encoder on one 30 s window and prepares the
/// cross-attention keys and values and an empty self-attention cache; `decode` appends tokens to the decoder and
/// returns their logits. Transcription (prompting, sampling, language detection, windowing) sits on top.
public protocol WhisperInference: AnyObject {
  var hyperparameters: WhisperHyperparameters { get }
  var vocabulary: Vocabulary { get }

  /// Encodes `mel` frames `offset ..< offset + 3000` (zero-padded past the end). `audioContext` limits the encoder
  /// to its first that many positions (whisper.cpp's `audio_ctx`; 0 = the model's `nAudioContext`, 1500).
  func encode(mel: MelSpectrogram, offset: Int, audioContext: Int) throws
  /// Decodes `tokens` at positions `past ..< past + tokens.count` (the self-attention cache holds `past` tokens),
  /// returning their logits, row-major [tokens.count, nVocab].
  func decode(tokens: [Int32], past: Int) throws -> [Float]
}

// MARK: - Errors

public enum WhisperError: Error, Equatable {
  case badMagic(UInt32)
  case truncated(String)
  case unsupportedWeightType(Int32, tensor: String)
  case missingTensor(String)
  case shapeMismatch(String)
  case metalUnavailable
  case kernelCompileFailed(String)
  case decodeFailed(String)
}

// MARK: - Seams the modules fill in

/// Weight decoding (f32/f16/q8_0 to Float32). Implemented in Weights.swift.
public enum WeightDecoding {}
/// Language codes <-> tokens (whisper.cpp's `g_lang` table). Implemented in Languages.swift.
public enum WhisperLanguages {}
/// Token ids to text. Implemented in Vocabulary.swift.
public enum WhisperText {}
