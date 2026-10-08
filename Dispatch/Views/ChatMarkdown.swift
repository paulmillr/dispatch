import SwiftUI

enum ChatSearchHighlight: EnvironmentKey {
    static let defaultValue = ""
    static func text(_ value: AttributedString, query: String, theme: ChatTheme) -> AttributedString {
        guard !query.isEmpty else { return value }
        var result = value
        let plain = String(value.characters)
        var start = plain.startIndex
        while start < plain.endIndex,
              let range = plain.range(of: query, options: .caseInsensitive, range: start..<plain.endIndex) {
            if let span = Range(range, in: result) {
                result[span].backgroundColor = theme.yellow
                result[span].foregroundColor = theme.terminal
            }
            start = range.upperBound
        }
        return result
    }
}

extension EnvironmentValues {
    var chatSearchQuery: String {
        get { self[ChatSearchHighlight.self] }
        set { self[ChatSearchHighlight.self] = newValue }
    }
}

struct ChatMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph, heading(Int), list(String, Int), quote, code(String), rule, table([[String]])
    }
    let kind: Kind
    let text: String

    /// Line-based fences keep inline backticks and incomplete streaming fences intact.
    static func parse(_ text: String) -> [ChatMarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.init(kind: .paragraph, text: paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(while: { $0 == marker }).count >= 3 {
                flush()
                let length = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if next.prefix(while: { $0 == marker }).count >= length && next.allSatisfy({ $0 == marker }) { break }
                    code.append(lines[index - 1])
                }
                blocks.append(.init(kind: .code(language.isEmpty ? "text" : language), text: code.joined(separator: "\n")))
            } else if trimmed.isEmpty { flush() }
            else if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 || trimmed == "***" || trimmed == "___" {
                flush(); blocks.append(.init(kind: .rule, text: ""))
            } else if index < lines.count, line.contains("|"), isTableDivider(lines[index]) {
                flush(); index += 1
                var rows = [cells(line)]
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.init(kind: .table(rows), text: ""))
            } else if trimmed.hasPrefix("#"), (1...6).contains(trimmed.prefix(while: { $0 == "#" }).count), trimmed.drop(while: { $0 == "#" }).first == " " {
                flush()
                let count = trimmed.prefix(while: { $0 == "#" }).count
                blocks.append(.init(kind: .heading(count), text: String(trimmed.dropFirst(count + 1))))
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                flush(); blocks.append(.init(kind: .quote, text: String(trimmed.dropFirst(min(2, trimmed.count)))))
            } else if let match = trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush()
                let marker = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
                var content = String(trimmed[match.upperBound...])
                var bullet = ["-", "*", "+"].contains(marker) ? "•" : marker
                if content.hasPrefix("[ ] ") { bullet = "☐"; content = String(content.dropFirst(4)) }
                else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") { bullet = "☑"; content = String(content.dropFirst(4)) }
                blocks.append(.init(kind: .list(bullet, min(6, (line.count - trimmed.count) / 2)), text: content))
            } else { paragraph.append(line) }
        }
        flush(); return blocks
    }
    private static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        // Escaped pipes and pipes inside inline code are content, not separators.
        var cells: [String] = [], cell = "", escaped = false, inCode = false
        for char in value {
            if escaped { cell.append(char); escaped = false; continue }
            if char == "\\" { cell.append(char); escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|" && !inCode { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(char) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces)); return cells
    }
    private static func isTableDivider(_ line: String) -> Bool {
        let row = cells(line)
        return !row.isEmpty && row.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
}

struct ChatMarkdown: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let text: String
    var fillWidth = true
    /// Default text color; selectable text on macOS 26 ignores foregroundStyle.
    var color: Color?
    @State private var fileLink: ChatFileLink?
    @State private var selection = ChatMessageSelection()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .code(let language): ChatCodeBlock(code: block.text, language: language)
                case .heading(let level):
                    inline(block.text).font(theme.typography.font(offset: level == 1 ? 7.5 : (level == 2 ? 3.5 : 1), weight: .semibold))
                        .padding(.top, 6).accessibilityAddTraits(.isHeader)
                case .list(let marker, let depth):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker).foregroundStyle(theme.muted).frame(minWidth: 14, alignment: .trailing)
                        inline(block.text).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, CGFloat(depth) * 14)
                case .quote:
                    HStack(spacing: 10) {
                        Rectangle().fill(theme.muted.opacity(0.5)).frame(width: 2)
                        inline(block.text, color: theme.muted)
                    }.fixedSize(horizontal: false, vertical: true)
                case .rule: Divider().padding(.vertical, 4)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        inline(cell).fontWeight(index == 0 ? .semibold : .regular)
                                    }
                                }
                                if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(12)
                    }.background(theme.sidebar, in: RoundedRectangle(cornerRadius: 6))
                case .paragraph: inline(block.text)
                }
            }
        }.frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if let link = ChatFileLink(url) { fileLink = link; return .handled }
                return Self.isWebLink(url) ? .systemAction : .discarded
            })
            .sheet(item: $fileLink) { ChatFileLinkPreview(link: $0) }
    }
    @ViewBuilder private func inline(_ text: String, color: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            ChatSelectableText(value: attributed(text, color: color), selection: selection, source: self.text)
        } else {
            Text(attributed(text, color: color)).textSelection(.enabled).lineSpacing(4).tint(theme.blue)
        }
    }
    private func attributed(_ text: String, color: Color?) -> AttributedString {
        var value = Self.safeInlineMarkdown(text)
        if let color = color ?? self.color { value.foregroundColor = color }
        for run in value.runs where run.link != nil {
            value[run.range].foregroundColor = theme.blue
            value[run.range].underlineStyle = .single
        }
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].foregroundColor = theme.blue
            value[run.range].backgroundColor = theme.ink.opacity(0.05)
            value[run.range].font = theme.typography.codeFont()
        }
        return ChatSearchHighlight.text(value, query: query, theme: theme)
    }

    static func safeInlineMarkdown(_ text: String) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            guard isWebLink(url) || ChatFileLink(url) != nil else { return run.range }
            return nil
        }
        for range in unsafe { value[range].link = nil }
        return value
    }
    private static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
            && url.user == nil && url.password == nil
    }
}

// macOS 26's SwiftUI selection overlay can loop between clipping and wrapping
// when accessibility inspects an offscreen LazyVStack row. Keep native selection
// without that overlay; Font.resolve preserves the inherited SwiftUI typography.
@available(macOS 26, *)
private struct ChatSelectableText: NSViewRepresentable {
    @Environment(\.self) private var environment
    let value: AttributedString
    let selection: ChatMessageSelection
    /// The whole message's markdown, copied after Select All.
    let source: String
    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1: TextKit 2 adds and moves a view per text fragment during layout, and each one
        // asks the hosting views for another constraint pass. In a long transcript inside the
        // window's nested hosting views, AppKit stopped with "repeated Update Constraints passes".
        let view = SelectableTextView(usingTextLayoutManager: false)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.linkTextAttributes = [:]
        view.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.open = environment.openURL
        if let view = view as? SelectableTextView {
            view.source = source
            if view.selection !== selection { view.selection = selection; selection.views.add(view) }
        }
        let text = NSMutableAttributedString(attributedString: NSAttributedString(value))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        text.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor(environment.chatTheme.ink)],
                           range: NSRange(location: 0, length: text.length))
        var offset = 0
        for run in value.runs {
            let count = String(value[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: count)
            var font = run.font ?? environment.font ?? environment.chatTheme.typography.body
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { font = font.bold() }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { font = font.italic() }
            text.addAttribute(.font, value: font.resolve(in: environment.fontResolutionContext).ctFont, range: range)
            if let color = run.foregroundColor { text.addAttribute(.foregroundColor, value: NSColor(color), range: range) }
            if let color = run.backgroundColor { text.addAttribute(.backgroundColor, value: NSColor(color), range: range) }
            if run.link != nil { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            offset += count
        }
        if view.attributedString() != text { view.textStorage?.setAttributedString(text) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = view.attributedString().boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    }
    func makeCoordinator() -> Coordinator { Coordinator(open: environment.openURL) }
    final class SelectableTextView: NSTextView {
        weak var selection: ChatMessageSelection?
        var source = ""
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Select All spans every block of the message, not just this paragraph.
        override func selectAll(_ sender: Any?) {
            guard let selection else { return super.selectAll(sender) }
            selection.selectAll()
        }
        override func copy(_ sender: Any?) {
            guard selection?.isWhole == true else { return super.copy(sender) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { selection?.clear(except: nil) }
            return resigned
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: OpenURLAction
        init(open: OpenURLAction) { self.open = open }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? SelectableTextView,
                  let selection = view.selection, selection.isWhole, !selection.applying else { return }
            selection.clear(except: view)
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { open(url) }
            return true
        }
    }
}

/// Ties the separate text views of one rendered message together so Select All
/// covers the whole message and Copy then yields its markdown source.
@MainActor final class ChatMessageSelection {
    let views = NSHashTable<NSTextView>.weakObjects()
    private(set) var isWhole = false
    private(set) var applying = false

    func selectAll() {
        applying = true; defer { applying = false }
        for view in views.allObjects { view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count)) }
        isWhole = true
    }
    /// Drops the message-wide selection; `kept` retains the user's new selection.
    func clear(except kept: NSTextView?) {
        guard isWhole else { return }
        isWhole = false
        applying = true; defer { applying = false }
        for view in views.allObjects where view !== kept { view.setSelectedRange(NSRange(location: 0, length: 0)) }
    }
}
