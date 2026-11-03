import Foundation

/// Persisted chat font identities, with explicit native substitutions. The Mac measures each face against Source Code
/// Pro (`ChatFont.sizeScale`); the iPhone sizes from Dynamic Type and only lifts Latin Modern's small lowercase.
enum ChatFontChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "San Francisco"
    case sameAsCode = "Same as code"
    case comicSans = "Comic Sans"
    case latinModernRoman = "Latin Modern Roman"
    case newYork = "New York"

    enum Platform { case macOS, iOS }
    var id: Self { self }

    /// The iPhone's scale on its Dynamic Type size, against the system font.
    var iOSScale: Double { self == .latinModernRoman ? 1.126 : 1 }

    func namedFace(on platform: Platform) -> String? {
        switch self {
        case .comicSans: platform == .macOS ? "ComicSansMS" : "Chalkboard SE"
        case .latinModernRoman: "LMRoman10-Regular"
        case .sameAsCode, .system, .newYork: nil
        }
    }
}
