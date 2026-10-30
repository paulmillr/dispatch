import Foundation

/// What turns chat dictation into text. All run on the device: Apple's speech recognizer (SpeechAnalyzer on macOS
/// and iOS 26, SFSpeechRecognizer's on-device mode on older Macs), a downloaded Whisper model (WhisperEngine,
/// Packages/WhisperEngine: whisper.cpp in Swift), or downloaded Parakeet models (Core ML, `ParakeetTranscriber`).
public enum DictationEngine: String, Codable, CaseIterable, Sendable {
    case apple, whisper, parakeet

    public var title: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .parakeet: "Parakeet"
        }
    }

    /// The engine with its model, when it has a choice of them: "Whisper Small".
    public func label(whisper model: WhisperModel) -> String {
        self == .whisper ? "Whisper \(model.title)" : title
    }

    /// The model this engine downloads, when it needs one.
    public func model(whisper model: WhisperModel) -> DictationModel? {
        switch self {
        case .apple: nil
        case .whisper: .whisper(model)
        case .parakeet: .parakeet
        }
    }
}

/// A model Settings downloads for dictation: one of the Whisper files, or Parakeet's Core ML models (a folder).
public enum DictationModel: Hashable, Identifiable, Sendable {
    case whisper(WhisperModel)
    case parakeet

    public static let all: [DictationModel] = WhisperModel.allCases.map(Self.whisper) + [.parakeet]

    public var id: String {
        switch self {
        case .whisper(let model): model.rawValue
        case .parakeet: "parakeet"
        }
    }

    public var title: String {
        switch self {
        case .whisper(let model): model.title
        case .parakeet: "Parakeet TDT v3"
        }
    }

    /// The engine and model, for messages: "Whisper Small".
    public var name: String {
        switch self {
        case .whisper(let model): "Whisper \(model.title)"
        case .parakeet: "Parakeet"
        }
    }

    public var detail: String {
        switch self {
        case .whisper(let model): model.detail
        case .parakeet: "Fast and accurate, English and 24 more European languages"
        }
    }

    /// "632 MB".
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// What to download, each checked against its size and SHA-256. A Whisper model is one file (`path` empty: the
    /// model's own location); Parakeet's are the files of its folder.
    var files: [ModelFile] {
        switch self {
        case .whisper(let model): [ModelFile(path: "", bytes: model.bytes, sha256: model.sha256, url: model.url)]
        case .parakeet: ParakeetModel.files
        }
    }
}

/// One file of a model download.
struct ModelFile: Sendable {
    /// Where it goes in the model's folder; empty for a model that is a single file.
    let path: String
    let bytes: Int64
    let sha256: String
    let url: URL
}

/// Parakeet TDT 0.6B v3 (NVIDIA, CC BY 4.0) in FluidInference's Core ML conversion
/// (huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml): the mel preprocessor, the FastConformer encoder,
/// the LSTM prediction network and the TDT joint, plus the SentencePiece vocabulary. The set FluidAudio loads for v3,
/// with the int8 `Encoder_v2` (its fix for words that change with the audio after them in the 15 s window), pinned to
/// one revision of the repository.
enum ParakeetModel {
    static let folder = "parakeet-tdt-0.6b-v3"
    static let revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"

    static let files: [ModelFile] = [
        file("Decoder.mlmodelc/analytics/coremldata.bin", 243, "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        file("Decoder.mlmodelc/coremldata.bin", 554, "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        file("Decoder.mlmodelc/metadata.json", 3_427, "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        file("Decoder.mlmodelc/model.mil", 13_110, "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        file("Decoder.mlmodelc/weights/weight.bin", 23_604_992, "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        file("Encoder_v2.mlmodelc/analytics/coremldata.bin", 243, "af98d71151609799efbbffc00112fcba4bd91adf0b01135a982c574e91822f9c"),
        file("Encoder_v2.mlmodelc/coremldata.bin", 478, "70628bd4fd25fb554cc0cebc31356723930c885480132bf3ecd1b5dbe71dd0a2"),
        file("Encoder_v2.mlmodelc/model.mil", 1_002_653, "abc621390840dd064e6833dc098101706621e47e17119ead904f8c383211dd1d"),
        file("Encoder_v2.mlmodelc/weights/weight.bin", 594_211_328, "8d2c79e15a4545e08fe3a21fe741e42b8bf24329db81de8fdfacd92388ea5a66"),
        file("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243, "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        file("JointDecisionv3.mlmodelc/coremldata.bin", 521, "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        file("JointDecisionv3.mlmodelc/metadata.json", 3_453, "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        file("JointDecisionv3.mlmodelc/model.mil", 11_775, "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        file("JointDecisionv3.mlmodelc/weights/weight.bin", 12_642_764, "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        file("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        file("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        file("Preprocessor.mlmodelc/metadata.json", 2_841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        file("Preprocessor.mlmodelc/model.mil", 28_181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        file("Preprocessor.mlmodelc/weights/weight.bin", 491_072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        file("parakeet_vocab.json", 151_122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    private static func file(_ path: String, _ bytes: Int64, _ sha256: String) -> ModelFile {
        let base = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(revision)/"
        return ModelFile(path: path, bytes: bytes, sha256: sha256, url: URL(string: base + path)!)
    }
}

/// The Whisper models Settings offers, as ggml files from whisper.cpp's model repository. Both are its 8-bit
/// quantizations: half the download of the full-precision files, with the same transcripts in practice.
public enum WhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, turbo

    public var id: Self { self }

    public var title: String {
        switch self {
        case .small: "Small"
        case .turbo: "Large v3 Turbo"
        }
    }

    public var detail: String {
        switch self {
        case .small: "Fastest, good for clear speech"
        case .turbo: "Most accurate"
        }
    }

    var fileName: String {
        switch self {
        case .small: "ggml-small-q8_0.bin"
        case .turbo: "ggml-large-v3-turbo-q8_0.bin"
        }
    }

    /// The file's size and SHA-256, from the repository's LFS records: a download must match both.
    var bytes: Int64 {
        switch self {
        case .small: 264_464_607
        case .turbo: 874_188_075
        }
    }

    var sha256: String {
        switch self {
        case .small: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"
        case .turbo: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
        }
    }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + fileName)! }
}

/// Where dictated text goes in a draft.
public enum DictationText {
    /// `dictated` in place of `selection` in `text`, with a space between it and a word before it, and the caret
    /// (an empty selection) after it.
    public static func insert(_ dictated: String, into text: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let words = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = text as NSString
        let location = min(max(0, selection.location), source.length)
        let range = NSRange(location: location, length: min(max(0, selection.length), source.length - location))
        guard !words.isEmpty else { return (text, range) }
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        let leadsWithPunctuation = words.unicodeScalars.first.map { CharacterSet.punctuationCharacters.contains($0) } ?? false
        let lead = before.last.map { !$0.isWhitespace && !leadsWithPunctuation } ?? false ? " " : ""
        let trail = after.first.map { !$0.isWhitespace && !CharacterSet.punctuationCharacters.contains($0.unicodeScalars.first!) } ?? false ? " " : ""
        let inserted = lead + words + trail
        let caret = range.location + (lead + words as NSString).length
        return (before + inserted + after, NSRange(location: caret, length: 0))
    }
}
