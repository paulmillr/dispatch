import SwiftUI

// Files, Review and Commits in a split's panes on a laptop, as the app lays them out (FilesView.shape): a 13-inch
// MacBook Air's zoomed window is 1470 × 920 points; with the sidebar shown, half of it is 602 points wide and a quarter
// 602 × 459. Side by side needs 900 points (FilesView.columnsWidth). Narrower and at least 560 tall (stackHeight), the
// list at its own height (Review's changes) or 40% of the view stands over the detail at the view's width; narrower and
// shorter, one column, Review open on its diff and a commit shown in the log's place, the header's name turned into a
// button back to the list with what is open after it and ↑ ↓ to step. Under 900 points diffs keep one gutter (the new
// line's number, a removed line's old one faint), wrap, and name Diff | Source by glyph; a commit's summary takes three
// lines and More (GitCommitSummary.short).

enum NarrowPanes {
    static let screens: [Screen] = [
        Screen("N1-halves-review", group: "narrow", "Review in half a laptop's window: the changes over the diff") {
            halves(.review)
        },
        Screen("N2-halves-commits", group: "narrow", "Commits in half a laptop's window: the log over the commit") {
            halves(.commits)
        },
        Screen("N3-halves-files", group: "narrow", "Files in half a laptop's window: the tree over the preview") {
            halves(.files)
        },
        Screen("N4-quarters", group: "narrow", "A 4-split: Review on a diff, a commit in the log's place, the tree") {
            quarters()
        },
        Screen("N5-quarters-changes", group: "narrow", "A quarter's Review: the change's name clicked lists the changes") {
            quarters(chooser: true)
        },
        Screen("N6-mode-menu", group: "narrow", "The strip's mode button names Review; held, its menu switches the files tabs") {
            halves(.review).overlay(alignment: .topTrailing) {
                // ChatModeSwitch's hold and right-click menu (ModeSwitchMenuItem.items), under the button.
                MacMenu(items: [
                    MenuItem(title: "Terminal", symbol: "apple.terminal", shortcut: "⇧⌘F"),
                    MenuItem(title: "Chat", symbol: "text.bubble", enabled: false),
                    nil,
                    MenuItem(title: "Files", symbol: "folder", shortcut: "⌃⌘1"),
                    MenuItem(title: "Review", symbol: FilesSegment.review.symbol, shortcut: "⌃⌘2", checked: true),
                    MenuItem(title: "Commits", symbol: FilesSegment.commits.symbol, shortcut: "⌃⌘3", highlighted: true),
                ], width: 210)
                .padding(.top, 44).padding(.trailing, 16)
            }
        },
    ]

    static let width: CGFloat = 1470
    static let height: CGFloat = 920

    // MARK: Windows

    /// Two columns: the agent's chat in the first, a files tab in the second (focused).
    @MainActor static func halves(_ segment: FilesSegment) -> some View {
        DispatchWindow(width: width, height: height, sidebar: Sample.sidebar) {
            Split(fraction: 0.5) {
                Pane(strip: StripModel(tabs: [TabItem(title: "Theme contrast", activity: .finished, selected: true)],
                                       mode: .chat, agent: true, layout: nil, paneBadge: 1, focused: false)) {
                    ChatPane(items: Sample.chat, composer: ComposerModel())
                }
            } second: {
                filesPane(segment, badge: 2, focused: true) {
                    switch segment {
                    case .review: StackedReview()
                    case .commits: StackedCommits()
                    case .files: StackedFiles()
                    }
                }
            }
        }
    }

    /// The grid: tests in a terminal, Review, Commits, Files.
    @MainActor static func quarters(chooser: Bool = false) -> some View {
        DispatchWindow(width: width, height: height, sidebar: Sample.sidebar) {
            Split(fraction: 0.5) {
                Split(axis: .vertical, fraction: 0.5) {
                    Pane(strip: StripModel(tabs: [TabItem(title: "tests", selected: true)], layout: nil, paneBadge: 1,
                                           focused: false)) {
                        TerminalScreen(lines: Sample.tests, focused: false)
                    }
                } second: {
                    filesPane(.commits, badge: 3, focused: false,
                              header: FilesHeader(segment: .commits, commit: CommitsTab.commits[0].subject)) {
                        CompactCommit(subject: false)
                    }
                }
            } second: {
                Split(axis: .vertical, fraction: 0.5) {
                    filesPane(.review, badge: 2, focused: true,
                              header: FilesHeader(segment: .review, reviewFile: true, fileMenu: chooser)) {
                        ReviewOnDiff(chooser: chooser)
                    }
                } second: {
                    filesPane(.files, badge: 4, focused: false) { TreeOnly() }
                }
            }
        }
    }

    /// A pane in Files mode: its strip (titled as FilesTab.tabName, the mode button naming the files tab), the files
    /// header, the tab's content.
    @MainActor static func filesPane<Content: View>(_ segment: FilesSegment, badge: Int, focused: Bool,
                                                    header: FilesHeader? = nil,
                                                    @ViewBuilder content: () -> Content) -> some View {
        let title = switch segment {
        case .files: "Theme/Palette.swift"
        case .review: "Review dark-mode"
        case .commits: CommitsTab.commits[0].subject
        }
        let strip = StripModel(tabs: [TabItem(title: title, selected: true)], mode: .files, layout: badge == 2 ? .grid : nil,
                               paneBadge: badge, focused: focused, modeSymbol: segment.symbol)
        return Pane(strip: strip, focusEdge: focused) {
            VStack(spacing: 0) {
                header ?? FilesHeader(segment: segment)
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            }
            .background(ChatColors.current.terminal)
        }
    }
}

@MainActor private var p: SidebarPalette { Chrome.palette }
@MainActor private var t: AppTypography { Mock.typography }
@MainActor private var theme: ChatColors { ChatColors.current }

// MARK: Pieces

extension FilesSegment {
    /// ModeSwitchState.glyph: the folder, Review the phone's clipboard (the chat bubble is Chat's), Commits the clock.
    var symbol: String {
        switch self {
        case .files: "folder"
        case .review: "pencil.and.list.clipboard"
        case .commits: "clock.arrow.circlepath"
        }
    }

    /// FilesHeader.title.
    var title: String {
        switch self {
        case .files: "Files"
        case .review: "Review"
        case .commits: "Commits"
        }
    }
}

/// FilesHeader.tabName: the tab's name in semibold ink; one column with a detail shown, the way back: "‹", the tab's
/// glyph in the accent, the name, on a raised pill.
struct FilesPill: View {
    let segment: FilesSegment
    var back = false
    var body: some View {
        if back {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(t.symbol(.micro, weight: .bold))
                Image(systemName: segment.symbol).font(t.symbol(.caption))
                Text(segment.title).foregroundStyle(p.ink)
            }
            .font(t.font(.label, weight: .semibold))
            .foregroundStyle(p.accent)
            .lineLimit(1)
            .padding(.horizontal, 9).frame(height: t.expanded(22))
            .background(Capsule().fill(Mock.glass ? GlassTone.selected : p.selectedControl))
            .fixedSize()
        } else {
            Text(segment.title).font(t.font(.label, weight: .semibold)).foregroundStyle(p.ink).fixedSize()
        }
    }
}

/// FilesSplitLayout's stacked shape: the list `list` points tall over the 1-point line and the detail.
private struct Stacked<List: View, Detail: View>: View {
    let list: CGFloat
    @ViewBuilder let top: List
    @ViewBuilder let detail: Detail
    var body: some View {
        VStack(spacing: 0) {
            top.frame(maxWidth: .infinity).frame(height: list, alignment: .top).clipped()
            Chrome.border.frame(height: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        }
    }
}

/// GitDiffModePicker with `glyphs`: Diff | Source as two glyphs on the picker's track.
struct GlyphModePicker: View {
    var body: some View {
        HStack(spacing: 1) {
            segment("plus.forwardslash.minus", on: true)
            segment("doc.plaintext", on: false)
        }
        .padding(1)
        .background { if Mock.glass { GlassCapsule() } else { RoundedRectangle(cornerRadius: 5).fill(p.control) } }
        .fixedSize()
    }

    private func segment(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: t.size(offset: -2.5), weight: .medium)).foregroundStyle(on ? p.ink : p.muted)
            .frame(width: t.expanded(16)).padding(.horizontal, 8).frame(height: 20)
            .background {
                if on {
                    if Mock.glass { Capsule().fill(GlassTone.selected) } else { RoundedRectangle(cornerRadius: 4).fill(p.selectedControl) }
                }
            }
    }
}

/// GitCommitSummary.short: the subject on one line (none on one column, where the header names the commit), the hash,
/// the author with the seal and the age, the body's first line and More.
private struct CompactSummary: View {
    var subject = true
    var body: some View {
        let commit = CommitsTab.commits[0]
        VStack(alignment: .leading, spacing: 5) {
            if subject {
                Text(commit.subject).font(.system(size: t.size(offset: 1.5), weight: .semibold)).foregroundStyle(p.ink)
            }
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("a41c9e2")
                    Image(systemName: "doc.on.doc").font(t.symbol(.caption))
                }
                .foregroundStyle(p.green)
                Text("·").foregroundStyle(p.faint)
                HStack(spacing: 6) {
                    Text("Alex Rivera")
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").font(t.symbol(.caption))
                        Text("Signed")
                    }
                    .foregroundStyle(p.green)
                }
                Text("·").foregroundStyle(p.faint)
                Text("35 min ago")
                Spacer(minLength: 0)
            }
            .font(t.font(.body)).foregroundStyle(p.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Adds the high-contrast palette: details at 80% and a stronger selection, so the sidebar stays readable over bright wallpapers.")
                    .font(.system(size: t.size(offset: -0.5))).foregroundStyle(p.secondary)
                Text("More").font(.system(size: t.size(offset: -0.5))).foregroundStyle(p.accent).fixedSize()
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .overlay(alignment: .bottom) { p.separator.frame(height: 1) }
    }
}

/// GitCommitDetailPane in a compact split: the short summary, the changed files, the picked file's diff.
private struct CompactCommit: View {
    var subject = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactSummary(subject: subject)
            CommitDetail().files
            p.controlBorder.frame(height: 1)
            DiffHeader(path: "Sources/Theme/Palette.swift", added: 6, removed: 0, review: false, compact: true)
            DiffBody(rows: CommitDetail.diff, review: false, oneGutter: true, wrap: true)
        }
    }
}

/// FilesSplit's height under a half's strip and files header.
@MainActor private var halfSplit: CGFloat { NarrowPanes.height - t.expanded(38) - t.expanded(34) }

// MARK: Halves

/// Review stacked: the changes at their own height (GitChangesList.height), the picked one's diff under them.
private struct StackedReview: View {
    var body: some View {
        let tab = ReviewTab()
        Stacked(list: t.expanded(28) + 4 + 2 * (t.expanded(26) + 6) + 3 * t.expanded(28) + 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("3 files").foregroundStyle(p.detail)
                    Counts(added: 37, removed: 3, totals: true)
                    Spacer(minLength: 0)
                }
                .font(t.font(.body)).lineLimit(1)
                .padding(.leading, 14).padding(.trailing, 12)
                .frame(height: t.expanded(28)).padding(.top, 4)
                tab.group("Unstaged", tab.unstaged)
                tab.group("Untracked", tab.untracked)
                Spacer(minLength: 0)
            }
        } detail: {
            VStack(spacing: 0) {
                DiffHeader(letter: "M", path: "Sources/Views/Sidebar.swift", added: 6, removed: 1, compact: true)
                DiffBody(rows: ReviewTab.diff, scroll: 4 + 30 + 2 * CodeMetrics.rowHeight, oneGutter: true, wrap: true)
            }
        }
    }
}

/// Commits stacked: the log at 40% of the view over the selected commit.
private struct StackedCommits: View {
    var body: some View {
        Stacked(list: (halfSplit * 0.4).rounded()) {
            VStack(spacing: 0) {
                GeometryReader { geometry in CommitsTab().rows(width: geometry.size.width) }
                CommitsTab().footer
            }
        } detail: {
            CompactCommit()
        }
    }
}

/// The tree's column names and rows (FilesColumnHeader, FilesOutline).
private struct Tree: View {
    var body: some View {
        let tab = FilesTab()
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Modified").frame(width: t.expanded(64), alignment: .trailing)
                Text("Size").frame(width: t.expanded(72), alignment: .trailing)
            }
            .font(t.font(.caption)).foregroundStyle(p.detail)
            .padding(.leading, 14).padding(.trailing, 12)
            .frame(height: FilesTab.headerHeight + 1)
            .overlay(alignment: .bottom) { p.separator.frame(height: 1) }
            ForEach(Array(tab.nodes.enumerated()), id: \.offset) { _, node in tab.row(node) }
            Spacer(minLength: 0)
        }
    }
}

/// Files stacked: the tree at 40% of the view over the picked file's preview.
private struct StackedFiles: View {
    var body: some View {
        Stacked(list: (halfSplit * 0.4).rounded()) {
            Tree()
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Palette.swift").font(t.font(.content)).foregroundStyle(theme.ink).lineLimit(1).layoutPriority(1)
                    IconButton { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    Text("572 B · modified 6m ago").font(t.font(.body)).foregroundStyle(theme.muted).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        IconButton { WrapGlyph() }
                        IconButton { Image(systemName: "square.and.pencil").font(.system(size: 11)) }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: FilesTab.headerHeight)
                theme.border.frame(height: 1)
                SourcePreview(lines: FilesTab.palette)
            }
        }
    }
}

// MARK: Quarters

/// Review on one column, open on the change's diff (the header names the change and steps through them).
private struct ReviewOnDiff: View {
    var chooser = false
    var body: some View {
        VStack(spacing: 0) {
            DiffHeader(letter: "M", path: "Sources/Views/Sidebar.swift", added: 6, removed: 1, compact: true)
            DiffBody(rows: ReviewTab.diff, scroll: 4 + 30 + 4 * CodeMetrics.rowHeight, oneGutter: true, wrap: true)
        }
        .overlay(alignment: .topLeading) {
            // Under the change's name in the header.
            if chooser { ChangeChooser().padding(.leading, 112).padding(.top, 2) }
        }
    }
}

/// FilesChangeChooser in its popover: the changes by area, each with its letter, name and folder, the shown one checked.
private struct ChangeChooser: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Unstaged")
            item("M", "Palette.swift", "Sources/Theme")
            item("M", "Sidebar.swift", "Sources/Views", checked: true)
            heading("Untracked")
            item("U", "Contrast.swift", "Sources/Theme", hovered: true)
        }
        .padding(.vertical, 6)
        .frame(width: t.expanded(320), alignment: .leading)
        .background(p.isDark ? Color(white: 0.19) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(t.font(.caption, weight: .semibold)).foregroundStyle(p.detail)
            .padding(.leading, 30).padding(.top, 6).padding(.bottom, 2)
    }

    private func item(_ letter: String, _ name: String, _ folder: String, checked: Bool = false,
                      hovered: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(t.symbol(.caption, weight: .semibold)).frame(width: 14).opacity(checked ? 1 : 0)
            Badge(letter: letter, side: 14, plain: true)
            Text(name).foregroundStyle(p.ink)
            Text(folder).foregroundStyle(p.detail)
            Spacer(minLength: 0)
        }
        .font(t.font(.body)).lineLimit(1)
        .padding(.horizontal, 8).frame(height: t.expanded(24))
        .background(hovered ? p.ink.opacity(0.08) : .clear)
    }
}

/// Files on one column: the tree with its columns across the pane; ⏎ shows the file in its place.
private struct TreeOnly: View {
    var body: some View {
        VStack(spacing: 0) {
            Tree()
            HStack(spacing: 0) {
                Text("7 items · 1 selected")
                Spacer(minLength: 12)
            }
            .lineLimit(1)
            .padding(.leading, 14).padding(.trailing, 12)
            .frame(height: t.expanded(24))
            .font(t.font(.caption)).foregroundStyle(p.detail)
            .background(Chrome.window)
            .overlay(alignment: .top) { p.separator.frame(height: 1) }
        }
    }
}
