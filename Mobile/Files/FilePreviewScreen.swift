import AVKit
import Photos
import SwiftUI
import UIKit

/// What F2 can do beyond showing the file, from the tab it was opened in: Attach to chat (the file into the tab's chat
/// composer; nil without an agent), Open in terminal (a cd in the tab's shell; nil when the tab's pane is not at a
/// shell), and Back.
struct FilesPreviewActions {
    var ask: ((FilePreview) -> Void)?
    /// Types the `cd` and, once the helper took it, shows the tab's terminal; returns why it did not ("The terminal is
    /// busy."), nil when it did.
    var openInTerminal: (() async -> String?)?
    /// The screen Back returns to ("Files", "Review").
    var back = "Files"
    var pop: () -> Void = {}
}

/// F2: a file pushed over the tab (its header, capsule and the modes' bar go with the push). The back pill names the
/// screen it returns to; the title is the file's name, the subtitle its folder, size, age and kind; "…" holds Wrap lines
/// and Line numbers (or Markdown's source), Copy path, Share, Save to Photos (an image's), Attach to chat and Open in
/// terminal. Code has line numbers (unless turned off, kept as `files.lineNumbers`) and the syntax palette, scrolls both
/// ways and zooms with a pinch (kept as the diff viewer's, `CodeFontSize`); Find counts and steps through matches.
/// Markdown renders as a page, as the Mac's preview does (`FileMarkdownReader`), its Outline in "…"; images zoom with a
/// pinch or a double tap, a binary shows its kind and size with Share, a long text its head with Load all. On a phone's
/// side no header: Back, "…" and ⓘ (the name and details) stand in a rail (`rail`), with the content's action at its
/// foot as a tab's rail holds its mode's: Find for code, Outline for a rendered page.
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
    @State private var wrap = true
    /// The code's gutter, kept across files and launches.
    @AppStorage("files.lineNumbers") private var lineNumbers = true
    @State private var showsSource = false
    /// The rendered Markdown's folded sections and the heading the outline asked for (`FileMarkdownReader`).
    @State private var folds: Set<String> = []
    @State private var reveal: String?
    @State private var finding = false
    @State private var find = FileFind()
    @State private var sharing: FilesShareItem?
    /// A Share or Save to Photos copying the file to the phone; leaving the preview cancels it.
    @State private var saving: Task<Void, Never>?
    /// A video's Play: the copy being made, then the player of that copy (`video`).
    @State private var playing: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var videoCopy: FilesShareItem?
    @State private var problem: String?
    /// Open in Terminal waiting for the terminal's screen or the helper's answer: cancelled when the screen goes, so
    /// nothing is typed or shown for a screen no longer there.
    @State private var opening: Task<Void, Never>?
    @FocusState private var findFocused: Bool
    @Environment(\.tabsColumnWidth) private var column
    /// A phone on its side (`MobileLandscape`): no header; Back, "…" and the title (or ⓘ) stand in a rail on the
    /// island's side, as the tab's do.
    @Environment(\.mobileLandscape) private var sideways
    @Environment(\.mobileRailEdge) private var railEdge
    @Environment(\.mobileIsland) private var island
    @State private var infoShown = false

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
        let leading = railEdge == .leading
        // One structure upright and on its side, so turning the phone keeps the content's scroll and zoom.
        return HStack(spacing: sideways ? MobileLandscape.railGap : 0) {
            if sideways && leading { rail }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if sideways && !leading { rail }
        }
        .padding(leading ? .leading : .trailing, sideways ? MobileLandscape.railInset(island: island) : 0)
        .padding(leading ? .trailing : .leading, sideways ? MobileLandscape.contentInset : 0)
        .ignoresSafeArea(.container, edges: sideways ? .horizontal : [])
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .tabsPushedScreen()
        // Visible, not automatic, upright: turned back from its side the stack kept the bar hidden now and then.
        .toolbarVisibility(sideways ? .hidden : .visible, for: .navigationBar)
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
        .onDisappear {
            opening?.cancel()
            opening = nil
            saving?.cancel()
            saving = nil
            stopVideo()
        }
        .sheet(item: $sharing) { item in
            FilesActivityView(items: [item.url]).ignoresSafeArea()
                // The sheet closed: the copy goes.
                .onDisappear { item.remove() }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// "src · 1.8 KB · 25m ago · TypeScript": the folder under the root, the size, the age, the kind.
    private var subtitle: String { details.joined(separator: " · ") }

    private var details: [String] {
        Self.details(path: preview.path, root: root, home: host.home, revision: preview.revision, now: System.date())
    }

    static func subtitle(path: String, root: String?, home: String?, revision: FileRevision?, now: Date) -> String {
        details(path: path, root: root, home: home, revision: revision, now: now).joined(separator: " · ")
    }

    /// The subtitle's parts, a line each in ⓘ's popover.
    static func details(path: String, root: String?, home: String?, revision: FileRevision?, now: Date) -> [String] {
        var parts = [FilesFormatting.location(of: path, root: root, home: home)]
        if let size = revision?.size { parts.append(FilesFormatting.size(size)) }
        if let ago = FilesText.ago(revision?.modified, now: now) { parts.append(ago) }
        if let kind = FilesFormatting.kindName(FilesPath.name(path)) { parts.append(kind) }
        return parts
    }

    // MARK: On its side

    /// Back, "…" and ⓘ stacked on the island's side, the rail's discs, and the content's action at its foot: Find for
    /// code, Outline for a rendered Markdown page (held empty otherwise, so nothing above it moves).
    private var rail: some View {
        VStack(spacing: 8) {
            TabsBackDisc(back: actions.back, action: actions.pop)
            if preview.content != .folder { menu }
            infoButton
            Spacer(minLength: 0)
            if hasText && !finding {
                findButton
            } else if case .markdown(let text, _) = preview.content, !showsSource {
                outlineButton(FileMarkdownDocuments.document(text))
            }
        }
        .frame(width: MobileLandscape.railWidth)
        .frame(maxHeight: .infinity)
        .padding(.vertical, MobileLandscape.railMargin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preview-rail")
    }

    /// The name and details in a popover (the upright header's title and subtitle).
    private var infoButton: some View {
        Button { infoShown = true } label: {
            Image(systemName: "info")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("Info")
        .accessibilityIdentifier("preview-info")
        .popover(isPresented: $infoShown, arrowEdge: railEdge == .leading ? .leading : .trailing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.name).font(.headline).padding(.bottom, 2)
                ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320, alignment: .leading)
            .padding(16)
            .presentationCompactAdaptation(.popover)
        }
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
                FileMarkdownReader(document: FileMarkdownDocuments.document(text), folded: $folds, reveal: $reveal,
                                   footer: preview.markdownCapped || preview.truncated ? AnyView(markdownFooter) : nil)
                    .accessibilityIdentifier("file-markdown")
            }
        case .image(let data):
            FilesImageView(data: data, name: preview.name)
        case .binary:
            if preview.isVideo { video } else { binary }
        case .failed(let message):
            FilesStateView(symbol: "exclamationmark.triangle", title: "\(preview.name) could not be shown", message: message,
                           action: ("Try again", { Task { await preview.load() } }))
        }
    }

    /// Under rendered Markdown longer than renders: what is left out, and Show source for all of it.
    private var markdownFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preview.markdownCapped {
                Text("The rest is not rendered: the source shows the whole file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Show source for all of it") { showsSource = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.dispatchPink)
                    .buttonStyle(.plain)
            }
            truncation
        }
    }

    private var code: some View {
        FileCodeView(lines: preview.lines, longest: preview.longest, fontSize: fontSize, wrap: wrap, numbers: lineNumbers,
                     find: find, footer: AnyView(truncation))
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

    /// A video: its name and size until Play is tapped, then the copy `FilePreview.download` made, in the system
    /// player. Nothing is read before the tap; leaving the preview stops the copy or the playback and removes the copy.
    @ViewBuilder private var video: some View {
        if let player {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(preview.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text([FilesFormatting.kindName(preview.name) ?? "Video", preview.size.map(FilesFormatting.size)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(action: play) {
                    Group {
                        if playing != nil {
                            Label { Text("Loading…") } icon: { ProgressView() }
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
                .disabled(!preview.canShare || playing != nil)
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Play: the video copied to the phone, then played from that copy.
    private func play() {
        playing = Task {
            defer { playing = nil }
            do {
                let copy = try await preview.download()
                guard !Task.isCancelled else { return copy.remove() }
                videoCopy = copy
                let player = AVPlayer(url: copy.url)
                self.player = player
                player.play()
            } catch is CancellationError {
            } catch {
                problem = (error as? FilesSourceError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Leaving the preview: the copy in progress stops, the player too, and the copy goes.
    private func stopVideo() {
        playing?.cancel()
        playing = nil
        player?.pause()
        player = nil
        videoCopy?.remove()
        videoCopy = nil
    }

    private var binary: some View {
        VStack(spacing: 12) {
            Image(systemName: FilesText.symbol(name: preview.name))
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(preview.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text([preview.format ?? FilesFormatting.kindName(preview.name) ?? "Binary file", preview.size.map(FilesFormatting.size)]
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
            .disabled(!preview.canShare)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-binary")
    }

    // MARK: Bars

    /// Find at the trailing end of a text, its field in its place; anything else keeps the whole screen.
    @ViewBuilder private var bottomBar: some View {
        if finding {
            findBar
        } else if hasText && !sideways {
            // On its side Find is the rail's.
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                findButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    private var findButton: some View {
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
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("Find in file")
        .accessibilityIdentifier("preview-find")
    }

    /// On its side: the Outline as the rail's disc.
    @ViewBuilder private func outlineButton(_ document: FileMarkdownDocument) -> some View {
        if !document.headings.isEmpty {
            Menu {
                outlineItems(document)
            } label: {
                Image(systemName: "list.bullet.indent")
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
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityLabel("Outline")
            .accessibilityIdentifier("preview-outline")
        }
    }

    /// Attach to chat: for what has loaded and is not a binary (which offers Share only).
    private var asks: Bool {
        switch preview.content {
        case .loading, .binary, .failed, .folder: false
        default: true
        }
    }

    private var isImage: Bool {
        if case .image = preview.content { return true }
        return false
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

    /// Rendered Markdown's headings, indented under the ones they belong to: one scrolls to its section (opening the
    /// folded ones around it).
    @ViewBuilder private func outline(_ document: FileMarkdownDocument) -> some View {
        if !document.headings.isEmpty {
            Menu {
                outlineItems(document)
            } label: {
                Label("Outline", systemImage: "list.bullet.indent")
            }
        }
    }

    @ViewBuilder private func outlineItems(_ document: FileMarkdownDocument) -> some View {
        ForEach(document.headings) { heading in
            Button {
                folds = document.revealing(heading, in: folds)
                reveal = heading.id
            } label: {
                // Em spaces: a menu keeps them where it trims plain ones.
                Text(verbatim: String(repeating: "\u{2003}", count: min(heading.depth, 5)) + heading.title)
            }
        }
    }

    @ViewBuilder private var codeToggles: some View {
        Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.alignleft") }
        Toggle(isOn: $lineNumbers) { Label("Line numbers", systemImage: "list.number") }
    }

    private var menu: some View {
        Menu {
            switch preview.content {
            case .text:
                codeToggles
            case .markdown(let text, _):
                Toggle(isOn: $showsSource) { Label("Show source", systemImage: "chevron.left.forwardslash.chevron.right") }
                if showsSource {
                    codeToggles
                } else if !sideways {
                    // On its side the Outline is the rail's.
                    outline(FileMarkdownDocuments.document(text))
                }
            default:
                EmptyView()
            }
            Section {
                Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = preview.path }
                // Only with the helper's metadata of what loaded: never a failed, offline or partial read's bytes.
                Button("Share", systemImage: "square.and.arrow.up", action: share)
                    .disabled(!preview.canShare || saving != nil)
                if isImage || preview.isVideo {
                    Button("Save to Photos", systemImage: "square.and.arrow.down", action: saveToPhotos)
                        .disabled(!preview.canShare || saving != nil)
                }
            }
            Section {
                if let ask = actions.ask, asks {
                    Button("Attach to chat", systemImage: "paperclip") { ask(preview) }
                }
                if let open = actions.openInTerminal {
                    Button("Open in Terminal", systemImage: "apple.terminal") {
                        opening = Task {
                            let failure = await open()
                            opening = nil
                            if !Task.isCancelled { problem = failure }
                        }
                    }
                    .disabled(opening != nil)
                }
            }
        } label: {
            // A large file copying for Share or Save to Photos spins here until it is ready.
            Group {
                if saving != nil { ProgressView() } else { Image(systemName: "ellipsis") }
            }
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

    /// Share: the revision shown, copied to the phone (`FilePreview.download`) and named as on the host.
    private func share() {
        saving = Task {
            defer { saving = nil }
            do {
                let item = try await preview.download()
                if Task.isCancelled { item.remove() } else { sharing = item }
            } catch is CancellationError {
            } catch {
                problem = (error as? FilesSourceError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Save to Photos: an image's bytes (read whole when a smaller copy shows) or a video's copy, added to the library.
    private func saveToPhotos() {
        saving = Task {
            defer { saving = nil }
            do {
                if preview.isVideo {
                    let item = try await preview.download()
                    defer { item.remove() }
                    try await FilesPhotos.saveVideo(item.url)
                } else {
                    try await FilesPhotos.save(try await preview.bytes(), name: preview.name)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
            } catch {
                problem = (error as? FilesSourceError)?.message ?? (error as? FilesPhotos.Refused)?.message
                    ?? FilesPhotos.message(error) ?? error.localizedDescription
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

/// F2's code: line numbers in the gutter (unless `numbers` is off) and the lines in the syntax palette, one row each,
/// scrolling both ways (or wrapped), at the pinched size; Find's marks, the current one scrolled to.
struct FileCodeView: View {
    let lines: [AttributedString]
    let longest: Int
    let fontSize: Double
    var wrap = false
    var numbers = true
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
        /// The code's width unwrapped: the longest line and the margins, with the gutter and its gap unless `numbers` is off.
        func width(lines: Int, longest: Int, numbers: Bool = true) -> Double {
            edge + (numbers ? gutter(lines: lines) + gap : 0) + Double(longest) * character + edge * 2
        }
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
                .frame(width: wrap ? nil : metrics.width(lines: lines.count, longest: longest, numbers: numbers), alignment: .leading)
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
            if numbers {
                Text("\(index + 1)")
                    .font(.system(size: metrics.number, design: .monospaced))
                    .foregroundStyle(Color(uiColor: CodePalette.gutter))
                    .frame(width: gutter, alignment: .trailing)
            }
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

/// An image file fitted to the screen, zoomed with a pinch or a double tap.
struct FilesImageView: View {
    let data: Data
    let name: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image, inset: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel("Image, \(name)")
                    .accessibilityAddTraits(.isImage)
            } else {
                ProgressView()
            }
        }
        .task(id: data) {
            let data = data
            // Drawn from a copy at most 4,096 pixels on a side (what is loaded holds no more): zoomed in, it shows them.
            image = await Task.detached(priority: .userInitiated) {
                FilesImage.thumbnail(data, edge: FilesImage.thumbnailEdge).map { UIImage(cgImage: $0) }
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

/// Save to Photos: an image file added to the photo library (add-only access, asked the first time), as it is, or as a
/// PNG of its picture when Photos does not take its kind.
enum FilesPhotos {
    struct Refused: Error {
        var message: String { "Dispatch may not add to your photos. Allow it in Settings › Privacy & Security › Photos." }
    }

    static func save(_ data: Data, name: String) async throws {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: break
        default: throw Refused()
        }
        do {
            try await add(data, name: name)
        } catch {
            guard let png = UIImage(data: data)?.pngData() else { throw error }
            try await add(png, name: (name as NSString).deletingPathExtension + ".png")
        }
    }

    /// A video file (`FilePreview.download`'s copy): Photos copies it in; the caller removes the copy after.
    static func saveVideo(_ url: URL) async throws {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: break
        default: throw Refused()
        }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
        }
    }

    /// Photos' refusal of a file it cannot read as a video (a codec or container it does not take), said plainly.
    static func message(_ error: any Error) -> String? {
        let error = error as NSError
        guard error.domain == PHPhotosErrorDomain || error.domain == "PHPhotosErrorDomain" else { return nil }
        return "Photos could not import this file. Share it to Files instead."
    }

    private static func add(_ data: Data, name: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        }
    }
}

/// The system's share sheet.
struct FilesActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
