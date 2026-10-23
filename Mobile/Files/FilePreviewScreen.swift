import SwiftUI
import UIKit

/// What F2 can do beyond showing the file, from the tab it was opened in: Ask (attach the file to the tab's chat
/// composer, naming the tab's agent; nil without one), Open in terminal (a cd in the tab's shell; nil when the tab's pane
/// is not at a shell), and Back.
struct FilesPreviewActions {
    /// The tab's agent ("claude"), for "Ask claude".
    var agent: String?
    var ask: ((FilePreview) -> Void)?
    /// Types the `cd`; returns why it did not ("The terminal is busy."), nil when it did.
    var openInTerminal: (() -> String?)?
    /// The screen Back returns to ("Files", "Review").
    var back = "Files"
    var pop: () -> Void = {}
}

/// F2: a file pushed over the tab (its header, capsule and the modes' bar go with the push). The back pill names the
/// screen it returns to; the title is the file's name, the subtitle its folder, size, age and kind; "…" holds Wrap lines
/// (or Markdown's source), Copy path, Copy contents, Share, Attach to chat and Open in terminal. Code has line numbers
/// and the syntax palette, scrolls both ways and zooms with a pinch (kept as the diff viewer's, `CodeFontSize`); Find
/// counts and steps through matches; Ask attaches the file to the tab's chat. Markdown renders as chat does, images open
/// in the attachment viewer, a binary shows its kind and size with Share, a long text its head with Load all.
struct FilePreviewScreen: View {
    @State private var preview: FilePreview
    let host: TabsHost
    /// The breadcrumb's root, for the subtitle's folder ("src" under the repository).
    let root: String?
    let actions: FilesPreviewActions
    /// A folder's screen (the path turned out to be one): the listing, pushed.
    var folder: (() -> AnyView)?
    private let fonts: CodeFontStore
    @State private var fontSize: Double
    @State private var pinchBase: Double?
    @State private var wrap = false
    @State private var showsSource = false
    @State private var finding = false
    @State private var find = FileFind()
    @State private var sharing: FilesShareItem?
    @State private var viewing = false
    @State private var problem: String?
    @FocusState private var findFocused: Bool
    @Environment(\.tabsColumnWidth) private var column

    init(preview: FilePreview, host: TabsHost, root: String?, actions: FilesPreviewActions, fonts: CodeFontStore = .standard,
         folder: (() -> AnyView)? = nil) {
        _preview = State(initialValue: preview)
        self.host = host
        self.root = root
        self.actions = actions
        self.fonts = fonts
        self.folder = folder
        _fontSize = State(initialValue: CodeFontSize.stored(fonts))
    }

    var body: some View {
        // A folder is its listing's screen, with its own header and bar row.
        if preview.content == .folder, let folder {
            folder()
        } else {
            screen
        }
    }

    private var screen: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .tabsPushedScreen()
        .toolbar {
            TabsScreenHeader(title: preview.name, column: column) {
                TabsBackPill(label: actions.back, action: actions.pop)
            } subtitle: {
                Text(subtitle)
            } trailing: {
                if preview.content != .folder { menu }
            }
        }
        .task { await preview.load() }
        .sheet(item: $sharing) { item in
            FilesActivityView(items: [item.url]).ignoresSafeArea()
                // The sheet closed: the copy goes.
                .onDisappear { item.remove() }
        }
        .fullScreenCover(isPresented: $viewing) {
            if case .image(let data) = preview.content {
                MobileAttachmentPreview(attachment: ChatAttachment(name: preview.name, kind: .image, size: data.count, path: preview.path),
                                        read: { _ in data })
            }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// "src · 1.8 KB · 25m ago · TypeScript": the folder under the root, the size, the age, the kind.
    private var subtitle: String {
        Self.subtitle(path: preview.path, root: root, home: host.home, revision: preview.revision, now: System.date())
    }

    static func subtitle(path: String, root: String?, home: String?, revision: FileRevision?, now: Date) -> String {
        var parts = [FilesFormatting.location(of: path, root: root, home: home)]
        if let size = revision?.size { parts.append(FilesFormatting.size(size)) }
        if let ago = FilesText.ago(revision?.modified, now: now) { parts.append(ago) }
        if let kind = FilesFormatting.kindName(FilesPath.name(path)) { parts.append(kind) }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch preview.content {
        case .loading, .folder:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading \(preview.name)")
        case .text:
            code
        case .markdown(let text, _):
            if showsSource {
                code
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MobileChatMarkdownView(text: text)
                            .textSelection(.enabled)
                            .environment(\.openURL, MobileChatMarkdown.openURL)
                        if preview.markdownCapped {
                            Button("Show source for all of it") { showsSource = true }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.dispatchPink)
                                .buttonStyle(.plain)
                                .padding(.top, 8)
                        }
                        truncation
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("file-markdown")
            }
        case .image(let data):
            FilesImageView(data: data, name: preview.name) { viewing = true }
        case .binary:
            binary
        case .failed(let message):
            FilesStateView(symbol: "exclamationmark.triangle", title: "\(preview.name) could not be shown", message: message,
                           action: ("Try again", { Task { await preview.load() } }))
        }
    }

    private var code: some View {
        FileCodeView(lines: preview.lines, longest: preview.longest, fontSize: fontSize, wrap: wrap, find: find,
                     footer: AnyView(truncation))
            .simultaneousGesture(pinch)
    }

    /// A long text's footer: how much shows, and Load all.
    @ViewBuilder private var truncation: some View {
        if preview.truncated, let size = preview.size {
            VStack(spacing: 8) {
                Text("Showing the first \(FilesFormatting.size(FilePreview.headLimit)) of \(FilesFormatting.size(size))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if preview.canLoadAll {
                    Button {
                        Task { await preview.loadAll() }
                    } label: {
                        HStack(spacing: 6) {
                            if preview.loadingAll { ProgressView().controlSize(.small) }
                            Text("Load all").font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .disabled(preview.loadingAll)
                } else {
                    Text("Too large to show whole here.").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("file-truncated")
        }
    }

    private var binary: some View {
        VStack(spacing: 12) {
            Image(systemName: FilesText.symbol(name: preview.name))
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(preview.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text([FilesFormatting.kindName(preview.name) ?? "Binary file", preview.size.map(FilesFormatting.size)]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("This file has no text to show.").font(.footnote).foregroundStyle(.tertiary)
            Button(action: share) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-binary")
    }

    // MARK: Bars

    /// Ask (with the tab's agent) on the leading side and Find on the trailing one; Find's field in their place.
    @ViewBuilder private var bottomBar: some View {
        if finding {
            findBar
        } else if hasText || (actions.ask != nil && asks) {
            HStack(spacing: 10) {
                if let ask = actions.ask, let agent = actions.agent, asks {
                    Button { ask(preview) } label: {
                        Label("Ask \(agent)", systemImage: "paperclip")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .accessibilityHint("Attaches \(preview.name) to the chat")
                }
                Spacer(minLength: 0)
                if hasText {
                    Button {
                        finding = true
                        findFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Find in file")
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    /// Ask and Attach to chat: for what has loaded and is not a binary (which offers Share only).
    private var asks: Bool {
        switch preview.content {
        case .loading, .binary, .failed, .folder: false
        default: true
        }
    }

    /// Code is on screen (text, or Markdown's source): Find has lines to search.
    private var hasText: Bool {
        switch preview.content {
        case .text: true
        case .markdown: showsSource
        default: false
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in \(preview.name)", text: $find.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($findFocused)
                    .onSubmit { find.next(); findFocused = true }
                    .accessibilityLabel("Find")
                Text(find.position)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("find-position")
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular, in: Capsule())
            HStack(spacing: 0) {
                Button { find.previous() } label: { Image(systemName: "chevron.up").frame(width: 40, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Previous match")
                Button { find.next() } label: { Image(systemName: "chevron.down").frame(width: 40, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Next match")
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.plain)
            .disabled(find.matches.isEmpty)
            .glassEffect(.regular.interactive(), in: Capsule())
            Button {
                finding = false
                findFocused = false
                find.query = ""
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Done finding")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .onChange(of: find.query) { find.search(preview.lines) }
        .onChange(of: preview.version) { find.search(preview.lines) }
    }

    private var menu: some View {
        Menu {
            switch preview.content {
            case .text:
                Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.alignleft") }
            case .markdown:
                Toggle(isOn: $showsSource) { Label("Show source", systemImage: "chevron.left.forwardslash.chevron.right") }
                if showsSource { Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.alignleft") } }
            default:
                EmptyView()
            }
            Section {
                Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = preview.path }
                Button("Copy contents", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = preview.text }
                    .disabled(preview.text == nil || preview.truncated)
                Button("Share", systemImage: "square.and.arrow.up", action: share)
                    .disabled(preview.content == .loading)
            }
            Section {
                if let ask = actions.ask, asks {
                    Button("Attach to chat", systemImage: "paperclip") { ask(preview) }
                }
                if let open = actions.openInTerminal {
                    Button("Open in Terminal", systemImage: "apple.terminal") { problem = open() }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("More")
    }

    // MARK: Actions

    /// Share: the file's bytes (read whole when only its head is loaded) as a file named as on the host.
    private func share() {
        Task {
            do {
                let data = try await preview.bytes()
                sharing = try FilesShareItem.write(data, name: preview.name)
            } catch {
                problem = (error as? FilesSourceError)?.message ?? error.localizedDescription
            }
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? fontSize
                if pinchBase == nil { pinchBase = base }
                let size = CodeFontSize.pinched(base: base, scale: value.magnification)
                if size != fontSize { fontSize = size }
            }
            .onEnded { _ in
                pinchBase = nil
                fonts.save(fontSize)
            }
    }
}

/// F2's code: line numbers in the gutter and the lines in the syntax palette, one row each, scrolling both ways (or
/// wrapped), at the pinched size; Find's marks, the current one scrolled to.
struct FileCodeView: View {
    let lines: [AttributedString]
    let longest: Int
    let fontSize: Double
    var wrap = false
    var find = FileFind()
    var footer: AnyView = AnyView(EmptyView())

    /// The mockup's at 12.5 points: 19 point rows, a 28 point gutter, 12 between it and the code, 12 at the edges. The
    /// pinch's size is the diff viewer's (`CodeFontSize`, 12 standard), drawn a half point larger at that standard.
    struct Metrics: Equatable {
        let pinched: Double
        init(size: Double) { pinched = size }
        var size: Double { pinched * 12.5 / CodeFontSize.standard }
        var scale: Double { size / 12.5 }
        var row: Double { (19 * scale).rounded() }
        var number: Double { size }
        var gap: Double { 12 }
        var edge: Double { 12 }
        var character: Double {
            ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
        }

        func gutter(lines: Int) -> Double { max(28 * scale, Double(String(lines).count) * character) }
        /// The code's width unwrapped: the longest line and the margins.
        func width(lines: Int, longest: Int) -> Double { edge + gutter(lines: lines) + gap + Double(longest) * character + edge * 2 }
    }

    var body: some View {
        let metrics = Metrics(size: fontSize)
        let gutter = metrics.gutter(lines: lines.count)
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        row(index, metrics: metrics, gutter: gutter)
                    }
                    footer
                }
                .padding(.vertical, 8)
                .frame(width: wrap ? nil : metrics.width(lines: lines.count, longest: longest), alignment: .leading)
            }
            .onChange(of: find.currentMatch) {
                guard let match = find.currentMatch else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(match.line, anchor: UnitPoint(x: 0, y: 0.4)) }
            }
        }
        .accessibilityIdentifier("file-code")
    }

    private func row(_ index: Int, metrics: Metrics, gutter: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.gap) {
            Text("\(index + 1)")
                .font(.system(size: metrics.number, design: .monospaced))
                .foregroundStyle(Color(uiColor: CodePalette.gutter))
                .frame(width: gutter, alignment: .trailing)
            Text(find.highlighted(lines[index], index: index))
                .font(.system(size: metrics.size, design: .monospaced))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .padding(.horizontal, metrics.edge)
        .frame(minHeight: metrics.row)
        .id(index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Line \(index + 1), \(String(lines[index].characters))")
    }
}

/// An image file fitted to the screen; a tap opens it full screen in the attachment viewer.
struct FilesImageView: View {
    let data: Data
    let name: String
    let open: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Button(action: open) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Image, \(name)")
                .accessibilityHint("Opens it full screen")
            } else {
                ProgressView()
            }
        }
        .task(id: data) {
            let data = data
            // Drawn from a copy at most 2,048 pixels on a side: the screen shows no more.
            image = await Task.detached(priority: .userInitiated) {
                FilesImage.thumbnail(data, edge: 2_048).map { UIImage(cgImage: $0) }
            }.value
        }
        .accessibilityIdentifier("file-image")
    }
}

/// A file Share hands to the system's sheet: the bytes in the app's temporary folder under the host's name for them.
struct FilesShareItem: Identifiable {
    let url: URL
    var id: URL { url }

    /// Where the copies are: `tmp/Files/<uuid>/<name>`.
    static var folder: URL { System.temporary.appendingPathComponent("Files", isDirectory: true) }

    static func write(_ data: Data, name: String) throws -> FilesShareItem {
        let folder = folder.appendingPathComponent(System.uuid().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ChatAttachmentImage.clean(name))
        try data.write(to: url, options: .atomic)
        return FilesShareItem(url: url)
    }

    /// The share sheet closed: the copy goes.
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// At launch: copies a quit left behind go.
    static func sweep() { try? FileManager.default.removeItem(at: folder) }
}

/// The system's share sheet.
struct FilesActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
