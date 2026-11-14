import AppKit
import AVKit
import SwiftUI

/// The right pane: what the selected row is (F2a, F2d). A header as tall as the list's column header names it and
/// carries its controls; the body draws the kind the loader decided. Content and header always come from the same
/// `FilePreviewState`, and each state gets its own view identity, so a new selection never shows the last file's
/// text, scroll or find. One exception: an image replacing an image keeps the last picture until its own is decoded
/// (`FilesSession.imageHandoff`), so two versions of a picture compare without a blank frame between them.
struct FilePreviewPane: View {
    @Environment(\.appTypography) private var typography
    let session: FilesSession
    /// The folder the list shows (the files header's crumbs): on one column, the file's folder is named from it.
    var root: String? = nil

    private struct LoadKey: Hashable {
        let preview: ObjectIdentifier?
        let source: ObjectIdentifier?
        /// Previews turned back on read the file the pane only named.
        let previews: Bool
    }

    var body: some View {
        let theme = ChatThemeStore.shared.current
        let source = session.source
        Group {
            if let preview = session.preview {
                FilePreviewDetail(session: session, preview: preview, root: root)
                    .id(ObjectIdentifier(preview))
            } else {
                Text("Select a file to preview it")
                    .font(typography, .label)
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
        .task(id: LoadKey(preview: session.preview.map(ObjectIdentifier.init), source: source.map { ObjectIdentifier($0) },
                          previews: FilesSession.previews)) {
            guard let preview = session.preview, let source else { return }
            await FilePreviewLoader.load(preview, from: source)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preview")
    }
}

extension FilesFormatting {
    /// The header's muted line after the name: "4.1 KB · modified 6m ago", "48 KB · PNG · 512 × 512", "folder ·
    /// 5,120 items · 48 MB", and for text too large to show "9.6 MB" (F2d). The folder and language aren't repeated:
    /// the name's tooltip and Copy path give the path.
    @MainActor static func meta(_ preview: FilePreviewState, now: Date) -> String {
        if case .folder(let summary) = preview.kind {
            guard let summary else { return "folder" }
            let total = summary.files + summary.folders
            let items = count(total) + (summary.truncated ? "+" : "")
            return "folder · \(items) \(total == 1 ? "item" : "items") · \(size(summary.bytes))"
        }
        if preview.entry?.isDirectory == true { return "folder" }
        var parts: [String] = []
        if let bytes = preview.revision?.size ?? preview.entry?.size { parts.append(size(bytes)) }
        if let encoding = preview.encoding { parts.append(encoding) }
        if case .binary(_, _, let format?) = preview.kind { parts.append(format) }
        if case .image(_, let pixels) = preview.kind {
            if let kind = kindName(preview.name) { parts.append(kind) }
            parts.append("\(Int(pixels.width)) × \(Int(pixels.height))")
            return parts.joined(separator: " · ")
        }
        let tooLarge = if case .tooLarge = preview.kind { true } else { false }
        if !tooLarge, let modified = preview.revision?.modified ?? preview.entry?.modified {
            parts.append(self.modified(modified, at: now))
        }
        return parts.joined(separator: " · ")
    }
}

/// One selection's header and body. Its view state (find, fit) belongs to this file only; whether Markdown shows
/// rendered is the tab's choice (`FilesSession.previewRendered`), and a file's folded sections stay with the tab too.
private struct FilePreviewDetail: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.appTypography) private var typography
    /// The floating mode switch's room, which the files header leaves when this bar takes its place.
    @Environment(\.filesHeaderAccessory) private var accessory
    let session: FilesSession
    let preview: FilePreviewState
    var root: String?
    @State private var find = FilePreviewFind()
    @State private var zoom = FileImageZoom.fit
    @State private var headRequest: UUID?
    @State private var spinner = false
    @State private var video = FilePreviewVideo()
    @State private var hex = FileHexHolder()
    /// A video's bytes were asked for in place of its Play.
    @State private var showBytes = false
    @FocusState private var focus: Field?
    /// The text view (`FileTextDocument`) has the keyboard: AppKit's, so SwiftUI's `focus` is nil meanwhile.
    @State private var textFocused = false

    enum Field: Hashable { case content, find }

    private var files: FilesCoordinator { TerminalRuntime.shared.files }
    private var focused: Bool { session.previewFocused }

    var body: some View {
        VStack(spacing: 0) {
            header
            // On glass the rule's room without the rule, so the title stays level with the list's column names.
            Rectangle().fill(LiquidGlassStore.shared.active ? Color.clear : theme.border).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { FilesScrollEdge() }
                .contentShape(Rectangle())
                .focusable()
                .focusEffectDisabled()
                .focused($focus, equals: .content)
                // A click in the text is the text view's (its selection); elsewhere the pane takes the keyboard.
                .simultaneousGesture(TapGesture().onEnded { if !showsText, focus != .content { focus = .content } })
                .onKeyPress(.escape) {
                    guard find.open else { return .ignored }
                    closeFind()
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard case .binary = preview.kind, let document = hex.document else { return .ignored }
                    return FileHexPreview.key(press, in: document)
                }
        }
        .onChange(of: focus) { session.previewFocused = focus != nil || textFocused }
        .onChange(of: textFocused) { session.previewFocused = focus != nil || textFocused }
        .onChange(of: session.findRequest) {
            guard session.previewFocused else { return }
            openFind()
        }
        .onDisappear {
            if focus != nil { session.previewFocused = false }
            video.stop()
            hex.close()
        }
        .task(id: headRequest) {
            guard headRequest != nil, let source = session.source else { return }
            await FilePreviewLoader.loadHead(preview, from: source)
        }
    }

    // MARK: Header

    private var header: some View {
        // One column: the files header gives way to this one, which is then the pane's bar and looks like it.
        let bar = session.drilled && session.tab == .files
        return HStack(spacing: 10) {
            // Led by the way back, where the files header's label was, the name where its path started (12 + 12 in).
            if bar { FilesBackButton(session: session).padding(.trailing, 2) }
            // As the bar, the list and its path are out of sight: the file's folder, dimmed, before its name (relative to
            // the list's folder, as its crumbs show it), while there is room; it gives way before the name does.
            // The folder and the name in one stack: the folder's gap goes with it, so a name alone starts where it would.
            HStack(spacing: 0) {
                if bar {
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: TextRendering.visible(FilesFormatting.location(of: preview.path, root: root, home: session.home)) + " /")
                            .font(typography, .content)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                            .help(FilesPath.parent(preview.path) ?? preview.path)
                            .accessibilityIdentifier("file-preview-location")
                            .padding(.trailing, 10)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(0.5)
                }
                Text(verbatim: TextRendering.visible(preview.name))
                    .font(typography, .content)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                    .help(TextRendering.visible(preview.path))
                    .accessibilityIdentifier("file-preview-name")
            }.layoutPriority(1)
            if !isFolder {
                Button(action: copyPath) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: false))
                .keyboardShortcut(focused ? KeyboardShortcut("c", modifiers: [.command, .option]) : nil)
                .help("Copy path · ⌥⌘C")
                .accessibilityLabel("Copy path")
                .accessibilityIdentifier("file-preview-copy-path")
                .layoutPriority(1)
            }
            Text(verbatim: TextRendering.visible(FilesFormatting.meta(preview, now: System.date())))
                .font(typography, .body)
                .foregroundStyle(theme.muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("file-preview-meta")
            if find.open { findField }
            // The buttons keep their room before the folder takes any; with previews off there is no content to set.
            if !infoOnly { controls.fixedSize().layoutPriority(1) }
            // As the bar, the files header's trailing end too: the views toggle where it stood, then the mode switch's
            // room, so neither moves when a file takes the list's place.
            if bar {
                // The files header's spacing (12), so the toggle lands where it was.
                HStack(spacing: 12) {
                    if session.canShowBoth { FilesViewsToggle(session: session).glassControlGroup() }
                    if let accessory { accessory.fixedSize() }
                }.layoutPriority(1)
            }
        }
        .padding(.leading, bar ? 12 : 14).padding(.trailing, bar ? 12 : 14)
        // The list's column header beside it is as tall (FilesColumns.headerHeight); as the bar, the files header is.
        .frame(height: bar ? FilesHeader.height(typography) : FilesColumns.headerHeight(typography))
        .background { if bar && !LiquidGlassStore.shared.active { Chrome.window } }
        .overlay(alignment: .bottom) { if bar && !LiquidGlassStore.shared.active { Chrome.palette.separator.frame(height: 1) } }
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

    private var isFolder: Bool {
        if case .folder = preview.kind { return true }
        return preview.entry?.isDirectory == true
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 4) {
            if wrappable {
                Button { session.previewWrap = !wrap } label: {
                    FileWrapGlyph().frame(width: 14, height: 14)
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: wrap))
                .help(wrap ? "Don’t wrap lines" : "Wrap lines")
                .accessibilityLabel("Wrap lines")
                .accessibilityValue(wrap ? "on" : "off")
                .accessibilityIdentifier("file-preview-wrap")
            }
            if rendered, case .markdown(let text) = preview.kind {
                let document = FileMarkdownDocuments.document(text)
                if !document.headings.isEmpty {
                    FileMarkdownOutlineButton(session: session, path: preview.path, document: document)
                }
            }
            if case .markdown = preview.kind {
                Button { session.previewRendered = !rendered } label: {
                    Image(systemName: "eye").font(.system(size: 11))
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: rendered))
                .help(rendered ? "Show the Markdown source" : "Show the Markdown rendered")
                .accessibilityLabel("Rendered")
                .accessibilityValue(rendered ? "on" : "off")
                .accessibilityIdentifier("file-preview-rendered")
            }
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
        .font(typography, .label)
        .padding(.horizontal, 8)
        .frame(width: 190, height: 22)
        .background(theme.window, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border))
    }

    /// This tab's wrap choice, else Settings' (Files › Wrap lines).
    private var wrap: Bool { session.previewWrap ?? TerminalRuntime.shared.preferences.filesWrapLines }
    private var lineNumbers: Bool { TerminalRuntime.shared.preferences.filesLineNumbers }
    /// This tab's choice for Markdown, else Settings' (Files › Render Markdown).
    private var rendered: Bool { session.previewRendered ?? TerminalRuntime.shared.preferences.filesRenderMarkdown }

    private var wrappable: Bool {
        switch preview.kind {
        case .text: true
        case .markdown: !rendered
        case .tooLarge(_, let head): head != nil
        default: false
        }
    }

    private var findable: Bool { preview.findable && !infoOnly }

    /// The preview is the text view (`FileTextDocument`): text, Markdown's source, a large file's first 64 KB.
    private var showsText: Bool {
        guard !infoOnly else { return false }
        switch preview.kind {
        case .text: return true
        case .markdown: return !rendered
        case .tooLarge(_, let head): return head != nil
        default: return false
        }
    }

    private func textFocusChanged(_ focused: Bool) {
        // After this update: the pane's focus is SwiftUI state.
        DispatchQueue.main.async { if textFocused != focused { textFocused = focused } }
    }

    /// Esc in the text closes find while it is open; otherwise it is the files pane's (back to the list).
    private func escapeText() -> Bool {
        guard find.open else { return false }
        closeFind()
        return true
    }

    /// Settings › Files › Disable file previews: a file shows what its listing entry says of it (its kind, size and
    /// date), never its contents, whatever was read before the setting changed. A folder still shows its summary.
    private var infoOnly: Bool { !FilesSession.previews && !isFolder }

    // MARK: Body

    private var loading: some View {
        ZStack {
            if spinner { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // A read that answers at once shows no spinner flashing before its text.
            try? await System.sleep(for: .milliseconds(300), "files.preview-spinner")
            spinner = true
        }
    }

    @ViewBuilder private var content: some View {
        if infoOnly { infoBody } else { kindBody }
    }

    /// Previews off: the file's kind, size and date, and Download…; nothing of it is read to show this.
    private var infoBody: some View {
        let video = FilePreviewVideo.isVideo(preview.name)
        let image = FilePreviewLoader.isImageName(preview.name)
        let kind = FilesFormatting.kindName(preview.name) ?? (video ? "Video" : image ? "Image" : "File")
        let facts = [preview.entry.map { FilesFormatting.size($0.size) },
                     (preview.entry?.modified).map { FilesFormatting.modified($0, at: System.date()) }].compactMap { $0 }
        return VStack(spacing: 10) {
            Image(systemName: video ? "film" : image ? "photo" : "doc")
                .font(.system(size: 24, weight: .ultraLight)).foregroundStyle(theme.muted)
            Text(kind)
                .font(typography, .label)
                .foregroundStyle(theme.ink.opacity(0.85))
                .accessibilityIdentifier("file-preview-info")
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(typography, .body)
                    .foregroundStyle(theme.muted)
                    .accessibilityIdentifier("file-preview-info-facts")
            }
            Text("Previews are off in Settings › Files.")
                .font(typography, .body)
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Download…", action: download)
                .buttonStyle(FilePreviewButtonStyle(prominent: false))
                .accessibilityIdentifier("file-preview-download")
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var kindBody: some View {
        let owner = ObjectIdentifier(preview)
        switch preview.kind {
        case .loading:
            if FilePreviewLoader.isImageName(preview.name), let handoff = session.imageHandoff {
                // Another image is being read in place of the last: its picture stays until this one's is ready.
                FileImagePreview(data: nil, revision: nil, pixelSize: handoff.pixelSize, zoom: $zoom, focused: focused,
                                 activate: { if focus != .content { focus = .content } }, handoff: handoff)
            } else {
                loading
            }
        case .text(let text, let language):
            FileTextPreview(owner: owner, content: .text(text, language: language), wrap: wrap, lineNumbers: lineNumbers,
                            find: find, highlightsQuery: find.open, keeper: .init(preview: preview, key: .text),
                            focusChanged: textFocusChanged, wantsFocus: focus == .content, escape: escapeText)
        case .markdown(let text):
            if rendered {
                FileMarkdownView(session: session, path: preview.path, text: text,
                                 keeper: .init(preview: preview, key: .rendered))
                    .environment(\.chatSearchQuery, find.open ? find.query : "")
                    .accessibilityIdentifier("file-preview-markdown")
            } else {
                FileTextPreview(owner: owner, content: .text(text, language: "markdown"), wrap: wrap, lineNumbers: lineNumbers,
                                find: find, highlightsQuery: find.open, keeper: .init(preview: preview, key: .text),
                            focusChanged: textFocusChanged, wantsFocus: focus == .content, escape: escapeText)
            }
        case .image(let data, let pixels):
            FileImagePreview(data: data, revision: preview.revision, pixelSize: pixels, zoom: $zoom, focused: focused,
                             toggleFullScreen: {
                                 FileImageFullScreen.show(name: preview.name, data: data, revision: preview.revision,
                                                          pixelSize: pixels, from: NSApp.keyWindow)
                             },
                             activate: { if focus != .content { focus = .content } },
                             handoff: session.imageHandoff,
                             drew: { session.drawnImage = FileImageHandoff(owner: owner, image: $0, pixelSize: pixels) })
        case .folder(let summary):
            FileFolderPreview(path: preview.path, entry: preview.entry, summary: summary,
                              openFolder: { session.pin(preview.path) },
                              changeDirectory: { files.changeDirectory(session.id, to: preview.path) },
                              copyPath: copyPath, focused: focused)
        case .tooLarge(let size, let head):
            if let head {
                VStack(spacing: 0) {
                    headBar("First 64 KB of \(FilesFormatting.size(size))")
                    FileTextPreview(owner: owner, content: .text(head, language: preview.name), wrap: wrap, lineNumbers: lineNumbers,
                                    find: find, highlightsQuery: find.open, keeper: .init(preview: preview, key: .head),
                            focusChanged: textFocusChanged, wantsFocus: focus == .content, escape: escapeText)
                }
            } else {
                FileLargeNotice(title: "Too large to preview here",
                                detail: "Text over 2 MB is read on request: show its first 64 KB here, or download it.",
                                loading: headRequest != nil, showHead: { headRequest = System.uuid() }, download: download)
            }
        case .binary(let size, let head, _):
            if FilePreviewVideo.isVideo(preview.name), !showBytes {
                videoBody
            } else {
                FileHexPreview(document: hex.document(preview, size: size, head: head, source: session.source),
                               focused: focused, activate: { if focus != .content { focus = .content } },
                               download: download,
                               reload: {
                                   guard let source = session.source else { return }
                                   Task { await FilePreviewLoader.reload(preview, from: source) }
                               })
            }
        case .error(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(theme.muted)
                Text(message)
                    .font(typography, .label)
                    .foregroundStyle(theme.ink.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("file-preview-error")
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A video: Play until it is asked for (nothing is read before), then the system player (`FilePreviewVideo`).
    @ViewBuilder private var videoBody: some View {
        if case .playing(let player) = video.stage {
            VideoPlayer(player: player)
                .accessibilityIdentifier("file-preview-video-player")
        } else {
            let remote = session.source?.endpoint.isLocal == false
            let detail: String = switch video.stage {
            case .failed(let message): message
            case .copying: "Copying it to this Mac; the row below shows how far."
            default: remote ? "Play copies it to this Mac first, then plays the copy; leaving the preview removes it."
                : "Nothing is read until Play."
            }
            VStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(theme.muted)
                Text("Video")
                    .font(typography, .label)
                    .foregroundStyle(theme.ink.opacity(0.85))
                    .accessibilityIdentifier("file-preview-video")
                Text(detail)
                    .font(typography, .body)
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("file-preview-video-detail")
                HStack(spacing: 8) {
                    Button { video.play(preview.path, in: session) } label: {
                        ReservedText(text: video.copying ? "Copying…" : "Play", variants: ["Play", "Copying…"])
                    }
                        .buttonStyle(FilePreviewButtonStyle())
                        .disabled(video.copying)
                        .accessibilityIdentifier("file-preview-play")
                    Button("Show bytes") { showBytes = true }
                        .buttonStyle(FilePreviewButtonStyle(prominent: false))
                        .disabled(video.copying)
                        .accessibilityIdentifier("file-preview-show-bytes")
                    Button("Download…", action: download)
                        .buttonStyle(FilePreviewButtonStyle(prominent: false))
                        .accessibilityIdentifier("file-preview-download")
                }
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Download…", action: download)
                .buttonStyle(FilePreviewButtonStyle())
                .accessibilityIdentifier("file-preview-download")
        }
        .font(typography, .body)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    /// Download… for the previewed file (`FilesCoordinator.download`).
    private func download() {
        files.download(session.id, paths: [preview.path], window: NSApp.keyWindow)
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.path, forType: .string)
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

/// "Too large to preview here", with Show first 64 KB and Download… (F2d).
private struct FileLargeNotice: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme
    let title: String
    let detail: String
    let loading: Bool
    let showHead: () -> Void
    let download: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc").font(.system(size: 24, weight: .ultraLight)).foregroundStyle(theme.muted)
            Text(title)
                .font(typography, .label)
                .foregroundStyle(theme.ink.opacity(0.85))
                .accessibilityIdentifier("file-preview-unpreviewable")
            Text(detail)
                .font(typography, .body)
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Show first 64 KB", action: showHead)
                    .buttonStyle(FilePreviewButtonStyle())
                    .disabled(loading)
                    .accessibilityIdentifier("file-preview-show-head")
                Button("Download…", action: download)
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                    .accessibilityIdentifier("file-preview-download")
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
        @Environment(\.appTypography) private var typography
        @Environment(\.chatTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        let configuration: Configuration
        let prominent: Bool

        var body: some View {
            configuration.label
                .font(typography, .body)
                .foregroundStyle(prominent ? theme.ink.opacity(0.9) : theme.ink.opacity(0.6))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 22)
                .hoverFill(LiquidGlassStore.shared.active ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
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
        @Environment(\.appTypography) private var typography
        @Environment(\.chatTheme) private var theme
        let configuration: Configuration
        let on: Bool

        var body: some View {
            configuration.label
                .font(typography, .body)
                .foregroundStyle(on ? theme.ink : theme.ink.opacity(0.6))
                .fixedSize()
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 22)
                .hoverFill(LiquidGlassStore.shared.active ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
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
