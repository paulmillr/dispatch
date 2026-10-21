import Foundation

/// What turns chat dictation into text. Both run on the device: Apple's speech recognizer (SpeechAnalyzer on macOS
/// and iOS 26, SFSpeechRecognizer's on-device mode on older Macs), or a downloaded Whisper model (WhisperEngine,
/// Packages/WhisperEngine: whisper.cpp in Swift).
public enum DictationEngine: String, Codable, CaseIterable, Sendable {
    case apple, whisper

    public var title: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        }
    }
}

/// The Whisper models Settings offers, as ggml files from whisper.cpp's model repository. All three are its 8-bit
/// quantizations: half the download of the full-precision files, with the same transcripts in practice.
public enum WhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, turbo

    public var id: Self { self }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .turbo: "Large v3 Turbo"
        }
    }

    public var detail: String {
        switch self {
        case .small: "Fastest, good for clear speech"
        case .medium: "More accurate, slower"
        case .turbo: "Most accurate, near Medium’s speed"
        }
    }

    var fileName: String {
        switch self {
        case .small: "ggml-small-q8_0.bin"
        case .medium: "ggml-medium-q8_0.bin"
        case .turbo: "ggml-large-v3-turbo-q8_0.bin"
        }
    }

    /// The file's size and SHA-256, from the repository's LFS records: a download must match both.
    var bytes: Int64 {
        switch self {
        case .small: 264_464_607
        case .medium: 823_369_779
        case .turbo: 874_188_075
        }
    }

    var sha256: String {
        switch self {
        case .small: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"
        case .medium: "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502"
        case .turbo: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
        }
    }

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + fileName)! }

    /// "264 MB".
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
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
