import Foundation

// The ggml model file reader: the parsing half of whisper.cpp 1.9.5's `whisper_model_load`. The format is a plain
// little-endian stream with no index, no alignment and no trailer: a magic, eleven int32 hyperparameters, the mel
// filterbank, the vocabulary, then tensors until the end of the file. whisper.cpp reads it sequentially with
// `read_safe`; this file does the same over a memory-mapped `Data`, so a 1 GB model costs one mapping and the
// tensors are views into it rather than copies.
//
// Trust. The app checks a download's size and SHA-256 once, but the file sits in Application Support afterwards and
// may be altered, truncated or swapped; whisper.cpp itself only checks shapes against the graph it is about to
// build. Everything here therefore treats the file as hostile input: every count is bounded before it sizes an
// allocation or a multiplication (`multipliedReportingOverflow`), the hyperparameters are checked against what the
// graph and the transcription loop assume (`WhisperHyperparameters.validate`), and the whole file is checked again
// once parsed (`WhisperModelFile.validate`). A bad file throws a `WhisperError` from `load`; it never traps and
// never allocates in proportion to a number it has not bounded. Invalid structure reports `.shapeMismatch` with a
// message naming the field (the error set is shared with the other modules and kept as it is); a count that exceeds
// the bytes left in the file reports `.truncated`.

extension WhisperModelFile {
  /// `GGML_FILE_MAGIC`, the ASCII "ggml" as a little-endian word.
  public static let magic: UInt32 = 0x6767_6d6c

  /// Reads a whisper ggml model file. The file is memory-mapped when the system allows (`.mappedIfSafe`), and every
  /// `WeightTensor.data` is a slice of that mapping. Slices keep their position in the file as `startIndex`, so
  /// consumers must index relative to `startIndex` or use `withUnsafeBytes` (which `WeightDecoding` does).
  public static func load(_ url: URL) throws -> WhisperModelFile {
    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw WhisperError.truncated("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
    }
    return try parse(data)
  }

  /// Parses a whole model file held in memory (what `load` does once the file is mapped; tests build files in memory).
  /// The result has passed `validate()`.
  public static func parse(_ data: Data) throws -> WhisperModelFile {
    var reader = ByteReader(data)

    // verify magic
    let magic = try reader.uint32("magic")
    guard magic == Self.magic else { throw WhisperError.badMagic(magic) }

    // load hparams: eleven int32 in whisper_hparams order. whisper.cpp splits the file's ftype into the quantization
    // version (`ftype / 1000`, informational) and the type proper (`ftype % 1000`), and keeps only the latter in
    // hparams; `hyperparameters.ftype` is that reduced value.
    var fields = [Int32]()
    for name in hyperparameterNames { fields.append(try reader.int32("hparams.\(name)")) }
    let rawFType = fields[10]
    let ftype = rawFType % 1000
    // ggml_ftype_to_ggml_type: the model's default weight type. Only the three types the engine decodes are accepted
    // (f32, f16, q8_0); any other quantization is a valid ggml file the engine cannot run.
    guard WeightType.from(ftype: ftype) != nil else {
      throw WhisperError.unsupportedWeightType(ftype, tensor: "hparams.ftype")
    }
    let hyperparameters = WhisperHyperparameters(
      nVocab: Int(fields[0]), nAudioContext: Int(fields[1]), nAudioState: Int(fields[2]), nAudioHead: Int(fields[3]),
      nAudioLayer: Int(fields[4]), nTextContext: Int(fields[5]), nTextState: Int(fields[6]), nTextHead: Int(fields[7]),
      nTextLayer: Int(fields[8]), nMels: Int(fields[9]), ftype: Int(ftype))
    // Before anything is sized by them: the vocabulary padding runs to nVocab, the graph divides by the head counts.
    try hyperparameters.validate()

    // load mel filters: n_mel, n_fft, then n_mel * n_fft float32. The counts must be the model's (whisper.cpp only
    // checks them against the graph later; the mel code asserts nFFT == 201 and would trap at transcription time).
    let nMel = Int(try reader.int32("filters.n_mel"))
    let nFFT = Int(try reader.int32("filters.n_fft"))
    guard nMel == hyperparameters.nMels else {
      throw WhisperError.shapeMismatch("mel filters have \(nMel) bands, hparams.n_mels is \(hyperparameters.nMels)")
    }
    guard nFFT == MelFilters.whisperFFTBins else {
      throw WhisperError.shapeMismatch("mel filters have \(nFFT) coefficients per band, whisper needs \(MelFilters.whisperFFTBins)")
    }
    // nMel <= 256 and nFFT == 201 here, so the product is small; `floats` still bounds it by the bytes left.
    let filterData = try reader.floats(nMel * nFFT, "filters.data")
    let filters = MelFilters(nMel: nMel, nFFT: nFFT, data: filterData)

    // load vocab: a count, then each token as a uint32 length and its bytes. The count in the file is usually smaller
    // than hparams.n_vocab (50257 words for a 51865-token multilingual model); whisper.cpp invents names for the rest.
    // A count above hparams.n_vocab would leave more tokens than logits; whisper.cpp keeps the extra entries in its
    // map, this port rejects them (`validate` requires tokens.count == nVocab).
    let fileVocabCount = Int(try reader.int32("vocab.n_vocab"))
    guard fileVocabCount >= 0, fileVocabCount <= hyperparameters.nVocab else {
      throw WhisperError.shapeMismatch("vocab count \(fileVocabCount) for n_vocab \(hyperparameters.nVocab)")
    }
    // Every token costs at least its 4-byte length, so a count the file cannot hold is rejected before reserving.
    guard fileVocabCount <= reader.remaining / 4 else { throw WhisperError.truncated("vocab") }
    var tokens = [[UInt8]]()
    tokens.reserveCapacity(hyperparameters.nVocab)
    for index in 0..<fileVocabCount {
      let length = Int(try reader.uint32("vocab[\(index)].length"))
      // Empty tokens exist (multilingual files store "" at 50256); whisper.cpp reads nothing for them. `bytes`
      // rejects a length past the end of the file before anything is copied.
      tokens.append(length == 0 ? [] : [UInt8](try reader.bytes(length, "vocab[\(index)]")))
    }
    let vocabulary = Vocabulary.whisper(fileTokens: tokens, nVocab: hyperparameters.nVocab)

    // load weights: repeated (n_dims, name length, ttype, ne[n_dims], name, data) records with no padding between
    // them (whisper.cpp reads `ggml_nbytes` straight after the name; llama's old format aligned here, whisper's never
    // did). whisper.cpp reads the three-int header first and stops at EOF, so under 12 trailing bytes end the file
    // quietly; anything longer must be a complete record.
    var tensors = [String: WeightTensor]()
    while reader.remaining >= 12 {
      let nDims = Int(try reader.int32("tensor.n_dims"))
      let nameLength = Int(try reader.int32("tensor.name length"))
      let ttype = try reader.int32("tensor.ttype")
      // whisper writes 1- to 3-D tensors (ggml allows up to 4); a 0-D record is representable but never written,
      // and rejecting it keeps every shape non-empty for the graph's checks.
      guard (1...4).contains(nDims) else { throw WhisperError.shapeMismatch("tensor n_dims \(nDims)") }
      guard nameLength >= 0 else { throw WhisperError.shapeMismatch("tensor name length \(nameLength)") }
      var ne = [Int]()
      for axis in 0..<nDims {
        let extent = Int(try reader.int32("tensor.ne[\(axis)]"))
        guard extent >= 1 else { throw WhisperError.shapeMismatch("tensor ne[\(axis)] \(extent)") }
        ne.append(extent)
      }
      let name = String(decoding: try reader.bytes(nameLength, "tensor name"), as: UTF8.self)
      guard let type = WeightType(rawValue: ttype) else {
        throw WhisperError.unsupportedWeightType(ttype, tensor: name)
      }
      // Four int32 extents multiply past Int64; and every type stores at least one byte per element, so a count
      // beyond the bytes left cannot be a real tensor however it is typed.
      guard let elements = Self.elementCount(ne) else {
        throw WhisperError.shapeMismatch("\(name): element count overflows (ne \(ne))")
      }
      if type == .q8_0, elements % 32 != 0 {
        throw WhisperError.shapeMismatch("\(name): q8_0 needs a multiple of 32 elements, has \(elements) (ne \(ne))")
      }
      guard elements <= reader.remaining else { throw WhisperError.truncated("\(name) data") }
      guard let byteCount = Self.byteCount(type, elements: elements) else {
        throw WhisperError.shapeMismatch("\(name): byte count overflows (ne \(ne))")
      }
      let bytes = try reader.bytes(byteCount, "\(name) data")
      tensors[name] = WeightTensor(name: name, shape: ne.reversed(), type: type, data: bytes)
    }

    let file = WhisperModelFile(
      hyperparameters: hyperparameters, filters: filters, vocabulary: vocabulary, tensors: tensors)
    try file.validate()
    return file
  }

  /// Checks the whole file for the invariants the engine relies on without further checks: the hyperparameters
  /// (`WhisperHyperparameters.validate`), a filterbank of `nMels` x 201 coefficients, a vocabulary of exactly
  /// `nVocab` tokens whose special ids all lie inside it, and every tensor's shape, element count and byte count
  /// agreeing with each other. `parse` calls this; a file assembled or altered in memory can be checked with it too.
  public func validate() throws {
    try hyperparameters.validate()

    guard filters.nMel == hyperparameters.nMels, filters.nFFT == MelFilters.whisperFFTBins,
      filters.data.count == filters.nMel * filters.nFFT
    else {
      throw WhisperError.shapeMismatch(
        "mel filters \(filters.nMel) x \(filters.nFFT) with \(filters.data.count) values for \(hyperparameters.nMels) mels")
    }

    guard vocabulary.tokens.count == hyperparameters.nVocab else {
      throw WhisperError.shapeMismatch("vocabulary has \(vocabulary.tokens.count) tokens, n_vocab is \(hyperparameters.nVocab)")
    }
    let expected = Vocabulary.SpecialTokens(nVocab: hyperparameters.nVocab)
    let actual = [
      vocabulary.eot, vocabulary.sot, vocabulary.sotLanguage, vocabulary.translate, vocabulary.transcribe,
      vocabulary.solm, vocabulary.prev, vocabulary.nosp, vocabulary.not, vocabulary.beg,
    ].map(Int.init)
    let derived = [
      expected.eot, expected.sot, expected.sot + 1, expected.translate, expected.transcribe, expected.solm,
      expected.prev, expected.nosp, expected.not, expected.beg,
    ]
    guard actual == derived, vocabulary.isMultilingual == expected.isMultilingual else {
      throw WhisperError.shapeMismatch("vocabulary special tokens do not match n_vocab \(hyperparameters.nVocab)")
    }
    guard vocabulary.largestSpecialToken < hyperparameters.nVocab else {
      throw WhisperError.shapeMismatch(
        "n_vocab \(hyperparameters.nVocab) is below the special token ids (up to \(vocabulary.largestSpecialToken))")
    }

    for (name, tensor) in tensors {
      guard (1...4).contains(tensor.shape.count), tensor.shape.allSatisfy({ $0 >= 1 }) else {
        throw WhisperError.shapeMismatch("\(name): shape \(tensor.shape)")
      }
      guard let elements = Self.elementCount(tensor.shape) else {
        throw WhisperError.shapeMismatch("\(name): element count overflows (shape \(tensor.shape))")
      }
      if tensor.type == .q8_0, elements % 32 != 0 {
        throw WhisperError.shapeMismatch("\(name): q8_0 needs a multiple of 32 elements, has \(elements)")
      }
      guard let byteCount = Self.byteCount(tensor.type, elements: elements), tensor.data.count == byteCount else {
        throw WhisperError.shapeMismatch("\(name): \(tensor.data.count) bytes for shape \(tensor.shape) \(tensor.type)")
      }
    }
  }

  /// The product of `extents`, nil when it overflows `Int`.
  static func elementCount(_ extents: [Int]) -> Int? {
    var product = 1
    for extent in extents {
      let (next, overflow) = product.multipliedReportingOverflow(by: extent)
      if overflow { return nil }
      product = next
    }
    return product
  }

  /// `WeightType.byteCount` without the trap: nil when the byte count overflows `Int`.
  static func byteCount(_ type: WeightType, elements: Int) -> Int? {
    let (bytes, overflow): (Int, Bool)
    switch type {
    case .f32: (bytes, overflow) = elements.multipliedReportingOverflow(by: 4)
    case .f16: (bytes, overflow) = elements.multipliedReportingOverflow(by: 2)
    case .q8_0: (bytes, overflow) = (elements / 32).multipliedReportingOverflow(by: 34)
    }
    return overflow ? nil : bytes
  }

  /// `whisper_hparams` field names in file order, for error messages.
  private static let hyperparameterNames = [
    "n_vocab", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer", "n_text_ctx", "n_text_state",
    "n_text_head", "n_text_layer", "n_mels", "ftype",
  ]
}

extension MelFilters {
  /// Coefficients per mel band in a whisper model: `fftSize / 2 + 1` bins of the 400-point FFT.
  public static let whisperFFTBins = MelSpectrogram.fftSize / 2 + 1
}

extension WhisperHyperparameters {
  /// The bounds `validate` enforces. Whisper's released models span tiny (384 / 6 heads / 4 layers) to large
  /// (1280 / 20 / 32) with 80 or 128 mels, 1500 audio positions, 448 text positions and 51864 to 51866 tokens; the
  /// limits leave several times that headroom and keep every allocation the engine sizes from them small.
  public enum Limits {
    public static let mels = 1...256
    public static let audioContext = 1...1500
    public static let textContext = 16...8192
    public static let state = 1...8192
    public static let layers = 1...256
    public static let vocabulary = 1 << 17
  }

  /// Rejects hyperparameters the engine cannot run: every count positive, the state a multiple of the head count
  /// (the graph takes `state / heads` as the head width), the audio context at most whisper's 1500, a text context
  /// that leaves the loop at least one token (`n_text_ctx / 2 - 4`), and a vocabulary that holds every special
  /// token id `Vocabulary.whisper` derives from `nVocab` (50364 for an English-only layout) within `Limits`.
  public func validate() throws {
    func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
      if !condition { throw WhisperError.shapeMismatch("hparams: " + message()) }
    }
    try check(Limits.mels.contains(nMels), "n_mels \(nMels) outside \(Limits.mels)")
    try check(Limits.audioContext.contains(nAudioContext), "n_audio_ctx \(nAudioContext) outside \(Limits.audioContext)")
    try check(Limits.state.contains(nAudioState), "n_audio_state \(nAudioState) outside \(Limits.state)")
    try check((1...nAudioState).contains(nAudioHead), "n_audio_head \(nAudioHead) for n_audio_state \(nAudioState)")
    try check(nAudioState % nAudioHead == 0, "n_audio_state \(nAudioState) is not a multiple of n_audio_head \(nAudioHead)")
    try check(Limits.layers.contains(nAudioLayer), "n_audio_layer \(nAudioLayer) outside \(Limits.layers)")
    try check(Limits.textContext.contains(nTextContext), "n_text_ctx \(nTextContext) outside \(Limits.textContext)")
    try check(Limits.state.contains(nTextState), "n_text_state \(nTextState) outside \(Limits.state)")
    try check((1...nTextState).contains(nTextHead), "n_text_head \(nTextHead) for n_text_state \(nTextState)")
    try check(nTextState % nTextHead == 0, "n_text_state \(nTextState) is not a multiple of n_text_head \(nTextHead)")
    try check(Limits.layers.contains(nTextLayer), "n_text_layer \(nTextLayer) outside \(Limits.layers)")
    try check(WeightType.from(ftype: Int32(clamping: ftype)) != nil, "ftype \(ftype) is not f32, f16 or q8_0")
    try check(nVocab >= 1 && nVocab <= Limits.vocabulary, "n_vocab \(nVocab) outside 1...\(Limits.vocabulary)")
    let special = Vocabulary.SpecialTokens(nVocab: nVocab)
    try check(
      Int(special.largest) < nVocab,
      "n_vocab \(nVocab) is below the special token ids (up to \(special.largest)); the smallest layout needs \(special.largest + 1)")
  }
}

extension WeightType {
  /// `ggml_ftype_to_ggml_type` restricted to the types the engine decodes: ftype 0 all-f32, 1 mostly-f16, 7 mostly-q8_0.
  /// The ftype numbering is not the ggml_type numbering (q8_0 is ftype 7 but type 8).
  public static func from(ftype: Int32) -> WeightType? {
    switch ftype {
    case 0: .f32
    case 1: .f16
    case 7: .q8_0
    default: nil
    }
  }
}

/// A cursor over a little-endian byte buffer. Reads are bounds-checked and throw `WhisperError.truncated` naming the
/// field, since a short download is the common failure. Loads are unaligned on purpose: tensor data starts wherever
/// the previous record ended.
struct ByteReader {
  let data: Data
  /// Absolute index into `data` (a `Data` slice does not start at 0).
  private(set) var offset: Int

  init(_ data: Data) {
    self.data = data
    offset = data.startIndex
  }

  var remaining: Int { data.endIndex - offset }

  mutating func int32(_ field: String) throws -> Int32 {
    Int32(bitPattern: try uint32(field))
  }

  mutating func uint32(_ field: String) throws -> UInt32 {
    guard remaining >= 4 else { throw WhisperError.truncated(field) }
    let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset - data.startIndex, as: UInt32.self) }
    offset += 4
    return UInt32(littleEndian: value)
  }

  /// The next `count` bytes as a slice sharing `data`'s storage.
  mutating func bytes(_ count: Int, _ field: String) throws -> Data {
    guard count >= 0, remaining >= count else { throw WhisperError.truncated(field) }
    let slice = data[offset..<offset + count]
    offset += count
    return slice
  }

  /// The next `count` little-endian float32 values, copied (the mel filters are small). `count` must be at most
  /// `remaining / 4`, which `bytes` enforces, so the byte count cannot overflow.
  mutating func floats(_ count: Int, _ field: String) throws -> [Float] {
    guard count >= 0, count <= remaining / 4 else { throw WhisperError.truncated(field) }
    let slice = try bytes(count * 4, field)
    return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
      slice.copyBytes(to: buffer, count: count * 4)
      initialized = count
    }
  }
}
