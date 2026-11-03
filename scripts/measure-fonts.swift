// Run from the repository root:
// swift scripts/measure-fonts.swift [font size, default 14]
// Every role's text at a Settings font size, measured as the app calibrates (`TerminalFontScale`): the median outline
// height of "acemnorsuvwxz", against Source Code Pro. The app measures at run time and `PlanOneTests` holds it to
// Source Code Pro's height; this prints the result, with each face's line height and width, to compare by eye.
import AppKit
import CoreText

for url in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "Dispatch/Resources/Fonts"), includingPropertiesForKeys: nil)
where ["ttf", "otf"].contains(url.pathExtension) {
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}
let size = CGFloat(Double(CommandLine.arguments.dropFirst().first ?? "14") ?? 14)
let scp = "SourceCodePro-Regular"

func named(_ name: String, _ size: CGFloat) -> NSFont {
    guard let font = NSFont(name: name, size: size) else { fatalError("Missing font: \(name)") }
    return font
}
func system(_ design: NSFontDescriptor.SystemDesign, _ size: CGFloat, monospacedDigits: Bool = false) -> NSFont {
    let font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    return font.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? font
}
func lowercase(_ font: NSFont) -> CGFloat {
    let characters = Array("acemnorsuvwxz".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    var bounds = [CGRect](repeating: .zero, count: glyphs.count)
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, glyphs.count)
    let heights = bounds.map(\.height).sorted()
    return heights[heights.count / 2]
}
/// The app's scale for a face: Source Code Pro's lowercase height over the face's, both at 16 points.
func scale(_ face: (CGFloat) -> NSFont) -> CGFloat {
    ((lowercase(named(scp, 16)) / lowercase(face(16))) * 1000).rounded() / 1000
}

let rounded = { (size: CGFloat) in system(.rounded, size, monospacedDigits: true) }
let interface = scale(rounded)
let chatFaces: [(String, (CGFloat) -> NSFont)] = [
    ("San Francisco", { system(.rounded, $0) }), ("New York", { system(.serif, $0) }),
    ("Comic Sans", { named("ComicSansMS", $0) }), ("Latin Modern Roman", { named("LMRoman10-Regular", $0) }),
]
let roles: [(String, CGFloat)] = [("title", 0.5), ("label", -0.5), ("body", -1.5), ("caption", -2.5)]
var rows: [(String, NSFont)] = [("Terminal", named(scp, size))]
for (name, settings) in [("UI", size), ("Settings", 13.5)] {
    for (role, offset) in roles {
        rows.append(("\(name) \(role), Source Code Pro", named(scp, settings + offset)))
        rows.append(("\(name) \(role), San Francisco", rounded((settings + offset) * interface)))
    }
}
rows.append(("Chat code", named(scp, size)))
for (name, face) in chatFaces { rows.append(("Chat prose, \(name)", face((size + 1) * scale(face)))) }
rows.append(("Chat prose, Same as code", named(scp, size + 1)))

let layout = NSLayoutManager()
let sample = "the quick brown fox jumps over the lazy dog"
print(String(format: "Size %.1f · interface San Francisco ×%.3f · chat ", size, interface)
      + chatFaces.map { "\($0.0) ×" + String(format: "%.3f", scale($0.1)) }.joined(separator: ", "))
print("role".padding(toLength: 38, withPad: " ", startingAt: 0) + "    pt  lowercase   line   sample width")
for (name, font) in rows {
    let width = (sample as NSString).size(withAttributes: [.font: font]).width
    print(name.padding(toLength: 38, withPad: " ", startingAt: 0)
          + String(format: "%6.2f  %9.2f  %5.1f  %13.1f", font.pointSize, lowercase(font), layout.defaultLineHeight(for: font), width))
}
