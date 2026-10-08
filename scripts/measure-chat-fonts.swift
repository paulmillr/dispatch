// Run from the repository root:
// swift scripts/measure-chat-fonts.swift [output-directory]
// Rasterize actual fonts to verify lowercase height, and export a comparison.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/chat-font-measurements")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Dispatch/Resources/Fonts"), includingPropertiesForKeys: nil)
where ["ttf", "otf"].contains(url.pathExtension) {
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}
let families = [
    ("Source Code Pro", "SourceCodePro-Regular"),
    ("Comic Sans", "ComicSansMS")
]
func font(_ name: String, _ size: CGFloat) -> NSFont {
    guard let font = NSFont(name: name, size: size) else { fatalError("Missing font: \(name)") }
    return font
}
func bitmap(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
}
func draw(_ text: String, font: NSFont, x: CGFloat, y: CGFloat, in context: CGContext,
          color: NSColor = .white) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}
// Count rows with at least 50% opaque ink. Use a large raster as well as actual
// 2x display pixels so small-size antialiasing does not determine the mapping.
func inkHeight(_ font: NSFont, displayScale: CGFloat, text: String = "x") -> Int {
    let side = Int(ceil(font.pointSize * displayScale * 3))
    let context = bitmap(side, side)
    context.scaleBy(x: displayScale, y: displayScale)
    draw(text, font: font, x: font.pointSize / 2, y: font.pointSize, in: context)
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var rows: [Int] = []
    for y in 0..<side {
        if (0..<side).contains(where: { pixels[y * context.bytesPerRow + $0 * 4 + 3] >= 128 }) { rows.append(y) }
    }
    return rows.isEmpty ? 0 : rows.last! - rows.first! + 1
}
// A median avoids one unusually drawn letter (notably Comic Sans's x)
// determining the result. Keep the point size fixed while oversampling:
// variable fonts can change their optical design at different point sizes.
func lowercaseHeight(_ font: NSFont, displayScale: CGFloat = 32) -> CGFloat {
    let heights = "acemnorsuvwxz".map { inkHeight(font, displayScale: displayScale, text: String($0)) }.sorted()
    return CGFloat(heights[heights.count / 2]) / displayScale
}
let reference = font(families[0].1, 14)
let targetHeight = lowercaseHeight(reference)
var measurements: [[String: Any]] = []
let context = bitmap(2200, 1240)
context.scaleBy(x: 2, y: 2)
context.setFillColor(NSColor(srgbRed: 0.055, green: 0.055, blue: 0.07, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: 1100, height: 620))
let label = NSFont.systemFont(ofSize: 12)
draw("Chat font comparison · selected size 14 pt", font: .systemFont(ofSize: 22, weight: .semibold), x: 26, y: 575, in: context)
draw("Original sizes", font: label, x: 250, y: 537, in: context)
draw("Matched lowercase height", font: label, x: 665, y: 537, in: context)
for (index, family) in families.enumerated() {
    let original = font(family.1, 14)
    let originalHeight = lowercaseHeight(original)
    var scale = targetHeight / originalHeight
    // Recheck at the adjusted point size to account for optical sizing.
    for _ in 0..<2 { scale *= targetHeight / lowercaseHeight(font(family.1, 14 * scale)) }
    scale = (scale * 1000).rounded() / 1000
    let adjusted = font(family.1, 14 * scale)
    let record: [String: Any] = [
        "family": family.0, "postScriptName": family.1, "scale": scale,
        "originalPointSize": 14, "adjustedPointSize": adjusted.pointSize,
        "sizeChecks": [8.0, 12.5, 14.0, 22.0, 32.0].map { size -> [String: Any] in
            let target = lowercaseHeight(font(families[0].1, size))
            let actual = lowercaseHeight(font(family.1, size * scale))
            return ["selectedPointSize": size, "referenceInkHeight": target, "adjustedInkHeight": actual,
                    "relativeError": actual / target - 1]
        },
        "reportedXHeightPoints": original.xHeight,
        "originalLowercaseHeightPoints": originalHeight, "adjustedLowercaseHeightPoints": lowercaseHeight(adjusted),
        "originalLowercasePixelsAt2x": lowercaseHeight(original, displayScale: 2) * 2,
        "adjustedLowercasePixelsAt2x": lowercaseHeight(adjusted, displayScale: 2) * 2,
        "originalXPixelsAt2x": inkHeight(original, displayScale: 2),
        "adjustedXPixelsAt2x": inkHeight(adjusted, displayScale: 2),
        "originalXPixelsAt32x": inkHeight(original, displayScale: 32)
    ]
    measurements.append(record)
    let y: CGFloat = 482 - CGFloat(index) * 91
    draw(family.0, font: .systemFont(ofSize: 14, weight: .medium), x: 26, y: y, in: context)
    draw(String(format: "14 → %.2f pt (×%.4f)", adjusted.pointSize, scale), font: label, x: 26, y: y - 24, in: context)
    for (x, face) in [(CGFloat(250), original), (CGFloat(665), adjusted)] {
        draw("The quick brown fox jumps over the lazy dog.", font: face, x: x, y: y, in: context)
        draw("Reading a reply: 0123456789 · Hx aceosuvwxz", font: face, x: x, y: y - 27, in: context)
    }
}
draw("Measured median lowercase ink height against Source Code Pro. Font weight, capitals, and spacing retain each typeface’s design.",
     font: label, x: 26, y: 32, in: context)
let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("comparison.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output.appendingPathComponent("measurements.json"))
print(String(decoding: data, as: UTF8.self))
