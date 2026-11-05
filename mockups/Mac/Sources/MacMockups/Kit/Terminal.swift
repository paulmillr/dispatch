import CoreImage
import SwiftUI

// A terminal's screen: Source Code Pro 14 (the default font, the scale's reference) on the scheme's background, 10
// points in and 8 below the strip (Ghostty's window padding), lines 17.7 points apart as the app's capture shows.

/// A run of text in one style. `color` is an ANSI index (0–15) in the theme's terminal scheme; nil the foreground.
struct TermSpan {
    var text: String
    var color: Int?
    var bold = false
    var dim = false
    /// Drawn as a selection or a reverse-video cell.
    var inverse = false
}

struct TermLine: ExpressibleByStringLiteral {
    var spans: [TermSpan]
    init(_ spans: [TermSpan]) { self.spans = spans }
    init(stringLiteral value: String) { spans = [TermSpan(text: value)] }

    /// A zsh prompt as the fictional user's: `alex@mba2 app %` then the command.
    static func prompt(_ command: String = "", user: String = "alex", host: String = "mba2", folder: String = "app") -> TermLine {
        TermLine([TermSpan(text: "\(user)@\(host) \(folder) % "), TermSpan(text: command)])
    }
}

/// Builds a line from styled runs: `T("On branch ", c(2, "main"))`.
func T(_ parts: TermSpan...) -> TermLine { TermLine(parts) }
func c(_ color: Int?, _ text: String, bold: Bool = false, dim: Bool = false) -> TermSpan {
    TermSpan(text: text, color: color, bold: bold, dim: dim)
}
extension TermSpan: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self.init(text: value) }
}

struct TerminalScreen: View {
    var lines: [TermLine]
    /// The cursor after the last line's text: a bar, as the app's terminal draws it focused.
    var cursor = true
    var blockCursor = false
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 17.7
    var body: some View {
        if Mock.glowing {
            // The app's phosphor pass (TermApple/GlowShaders.swift) over the plain screen, drawn as a bitmap.
            GeometryReader { geometry in
                if let image = PhosphorGlow.apply(to: plain.frame(width: geometry.size.width, height: geometry.size.height),
                                                  size: geometry.size, cell: lineHeight, top: 8) {
                    Image(decorative: image, scale: Mock.scale).resizable().frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        } else {
            plain
        }
    }

    private var plain: some View {
        let scheme = TerminalScheme.current
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 0) {
                    ForEach(Array(line.spans.enumerated()), id: \.offset) { _, span in
                        let color = span.color.map { scheme.palette[$0] } ?? scheme.foreground
                        Text(span.text)
                            .font(.custom(span.bold ? "SourceCodePro-Semibold" : "SourceCodePro-Regular", size: fontSize))
                            .foregroundStyle(span.inverse ? scheme.background : color.opacity(span.dim ? 0.6 : 1))
                            .background(span.inverse ? color : .clear)
                    }
                    if cursor && index == lines.count - 1 {
                        Rectangle().fill(scheme.foreground).frame(width: blockCursor ? fontSize * 0.6 : 1.5, height: lineHeight - 2).padding(.leading, blockCursor ? 0 : 1)
                    }
                }
                .frame(height: lineHeight, alignment: .leading)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme.background)
        .clipped()
    }
}

/// The glowing schemes' post pass, as TermApple/GlowShaders.swift draws it with Glow's defaults (strength 2.5,
/// scanlines 0.3): a halo of what is brighter than the background, from two blurs (the shader's mip levels, a near one
/// about an eighth of a row and a far one four times wider, mixed 0.65 / 0.35), then a whole number of scanlines per row
/// (about every 3 pixels) aligned to the grid. The mip box filters are drawn as Gaussian blurs of about the same spread.
@MainActor enum PhosphorGlow {
    static let strength: Float = 2.5, scanlines: Float = 0.3

    /// `content` (`size` points) with the pass, at the render's scale; `cell` is the row height and `top` the grid's
    /// top padding, in points.
    static func apply<V: View>(to content: V, size: CGSize, cell: CGFloat, top: CGFloat) -> CGImage? {
        let scale = Mock.scale
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let source = renderer.cgImage else { return nil }
        let width = source.width, height = source.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return data
        }
        let frame = pixels(source)
        let raw = TerminalScheme.current.backgroundComponents
        let bg = [raw.0, raw.1, raw.2].map { Int(($0 * 255).rounded()) }
        // What is brighter than the background, as an image to blur.
        var excess = frame
        for i in stride(from: 0, to: excess.count, by: 4) {
            for c in 0..<3 { excess[i + c] = UInt8(max(Int(frame[i + c]) - bg[c], 0)) }
            excess[i + 3] = 255
        }
        let cellPixels = cell * scale
        let near = max(log2(cellPixels / 8), 0)
        // A mip level's box (2^lod pixels), its four half-texel taps and the bilinear read spread about 0.56 of it.
        let blurred = [near, near + 2].map { lod -> [UInt8] in
            let image = CIImage(bitmapData: Data(excess), bytesPerRow: width * 4, size: CGSize(width: width, height: height),
                                format: .RGBA8, colorSpace: space)
            let blur = image.clampedToExtent().applyingGaussianBlur(sigma: Double(exp2(lod) * 0.56)).cropped(to: image.extent)
            var out = [UInt8](repeating: 0, count: width * height * 4)
            CIContext(options: [.workingColorSpace: space]).render(blur, toBitmap: &out, rowBytes: width * 4,
                                                                   bounds: image.extent, format: .RGBA8, colorSpace: space)
            return out
        }
        let lines = max((cellPixels / 3).rounded(), 1), period = cellPixels / lines, padding = top * scale
        var result = frame
        for y in 0..<height {
            let phase = ((CGFloat(y) + 0.5 - padding) / period).truncatingRemainder(dividingBy: 1)
            let shade = 1 - scanlines * Float(0.5 - 0.5 * cos((phase < 0 ? phase + 1 : phase) * 2 * .pi))
            for x in 0..<width {
                let i = (y * width + x) * 4
                for c in 0..<3 {
                    let halo = Float(blurred[0][i + c]) * 0.65 + Float(blurred[1][i + c]) * 0.35
                    let value = (Float(frame[i + c]) + halo * strength) * shade
                    result[i + c] = UInt8(min(max(value, 0), Float(frame[i + 3])))
                }
            }
        }
        let provider = CGDataProvider(data: Data(result) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
