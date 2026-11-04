import AppKit
import SwiftUI

/// The binary preview's document for the shown revision: kept across redraws, replaced (and the old one's reads
/// stopped) when the preview reads another revision.
@MainActor final class FileHexHolder {
    private(set) var document: FileHexDocument?

    func document(_ preview: FilePreviewState, size: UInt64, head: Data, source: (any FilesSource)?) -> FileHexDocument {
        if let document, document.size == size, document.revision == preview.revision, document.head.count == head.count {
            return document
        }
        document?.close()
        let made = FileHexDocument(path: preview.path, size: size, revision: preview.revision, head: head, source: source)
        document = made
        return made
    }

    func close() {
        document?.close()
        document = nil
    }
}

/// A binary as hex (F2d): the whole file, read a page at a time as it scrolls, bytes coloured by class. A bar to
/// switch to its strings, go to an offset or the end; under the rows, what the selection's bytes read as. Arrows,
/// pages, Home and End move the selection (shift extends it); ⌘C copies it as hex, the context menu in other forms.
struct FileHexPreview: View {
    @Environment(\.chatTheme) private var theme
    let document: FileHexDocument
    /// The preview has focus: ⌘C, ⌘A and ⌘L are the hex view's then.
    let focused: Bool
    let activate: () -> Void
    let openTerminal: () -> Void
    /// The file changed under the rows: read it again.
    let reload: () -> Void
    @State private var target = ""
    @State private var littleEndian = true
    @FocusState private var going: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            switch document.mode {
            case .hex:
                FileHexGrid(document: document, theme: theme, activate: activate, copy: copy)
                    .accessibilityIdentifier("file-preview-hex")
                if let selection = document.selection { inspector(selection) }
            case .strings:
                strings
            }
        }
        .background { shortcuts }
        .onChange(of: document.changed) { if document.changed { reload() } }
        .task(id: document.notice) {
            guard document.notice != nil else { return }
            try? await System.sleep(for: .seconds(3), "files.hex-notice")
            document.notice = nil
        }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                modeButton("Hex", .hex)
                modeButton("Strings", .strings)
            }
            Text(status)
                .foregroundStyle(document.failure != nil ? theme.yellow : theme.muted)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("file-preview-hex-status")
            Spacer(minLength: 8)
            if document.mode == .hex {
                TextField("Go to offset", text: $target)
                    .textFieldStyle(.plain)
                    .focused($going)
                    .onSubmit(go)
                    .onExitCommand { target = ""; activate() }
                    .padding(.horizontal, 8)
                    .frame(width: 120, height: 22)
                    .background(theme.window, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border))
                    .help("An offset: 0x1a0 or 1a0 in hex, 416 in decimal, -16 from the end · ⌘L")
                    .accessibilityIdentifier("file-preview-hex-go")
                Button { if document.size > 0 { document.select(document.size - 1..<document.size) } } label: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 11))
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: false))
                .disabled(document.size == 0)
                .help("Go to the end · ⌘↓")
                .accessibilityLabel("Go to the end")
                .accessibilityIdentifier("file-preview-hex-end")
            }
            Button("Open in terminal", action: openTerminal)
                .buttonStyle(FilePreviewButtonStyle())
                .help("Show this tab’s terminal")
                .accessibilityIdentifier("file-preview-open-terminal")
        }
        .font(theme.typography.font(offset: -1.5))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private func modeButton(_ title: String, _ mode: FileHexDocument.Mode) -> some View {
        Button(title) { document.mode = mode }
            .buttonStyle(FilePreviewIconButtonStyle(on: document.mode == mode))
            .accessibilityValue(document.mode == mode ? "on" : "off")
            .accessibilityIdentifier("file-preview-hex-mode-\(title.lowercased())")
    }

    private var status: String {
        if let failure = document.failure { return failure }
        if let notice = document.notice { return notice }
        guard document.mode == .strings else { return "" }
        let end = min(document.size, FileHexDocument.stringsLimit)
        if document.scanning {
            return "Reading strings… \(FilesFormatting.size(document.scanned)) of \(FilesFormatting.size(end))"
        }
        let count = document.strings.count
        var text = "\(FilesFormatting.count(count)) \(count == 1 ? "string" : "strings")"
        if count >= FileHexDocument.stringsCount { text = "The first " + text }
        if document.size > FileHexDocument.stringsLimit { text += " in the first \(FilesFormatting.size(end))" }
        return text
    }

    private func go() {
        guard let offset = FileHexDocument.offset(target, size: document.size) else {
            document.notice = "Not an offset in this file"
            return
        }
        document.select(offset..<offset + 1)
        target = ""
        activate()
    }

    /// ⌘C, ⌘A and ⌘L while the preview has focus, ahead of the menus' (the find button's pattern).
    private var shortcuts: some View {
        let on = focused && document.mode == .hex
        return ZStack {
            Button { copy(.hex) } label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(on && document.selection != nil ? KeyboardShortcut("c", modifiers: .command) : nil)
            Button { document.selectAll() } label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(on ? KeyboardShortcut("a", modifiers: .command) : nil)
            Button { going = true } label: { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut(on ? KeyboardShortcut("l", modifiers: .command) : nil)
        }
        .buttonStyle(.plain).opacity(0).allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func copy(_ format: FileHexDocument.CopyFormat) {
        Task {
            guard let text = await document.copyText(format) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Arrows, pages, Home and End for the hex rows; the preview's focused content passes its keys here.
    static func key(_ press: KeyPress, in document: FileHexDocument) -> KeyPress.Result {
        guard document.mode == .hex, document.size > 0 else { return .ignored }
        let extend = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)
        let row = Int64(document.bytesPerRow)
        let page = row * Int64(max(1, document.visibleRows - 1))
        let end = document.size - 1
        switch press.key {
        case .upArrow: command ? document.move(to: 0, extend: extend) : document.move(by: -row, extend: extend)
        case .downArrow: command ? document.move(to: end, extend: extend) : document.move(by: row, extend: extend)
        case .leftArrow: document.move(by: -1, extend: extend)
        case .rightArrow: document.move(by: 1, extend: extend)
        case .pageUp: document.move(by: -page, extend: extend)
        case .pageDown: document.move(by: page, extend: extend)
        case .home: document.move(to: 0, extend: extend)
        case .end: document.move(to: end, extend: extend)
        default: return .ignored
        }
        return .handled
    }

    // MARK: Inspector

    private func inspector(_ selection: ClosedRange<UInt64>) -> some View {
        _ = document.loaded
        let start = selection.lowerBound
        let length = selection.upperBound - selection.lowerBound + 1
        let bytes = document.bytes(at: start, count: 8)
        let values = FileHexDocument.values(bytes, littleEndian: littleEndian)
        let text = length <= 64 ? FileHexDocument.utf8(document.bytes(at: start, count: Int(length))) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "0x" + String(start, radix: 16) + " · " + FilesFormatting.count(start))
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("file-preview-hex-offset")
                Text(verbatim: "\(FilesFormatting.count(length)) \(length == 1 ? "byte" : "bytes") selected")
                    .foregroundStyle(theme.muted)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button("LE") { littleEndian = true }
                        .buttonStyle(FilePreviewIconButtonStyle(on: littleEndian))
                        .help("Read the numbers little-endian")
                        .accessibilityIdentifier("file-preview-hex-little-endian")
                    Button("BE") { littleEndian = false }
                        .buttonStyle(FilePreviewIconButtonStyle(on: !littleEndian))
                        .help("Read the numbers big-endian")
                        .accessibilityIdentifier("file-preview-hex-big-endian")
                }
                Menu("Copy") {
                    ForEach(FileHexDocument.CopyFormat.allCases, id: \.self) { format in
                        Button(format.title) { copy(format) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("file-preview-hex-copy")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14, alignment: .leading)],
                      alignment: .leading, spacing: 3) {
                ForEach(values) { item in
                    HStack(spacing: 6) {
                        Text(item.label).foregroundStyle(theme.muted)
                        Text(verbatim: item.value).foregroundStyle(theme.ink).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("file-preview-hex-value-\(item.label)")
                }
                HStack(spacing: 6) {
                    Text("UTF-8").foregroundStyle(theme.muted)
                    Text(verbatim: text.map { "“" + TextRendering.visible($0) + "”" } ?? "—").foregroundStyle(theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .accessibilityIdentifier("file-preview-hex-value-utf8")
            }
            .font(theme.typography.codeFont(offset: -1.5))
        }
        .font(theme.typography.font(offset: -1.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preview-hex-inspector")
    }

    // MARK: Strings

    private var strings: some View {
        let digits = max(8, String(max(document.size, 1) - 1, radix: 16).count)
        return Group {
            if document.strings.isEmpty && !document.scanning {
                Text(document.failure == nil ? "No runs of 4 or more printable characters" : "")
                    .font(theme.typography.font(offset: -1.5))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.strings) { found in
                            Button {
                                document.mode = .hex
                                document.select(found.offset..<found.offset + found.length)
                            } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Text(verbatim: Self.padded(found.offset, digits: digits)).foregroundStyle(theme.muted)
                                    Text(verbatim: found.text).foregroundStyle(theme.ink)
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .frame(height: FilePreviewMetrics.metrics(theme.typography).rowHeight)
                            .help("Show it in the hex")
                        }
                    }
                    .padding(.vertical, 6)
                }
                .font(theme.typography.codeFont())
            }
        }
        .accessibilityIdentifier("file-preview-hex-strings")
    }

    static func padded(_ value: UInt64, digits: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

/// The rows in AppKit: only what shows is drawn, so a file of any size scrolls as one of a page.
private struct FileHexGrid: NSViewRepresentable {
    let document: FileHexDocument
    let theme: ChatTheme
    let activate: () -> Void
    let copy: (FileHexDocument.CopyFormat) -> Void

    func makeNSView(context: Context) -> FileHexGridView {
        FileHexGridView(document: document)
    }

    func updateNSView(_ view: FileHexGridView, context: Context) {
        view.document = document
        view.theme = theme
        view.activate = activate
        view.copy = copy
    }

    static func dismantleNSView(_ view: FileHexGridView, coordinator: ()) {
        view.document.redraw = nil
    }
}

/// Offset, sixteen bytes (eight in a narrow pane) in two groups, and their characters, under a header naming the
/// columns. Bytes are coloured by class, as hexyl does: NUL, printable, whitespace, other control, and non-ASCII. A
/// row whose page is not read yet is blank until it arrives. The scroll position is the document's, in points, kept
/// as a double: 5 GB of rows are 6.7 billion points, past what a view frame holds exactly. The thin knob at the
/// right drags and pages.
final class FileHexGridView: NSView {
    var document: FileHexDocument {
        didSet {
            guard document !== oldValue else { return }
            oldValue.redraw = nil
            attach()
        }
    }
    var theme = ChatTheme.standard {
        didSet {
            guard theme != oldValue else { return }
            style()
            needsLayout = true
            needsDisplay = true
        }
    }
    var activate: (() -> Void)?
    var copy: ((FileHexDocument.CopyFormat) -> Void)?

    private enum Drag {
        case select
        case knob(grab: CGFloat)
    }

    static let padding: CGFloat = 14
    private static let knobWidth: CGFloat = 6
    private static let knobArea: CGFloat = 12
    /// Above the first row and below the last.
    private static let inset: CGFloat = 4

    private var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private var digit: CGFloat = 7.5
    private var rowHeight: CGFloat = 20
    private var lineHeight: CGFloat = 15
    private var colors = Colors()
    private var drag: Drag?
    /// The height the last layout had: a change keeps the selected byte, or the end, in view.
    private var laidOutHeight: CGFloat = 0

    private struct Colors {
        var ink = NSColor.textColor
        var muted = NSColor.secondaryLabelColor
        var printable = NSColor.cyan
        var whitespace = NSColor.green
        var control = NSColor.magenta
        var high = NSColor.orange
        var selection = NSColor.selectedTextBackgroundColor
        var border = NSColor.separatorColor
        var background = NSColor.textBackgroundColor
    }

    init(document: FileHexDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Hex")
        style()
        attach()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    /// SwiftUI's focus stays on the preview, which passes the keys on (`FileHexPreview.key`).
    override var acceptsFirstResponder: Bool { false }

    private func attach() {
        document.redraw = { [weak self] in
            guard let self else { return }
            revealIfAsked()
            needsDisplay = true
        }
        needsLayout = true
        needsDisplay = true
    }

    private func style() {
        let typography = theme.typography
        font = typography.unligated(typography.codeFontName, typography.size)
            ?? NSFont(name: typography.codeFontName, size: typography.size)
            ?? .monospacedSystemFont(ofSize: typography.size, weight: .regular)
        let metrics = FilePreviewMetrics.metrics(typography)
        digit = metrics.digitWidth
        rowHeight = metrics.rowHeight
        lineHeight = metrics.lineHeight
        colors = Colors(ink: NSColor(theme.ink), muted: NSColor(theme.muted), printable: NSColor(theme.cyan),
                        whitespace: NSColor(theme.green), control: NSColor(theme.keyword), high: NSColor(theme.yellow),
                        selection: NSColor(theme.accent).withAlphaComponent(0.35), border: NSColor(theme.border),
                        background: NSColor(theme.terminal))
    }

    // MARK: Geometry

    private var size: UInt64 { document.size }
    private var bytesPerRow: UInt64 { document.bytesPerRow }
    private var rows: UInt64 { size == 0 ? 0 : (size - 1) / bytesPerRow + 1 }
    private var header: CGFloat { rowHeight + 1 }
    private var viewport: CGFloat { max(0, bounds.height - header) }
    private var contentHeight: Double { Double(rows) * Double(rowHeight) + Double(Self.inset * 2) }
    private var maxScroll: Double { max(0, contentHeight - Double(viewport)) }
    private var offsetDigits: Int { max(8, String(max(size, 1) - 1, radix: 16).count) }

    /// Byte `index`'s column in the hex area: three per byte, one more between the groups of eight.
    private static func column(_ index: Int) -> Int { index * 3 + index / 8 }
    private var hexStart: CGFloat { Self.padding + CGFloat(offsetDigits + 2) * digit }
    private func asciiStart(_ perRow: Int) -> CGFloat { hexStart + CGFloat(Self.column(perRow - 1) + 5) * digit }
    private func width(_ perRow: Int) -> CGFloat {
        asciiStart(perRow) + CGFloat(perRow) * digit + Self.padding + Self.knobArea
    }

    override func layout() {
        super.layout()
        let perRow: UInt64 = width(16) <= bounds.width ? 16 : 8
        if perRow != document.bytesPerRow {
            // The same bytes stay at the top.
            let top = UInt64(max(0, document.scrollTop) / Double(rowHeight)) * document.bytesPerRow
            document.bytesPerRow = perRow
            document.scrollTop = Double(top / perRow) * Double(rowHeight)
        }
        if bounds.height != laidOutHeight, laidOutHeight > header {
            // The inspector came or went: what was in view stays there.
            let oldViewport = Double(laidOutHeight - header)
            let atEnd = document.scrollTop >= max(0, contentHeight - oldViewport) - 0.5
            if atEnd { document.scrollTop = maxScroll }
            else if document.reveal == nil, let caret = document.caret {
                let top = Double(caret / bytesPerRow) * Double(rowHeight) + Double(Self.inset)
                if top >= document.scrollTop, top < document.scrollTop + oldViewport { document.reveal = (caret, false) }
            }
        }
        laidOutHeight = bounds.height
        document.visibleRows = UInt64(max(1, viewport / rowHeight))
        document.scrollTop = min(document.scrollTop, maxScroll)
        revealIfAsked()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private func scroll(to top: Double) {
        let clamped = min(max(0, top), maxScroll)
        guard clamped != document.scrollTop else { return }
        document.scrollTop = clamped
        needsDisplay = true
    }

    /// A Go to or a key asked for a byte: a jump puts its row a third down, a key just brings it into view.
    private func revealIfAsked() {
        guard let reveal = document.reveal, bounds.height > header else { return }
        document.reveal = nil
        let top = Double(reveal.offset / bytesPerRow) * Double(rowHeight) + Double(Self.inset)
        let bottom = top + Double(rowHeight)
        let shown = document.scrollTop...(document.scrollTop + Double(viewport))
        if reveal.jump {
            if !(shown.contains(top) && shown.contains(bottom)) { scroll(to: top - Double(viewport) / 3) }
        } else if top < shown.lowerBound {
            scroll(to: top - Double(Self.inset))
        } else if bottom > shown.upperBound {
            scroll(to: bottom + Double(Self.inset) - Double(viewport))
        }
    }

    /// The byte under `point`, nil above the rows; `clamp` (a drag) takes the nearest row past either edge.
    private func offset(at point: NSPoint, clamp: Bool = false) -> UInt64? {
        guard rows > 0 else { return nil }
        var y = Double(point.y - header - Self.inset) + document.scrollTop
        if point.y < header { guard clamp else { return nil }; y = document.scrollTop }
        let row = min(UInt64(max(0, y / Double(rowHeight))), rows - 1)
        let perRow = Int(bytesPerRow)
        let ascii = asciiStart(perRow)
        let index: Int
        if point.x >= ascii - 2 * digit {
            index = Int((point.x - ascii) / digit)
        } else if point.x < hexStart {
            index = 0
        } else {
            let column = Int((point.x - hexStart) / digit)
            index = (0..<perRow).last { Self.column($0) <= column } ?? 0
        }
        return min(row * bytesPerRow + UInt64(min(max(0, index), perRow - 1)), size - 1)
    }

    private var knob: NSRect? {
        guard maxScroll > 0 else { return nil }
        let track = Double(viewport) - 4
        let height = max(24, track * Double(viewport) / contentHeight)
        let y = Double(header) + 2 + (track - height) * document.scrollTop / maxScroll
        return NSRect(x: bounds.maxX - 3 - Self.knobWidth, y: y, width: Self.knobWidth, height: height)
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * rowHeight * 3
        scroll(to: document.scrollTop - Double(delta))
    }

    override func mouseDown(with event: NSEvent) {
        activate?()
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.maxX - Self.knobArea, let knob {
            drag = .knob(grab: knob.contains(point) ? point.y - knob.minY : knob.height / 2)
            if !knob.contains(point) { follow(point) }
            return
        }
        guard let offset = offset(at: point) else { return }
        document.click(offset, extend: event.modifierFlags.contains(.shift))
        drag = .select
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .knob: follow(point)
        case .select:
            if point.y < header { scroll(to: document.scrollTop - Double(rowHeight)) }
            if point.y > bounds.maxY { scroll(to: document.scrollTop + Double(rowHeight)) }
            if let offset = offset(at: NSPoint(x: point.x, y: min(point.y, bounds.maxY - 1)), clamp: true) {
                document.drag(to: offset)
            }
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    /// The knob follows the pointer, held where it was grabbed.
    private func follow(_ point: NSPoint) {
        guard case .knob(let grab) = drag, let knob else { return }
        let track = Double(viewport) - 4 - Double(knob.height)
        guard track > 0 else { return }
        let fraction = (Double(point.y - grab) - Double(header) - 2) / track
        scroll(to: fraction * maxScroll)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let offset = offset(at: point), !(document.selection?.contains(offset) ?? false) {
            document.click(offset, extend: false)
        }
        guard document.selection != nil else { return nil }
        let menu = NSMenu()
        for (index, format) in FileHexDocument.CopyFormat.allCases.enumerated() {
            let item = NSMenuItem(title: format.title, action: #selector(copyItem(_:)), keyEquivalent: index == 0 ? "c" : "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Select All", action: #selector(selectAllItem), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)
        return menu
    }

    @objc private func copyItem(_ item: NSMenuItem) {
        copy?(FileHexDocument.CopyFormat.allCases[item.tag])
    }

    @objc private func selectAllItem() { document.selectAll() }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let perRow = Int(bytesPerRow)
        if rows > 0 {
            let first = UInt64(max(0, (document.scrollTop - Double(Self.inset)) / Double(rowHeight)))
            let last = min(rows - 1, UInt64(max(0, (document.scrollTop + Double(viewport)) / Double(rowHeight))))
            if first <= last {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: 0, y: header, width: bounds.width, height: viewport).clip()
                for row in first...last {
                    let y = header + CGFloat(Double(row) * Double(rowHeight) + Double(Self.inset) - document.scrollTop)
                    drawRow(row, at: y, perRow: perRow)
                }
                NSGraphicsContext.restoreGraphicsState()
                // A screen past what shows is read too, so a page down finds its rows ready.
                let ahead = last + UInt64(max(1, document.visibleRows))
                document.want(first * bytesPerRow..<min(size, (ahead + 1) * bytesPerRow))
            }
        }
        drawHeader(perRow: perRow)
        if let knob {
            colors.muted.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: knob, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2).fill()
        }
    }

    private func drawHeader(perRow: Int) {
        colors.background.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight).fill()
        colors.border.setFill()
        NSRect(x: 0, y: rowHeight, width: bounds.width, height: 1).fill()
        var line = String(repeating: " ", count: offsetDigits + 2)
        for index in 0..<perRow {
            if index > 0 { line += index % 8 == 0 ? "  " : " " }
            line += FileHexPreview.padded(UInt64(index), digits: 2)
        }
        line += "   " + (0..<perRow).map { String($0, radix: 16) }.joined()
        drawLine(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: colors.muted]), at: 0)
    }

    private func drawRow(_ row: UInt64, at y: CGFloat, perRow: Int) {
        let start = row * bytesPerRow
        if let selection = document.selection, selection.lowerBound < start + bytesPerRow, selection.upperBound >= start {
            let low = Int(max(selection.lowerBound, start) - start)
            let high = Int(min(selection.upperBound, start + bytesPerRow - 1) - start)
            colors.selection.setFill()
            let hexLeft = hexStart + CGFloat(Self.column(low)) * digit - digit / 2
            let hexRight = hexStart + CGFloat(Self.column(high) + 2) * digit + digit / 2
            NSRect(x: hexLeft, y: y, width: hexRight - hexLeft, height: rowHeight).fill()
            let ascii = asciiStart(perRow)
            NSRect(x: ascii + CGFloat(low) * digit, y: y, width: CGFloat(high - low + 1) * digit, height: rowHeight).fill()
        }
        var line = FileHexPreview.padded(start, digits: offsetDigits) + "  "
        var runs: [(NSRange, NSColor)] = [(NSRange(location: 0, length: offsetDigits), colors.muted)]
        var bytes: [UInt8?] = []
        for index in 0..<perRow {
            let offset = start + UInt64(index)
            bytes.append(offset < size ? document.byte(at: offset) : nil)
        }
        for (index, byte) in bytes.enumerated() {
            if index > 0 { line += index % 8 == 0 ? "  " : " " }
            if let byte {
                runs.append((NSRange(location: line.utf16.count, length: 2), color(byte)))
                line += FileHexPreview.padded(UInt64(byte), digits: 2)
            } else {
                line += "  "
            }
        }
        line += "   "
        for byte in bytes {
            if let byte {
                runs.append((NSRange(location: line.utf16.count, length: 1), color(byte)))
                line.append((0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : ".")
            } else {
                line += " "
            }
        }
        let text = NSMutableAttributedString(string: line, attributes: [.font: font, .foregroundColor: colors.ink])
        for (range, color) in runs { text.addAttribute(.foregroundColor, value: color, range: range) }
        drawLine(text, at: y)
    }

    private func drawLine(_ text: NSAttributedString, at y: CGFloat) {
        text.draw(at: NSPoint(x: Self.padding, y: y + (rowHeight - lineHeight) / 2))
    }

    private func color(_ byte: UInt8) -> NSColor {
        switch byte {
        case 0: colors.muted
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20: colors.whitespace
        case 0x21...0x7E: colors.printable
        case 0x01...0x1F, 0x7F: colors.control
        default: colors.high
        }
    }
}
