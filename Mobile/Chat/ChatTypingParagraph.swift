import QuartzCore
import SwiftUI
import UIKit

// The paragraph a reply types into, drawn once per arrival and revealed by Core Animation (docs/ios.md, typed reveal):
// SwiftUI draws the block's text as it has arrived into an image, recording where each character went, and every
// frame after that moves a mask and the caret over it, on the reveal's display link, with no SwiftUI update at all.
// SwiftUI lays the paragraph out again only when text arrives or the reveal reaches a new line (the bubble grows a
// line at a time). Once the block shows whole it is drawn as SwiftUI text again (`ChatTypingStage`).

/// A text block of a typing reply, revealed up to the reveal's frame: what it draws is `text` (the block's runs as the
/// thread draws them, in the environment's font and style) cut after the block's shown characters, with the caret.
struct ChatTypingParagraph: UIViewRepresentable {
    let text: AttributedString
    let reveal: ChatTypingReveal
    /// The block's index in the reveal's layout.
    let block: Int

    func makeUIView(context: Context) -> ParagraphView { ParagraphView() }

    func updateUIView(_ view: ParagraphView, context: Context) {
        view.configure(text: text, environment: context.environment, reveal: reveal, block: block)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ParagraphView, context: Context) -> CGSize? {
        uiView.size(fitting: proposal.width)
    }

    static func dismantleUIView(_ view: ParagraphView, coordinator: ()) { view.detach() }

    /// Whether `text` can type this way: a paragraph running left to right (the reveal follows character order across
    /// a line, which a right-to-left or mixed line does not draw in).
    static func supports(_ text: AttributedString, direction: LayoutDirection) -> Bool {
        guard direction == .leftToRight else { return false }
        let string = String(text.characters)
        // Any letter of a right-to-left script (the ranges `MobileChatMarkdownView.direction(of:)` knows).
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return false
            default: continue
            }
        }
        return true
    }

    /// Where SwiftUI put each character of a drawing of the text: its lines, top to bottom, and its glyphs in character
    /// order, each with the UTF-16 offset of the first character it draws (`Text.Layout.CharacterIndex`).
    struct Geometry {
        struct Glyph { let character: Int; let line: Int; let rect: CGRect }
        var lines: [CGRect] = []
        var glyphs: [Glyph] = []

        /// The last glyph drawing a character before UTF-16 offset `end`; nil before the first.
        func last(before end: Int) -> Glyph? {
            var low = 0, high = glyphs.count
            while low < high {
                let mid = (low + high) / 2
                if glyphs[mid].character < end { low = mid + 1 } else { high = mid }
            }
            return low > 0 ? glyphs[low - 1] : nil
        }
    }

    /// Draws the text as SwiftUI would and records where its glyphs went (`Geometry`).
    struct Recorder: TextRenderer {
        final class Box { var geometry = Geometry() }
        let box: Box
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            var geometry = Geometry()
            for (number, line) in layout.enumerated() {
                geometry.lines.append(line.typographicBounds.rect)
                for run in line {
                    context.draw(run)
                    for index in run.indices {
                        let slice = run[index]
                        guard let first = slice.characterIndices.min() else { continue }
                        geometry.glyphs.append(Geometry.Glyph(character: Self.offset(first), line: number,
                                                              rect: slice.typographicBounds.rect))
                    }
                }
            }
            geometry.glyphs.sort { $0.character < $1.character }
            // The layout's coordinates are not always the drawing's: with emoji on a line SwiftUI places the lines a few
            // points in and down (room for glyphs that overflow), yet draws the first line's start at the view's
            // corner. The lines start at the leading edge and the first at the top, so that is where they go.
            let dx = geometry.lines.map(\.minX).min() ?? 0, dy = geometry.lines.first?.minY ?? 0
            if dx != 0 || dy != 0 {
                geometry.lines = geometry.lines.map { $0.offsetBy(dx: -dx, dy: -dy) }
                geometry.glyphs = geometry.glyphs.map {
                    Geometry.Glyph(character: $0.character, line: $0.line, rect: $0.rect.offsetBy(dx: -dx, dy: -dy))
                }
            }
            box.geometry = geometry
        }

        /// The UTF-16 offset a character index stands for: its one stored value (no public accessor).
        static func offset(_ index: Text.Layout.CharacterIndex) -> Int {
            precondition(MemoryLayout<Text.Layout.CharacterIndex>.size == MemoryLayout<Int>.size)
            return unsafeBitCast(index, to: Int.self)
        }
    }

    final class ParagraphView: UIView {
        /// What the image is drawn from: the text, and what in the environment changes how it draws.
        private struct Key: Equatable {
            var text: AttributedString
            var font: Font?
            var scheme: ColorScheme
            var contrast: ColorSchemeContrast
            var typeSize: DynamicTypeSize
            var weight: LegibilityWeight?
            var scale: CGFloat
        }
        /// A drawing of the text at one proposed width.
        private struct Drawing {
            let size: CGSize
            let image: CGImage?
            let geometry: Geometry
        }

        private let ink = CALayer()
        private let cover = CAShapeLayer()
        private let caret = CALayer()
        private var key: Key?
        private var environment = EnvironmentValues()
        /// The text's drawings by proposed width (SwiftUI may ask for several in one layout), for `key`.
        private var drawings: [CGFloat?: Drawing] = [:]
        /// The drawing on screen: the one whose width the view was given.
        private var shown: Drawing?
        /// The UTF-16 offset after each of the text's first n characters.
        private var offsets: [Int] = [0]
        private weak var reveal: ChatTypingReveal?
        private var block = 0
        /// The height last reported to SwiftUI for `shown`.
        private var reported: CGFloat = 0
        /// The block's characters showing (VoiceOver reads them).
        private var count = 0

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            ink.anchorPoint = .zero
            ink.mask = cover
            layer.addSublayer(ink)
            caret.anchorPoint = .zero
            layer.addSublayer(caret)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        func configure(text: AttributedString, environment: EnvironmentValues, reveal: ChatTypingReveal, block: Int) {
            self.environment = environment
            let key = Key(text: text, font: environment.font, scheme: environment.colorScheme,
                          contrast: environment.colorSchemeContrast, typeSize: environment.dynamicTypeSize,
                          weight: environment.legibilityWeight, scale: environment.displayScale)
            if key != self.key {
                self.key = key
                drawings.removeAll()
                shown = nil
                offsets = [0]
                var total = 0
                for character in text.characters { total += character.utf16.count; offsets.append(total) }
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
            caret.backgroundColor = Color.dispatchPink.resolve(in: environment).cgColor
            self.block = block
            if self.reveal !== reveal {
                self.reveal?.stopsDrawing(for: self)
                self.reveal = reveal
                reveal.draws(for: self) { [weak self] frame in self?.show(frame) }
            }
            show(reveal.drawnFrame)
        }

        func detach() {
            reveal?.stopsDrawing(for: self)
            reveal = nil
        }

        /// The text's width at `width`, and its height down to the line being typed.
        func size(fitting width: CGFloat?) -> CGSize {
            guard let drawing = drawing(width: width) else { return .zero }
            let frame = reveal?.drawnFrame ?? ChatTypingFrame(shown: 0, caret: 0)
            return CGSize(width: drawing.size.width, height: place(frame, in: drawing).height)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The drawing SwiftUI sized the view from: the one as wide as the view.
            let fitting = drawings.values.min { abs($0.size.width - bounds.width) < abs($1.size.width - bounds.width) }
            let drawing = fitting.flatMap { abs($0.size.width - bounds.width) < 0.5 ? $0 : nil } ?? self.drawing(width: bounds.width)
            guard let drawing else { return }
            if shown?.image !== drawing.image {
                shown = drawing
                CATransaction.begin(); CATransaction.setDisableActions(true)
                ink.contents = drawing.image
                ink.contentsScale = key?.scale ?? 2
                ink.frame = CGRect(origin: .zero, size: drawing.size)
                CATransaction.commit()
            }
            if let reveal { show(reveal.drawnFrame) }
        }

        /// The drawing for a proposed `width`, drawn once per text, style and width.
        private func drawing(width: CGFloat?) -> Drawing? {
            guard let key else { return nil }
            if let drawing = drawings[width] { return drawing }
            let box = Recorder.Box()
            let content = Text(key.text)
                .textRenderer(Recorder(box: box))
                .environment(\.self, environment)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            renderer.scale = key.scale
            let image = renderer.cgImage
            let size = CGSize(width: CGFloat(image?.width ?? 0) / key.scale, height: CGFloat(image?.height ?? 0) / key.scale)
            let drawing = Drawing(size: size, image: image, geometry: box.geometry)
            if drawings.count >= 4 { drawings.removeAll() }
            drawings[width] = drawing
            return drawing
        }

        /// Reveals the block's shown characters and places the caret; tells SwiftUI when the reveal reaches a new line.
        func show(_ frame: ChatTypingFrame) {
            guard let shown else { return }
            let placed = place(frame, in: shown)
            count = placed.count
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cover.path = placed.cover
            caret.frame = placed.caret
            caret.opacity = Float(frame.caret)
            caret.isHidden = frame.caret <= 0 || placed.count == 0
            CATransaction.commit()
            if placed.height != reported {
                reported = placed.height
                invalidateIntrinsicContentSize()
            }
        }

        /// Where `frame` cuts the block in `drawing`: the characters showing, the region of the text they cover (the
        /// lines above the caret's whole, its own up to the caret), the caret's bar, and the height down to the caret's
        /// line as SwiftUI measures that many lines (with the text's own margin below its last line).
        private func place(_ frame: ChatTypingFrame, in drawing: Drawing) -> (count: Int, cover: CGPath, caret: CGRect, height: CGFloat) {
            let start = reveal.flatMap { block < $0.layout.blocks.count ? $0.layout.blocks[block].start : nil } ?? 0
            let count = min(max(0, frame.shown - start), offsets.count - 1)
            let geometry = drawing.geometry
            let glyph = geometry.last(before: offsets[count])
            let line = glyph?.line ?? 0
            let lines = geometry.lines
            let top = lines.indices.contains(line) ? lines[line].minY : 0
            let next = line + 1 < lines.count ? lines[line + 1].minY : drawing.size.height
            let x = glyph?.rect.maxX ?? 0
            let path = CGMutablePath()
            if glyph != nil {
                path.addRect(CGRect(x: -8, y: -8, width: drawing.size.width + 16, height: top + 8))
                path.addRect(CGRect(x: -8, y: top, width: x + 8, height: next - top))
            }
            let height: CGFloat
            if line + 1 >= lines.count || !lines.indices.contains(line) {
                height = drawing.size.height
            } else {
                height = min(drawing.size.height, lines[line].maxY + (drawing.size.height - (lines.last?.maxY ?? 0)))
            }
            let bar = glyph?.rect ?? lines.first ?? .zero
            return (count, path, CGRect(x: x.rounded(), y: bar.minY, width: 2, height: bar.height), height)
        }

        override var accessibilityLabel: String? {
            get { key.map { String($0.text.characters.prefix(count)) } }
            set {}
        }
    }
}
