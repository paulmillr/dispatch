import SwiftUI

// Files mode's three tabs as the Mac app draws them, the sidebar hidden (FilesView, FilesHeader, FilesOutline, FilePreviewPane,
// GitChangesView, GitDiffView, ReviewViews, GitCommitsView): the 34-point files header over a list | detail split, the
// detail 560 points wide once the view is 1,000 wide. Fictional repository: `app` on `dark-mode`, the same work as the
// kit's `git status` sample.

enum FilesModes {
    static let screens: [Screen] = [
        Screen("J1-files", group: "files", "Files: the tree with columns, a file's preview, a transfer") {
            window(tab: "Sources/Theme/Palette.swift", segment: .files) { FilesTab() }
        },
        Screen("J2-review", group: "files", "Review: the changes, a diff with a comment and a comment being written") {
            window(tab: "Review dark-mode", segment: .review) { ReviewTab() }
        },
        Screen("J2b-review-finish", group: "files", "Review: Finish your review, before sending it to the agent") {
            window(tab: "Review dark-mode", segment: .review) {
                ReviewTab().overlay(alignment: .topLeading) { FinishReview().padding(.leading, 96).padding(.top, 6) }
            }
        },
        Screen("J3-commits", group: "files", "Commits: the graph, a commit's summary, files and diff") {
            window(tab: "Theme: high-contrast sidebar rows", segment: .commits) { CommitsTab() }
        },
    ]

    @MainActor static func window<Content: View>(tab: String, segment: FilesSegment,
                                                 @ViewBuilder content: () -> Content) -> some View {
        DispatchWindow(width: 1180, height: 780, sidebar: nil) {
            Pane(strip: StripModel(tabs: [
                TabItem(title: tab, shortcut: 1, selected: true),
                TabItem(title: "Theme contrast", activity: .finished, shortcut: 2),
            ], mode: .files, titleRow: true)) {
                VStack(spacing: 0) {
                    FilesHeader(segment: segment)
                    content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .background(ChatColors.current.terminal)
            }
        }
    }
}

enum FilesSegment { case files, review, commits }

// MARK: Shared

@MainActor private var p: SidebarPalette { Chrome.palette }
@MainActor private var t: AppTypography { Mock.typography }
@MainActor private var theme: ChatColors { ChatColors.current }
/// Selected rows everywhere: ink at 8%.
@MainActor private var selection: Color { p.ink.opacity(0.08) }
private let codeSize: CGFloat = 12.5
private let codeRow: CGFloat = 20

/// The header: location, Create review, search, the pane toggle and the Files | Review | Commits well.
private struct FilesHeader: View {
    let segment: FilesSegment
    var body: some View {
        HStack(spacing: 12) {
            if segment == .files {
                HStack(spacing: 4) {
                    ForEach(Array(["app", "Sources", "Theme"].enumerated()), id: \.offset) { index, crumb in
                        if index > 0 { Text("/").foregroundStyle(p.faint) }
                        Text(crumb).foregroundStyle(index == 2 ? p.secondary : p.sidebarDetail)
                    }
                    Image(systemName: "link").font(t.symbol(.caption)).foregroundStyle(p.muted).padding(.leading, 4)
                }
            } else {
                RepoLine()
                if segment == .review { CreateReviewButton() }
            }
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass").font(t.symbol(.label))
            Image(systemName: "rectangle.righthalf.inset.filled").font(t.symbol(.label))
            Segments(selected: segment)
        }
        .font(t.font(.label)).foregroundStyle(p.muted)
        .padding(.horizontal, 12)
        .frame(height: t.expanded(34))
        .background(Chrome.window)
        .overlay(alignment: .bottom) { if !Mock.glass { Rectangle().fill(p.separator).frame(height: 1) } }
    }
}

private struct RepoLine: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("app").foregroundStyle(p.secondary)
            Image(systemName: "arrow.triangle.branch").font(t.symbol(.caption)).foregroundStyle(p.faint)
            Text("dark-mode")
            Text("↑2").foregroundStyle(p.green)
        }
    }
}

private struct CreateReviewButton: View {
    var body: some View {
        Label("Create review", systemImage: "text.bubble.fill")
            .font(t.font(.body, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(theme.blue.opacity(0.9)))
    }
}

/// The segmented well: track `control`, the selected pill `selectedControl`; Review carries its comment count in blue.
private struct Segments: View {
    let selected: FilesSegment
    var body: some View {
        HStack(spacing: 0) {
            segment(.files, "Files", "folder")
            segment(.review, "Review", "text.bubble", count: 3)
            segment(.commits, "Commits", "clock.arrow.circlepath")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.control))
    }

    private func segment(_ kind: FilesSegment, _ title: String, _ symbol: String, count: Int? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(t.symbol(.caption))
            Text(title)
            if let count {
                Text("\(count)").font(t.font(.micro, weight: .semibold)).foregroundStyle(theme.blue)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(theme.blue.opacity(0.16)))
            }
        }
        .font(t.font(.body)).foregroundStyle(kind == selected ? p.ink : p.muted)
        .padding(.horizontal, 10).frame(height: 22)
        .background { if kind == selected { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.selectedControl) } }
    }
}

/// List | detail, the detail 560 wide, on a 1-point border.
private struct FilesSplit<List: View, Detail: View>: View {
    @ViewBuilder let list: List
    @ViewBuilder let detail: Detail
    var body: some View {
        HStack(spacing: 0) {
            list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Chrome.border).frame(width: 1)
            detail.frame(width: 560, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .topLeading).clipped()
        }
    }
}

/// A git status letter, plain (Review) or on a tinted 20-point tile (Commits), coloured by kind.
private struct StatusLetter: View {
    let letter: String
    var tile = false
    var size: CGFloat = 14
    var color: Color {
        switch letter {
        case "M", "T": p.warning
        case "A", "U", "C": p.green
        case "D", "X": Color(hex: 0xeca19a)
        case "R": Color(hex: 0x7db8e3)
        default: p.detail
        }
    }
    var body: some View {
        Text(letter).font(t.font(.body, weight: .semibold)).foregroundStyle(color)
            .frame(width: tile ? 20 : size, height: tile ? 20 : size)
            .background { if tile { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.13)) } }
    }
}

private struct Counts: View {
    let added: Int
    var removed = 0
    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(theme.green)
            if removed > 0 { Text("−\(removed)").foregroundStyle(theme.red) }
        }
        .font(t.font(.body).monospacedDigit())
    }
}

// MARK: Code

/// A run of code coloured by an ANSI index of the terminal scheme (nil: the foreground).
private struct Code {
    var spans: [(String, Int?)]
    init(_ spans: (String, Int?)...) { self.spans = spans }
    init(plain: String) { spans = [(plain, nil)] }
    @MainActor var text: Text {
        let scheme = TerminalScheme.current
        return spans.reduce(Text("")) { result, span in
            result + Text(span.0).foregroundColor(span.1.map { scheme.palette[$0] } ?? scheme.foreground)
        }
    }
}

// Swift colouring after the app's highlighter: keywords magenta (5), types cyan (6), strings green (2), calls blue (4),
// comments grey (8).
private func kw(_ s: String) -> (String, Int?) { (s, 5) }
private func ty(_ s: String) -> (String, Int?) { (s, 6) }
private func fn(_ s: String) -> (String, Int?) { (s, 4) }
private func st(_ s: String) -> (String, Int?) { (s, 2) }
private func cm(_ s: String) -> (String, Int?) { (s, 8) }
private func pl(_ s: String) -> (String, Int?) { (s, nil) }

private enum DiffRow {
    case hunk(String, String)
    case line(old: Int?, new: Int?, Code, hoverPlus: Bool = false, draft: Bool = false)
    case fold(Int)
    case comment(location: String, text: String)
    case composer(location: String, draft: String)
}

/// A diff: hunk headers, two number gutters, the sign column and code, green and red washes, folds, and in Review the
/// 20-point comment column with comments and the composer as cards under their line.
private struct DiffBody: View {
    let rows: [DiffRow]
    var review = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in rowView(row) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var gutter: CGFloat { 34 }
    private var codeLeading: CGFloat { (review ? 20 : 0) + gutter * 2 + 14 }

    @ViewBuilder private func rowView(_ row: DiffRow) -> some View {
        switch row {
        case .hunk(let range, let section):
            HStack(spacing: 8) {
                Text(range).foregroundStyle(theme.blue)
                Text(section).foregroundStyle(theme.muted)
            }
            .font(AppFont.code(size: codeSize)).lineLimit(1)
            .padding(.leading, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(theme.blue.opacity(0.07))
        case .line(let old, let new, let code, let hoverPlus, let draft):
            let sign = old == nil ? "+" : new == nil ? "−" : " "
            let wash = old == nil ? theme.green.opacity(0.1) : new == nil ? theme.red.opacity(0.1) : .clear
            HStack(spacing: 0) {
                if review {
                    ZStack {
                        if hoverPlus {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.blue))
                        }
                    }
                    .frame(width: 20)
                }
                Text(old.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(new.map(String.init) ?? "").frame(width: gutter, alignment: .trailing)
                Text(sign).foregroundStyle(old == nil ? theme.green : theme.red).frame(width: 14)
                    .padding(.leading, 6)
                code.text.font(AppFont.code(size: codeSize)).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .font(AppFont.code(size: codeSize - 1.5)).foregroundStyle(theme.muted)
            .frame(height: codeRow)
            .background(draft ? theme.blue.opacity(0.14) : wash)
        case .fold(let count):
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                Text("\(count) unmodified lines")
            }
            .font(t.font(.caption)).foregroundStyle(theme.muted)
            .padding(.leading, codeLeading - 14)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(Chrome.window)
            .overlay(alignment: .top) { Rectangle().fill(Chrome.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1) }
        case .comment(let location, let text):
            CommentCard(location: location, text: text).frame(width: max(260, min(560 - codeLeading - 14, 720))).padding(.leading, codeLeading).padding(.vertical, 6)
        case .composer(let location, let draft):
            CommentComposer(location: location, draft: draft).frame(width: max(260, min(560 - codeLeading - 14, 720))).padding(.leading, codeLeading).padding(.vertical, 6)
        }
    }
}

private struct CommentCard: View {
    let location: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(theme.blue)
                Text(location).foregroundStyle(p.ink)
                Spacer()
                quiet("Edit"); quiet("Delete")
            }
            .font(t.font(.body))
            Text(text).font(t.font(.label)).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8).padding(.horizontal, 10).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.window))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
    }
}

@MainActor private func quiet(_ title: String, prominent: Bool = false) -> some View {
    Text(title).font(t.font(.body, weight: prominent ? .semibold : .regular))
        .foregroundStyle(prominent ? p.ink : p.muted)
        .padding(.horizontal, 9).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.ink.opacity(prominent ? 0.14 : 0.07)))
}

private struct CommentComposer: View {
    let location: String
    let draft: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location).font(t.font(.body)).foregroundStyle(theme.muted)
            HStack(spacing: 0) {
                Text(draft).font(t.font(.label)).foregroundStyle(p.ink)
                Rectangle().fill(p.accent).frame(width: 1.5, height: 16).padding(.leading, 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.terminal))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            HStack(spacing: 8) {
                Text("⏎ comments · ⌥⏎ / ⇧⏎ new line · esc cancels").font(t.font(.caption)).foregroundStyle(theme.muted)
                Spacer()
                quiet("Cancel")
                quiet("Comment", prominent: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Chrome.window))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.blue.opacity(0.5), lineWidth: 1))
    }
}

/// The diff pane's 40-point header: letter, path, counts, then wrap, comment-on-file and Diff | Source.
private struct DiffHeader: View {
    let letter: String
    let path: String
    let added: Int
    let removed: Int
    var review = true
    var body: some View {
        HStack(spacing: 8) {
            StatusLetter(letter: letter, size: 18)
            Text(path).font(t.font(.content)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
            Counts(added: added, removed: removed)
            Spacer(minLength: 0)
            Image(systemName: "text.word.spacing").font(t.symbol(.body)).foregroundStyle(p.muted)
            if review { Image(systemName: "text.bubble").font(t.symbol(.body)).foregroundStyle(p.muted) }
            HStack(spacing: 0) {
                Text("Diff").foregroundStyle(p.ink).padding(.horizontal, 9).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.selectedControl))
                Text("Source").foregroundStyle(p.muted).padding(.horizontal, 9).frame(height: 20)
            }
            .font(t.font(.body)).padding(1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.control))
        }
        .padding(.horizontal, 14).frame(height: t.expanded(40))
        .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1) }
    }
}

// MARK: Review

private struct Change {
    let letter: String
    let name: String
    let folder: String
    let added: Int
    var removed = 0
    var comments = 0
    var selected = false
}

private struct ReviewTab: View {
    let unstaged = [
        Change(letter: "M", name: "Sidebar.swift", folder: "Sources/Views", added: 14, removed: 6, comments: 2, selected: true),
        Change(letter: "M", name: "Palette.swift", folder: "Sources/Theme", added: 22, removed: 9, comments: 1),
        Change(letter: "M", name: "Header.swift", folder: "Sources/Views", added: 5, removed: 2),
    ]
    let untracked = [
        Change(letter: "U", name: "Contrast.swift", folder: "Sources/Theme", added: 27),
        Change(letter: "U", name: "ContrastTests.swift", folder: "Tests/Theme", added: 40),
    ]
    var body: some View {
        FilesSplit {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("5 files").foregroundStyle(p.detail)
                    Counts(added: 108, removed: 17)
                }
                .font(t.font(.body)).padding(.horizontal, 14).frame(height: 28).padding(.top, 4)
                group("Unstaged", unstaged)
                group("Untracked", untracked)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                DiffHeader(letter: "M", path: "Sources/Views/Sidebar.swift", added: 14, removed: 6)
                DiffBody(rows: Self.diff)
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ changes: [Change]) -> some View {
        HStack {
            Text(title).font(t.font(.body, weight: .semibold)).foregroundStyle(p.ink)
            Spacer()
            Text("\(changes.count)").font(t.font(.body)).foregroundStyle(p.detail)
        }
        .padding(.horizontal, 14).frame(height: 26).padding(.top, 6)
        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
            HStack(spacing: 8) {
                StatusLetter(letter: change.letter)
                Text(change.name).font(t.font(.content)).foregroundStyle(p.ink)
                Text(change.folder).font(t.font(.body)).foregroundStyle(p.detail).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                if change.comments > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "text.bubble.fill").font(.system(size: 9))
                        Text("\(change.comments)").font(t.font(.caption))
                    }
                    .foregroundStyle(theme.blue)
                }
                Counts(added: change.added, removed: change.removed)
            }
            .padding(.leading, 14).padding(.trailing, 12).frame(height: 28)
            .background(change.selected ? selection : .clear)
        }
    }

    static let diff: [DiffRow] = [
        .hunk("@@ -12,7 +12,9 @@", "struct Sidebar: View {"),
        .line(old: 12, new: 12, Code(pl("    "), kw("@Environment"), pl("(\\.colorScheme) "), kw("private var"), pl(" scheme"))),
        .line(old: 13, new: 13, Code(pl("    "), kw("let"), pl(" spaces: ["), ty("Space"), pl("]"))),
        .line(old: nil, new: 14, Code(pl("    "), kw("@State private var"), pl(" contrast = "), ty("Contrast"), pl(".standard"))),
        .line(old: 14, new: 15, Code(plain: "")),
        .line(old: 15, new: 16, Code(pl("    "), kw("var"), pl(" body: "), kw("some"), pl(" "), ty("View"), pl(" {"))),
        .line(old: 16, new: nil, Code(pl("        "), ty("List"), pl("(spaces) { "), ty("SpaceRow"), pl("(space: $0) }"))),
        .line(old: nil, new: 17, Code(pl("        "), ty("List"), pl("(spaces) { "), ty("SpaceRow"), pl("(space: $0, contrast: contrast) }"))),
        .line(old: nil, new: 18, Code(pl("            ."), fn("background"), pl("("), ty("Palette"), pl("."), fn("sidebar"), pl("(for: scheme))"))),
        .comment(location: "Line 18", text: "Use Palette.sidebar only in dark mode; light already gets the system material."),
        .line(old: 17, new: 19, Code(pl("    }"))),
        .fold(6),
        .hunk("@@ -24,6 +26,10 @@", "struct SpaceRow: View {"),
        .line(old: 24, new: 26, Code(pl("    "), kw("let"), pl(" space: "), ty("Space"))),
        .line(old: nil, new: 27, Code(pl("    "), kw("var"), pl(" contrast: "), ty("Contrast"), pl(" = .standard"))),
        .line(old: 25, new: 28, Code(plain: "")),
        .line(old: 26, new: 29, Code(pl("    "), kw("var"), pl(" body: "), kw("some"), pl(" "), ty("View"), pl(" {"))),
        .line(old: 27, new: 30, Code(pl("        "), ty("Text"), pl("(space.name)"))),
        .line(old: nil, new: 31, Code(pl("            ."), fn("foregroundStyle"), pl("(contrast.text)")), hoverPlus: true),
        .line(old: nil, new: 32, Code(pl("            ."), fn("fontWeight"), pl("(contrast == .high ? .semibold : .regular)")), draft: true),
        .composer(location: "Comment on line 32", draft: "High contrast should raise the branch label too, not only the name."),
        .line(old: 28, new: 33, Code(pl("    }"))),
    ]
}

/// The popover from Create review: an overview of the comments, an overall comment, Send to the agent.
private struct FinishReview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish your review").font(t.font(.content, weight: .semibold)).foregroundStyle(p.ink)
            Text("3 comments on 2 files").font(t.font(.body)).foregroundStyle(theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                row("Sidebar.swift", "Line 18", "Use Palette.sidebar only in dark mode; light already gets the system material.")
                row("Sidebar.swift", "Line 32", "High contrast should raise the branch label too, not only the name.")
                row("Palette.swift", "Lines 40–44", "Name these after their roles, not their colours.")
            }
            HStack(spacing: 0) {
                Text("Close. Fix these, then run ContrastTests.").font(t.font(.label)).foregroundStyle(p.ink)
                Rectangle().fill(p.accent).frame(width: 1.5, height: 16).padding(.leading, 1)
                Spacer(minLength: 0)
            }
            .padding(8).frame(height: 54, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.terminal))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            HStack(spacing: 8) {
                Text("Then clears the comments").font(t.font(.caption)).foregroundStyle(theme.muted)
                Spacer()
                quiet("Cancel")
                quiet("Copy review")
                Text("Send to Claude Code").font(t.font(.body, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.accent))
                HStack(spacing: 3) {
                    Text("Other agent…")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(t.font(.body)).foregroundStyle(p.muted)
            }
        }
        .padding(14)
        .frame(width: 600, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.isDark ? Color(white: 0.16) : Color(white: 0.985)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.ink.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            // The arrow up to Create review.
            Rectangle().fill(p.isDark ? Color(white: 0.16) : Color(white: 0.985)).frame(width: 14, height: 14)
                .rotationEffect(.degrees(45)).offset(x: 115, y: -7)
                .mask(Rectangle().frame(width: 30, height: 14).offset(x: 107, y: -7))
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(.top, t.expanded(34) - 2)
    }

    private func row(_ file: String, _ location: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(file).foregroundStyle(p.ink)
            Text(location).foregroundStyle(theme.blue)
            Text(text).foregroundStyle(theme.muted).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(t.font(.body)).frame(height: 22)
    }
}

// MARK: Files

private struct FileNode {
    let name: String
    var depth = 0
    var folder = false
    var open = false
    var modified = ""
    var size = ""
    var selected = false
}

private struct FilesTab: View {
    let nodes = [
        FileNode(name: "Sources", folder: true, open: true, modified: "6m", size: "—"),
        FileNode(name: "Billing", depth: 1, folder: true, modified: "2d", size: "—"),
        FileNode(name: "Theme", depth: 1, folder: true, open: true, modified: "6m", size: "—"),
        FileNode(name: "Contrast.swift", depth: 2, modified: "6m", size: "1.9 KB"),
        FileNode(name: "Palette.swift", depth: 2, modified: "6m", size: "4.1 KB", selected: true),
        FileNode(name: "Typography.swift", depth: 2, modified: "3d", size: "2.6 KB"),
        FileNode(name: "Views", depth: 1, folder: true, modified: "6m", size: "—"),
        FileNode(name: "Tests", folder: true, modified: "1h", size: "—"),
        FileNode(name: "docs", folder: true, modified: "2d", size: "—"),
        FileNode(name: "assets", folder: true, modified: "5d", size: "—"),
        FileNode(name: ".gitignore", modified: "2w", size: "84 B"),
        FileNode(name: "Package.swift", modified: "3d", size: "1.2 KB"),
        FileNode(name: "README.md", modified: "2d", size: "3.4 KB"),
    ]
    var body: some View {
        FilesSplit {
            VStack(spacing: 0) {
                HStack {
                    Text("Name")
                    Spacer()
                    Text("Modified").frame(width: 64, alignment: .trailing)
                    Text("Size").frame(width: 72, alignment: .trailing)
                }
                .font(t.font(.caption)).foregroundStyle(p.detail)
                .padding(.leading, 14).padding(.trailing, 12).frame(height: t.expanded(40))
                .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1) }
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in row(node) }
                Spacer(minLength: 0)
                transfer
                HStack {
                    Text("13 items · 1 selected")
                    Spacer()
                }
                .font(t.font(.caption)).foregroundStyle(p.detail)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Chrome.window)
                .overlay(alignment: .top) { Rectangle().fill(Chrome.border).frame(height: 1) }
            }
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Palette.swift").font(t.font(.content)).foregroundStyle(p.ink)
                            Image(systemName: "doc.on.doc").font(t.symbol(.caption)).foregroundStyle(p.muted)
                        }
                        Text("4.1 KB · modified 6m ago").font(t.font(.caption)).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    ForEach(["text.word.spacing", "square.and.pencil"], id: \.self) { symbol in
                        Image(systemName: symbol).font(t.symbol(.body)).foregroundStyle(p.muted).frame(width: 22, height: 22)
                    }
                }
                .padding(.horizontal, 14).frame(height: t.expanded(40))
                .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1) }
                SourcePreview(lines: Self.palette, first: 1)
            }
        }
    }

    private func row(_ node: FileNode) -> some View {
        HStack(spacing: 0) {
            Group {
                if node.folder {
                    Image(systemName: node.open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(p.detail)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
            Image(systemName: node.folder ? "folder" : "doc").font(.system(size: 14)).foregroundStyle(p.muted)
                .frame(width: 18).padding(.leading, 2)
            Text(node.name).font(t.font(.content)).foregroundStyle(node.selected ? p.ink : p.secondary).padding(.leading, 7)
            Spacer(minLength: 8)
            Group {
                Text(node.modified).frame(width: 64, alignment: .trailing)
                Text(node.size).frame(width: 72, alignment: .trailing)
            }
            .font(t.font(.body)).foregroundStyle(node.selected ? p.sidebarHostLabel : p.sidebarDetail)
        }
        .padding(.leading, 10 + CGFloat(node.depth) * 20).padding(.trailing, 12)
        .frame(height: 24)
        .background(node.selected ? selection : .clear)
    }

    /// A drop on the list copying files to an SSH host: progress, stages, cancel.
    private var transfer: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(p.ink.opacity(0.06))
                    Rectangle().fill(p.accent).frame(width: geometry.size.width * 0.62)
                }
            }
            .frame(height: 2)
            HStack(spacing: 8) {
                Image(systemName: "arrow.up").font(t.symbol(.caption, weight: .semibold)).foregroundStyle(p.accent)
                Text("Copying 3 items to build-box").font(t.font(.body)).foregroundStyle(p.ink)
                HStack(spacing: 4) {
                    Text("pack").foregroundStyle(p.green)
                    Text("·").foregroundStyle(p.faint)
                    Text("send").foregroundStyle(p.ink)
                    Text("·").foregroundStyle(p.faint)
                    Text("unpack").foregroundStyle(p.detail)
                }
                .font(t.font(.caption))
                Spacer()
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, 14).frame(height: 32)
        }
        .background(Chrome.window)
        .overlay(alignment: .top) { Rectangle().fill(Chrome.border).frame(height: 1) }
    }

    static let palette: [Code] = [
        Code(kw("import"), pl(" SwiftUI")),
        Code(plain: ""),
        Code(cm("/// The sidebar's colours by role, for each contrast level.")),
        Code(kw("struct"), pl(" "), ty("Palette"), pl(" {")),
        Code(pl("    "), kw("var"), pl(" text: "), ty("Color")),
        Code(pl("    "), kw("var"), pl(" detail: "), ty("Color")),
        Code(pl("    "), kw("var"), pl(" selection: "), ty("Color")),
        Code(plain: ""),
        Code(pl("    "), kw("static func"), pl(" "), fn("sidebar"), pl("(for scheme: "), ty("ColorScheme"), pl(") -> "), ty("Color"), pl(" {")),
        Code(pl("        scheme == .dark ? "), ty("Color"), pl("("), st("\"SidebarDark\""), pl(") : .clear")),
        Code(pl("    }")),
        Code(plain: ""),
        Code(pl("    "), kw("static let"), pl(" standard = "), ty("Palette"), pl("(")),
        Code(pl("        text: .primary,")),
        Code(pl("        detail: .secondary,")),
        Code(pl("        selection: ."), fn("accentColor"), pl("."), fn("opacity"), pl("(0.18)")),
        Code(pl("    )")),
        Code(plain: ""),
        Code(pl("    "), kw("static let"), pl(" high = "), ty("Palette"), pl("(")),
        Code(pl("        text: .primary,")),
        Code(pl("        detail: .primary."), fn("opacity"), pl("(0.8),")),
        Code(pl("        selection: .accentColor."), fn("opacity"), pl("(0.32)")),
        Code(pl("    )")),
        Code(pl("}")),
    ]
}

/// A text preview or a commit's file as of then: one number gutter, a 1-point rule, the code.
private struct SourcePreview: View {
    let lines: [Code]
    let first: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 0) {
                    Text("\(first + index)").font(AppFont.code(size: codeSize - 1.5)).foregroundStyle(theme.muted)
                        .frame(width: 28, alignment: .trailing)
                    Rectangle().fill(Chrome.border).frame(width: 1).padding(.horizontal, 10)
                    line.text.font(AppFont.code(size: codeSize)).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                .frame(height: codeRow)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

// MARK: Commits

private struct Commit {
    let subject: String
    var lane = 0
    var refs: [Ref] = []
    var signed = false
    let author: String
    let age: String
    var selected = false
}

private struct Ref {
    enum Kind { case head, tag, branch }
    let name: String
    let kind: Kind
}

private struct CommitsTab: View {
    static let commits = [
        Commit(subject: "Theme: high-contrast sidebar rows", refs: [Ref(name: "dark-mode", kind: .head), Ref(name: "origin/dark-mode", kind: .branch)],
               signed: true, author: "Alex Kim", age: "6m", selected: true),
        Commit(subject: "Palette: name colours by role", signed: true, author: "Alex Kim", age: "2h"),
        Commit(subject: "Merge branch 'main' into dark-mode", author: "Alex Kim", age: "3h"),
        Commit(subject: "Billing: round once, half-even", lane: 1, refs: [Ref(name: "main", kind: .branch), Ref(name: "v0.4.2", kind: .tag)],
               signed: true, author: "Sam Ortiz", age: "5h"),
        Commit(subject: "Sidebar: host discs in group headings", author: "Alex Kim", age: "1d"),
        Commit(subject: "Docs: theming guide", lane: 1, author: "Jo Park", age: "1d"),
        Commit(subject: "Theme: start the dark mode", author: "Alex Kim", age: "2d"),
        Commit(subject: "Billing: invoice totals in minor units", lane: 1, author: "Sam Ortiz", age: "2d"),
        Commit(subject: "Release 0.4.1", refs: [Ref(name: "v0.4.1", kind: .tag)], signed: true, author: "Sam Ortiz", age: "4d"),
        Commit(subject: "Files: drop folders onto hosts", author: "Jo Park", age: "5d"),
        Commit(subject: "Tests: cover the empty invoice", author: "Sam Ortiz", age: "6d"),
    ]
    let row: CGFloat = 28
    var body: some View {
        FilesSplit {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text("Uncommitted changes").font(t.font(.content)).foregroundStyle(p.sidebarHostLabel)
                            Spacer()
                            Text("5 files").font(t.font(.caption)).foregroundStyle(p.detail)
                        }
                        .padding(.leading, 56).padding(.trailing, 12).frame(height: row)
                        ForEach(Array(Self.commits.enumerated()), id: \.offset) { _, commit in commitRow(commit) }
                    }
                    Graph(rows: Self.commits.count + 1, row: row)
                }
                Spacer(minLength: 0)
                HStack {
                    Text("200 loaded · scroll for more")
                    Spacer()
                    HStack(spacing: 3) {
                        Text("All branches")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .font(t.font(.caption)).foregroundStyle(p.detail)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Chrome.window)
                .overlay(alignment: .top) { Rectangle().fill(Chrome.border).frame(height: 1) }
            }
        } detail: {
            CommitDetail()
        }
    }

    private func commitRow(_ commit: Commit) -> some View {
        HStack(spacing: 8) {
            Text(commit.subject).font(t.font(.content)).foregroundStyle(commit.selected ? p.ink : p.secondary).lineLimit(1)
            ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in RefChip(ref: ref) }
            if commit.signed { Image(systemName: "checkmark.seal.fill").font(t.symbol(.caption)).foregroundStyle(p.green) }
            Spacer(minLength: 8)
            Text(commit.author).frame(width: 84, alignment: .leading)
            Text(commit.age).frame(width: 24, alignment: .trailing)
        }
        .font(t.font(.caption)).foregroundStyle(p.detail)
        .padding(.leading, 56).padding(.trailing, 12).frame(height: row)
        .background(commit.selected ? selection : .clear)
    }
}

private struct RefChip: View {
    let ref: Ref
    var body: some View {
        let color: Color = switch ref.kind { case .head: p.green; case .tag: p.warning; case .branch: p.muted }
        Text(ref.name).font(t.font(.caption)).foregroundStyle(color)
            .padding(.horizontal, 6).frame(height: 16)
            .background { if ref.kind == .head { Capsule().fill(color.opacity(0.18)) } }
            .overlay { if ref.kind == .tag { Capsule().strokeBorder(color.opacity(0.6), lineWidth: 1) } }
            .overlay { if ref.kind == .branch { Capsule().strokeBorder(p.selectedControl, lineWidth: 1) } }
    }
}

/// The graph: lanes on a 14-point grid from x 22, 2-point lines, 4.5-point dots; green for HEAD's first parents,
/// slate for the rest; the uncommitted dot hollow.
private struct Graph: View {
    let rows: Int
    let row: CGFloat
    var body: some View {
        Canvas { context, _ in
            func x(_ lane: Int) -> CGFloat { 22 + CGFloat(lane) * 14 }
            func y(_ index: Int) -> CGFloat { CGFloat(index) * row + row / 2 }
            let current = p.graphCurrent, merged = p.graphMerged
            var main = Path()
            main.move(to: CGPoint(x: x(0), y: y(0)))
            main.addLine(to: CGPoint(x: x(0), y: y(rows - 1) + row))
            context.stroke(main, with: .color(current), lineWidth: 2)
            // main's lane: from the merge (row 3) through its commits down to where it forked (row 9, Release 0.4.1).
            var side = Path()
            side.move(to: CGPoint(x: x(0), y: y(3)))
            side.addCurve(to: CGPoint(x: x(1), y: y(4)), control1: CGPoint(x: x(0), y: y(3) + row * 0.6),
                          control2: CGPoint(x: x(1), y: y(4) - row * 0.6))
            side.addLine(to: CGPoint(x: x(1), y: y(8)))
            side.addCurve(to: CGPoint(x: x(0), y: y(9)), control1: CGPoint(x: x(1), y: y(8) + row * 0.6),
                          control2: CGPoint(x: x(0), y: y(9) - row * 0.6))
            context.stroke(side, with: .color(merged), lineWidth: 2)
            let lanes = [0] + CommitsTab.commits.map(\.lane)
            for (index, lane) in lanes.enumerated() {
                let dot = Path(ellipseIn: CGRect(x: x(lane) - 4.5, y: y(index) - 4.5, width: 9, height: 9))
                if index == 0 {
                    context.fill(dot, with: .color(ChatColors.current.terminal))
                    context.stroke(dot, with: .color(current), lineWidth: 2)
                } else {
                    context.fill(dot, with: .color(lane == 0 ? current : merged))
                }
            }
        }
        .frame(width: 56, height: CGFloat(rows) * row)
        .allowsHitTesting(false)
    }
}

private struct CommitDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme: high-contrast sidebar rows").font(.system(size: 15.5, weight: .semibold)).foregroundStyle(p.ink)
                HStack(spacing: 5) {
                    Text("a41c9e2").foregroundStyle(p.green)
                    Image(systemName: "doc.on.doc").font(t.symbol(.caption)).foregroundStyle(theme.muted)
                    Text("·")
                    Text("Alex Kim")
                    Text("✓ Signed").foregroundStyle(p.green)
                    Text("·")
                    Text("6 minutes ago")
                }
                .font(t.font(.body)).foregroundStyle(theme.muted)
                Text("Rows take the contrast setting: high contrast draws names semibold and details at 80%, so the sidebar stays readable over bright wallpapers.")
                    .font(.system(size: 13.5)).foregroundStyle(p.secondary).lineSpacing(3)
                    .frame(maxWidth: 480, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14).padding(.horizontal, 16).padding(.bottom, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Chrome.border).frame(height: 1) }
            HStack(spacing: 6) {
                Text("CHANGED FILES").tracking(0.4).foregroundStyle(p.detail)
                Text("3").foregroundStyle(theme.muted)
                Spacer()
                Counts(added: 41, removed: 8)
            }
            .font(t.font(.caption)).padding(.leading, 16).padding(.trailing, 12).frame(height: 28)
            file("M", "Sources/Views/Sidebar.swift", 14, 6, selected: true)
            file("M", "Sources/Theme/Palette.swift", 22, 2)
            file("A", "Sources/Theme/Contrast.swift", 5, 0)
            Rectangle().fill(p.controlBorder).frame(height: 1).padding(.top, 6)
            DiffHeader(letter: "M", path: "Sources/Views/Sidebar.swift", added: 14, removed: 6, review: false)
            DiffBody(rows: Array(ReviewTab.diff.filter {
                if case .comment = $0 { return false }
                if case .composer = $0 { return false }
                return true
            }.map { row -> DiffRow in
                if case .line(let old, let new, let code, _, _) = row { return .line(old: old, new: new, code) }
                return row
            }), review: false)
        }
    }

    private func file(_ letter: String, _ path: String, _ added: Int, _ removed: Int, selected: Bool = false) -> some View {
        HStack(spacing: 8) {
            StatusLetter(letter: letter, tile: true)
            Text(path).font(t.font(.content)).foregroundStyle(p.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Counts(added: added, removed: removed)
        }
        .padding(.leading, 16).padding(.trailing, 12).frame(height: 32)
        .background(selected ? selection : .clear)
    }
}
