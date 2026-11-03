import Foundation

/// Persisted chat font identities, with explicit native substitutions and lowercase-height calibration.
enum ChatFontChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "San Francisco"
    case sameAsCode = "Same as code"
    case comicSans = "Comic Sans"
    case latinModernRoman = "Latin Modern Roman"
    case newYork = "New York"

    enum Platform { case macOS, iOS }
    var id: Self { self }

    func scale(on platform: Platform) -> Double {
        switch self {
        case .latinModernRoman: 1.126
        case .comicSans: platform == .macOS ? 0.907 : 1
        case .sameAsCode, .system, .newYork: 1
        }
    }

    func namedFace(on platform: Platform) -> String? {
        switch self {
        case .comicSans: platform == .macOS ? "ComicSansMS" : "Chalkboard SE"
        case .latinModernRoman: "LMRoman10-Regular"
        case .sameAsCode, .system, .newYork: nil
        }
    }
}
