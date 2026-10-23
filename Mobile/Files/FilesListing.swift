import SwiftUI
import UIKit

/// Files' words on the phone: the mockup's ages ("4m", "25m", "2d", "3w") and the rows' and preview's lines.
enum FilesText {
    /// "now", "4m", "2h", "6d", "3w", "5mo", "2y": a row's age at `now`; a date ahead of the phone's clock reads "now".
    static func age(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    /// "25m ago", "just now".
    static func ago(_ date: Date?, now: Date) -> String? {
        guard let age = age(date, now: now) else { return nil }
        return age == "now" ? "just now" : age + " ago"
    }

    /// "1 item", "3 items", "10,000+ items".
    static func items(_ count: Int, truncated: Bool = false) -> String {
        "\(FilesFormatting.count(count))\(truncated ? "+" : "") \(count == 1 && !truncated ? "item" : "items")"
    }

    /// A row's second line: "3 items · 4m" for a folder (its age alone until its count is read), "2.4 KB · 2d" for a
    /// file, "→ folder" for a link.
    static func detail(_ entry: FileEntry, count: (count: Int, truncated: Bool)?, now: Date) -> String {
        var parts: [String] = []
        if entry.isDirectory {
            if let count { parts.append(items(count.count, truncated: count.truncated)) }
        } else if entry.kind == .file || entry.isRegularFile {
            parts.append(FilesFormatting.size(entry.size))
        } else if entry.kind == .symlink {
            parts.append("Link")
        } else {
            parts.append("Special file")
        }
        if let age = age(entry.modified, now: now) { parts.append(age) }
        return parts.joined(separator: " · ")
    }

    /// The SF Symbol of a row (the mockup's: a filled folder, a document by kind).
    static func symbol(_ entry: FileEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        if entry.kind == .symlink, entry.targetKind == nil { return "link" }
        return symbol(name: entry.name)
    }

    static func symbol(name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": "doc.richtext"
        case "json", "jsonl", "yaml", "yml", "toml": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tif", "tiff", "bmp": "photo"
        case "zip", "gz", "tgz", "zst", "xz", "tar": "doc.zipper"
        case "pdf": "doc.richtext"
        default: "doc.text"
        }
    }
}

/// H1's row under the capsule: the folder glyph and the breadcrumb (each crumb opens its folder), Search and the "…"
/// menu (sort, hidden files, Refresh, Copy path). While searching: the search field and Cancel.
struct FilesListingBar: View {
    @Bindable var browser: FilesBrowser
    /// The crumbs until the browser follows the tab's folder (the bar's first frame).
    var fallback: [FilesCrumb] = []
    @FocusState private var focused: Bool

    var body: some View {
        if browser.searching {
            searchField
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    FilesBreadcrumb(crumbs: browser.folder == nil ? fallback : browser.crumbs, open: { browser.open($0) })
                }
                Spacer(minLength: 0)
                MobileBarButton(symbol: "magnifyingglass", label: "Search") {
                    browser.searching = true
                    focused = true
                }
                menu
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Sort by", selection: $browser.sort) {
                Text("Name").tag(FilesSort.name)
                Text("Date").tag(FilesSort.modified)
                Text("Size").tag(FilesSort.size)
            }
            .pickerStyle(.inline)
            Section {
                Toggle(isOn: Binding(get: { browser.showsHidden }, set: { browser.showsHidden = $0 })) {
                    Label("Show hidden files", systemImage: "eye")
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await browser.refresh() } }
                Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = browser.folder }
                    .disabled(browser.folder == nil)
            }
        } label: {
            MobileBarGlyph(symbol: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("More")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search in \(browser.crumbs.last?.title ?? "this folder")", text: $browser.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .accessibilityLabel("Search file names")
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(height: MobileBarButton.size)
            .glassEffect(.regular, in: Capsule())
            Button("Cancel") {
                focused = false
                browser.endSearch()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.dispatchPink)
            .buttonStyle(.plain)
        }
        .onAppear { focused = true }
    }
}

/// "web › src": every crumb but the last opens its folder; the row scrolls when it is longer than the bar, held at its
/// end so the shown folder stays in view.
struct FilesBreadcrumb: View {
    let crumbs: [FilesCrumb]
    let open: (String) -> Void

    var body: some View {
        // Leading while it fits; scrolling, held at its end, once it does not.
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
        .accessibilityIdentifier("files-breadcrumb")
    }

    private var row: some View {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    let last = index == crumbs.count - 1
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button { if !last { open(crumb.path) } } label: {
                        Text(crumb.title)
                            .font(.subheadline.weight(last ? .semibold : .regular))
                            .foregroundStyle(last ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .frame(minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(crumb.title == "~" ? "Home" : crumb.title)
                    .accessibilityAddTraits(last ? .isHeader : [])
                    .accessibilityHint(last ? "" : "Opens this folder")
                }
            }
            .fixedSize()
    }
}

/// H1's body: the shown folder's rows (folders first: glyph, name, "3 items · 4m"; files: glyph by kind, name, "2.4 KB ·
/// 2d", git's letter), the footer's count, pull to refresh; while searching the folder's matches and those found
/// below it. Loading, empty, failed and offline states in the same grammar as S1 and S2.
struct FilesListingView: View {
    let browser: FilesBrowser
    /// The folders' glyph colour: the host's tint, as the mockup's.
    let tint: Color
    /// The host's link is down: the last listing shows (dimmed by the segment), with no request made.
    var offline = false
    let preview: (String, FileEntry) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
        }
        .refreshable { await browser.refresh() }
        .task(id: "\(browser.folder ?? "")|\(browser.showsHidden)") { await browser.load() }
        // Back in the foreground: the folder and git's letters again.
        .onChange(of: scenePhase) { old, new in
            if old != .active, new == .active, !offline { Task { await browser.refresh() } }
        }
        // Off screen, no folder's count is read.
        .onDisappear { browser.cancelCounts() }
        .animation(nil, value: browser.folder)
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let state = browser.current
        if browser.searching, !browser.query.trimmingCharacters(in: .whitespaces).isEmpty {
            results(now: now)
        } else if let listing = state?.listing {
            if listing.entries.isEmpty {
                FilesStateView(symbol: "folder", title: "This folder is empty",
                               message: browser.showsHidden ? nil : "Hidden files are not shown.",
                               action: browser.showsHidden ? nil : ("Show hidden files", { browser.showsHidden = true }))
            } else {
                list(listing, now: now)
            }
        } else if let error = state?.error {
            failure(error)
        } else {
            FilesLoadingView()
        }
    }

    private func list(_ listing: FileListing, now: Date) -> some View {
        let rows = browser.rows
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                    row(entry, last: index == rows.count - 1, now: now)
                }
                Text(listing.truncated ? "The first \(FilesText.items(listing.entries.count))" : FilesText.items(listing.entries.count))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)
                    .padding(.bottom, browser.marksTruncated ? 4 : 24)
                    .accessibilityIdentifier("files-footer")
                if browser.marksTruncated {
                    Text("git status truncated: some letters may be missing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 24)
                }
            }
        }
        // Each folder starts at its top.
        .id(browser.folder)
        .accessibilityIdentifier("files-listing")
    }

    private func row(_ entry: FileEntry, last: Bool, now: Date) -> some View {
        let path = browser.folder.map { FilesPath.join($0, entry.name) } ?? entry.name
        return Button {
            if entry.isDirectory { browser.open(path) } else { preview(path, entry) }
        } label: {
            FilesRow(entry: entry, detail: FilesText.detail(entry, count: browser.count(path), now: now),
                     mark: browser.mark(entry), tint: tint, last: last)
        }
        .buttonStyle(.plain)
        .tabsRowHover()
        .task(id: path) { if entry.isDirectory && !offline { browser.needCount(path) } }
        .onDisappear { if entry.isDirectory { browser.dropCount(path) } }
        .contextMenu {
            Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            if !entry.isDirectory {
                Button("Open", systemImage: "doc.text") { preview(path, entry) }
            }
        }
    }

    @ViewBuilder private func results(now: Date) -> some View {
        let here = browser.rows
        ScrollView {
            LazyVStack(spacing: 0) {
                if !here.isEmpty {
                    MobileCountedSectionHeader(title: "In \(browser.crumbs.last?.title ?? "this folder")", count: here.count)
                    ForEach(Array(here.enumerated()), id: \.element.id) { index, entry in
                        row(entry, last: index == here.count - 1, now: now)
                    }
                }
                if !browser.hits.isEmpty || browser.walking {
                    MobileCountedSectionHeader(title: "Below", count: browser.hits.isEmpty ? nil : browser.hits.count)
                }
                ForEach(Array(browser.hits.enumerated()), id: \.element.id) { index, hit in
                    Button {
                        if hit.entry.isDirectory { browser.open(hit.path) } else { preview(hit.path, hit.entry) }
                    } label: {
                        FilesRow(entry: hit.entry, detail: hit.folder.isEmpty ? FilesText.detail(hit.entry, count: nil, now: now)
                                                                              : hit.folder + "/",
                                 mark: nil, tint: tint, last: index == browser.hits.count - 1)
                    }
                    .buttonStyle(.plain)
                    .tabsRowHover()
                }
                if browser.walking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                } else if here.isEmpty && browser.hits.isEmpty {
                    FilesStateView(symbol: "magnifyingglass", title: "No matches",
                                   message: "Nothing named “\(browser.query)” in or below \(browser.crumbs.last?.title ?? "this folder").")
                        .padding(.top, 60)
                } else if let bound = browser.walkBound {
                    Text(Self.bound(bound))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("files-results")
    }

    /// Why a search stopped early, under its hits.
    static func bound(_ bound: FilesBrowser.SearchBound) -> String {
        switch bound {
        case .hits: "Showing the first \(FilesBrowser.hitLimit) matches."
        case .folders(let count): "Stopped after \(FilesFormatting.count(count)) \(count == 1 ? "folder" : "folders")."
        }
    }

    @ViewBuilder private func failure(_ error: FilesSourceError) -> some View {
        switch error {
        case .offline:
            FilesStateView(symbol: "wifi.slash", title: "\(browser.host) is offline",
                           message: "The folder shows once the host is connected.")
        case .notFound, .notDirectory:
            FilesStateView(symbol: "questionmark.folder", title: "This folder is gone",
                           message: "\(browser.folder.map(FilesPath.name) ?? "It") was moved or deleted on \(browser.host).",
                           action: browser.crumbs.first.map { root in ("Open \(root.title)", { browser.open(root.path) }) })
        case .permissionDenied:
            FilesStateView(symbol: "lock", title: "No permission",
                           message: "\(browser.host) does not let this account read \(browser.folder.map(FilesPath.name) ?? "this folder").")
        default:
            FilesStateView(symbol: "exclamationmark.triangle", title: "The folder could not be read", message: error.message,
                           action: ("Try again", { Task { await browser.load(force: true) } }))
        }
    }
}

/// A listing's row (the mockup's `FileRow`): the glyph (a folder in the host's tint, a document by kind), the name and
/// its second line, git's letter, a chevron; the hairline under it from the name's edge.
struct FilesRow: View {
    let entry: FileEntry
    let detail: String
    var mark: String?
    var tint: Color = .secondary
    var last = false
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: FilesText.symbol(entry))
                    .font(.system(size: glyph))
                    .foregroundStyle(entry.isDirectory ? tint : Color.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.body).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let mark { GitStatusBadge(status: mark) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            if !last { MobileHairline(inset: 56) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([entry.name, entry.isDirectory ? "folder" : nil, detail.isEmpty ? nil : detail,
                             mark.map(GitStatusBadge.spoken)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// Files' empty, failed and offline states, in S1's grammar: a light glyph, a title, a line, one action.
struct FilesStateView: View {
    let symbol: String
    let title: String
    var message: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    if let action {
                        Button(action: action.run) {
                            Text(action.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 44)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, geometry.size.height * 0.24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-state")
    }
}

/// The first listing of a folder: placeholder rows in the listing's shape, so the rows land where they were drawn.
struct FilesLoadingView: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)).frame(width: 26, height: 22)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                                .frame(width: CGFloat([120, 90, 150, 70, 110, 130][index]), height: 13)
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)).frame(width: 64, height: 10)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    if index < 5 { MobileHairline(inset: 56) }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading folder")
        .accessibilityIdentifier("files-loading")
    }
}
