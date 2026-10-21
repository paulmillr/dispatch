import AppKit
import SwiftUI

/// The right pane: what the selected row is (F2a, F2d). A 40 pt header names it and carries its controls; the body
/// draws the kind the loader decided. Content and header always come from the same `FilePreviewState`, and each
/// state gets its own view identity, so a new selection never shows the last file's text, scroll or find.
struct FilePreviewPane: View {
    let session: FilesSession

    private struct LoadKey: Hashable {
        let preview: ObjectIdentifier?
        let source: ObjectIdentifier?
    }

    var body: some View {
        let theme = ChatThemeStore.shared.current
        let source = session.source
        Group {
            if let preview = session.preview {
                FilePreviewContent(session: session, preview: preview)
                    .id(ObjectIdentifier(preview))
            } else {
                Text("Select a file to preview it")
                    .font(theme.typography.font(offset: -1))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("file-preview-empty")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.terminal)
        .foregroundStyle(theme.ink)
        .tint(theme.blue)
        .environment(\.chatTheme, theme)
        // Keyed by the state and the source: a new selection (or the source arriving) cancels the read in flight.
        .task(id: LoadKey(preview: session.preview.map(ObjectIdentifier.init), source: source.map { ObjectIdentifier($0) })) {
            guard let preview = session.preview, let source else { return }
            await FilePreviewLoader.load(preview, from: source)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preview")
    }
}

extension FilesFormatting {
    /// The header's muted line: "src/routes · 4.1 KB · modified 6m ago · TypeScript", "assets · 48 KB · PNG ·
    /// 512 × 512", "folder · 5,120 items · 48 MB", and for text too large to show "scheduler · 9.6 MB · JSON" (F2d).
    @MainActor static func meta(_ preview: FilePreviewState, root: String?, home: String?, now: Date) -> String {
        if case .folder(let summary) = preview.kind {
            guard let summary else { return "folder" }
            let total = summary.files + summary.folders
            let items = count(total) + (summary.truncated ? "+" : "")
            return "folder · \(items) \(total == 1 ? "item" : "items") · \(size(summary.bytes))"
        }
        if preview.entry?.isDirectory == true { return "folder" }
        var parts = [location(of: preview.path, root: root, home: home)]
        if let bytes = preview.revision?.size ?? preview.entry?.size { parts.append(size(bytes)) }
        if case .image(_, let pixels) = preview.kind {
            if let kind = kindName(preview.name) { parts.append(kind) }
            parts.append("\(Int(pixels.width)) × \(Int(pixels.height))")
            return parts.joined(separator: " · ")
        }
        let tooLarge = if case .tooLarge = preview.kind { true } else { false }
        if !tooLarge, let modified = preview.revision?.modified ?? preview.entry?.modified {
            parts.append(self.modified(modified, at: now))
        }
        if let kind = kindName(preview.name) { parts.append(kind) }
        return parts.joined(separator: " · ")
    }
}

/// One selection's header and body. Its view state (find, rendered, fit) belongs to this file only.
private struct FilePreviewContent: View {
    @Environment(\.chatTheme) private var theme
    let session: FilesSession
    let preview: FilePreviewState
    @State private var find = FilePreviewFind()
    @State private var rendered = false
    @State private var actualSize = false
    @State private var headRequest: UUID?
    @State private var spinner = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case content, find }

    private var files: FilesCoordinator { TerminalRuntime.shared.files }
    private var focused: Bool { session.previewFocused }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .focusable()
                .focusEffectDisabled()
                .focused($focus, equals: .content)
                .simultaneousGesture(TapGesture().onEnded { if focus != .content { focus = .content } })
                .onKeyPress(.escape) {
                    guard find.open else { return .ignored }
                    closeFind()
                    return .handled
                }
        }
        .onChange(of: focus) { session.previewFocused = focus != nil }
        .onChange(of: session.findRequest) {
            guard session.previewFocused else { return }
            openFind()
        }
        .onDisappear { if focus != nil { session.previewFocused = false } }
        .task(id: headRequest) {
            guard headRequest != nil, let source = session.source else { return }
            await FilePreviewLoader.loadHead(preview, from: source)
        }
    }

    // MARK: Header

    private var header: some View {
        let root = session.root(tabDirectory: TerminalRuntime.shared.workspace?.liveTab(session.id)?.directory)
        let notice = FilesEditorNotices.shared.notice(for: session.id)
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(theme.ink.opacity(0.6))
                .frame(width: 14)
            Text(verbatim: TextRendering.visible(preview.name))
                .font(theme.typography.font())
                .foregroundStyle(theme.ink)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
                .accessibilityIdentifier("file-preview-name")
            Text(verbatim: TextRendering.visible(FilesFormatting.meta(
                preview, root: root, home: session.home ?? session.source?.home, now: System.date())))
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("file-preview-meta")
            if let notice {
                Text(notice)
                    .font(theme.typography.font(offset: -1.5))
                    .foregroundStyle(theme.yellow)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("file-preview-notice")
            }
            if find.open { findField }
            controls
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            // Edit › Find reaches the preview through `findRequest`; this keeps ⌘F working while the preview has
            // focus even where the menu routes it elsewhere. Opening twice is harmless.
            Button(action: openFind) { Color.clear.frame(width: 0, height: 0) }
                .buttonStyle(.plain).opacity(0).allowsHitTesting(false)
                .keyboardShortcut(focused && findable ? KeyboardShortcut("f", modifiers: .command) : nil)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preview-header")
    }

    private var icon: String {
        switch preview.kind {
        case .folder: "folder"
        case .image: "photo"
        default: preview.entry?.isDirectory == true ? "folder" : "doc"
        }
    }

    private var isFolder: Bool {
        if case .folder = preview.kind { return true }
        return preview.entry?.isDirectory == true
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 4) {
            if wrappable {
                Button { session.previewWrap.toggle() } label: {
                    FileWrapGlyph().frame(width: 14, height: 14)
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: session.previewWrap))
                .help(session.previewWrap ? "Don’t wrap lines" : "Wrap lines")
                .accessibilityLabel("Wrap lines")
                .accessibilityValue(session.previewWrap ? "on" : "off")
                .accessibilityIdentifier("file-preview-wrap")
            }
            if case .markdown = preview.kind {
                Button("Rendered") { rendered.toggle() }
                    .buttonStyle(FilePreviewIconButtonStyle(on: rendered))
                    .help(rendered ? "Show the Markdown source" : "Show the Markdown rendered")
                    .accessibilityValue(rendered ? "on" : "off")
                    .accessibilityIdentifier("file-preview-rendered")
            }
            if !isFolder {
                Button(action: copyPath) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: false))
                .keyboardShortcut(focused ? KeyboardShortcut("c", modifiers: [.command, .option]) : nil)
                .help("Copy path · ⌥⌘C")
                .accessibilityLabel("Copy path")
                .accessibilityIdentifier("file-preview-copy-path")
            }
        }
        if editable {
            Button("Open in editor") { files.openInEditor(session.id, path: preview.path) }
                .buttonStyle(FilePreviewButtonStyle())
                .keyboardShortcut(focused ? KeyboardShortcut("o", modifiers: .command) : nil)
                .help("Open in editor · ⌘O")
                .accessibilityIdentifier("file-preview-open-editor")
        }
    }

    private var findField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.muted)
            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focus, equals: .find)
                // The field editor submits ⏎ and ⇧⏎ alike; the held modifier picks the direction, as the terminal's
                // search field does.
                .onSubmit { if NSEvent.modifierFlags.contains(.shift) { find.previous() } else { find.next() } }
                .onKeyPress(.escape) { closeFind(); return .handled }
                .onExitCommand { closeFind() }
                .onChange(of: find.query) { find.current = 0; find.step += 1 }
                .accessibilityIdentifier("file-preview-find")
            if !find.query.isEmpty {
                Text(find.total == 0 ? "none" : "\(min(find.current + 1, find.total)) of \(find.total)")
                    .foregroundStyle(theme.muted)
                    .fixedSize()
                    .accessibilityIdentifier("file-preview-find-count")
            }
        }
        .font(theme.typography.font(offset: -1))
        .padding(.horizontal, 8)
        .frame(width: 190, height: 22)
        .background(theme.window, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border))
    }

    private var wrappable: Bool {
        switch preview.kind {
        case .text: true
        case .markdown: !rendered
        case .tooLarge(_, let head): head != nil
        default: false
        }
    }

    private var findable: Bool { preview.findable }

    private var editable: Bool {
        switch preview.kind {
        case .folder, .image: false
        default: preview.entry?.isDirectory != true
        }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        let owner = ObjectIdentifier(preview)
        switch preview.kind {
        case .loading:
            ZStack {
                if spinner { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                // A read that answers at once shows no spinner flashing before its text.
                try? await System.sleep(for: .milliseconds(300), "files.preview-spinner")
                spinner = true
            }
        case .text(let text, let language):
            FileTextPreview(owner: owner, content: .text(text, language: language), wrap: session.previewWrap,
                            find: find, highlightsQuery: find.open)
        case .markdown(let text):
            if rendered {
                ScrollView {
                    ChatMarkdown(text: text, fillWidth: true, color: theme.ink)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.chatSearchQuery, find.open ? find.query : "")
                .accessibilityIdentifier("file-preview-markdown")
            } else {
                FileTextPreview(owner: owner, content: .text(text, language: "markdown"), wrap: session.previewWrap,
                                find: find, highlightsQuery: find.open)
            }
        case .image(let data, let pixels):
            FileImagePreview(data: data, revision: preview.revision, pixelSize: pixels, actualSize: $actualSize,
                             focused: focused)
        case .folder(let summary):
            FileFolderPreview(path: preview.path, entry: preview.entry, summary: summary,
                              openFolder: { session.pin(preview.path) },
                              changeDirectory: { files.changeDirectory(session.id, to: preview.path) },
                              copyPath: copyPath, focused: focused)
        case .tooLarge(let size, let head):
            if let head {
                VStack(spacing: 0) {
                    headBar("First 64 KB of \(FilesFormatting.size(size)) · the terminal has the rest")
                    FileTextPreview(owner: owner, content: .text(head, language: preview.name), wrap: session.previewWrap,
                                    find: find, highlightsQuery: find.open)
                }
            } else {
                FileLargeNotice(title: "Too large to preview here",
                                detail: "Text over 2 MB is read on request. The first 64 KB shows below; the terminal has the rest.",
                                loading: headRequest != nil, showHead: { headRequest = System.uuid() },
                                openTerminal: openTerminal)
            }
        case .binary(let size, let head):
            if let head {
                VStack(spacing: 0) {
                    headBar("First \(FilesFormatting.size(UInt64(head.count))) of \(FilesFormatting.size(size)) as hex · the terminal has the rest")
                    FileTextPreview(owner: owner, content: .lines(FileTextLines.hexLines(head)), wrap: false,
                                    find: find, highlightsQuery: find.open)
                }
            } else {
                FileLargeNotice(title: "Binary file",
                                detail: "Binary content has no text preview. The first 64 KB shows below as hex; the terminal has the rest.",
                                loading: headRequest != nil, showHead: { headRequest = System.uuid() },
                                openTerminal: openTerminal)
            }
        case .error(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(theme.muted)
                Text(message)
                    .font(theme.typography.font(offset: -0.5))
                    .foregroundStyle(theme.ink.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("file-preview-error")
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
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

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.path, forType: .string)
    }

    private func openTerminal() {
        files.switchMode(session.id, to: .terminal)
    }

    private func openFind() {
        guard findable else { return }
        find.open = true
        focus = .find
    }

    private func closeFind() {
        find.open = false
        focus = .content
    }
}

/// "Too large to preview here" / "Binary file", with Show first 64 KB and Open in terminal (F2d).
private struct FileLargeNotice: View {
    @Environment(\.chatTheme) private var theme
    let title: String
    let detail: String
    let loading: Bool
    let showHead: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(theme.muted)
            Text(title)
                .font(theme.typography.font(offset: -0.5))
                .foregroundStyle(theme.ink.opacity(0.85))
                .accessibilityIdentifier("file-preview-unpreviewable")
            Text(detail)
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Show first 64 KB", action: showHead)
                    .buttonStyle(FilePreviewButtonStyle())
                    .disabled(loading)
                    .accessibilityIdentifier("file-preview-show-head")
                Button("Open in terminal", action: openTerminal)
                    .buttonStyle(FilePreviewButtonStyle())
                    .help("Show this tab’s terminal")
                    .accessibilityIdentifier("file-preview-open-terminal")
            }
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The design's `.btn`: a quiet filled button, or text only beside others (`prominent` false).
struct FilePreviewButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, prominent: prominent)
    }

    private struct Styled: View {
        @Environment(\.chatTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let prominent: Bool

        var body: some View {
            configuration.label
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(prominent ? theme.ink.opacity(0.9) : theme.ink.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 22)
                .modifier(Ground(prominent: prominent, pressed: configuration.isPressed))
                .opacity(enabled ? 1 : 0.5)
        }
    }
}

extension FilePreviewButtonStyle {
    /// A prominent button is a glass capsule with Liquid Glass (as the chat's reply buttons are), else a faint well.
    fileprivate struct Ground: ViewModifier {
        @Environment(\.chatTheme) private var theme
        let prominent: Bool
        let pressed: Bool

        func body(content: Content) -> some View {
            if LiquidGlassStore.shared.active {
                content.liquidGlass(in: Capsule(), interactive: true, enabled: prominent).contentShape(Capsule())
            } else {
                content.background(prominent ? theme.ink.opacity(pressed ? 0.14 : 0.07) : .clear,
                                   in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

/// The design's `.hb`: a 22 pt header control, lit while its option is on.
struct FilePreviewIconButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, on: on)
    }

    private struct Styled: View {
        @Environment(\.chatTheme) private var theme
        let configuration: Configuration
        let on: Bool

        var body: some View {
            configuration.label
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(on ? theme.ink : theme.ink.opacity(0.6))
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 22)
                .background {
                    let fill = on || configuration.isPressed ? theme.ink.opacity(0.08) : Color.clear
                    if LiquidGlassStore.shared.active { Capsule().fill(fill) } else { RoundedRectangle(cornerRadius: 4).fill(fill) }
                }
                .contentShape(Capsule())
        }
    }
}

/// The design's wrap glyph (three lines, the middle one turning back under itself), drawn on a 14 pt grid.
struct FileWrapGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 14
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            var path = Path()
            path.move(to: point(2, 3.5)); path.addLine(to: point(12, 3.5))
            path.move(to: point(2, 7)); path.addLine(to: point(9.5, 7))
            path.addCurve(to: point(9.5, 11), control1: point(12.17, 7), control2: point(12.17, 11))
            path.addLine(to: point(8, 11))
            path.move(to: point(2, 10.5)); path.addLine(to: point(5, 10.5))
            path.move(to: point(9.5, 9.5)); path.addLine(to: point(8, 11)); path.addLine(to: point(9.5, 12.5))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
