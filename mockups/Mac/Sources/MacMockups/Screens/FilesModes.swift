import AppKit
import SwiftUI

// Files mode's three tabs as the Mac app draws them, the sidebar hidden (FilesView, FilesHeader, FilesOutline, FilePreviewPane,
// FileTextPreview, FileTransferRows, GitChangesView, GitDiffView, ReviewViews, GitCommitsView): the files header over a
// list | detail split, the detail 560 points wide once the view is 1,000 wide (FilesView.layout). Fictional repository:
// `app` (in ~/src) on `dark-mode`, up to date with origin/dark-mode, with the working tree of the kit's `git status`
// sample: Sources/Theme/Palette.swift and Sources/Views/Sidebar.swift modified, Sources/Theme/Contrast.swift untracked.

enum FilesModes {
    static let screens: [Screen] = [
        Screen("J1-files", group: "files", "Files: the tree with columns, a file's preview, a transfer") {
            // FilesTab.tabName: a file's parent folder and its name.
            window(tab: "Theme/Palette.swift", segment: .files) { FilesTab() }
        },
        Screen("J1g-files-glass", group: "files", "Files on Liquid Glass: today's bars, and the proposal at rest and scrolled") {
            FilesGlassBoard()
        },
        Screen("J2-review", group: "files", "Review: the changes, a diff with a comment and a comment being written") {
            // FilesTab.tabName: "Review" and the branch.
            window(tab: "Review dark-mode", segment: .review) { ReviewTab() }
        },
        Screen("J2b-review-finish", group: "files", "Review: Finish your review, before sending it to the agent") {
            window(tab: "Review dark-mode", segment: .review, finishing: true) { ReviewTab(composing: false) }
        },
        Screen("J3-commits", group: "files", "Commits: the graph, a commit's summary, files and diff") {
            // FilesTab.tabName: the open commit's subject.
            window(tab: CommitsTab.commits[0].subject, segment: .commits) { CommitsTab() }
        },
    ]

    @MainActor static func window<Content: View>(tab: String, segment: FilesSegment, finishing: Bool = false,
                                                 width: CGFloat = 1180, height: CGFloat = 780, floating: Bool = false,
                                                 @ViewBuilder content: () -> Content) -> some View {
        DispatchWindow(width: width, height: height, sidebar: nil) {
            Pane(strip: StripModel(tabs: [
                TabItem(title: tab, shortcut: 1, selected: true),
                TabItem(title: "Theme contrast", activity: .finished, shortcut: 2),
            ], mode: .files, titleRow: true, modeSymbol: segment.symbol)) {
                Group {
                    if floating {
                        // Proposal (J1g): no bar. The content runs to the top, under the header and the column
                        // headers it pins there, behind one soft scroll edge, as macOS 26's toolbars over content.
                        // The content draws the edge under the rows it pins (FilesTab.floatingBody).
                        ZStack(alignment: .top) {
                            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            FilesHeader(segment: segment, floating: true)
                        }
                    } else {
                        VStack(spacing: 0) {
                            FilesHeader(segment: segment)
                            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .background(ChatColors.current.terminal)
                // ReviewHeaderButton's popover (`.popover(arrowEdge: .bottom)`), under Create review.
                .overlayPreferenceValue(CreateReviewAnchor.self) { anchor in
                    if finishing, let anchor {
                        GeometryReader { geometry in
                            let button = geometry[anchor]
                            // Centred under the button as macOS places a popover, kept inside the window here.
                            let x = min(max(8, button.midX - FinishReview.width / 2), geometry.size.width - FinishReview.width - 8)
                            FinishReview(arrow: button.midX - x)
                                .offset(x: x, y: button.maxY + 2)
                        }
                    }
                }
            }
        }
    }
}

enum FilesSegment { case files, review, commits }

// MARK: Shared

@MainActor private var p: SidebarPalette { Chrome.palette }
@MainActor private var t: AppTypography { Mock.typography }
@MainActor private var theme: ChatColors { ChatColors.current }
/// Selected rows everywhere: the ink at 8% (FilesOutlineStyle.wash, GitChangeRow, GitCommitRow).
@MainActor private var selection: Color { p.ink.opacity(0.08) }

/// The code font as the preview and diffs draw it (ChatTypography.codeFont): Source Code Pro at Settings › Font size
/// (`Preferences.fontSize`, 14), unscaled.
@MainActor enum CodeMetrics {
    static var size: CGFloat { Mock.contentSize }
    static func font(_ offset: CGFloat = 0) -> Font { AppFont.code(size: size + offset) }
    /// FilePreviewMetrics.metrics: TextKit's line for the code font, rounded up.
    static var lineHeight: CGFloat { ceil(AppFont.lineHeight(size: size)) }
    /// FilePreviewMetrics.metrics: one line's row, max(line + 4, size × 1.6).
    static var rowHeight: CGFloat { max(lineHeight + 4, (size * 1.6).rounded()) }
    /// FilePreviewMetrics.metrics: a "0"'s advance.
    static var digitWidth: CGFloat {
        _ = AppFont.lineHeight(size: size)  // registers the bundled fonts
        let font = NSFont(name: "SourceCodePro-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}

/// A glass capsule (`liquidGlass(in: Capsule())`, `glassEffect(.regular, in: Capsule())`) as the kit draws glass
/// offscreen: GlassTone's track and rim, the strip's soft shadow (Kit/Strip.swift).
struct GlassCapsule: View {
    var fill: Color = GlassTone.track
    var body: some View {
        Capsule().fill(fill)
            .overlay(Capsule().strokeBorder(GlassTone.trackEdge, lineWidth: 0.5))
            .shadow(color: GlassTone.shadow, radius: 2, y: 1)
    }
}

/// The files header (FilesHeader): the tab's name (FilesPill), where you are (crumbs and the follow link on Files; the
/// repository line, and on Review Create review with the comments' count), the search and the pane's toggle on one
/// glass pill. The files tabs are the strip's mode button's (its glyph names the one shown, its menu switches).
struct FilesHeader: View {
    let segment: FilesSegment
    /// One column with a commit open in the log's place (FilesSession.drilled): "‹ Commits", back to the log, then the
    /// commit's subject; ↑ ↓ step through the log.
    var commit: String?
    /// One column on a change's diff: "‹ Review", back to the changes, then the change (its name opens the others,
    /// `fileMenu` open) and where it is among them; ↑ ↓ step through them.
    var reviewFile = false
    var fileMenu = false
    /// Proposal (J1g): no fill of its own; it floats over the content's scroll edge.
    var floating = false
    /// FilesHeader.height: expanded(34).
    static var height: CGFloat { t.expanded(34) }
    var body: some View {
        HStack(spacing: 12) {
            FilesPill(segment: segment, back: commit != nil || reviewFile)
            if segment == .files {
                HStack(spacing: 6) {
                    Crumbs()
                    // followToggle: lit while the view follows the shell's cd (FilesSession.followsShell, the default).
                    HeaderButton(symbol: "link", on: true)
                }
            } else if reviewFile {
                // FilesHeader.opened: the change (changesMenu) and "2 of 3".
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Badge(letter: "M", side: 14, plain: true)
                        Text("Sidebar.swift").font(t.font(.label, weight: .semibold)).foregroundStyle(p.ink)
                        Image(systemName: "chevron.up.chevron.down").font(t.symbol(.micro, weight: .semibold))
                    }
                    .fixedSize()
                    .padding(.horizontal, 6).frame(height: t.expanded(22))
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.ink.opacity(fileMenu ? 0.12 : 0)))
                    .padding(.horizontal, -6)
                    Text("2 of 3").font(t.font(.caption)).foregroundStyle(p.detail).fixedSize()
                }
                .lineLimit(1)
            } else if let commit {
                Text(commit).font(t.font(.label, weight: .semibold)).foregroundStyle(p.ink).lineLimit(1)
            } else {
                RepositoryLine()
            }
            if segment == .review { CreateReviewButton(count: 3) }
            Spacer(minLength: 0)
            if commit != nil || reviewFile {
                // stepButton: the previous and next change or commit.
                HStack(spacing: Mock.glass ? 2 : 12) {
                    HeaderButton(symbol: "chevron.up")
                    HeaderButton(symbol: "chevron.down")
                }
                .modifier(GlassControlGroup())
            }
            // searchSlot and paneToggle (lit while the pane shows), `glassControlGroup()`: spacing 2 on glass, 12 flat.
            HStack(spacing: Mock.glass ? 2 : 12) {
                HeaderButton(symbol: "magnifyingglass")
                HeaderButton(symbol: "rectangle.righthalf.inset.filled", on: true)
            }
            .modifier(GlassControlGroup())
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .font(t.font(.label)).foregroundStyle(p.muted)
        .background(floating ? Color.clear : Chrome.window)
        .overlay(alignment: .bottom) { if !Mock.glass && !floating { p.separator.frame(height: 1) } }
    }
}

/// GlassControlGroup: the buttons on one glass capsule, 3 × 2 inside it; flat chrome leaves them bare.
struct GlassControlGroup: ViewModifier {
    func body(content: Content) -> some View {
        if Mock.glass {
            content.padding(.horizontal, 3).padding(.vertical, 2).background(GlassCapsule())
        } else {
            content
        }
    }
}

/// FilesHeaderButtonStyle: muted, the ink and a 6% wash while on; a capsule on glass, a 4-point square flat. The symbol
/// at the body size in an expanded(22) square (searchButton, paneToggle, followToggle).
struct HeaderButton: View {
    let symbol: String
    var on = false
    var body: some View {
        let fill = on ? p.ink.opacity(0.06) : Color.clear
        Image(systemName: symbol).font(t.symbol(.body))
            .frame(minWidth: t.expanded(22), minHeight: t.expanded(22))
            .foregroundStyle(on ? p.ink : p.muted)
            .background {
                if Mock.glass { Capsule().fill(fill) } else { RoundedRectangle(cornerRadius: 4).fill(fill) }
            }
    }
}

/// crumbRow: FilesPath.crumbs from home ("~ / src / app"), the shown folder in `secondary`, the others `sidebarDetail`,
/// the "/" between them `faint`.
struct Crumbs: View {
    let crumbs = ["~", "src", "app"]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Text("/").foregroundStyle(p.faint) }
                Text(crumb).foregroundStyle(index == crumbs.count - 1 ? p.secondary : p.sidebarDetail)
            }
        }
        .font(t.font(.label)).lineLimit(1).fixedSize()
    }
}

/// repositoryLine: the repository's name in `secondary`, the branch glyph `faint`, the branch; no ↑/↓ while it is up to
/// date with its upstream (the kit's `git status`).
struct RepositoryLine: View {
    var name = true
    var body: some View {
        HStack(spacing: 6) {
            if name { Text("app").foregroundStyle(p.secondary) }
            Image(systemName: "arrow.triangle.branch").font(t.symbol(.caption)).foregroundStyle(p.faint)
            Text("dark-mode")
        }
        .font(t.font(.label)).lineLimit(1)
    }
}

/// Where Create review is, for its popover (J2b).
struct CreateReviewAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// ReviewHeaderButton in ReviewCreateButtonStyle: title and icon in white at the header's label size, 10 in, expanded(22)
/// tall, on a capsule of the theme's blue at 90%.
struct CreateReviewButton: View {
    /// ReviewHeaderButton.countPill: the review's comments, in the blue on white.
    var count: Int? = 3
    var body: some View {
        HStack(spacing: 6) {
            Label("Create Review", systemImage: "text.bubble.fill").labelStyle(.titleAndIcon)
            if let count {
                Text("\(count)").font(t.font(.caption)).foregroundStyle(theme.blue)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.white))
            }
        }
            .font(t.font(.label)).foregroundStyle(.white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 10).frame(height: t.expanded(22))
            .background(Capsule().fill(theme.blue.opacity(0.9)))
            .anchorPreference(key: CreateReviewAnchor.self, value: .bounds) { $0 }
    }
}

/// FilesSplit at FilesView.layout's widths: the detail 560 once the view is 1,000 wide (else half, within the list's
/// 320 and the preview's 240), its 1-point `Chrome.border` inside that width; none under 900.
struct FilesSplit<List: View, Detail: View>: View {
    @ViewBuilder let list: List
    @ViewBuilder let detail: Detail
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // FilesView.layout: under columnsWidth (900) no column beside the list (the stacked and
            // one-column shapes); else the preview within the minima (list 320, preview 240).
            let preview: CGFloat? = width < 900 ? nil
                : min(max(width >= 1_000 ? 560 : width / 2, 240), max(240, width - 320)).rounded()
            let height = geometry.size.height
            HStack(spacing: 0) {
                list.frame(width: width - (preview ?? 0), height: height, alignment: .topLeading).clipped()
                if let preview {
                    Chrome.border.frame(width: 1)
                    detail.frame(width: preview - 1, height: height, alignment: .topLeading).clipped()
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
    }
}

/// GitChangeBadge: the status letter in its kind's colour, plain at the body size semibold (Review), or at the caption
/// size on its tint at 12% (14% deleted) on a 5-point corner (Commits).
struct Badge: View {
    let letter: String
    var side: CGFloat = 20
    var plain = false
    /// GitChangeBadge.color: M and T `warning`, A, U and C `green`, D and X #eca19a, R SyntaxHighlight.function.
    var color: Color {
        switch letter {
        case "M", "T": p.warning
        case "A", "U", "C": p.green
        case "D", "X": Color(red: 236 / 255, green: 161 / 255, blue: 154 / 255)
        case "R": Color(red: 0.49, green: 0.72, blue: 0.89)
        default: p.detail
        }
    }
    var body: some View {
        Text(letter).font(t.font(plain ? .body : .caption, weight: plain ? .semibold : .regular)).foregroundStyle(color)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: 5).fill(plain ? .clear : color.opacity(letter == "D" ? 0.14 : 0.12)))
    }
}

/// GitCounts: "+8 −5" 4 apart in GitChangeBadge's added and deleted colours; `totals` shows both signs. The caller sets
/// the font.
struct Counts: View {
    let added: Int
    var removed = 0
    var totals = false
    var body: some View {
        HStack(spacing: 4) {
            if added > 0 || totals { Text("+\(added)").foregroundStyle(p.green) }
            if removed > 0 || totals { Text("−\(removed)").foregroundStyle(Color(red: 236 / 255, green: 161 / 255, blue: 154 / 255)) }
        }
        .monospacedDigit().lineLimit(1).fixedSize()
    }
}

/// FilePreviewButtonStyle: the body size, 10 in, 22 tall; prominent, the ink at 90% on a glass capsule (flat: a 7% well),
/// else the ink at 60% with no ground.
@MainActor func previewButton(_ title: String, prominent: Bool = true) -> some View {
    Text(title).font(t.font(.body))
        .foregroundStyle(theme.ink.opacity(prominent ? 0.9 : 0.6))
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 10).frame(height: 22)
        .background {
            if prominent {
                if Mock.glass { GlassCapsule() } else { RoundedRectangle(cornerRadius: 5).fill(theme.ink.opacity(0.07)) }
            }
        }
}

/// FilePreviewIconButtonStyle: the ink at 60%, 5 in, at least 22 × 22; lit (the ink, an 8% wash) while on.
struct IconButton<Label: View>: View {
    var on = false
    @ViewBuilder let label: Label
    var body: some View {
        let fill = on ? theme.ink.opacity(0.08) : Color.clear
        label.font(t.font(.body))
            .foregroundStyle(on ? theme.ink : theme.ink.opacity(0.6))
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 22)
            .background { if Mock.glass { Capsule().fill(fill) } else { RoundedRectangle(cornerRadius: 4).fill(fill) } }
    }
}

/// FileWrapGlyph: three lines, the middle one turning back under itself, on a 14-point grid.
struct WrapGlyph: View {
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
        .frame(width: 14, height: 14)
    }
}

/// A text editor as ReviewTextEditor draws it: the chat reply font (ChatTypography.reply) 8 × 6 in, the caret in the
/// ink (ChatCaretTextView), on the terminal's ground in a 6-point frame of `border`; at least `minimum` tall.
struct Editor: View {
    let text: String
    var caret = true
    let minimum: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            Text(text).font(ChatType.reply).foregroundStyle(theme.ink).lineLimit(1)
            if caret { Rectangle().fill(theme.ink).frame(width: 1.5, height: ChatType.replyLineHeight - 2).padding(.leading, 1) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(height: max(ChatType.replyLineHeight + 12, minimum), alignment: .topLeading)
        .background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
    }
}

// MARK: Code

/// A run of code coloured by an ANSI index of the terminal scheme (nil: the foreground).
struct Code {
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

// SyntaxHighlight.tokens on the desktop profile (SyntaxScanner), in ChatTheme's colours: keywords `keyword` (palette 5),
// capitalised names and calls `blue` (4), strings `string` (2), numbers `number` (3), comments `comment` (8). `some` is
// not a desktop keyword; "@State" is a plain "@" and a capitalised name.
func kw(_ s: String) -> (String, Int?) { (s, 5) }
func ty(_ s: String) -> (String, Int?) { (s, 4) }
func fn(_ s: String) -> (String, Int?) { (s, 4) }
func st(_ s: String) -> (String, Int?) { (s, 2) }
func nu(_ s: String) -> (String, Int?) { (s, 3) }
func cm(_ s: String) -> (String, Int?) { (s, 8) }
func pl(_ s: String) -> (String, Int?) { (s, nil) }

enum DiffRow {
    case hunk(String, String)
    case line(old: Int?, new: Int?, Code, hoverPlus: Bool = false, draft: Bool = false)
    /// GitDiffView.gapRow: the lines between two hunks, opened from the file.
    case gap(Int)
    case comment(location: String, text: String)
    case composer(location: String, draft: String)
}

/// GitDiffView.rowsView in Diff mode: hunk headers, two number gutters, the sign column and the code, green and red
/// washes, gaps; reviewing, the 20-point column for the + ahead of every line and the cards under their line.
struct DiffBody: View {
    let rows: [DiffRow]
    var review = true
    /// How far the diff is scrolled down.
    var scroll: CGFloat = 0
    /// Proposed for narrow panes: one number column (the new line's, a deleted line's old number in `faint`).
    var oneGutter = false
    /// Long lines wrap under their code's start instead of running off the pane.
    var wrap = false

    /// ReviewLineAction's column.
    private var inset: CGFloat { review ? 20 : 0 }
    /// GitDiffView.gutterWidth: two digits of the numbers' font, + 12, at least 34.
    private var gutter: CGFloat {
        max(34, (2 * CodeMetrics.digitWidth * (CodeMetrics.size - 1.5) / CodeMetrics.size + 12).rounded(.up))
    }
    private var codeLeading: CGFloat { inset + gutter * (oneGutter ? 1 : 2) + 14 }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in rowView(row, pane: geometry.size.width) }
            }
            .padding(.top, 4)
            // Rows that wrap keep their height when the diff runs past the pane.
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: geometry.size.width, alignment: .topLeading)
            .offset(y: -scroll)
        }
        .clipped()
    }

    @ViewBuilder private func rowView(_ row: DiffRow, pane: CGFloat) -> some View {
        // reviewRow: in line with the code, no wider than the pane.
        let cardWidth = max(oneGutter ? 200 : 260, min(pane - codeLeading - 14, 720))
        switch row {
        case .hunk(let range, let section):
            HStack(spacing: 10) {
                Text(range).foregroundStyle(theme.blue)
                Text(section).foregroundStyle(theme.muted)
            }
            .font(CodeMetrics.font(-1)).lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
            .background(theme.blue.opacity(0.07))
            .padding(.vertical, 4)
        case .line(let old, let new, let code, let hoverPlus, let draft):
            let tint: Color = old == nil ? theme.green.opacity(0.10) : new == nil ? theme.red.opacity(0.10) : .clear
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if inset > 0 { Color.clear.frame(width: inset, height: 1) }
                if oneGutter {
                    number(new ?? old, faint: new == nil)
                } else {
                    number(old)
                    number(new)
                }
                Text(old == nil ? "+" : new == nil ? "−" : "").foregroundStyle(old == nil ? theme.green : theme.red)
                    .frame(width: 14)
                if wrap {
                    code.text.lineSpacing(CodeMetrics.rowHeight - CodeMetrics.lineHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
                } else {
                    code.text.lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .font(CodeMetrics.font())
            .padding(.vertical, wrap ? (CodeMetrics.rowHeight - CodeMetrics.lineHeight) / 2 : 0)
            .frame(maxWidth: .infinity, minHeight: CodeMetrics.rowHeight, maxHeight: wrap ? nil : CodeMetrics.rowHeight,
                   alignment: .leading)
            .background(tint)
            // ReviewLineAction: the comment being written tints its lines; the + shows on the line under the pointer.
            .background(draft ? theme.blue.opacity(0.14) : .clear)
            .overlay(alignment: .leading) {
                if hoverPlus {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(theme.blue, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 3)
                }
            }
        case .gap(let count):
            HStack(spacing: 8) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                // GitChangesText.unmodified.
                Text("\(count) unmodified \(count == 1 ? "line" : "lines")")
            }
            .font(t.font(.body)).foregroundStyle(theme.muted).lineLimit(1)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
            .background(Chrome.window)
            .overlay(alignment: .top) { theme.border.frame(height: 1) }
            .overlay(alignment: .bottom) { theme.border.frame(height: 1) }
        case .comment(let location, let text):
            CommentCard(location: location, text: text)
                .frame(width: cardWidth, alignment: .leading)
                .padding(.leading, codeLeading).padding(.vertical, 6)
        case .composer(let location, let draft):
            CommentComposer(location: location, draft: draft)
                .frame(width: cardWidth, alignment: .leading)
                .padding(.leading, codeLeading).padding(.vertical, 6)
        }
    }

    /// GitDiffView.number: the code font 1.5 smaller, muted, right-aligned 8 in from the gutter's end.
    private func number(_ value: Int?, faint: Bool = false) -> some View {
        Text(value.map(String.init) ?? "").font(CodeMetrics.font(-1.5)).foregroundStyle(faint ? theme.muted.opacity(0.5) : theme.muted)
            .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8)
    }
}

/// ReviewCommentCard: where it is, Edit and Delete (not prominent), the text at the label size; 8 · 10 · 10 · 8 in,
/// on `Chrome.window` in an 8-point frame of `border`.
struct CommentCard: View {
    let location: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").foregroundStyle(theme.blue)
                Text(location).foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                previewButton("Edit", prominent: false)
                previewButton("Delete", prominent: false)
            }
            .font(t.font(.body)).lineLimit(1)
            Text(text).font(t.font(.label)).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 8))
        .background(Chrome.window, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border))
    }
}

/// ReviewComposer: what it comments on, the editor (at least 30 tall), the keys, Cancel and Comment; 10 in, on
/// `Chrome.window` in an 8-point frame of the blue at 50%.
struct CommentComposer: View {
    let location: String
    let draft: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(location).font(t.font(.body)).foregroundStyle(theme.muted)
            Editor(text: draft, minimum: 30)
            HStack(spacing: 8) {
                Text("⏎ comments · ⌥⏎ / ⇧⏎ new line · esc cancels").font(t.font(.caption)).foregroundStyle(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                previewButton("Cancel", prominent: false)
                previewButton("Comment")
            }
        }
        .padding(10)
        .background(Chrome.window, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.blue.opacity(0.5)))
    }
}

/// GitDiffView.header: 40 tall, 14 in, 10 apart: the status letter (Review only; GitCommitDiff passes no kind), the
/// path, the counts at the body size, then wrap (FileWrapGlyph, off: `diffWrap`), comment on the file (Review) and
/// Diff | Source; a 1-point `border` under it.
struct DiffHeader: View {
    var letter: String?
    let path: String
    let added: Int
    let removed: Int
    var review = true
    /// A compact split (FilesView.columnsWidth): Diff | Source as glyphs, wrap on (`FilesSession.wraps`).
    var compact = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let letter { Badge(letter: letter, side: 18, plain: true) }
                Text(path).font(t.font(.content)).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Counts(added: added, removed: removed).font(t.font(.body))
                Spacer(minLength: 0)
                IconButton(on: compact) { WrapGlyph() }
                if review {
                    IconButton { Image(systemName: "text.bubble").font(.system(size: 11, weight: .medium)).frame(width: 14, height: 14) }
                }
                if compact { GlyphModePicker() } else { ModePicker() }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            theme.border.frame(height: 1)
        }
    }
}

/// GitDiffModePicker: Diff | Source 1 apart on the track (inset 1, a 5-point corner flat), each at the body size, 8 in,
/// 20 tall, Diff (`diffMode`'s default) raised.
struct ModePicker: View {
    var body: some View {
        HStack(spacing: 1) {
            segment("Diff", on: true)
            segment("Source", on: false)
        }
        .padding(1)
        .background { if Mock.glass { GlassCapsule() } else { RoundedRectangle(cornerRadius: 5).fill(p.control) } }
        .fixedSize()
    }

    private func segment(_ title: String, on: Bool) -> some View {
        Text(title).font(t.font(.body)).foregroundStyle(on ? p.ink : p.muted)
            .padding(.horizontal, 8).frame(height: 20)
            .background {
                if on {
                    if Mock.glass { Capsule().fill(GlassTone.selected) } else { RoundedRectangle(cornerRadius: 4).fill(p.selectedControl) }
                }
            }
    }
}

// MARK: Review

struct Change {
    let letter: String
    let name: String
    let folder: String
    let added: Int
    var removed = 0
    var comments = 0
    var selected = false
}

struct ReviewTab: View {
    /// J2b: the popover's editor has the keyboard; the composer is closed.
    var composing = true
    let unstaged = [
        Change(letter: "M", name: "Palette.swift", folder: "Sources/Theme", added: 4, removed: 2, comments: 2),
        Change(letter: "M", name: "Sidebar.swift", folder: "Sources/Views", added: 6, removed: 1, comments: 1, selected: true),
    ]
    let untracked = [Change(letter: "U", name: "Contrast.swift", folder: "Sources/Theme", added: 27)]

    var body: some View {
        FilesSplit {
            VStack(alignment: .leading, spacing: 0) {
                // GitChangesList.summary: the files and their totals, expanded(28) tall, 4 down.
                HStack(spacing: 8) {
                    Text("3 files").foregroundStyle(p.detail)
                    Counts(added: 37, removed: 3, totals: true)
                    Spacer(minLength: 0)
                }
                .font(t.font(.body)).lineLimit(1)
                .padding(.leading, 14).padding(.trailing, 12)
                .frame(height: t.expanded(28)).padding(.top, 4)
                group("Unstaged", unstaged)
                group("Untracked", untracked)
                Spacer(minLength: 0)
            }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                DiffHeader(letter: "M", path: "Sources/Views/Sidebar.swift", added: 6, removed: 1)
                // Writing, the diff is scrolled to the composer: the first hunk's header and five lines are above.
                DiffBody(rows: composing ? Self.diff : Self.diff.compactMap { row in
                    if case .composer = row { return nil }
                    if case .line(let old, let new, let code, _, _) = row { return .line(old: old, new: new, code) }
                    return row
                }, scroll: composing ? 4 + 30 + 5 * CodeMetrics.rowHeight : 0)
            }
        }
    }

    /// GitChangesList.group (semibold ink, the count `detail`, expanded(26) tall, 6 down) and GitChangeRow: the plain
    /// 14-point letter, the name at the content size and its folder `detail`, 8 apart; the comments in blue; the counts.
    @ViewBuilder func group(_ title: String, _ changes: [Change]) -> some View {
        HStack {
            Text(title).fontWeight(.semibold).foregroundStyle(p.ink)
            Spacer(minLength: 8)
            Text("\(changes.count)").foregroundStyle(p.detail)
        }
        .font(t.font(.body))
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: t.expanded(26)).padding(.top, 6)
        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
            HStack(spacing: 8) {
                Badge(letter: change.letter, side: 14, plain: true)
                HStack(spacing: 8) {
                    Text(change.name).font(t.font(.content)).foregroundStyle(p.ink).layoutPriority(1)
                    Text(change.folder).font(t.font(.body)).foregroundStyle(p.detail).truncationMode(.head)
                }
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if change.comments > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "text.bubble.fill").font(.system(size: 9))
                        Text("\(change.comments)")
                    }
                    .font(t.font(.body)).foregroundStyle(theme.blue)
                }
                Counts(added: change.added, removed: change.removed).font(t.font(.body))
            }
            .padding(.leading, 14).padding(.trailing, 12)
            .frame(height: t.expanded(28))
            .background(change.selected ? selection : .clear)
        }
    }

    /// Sidebar.swift against HEAD: two hunks (9 → 11 and 8 → 11 lines, +6 −1) a line apart, a comment under line 19, one
    /// being written on line 32.
    static let diff: [DiffRow] = [
        .hunk("@@ -12,9 +12,11 @@", "struct Sidebar: View {"),
        .line(old: 12, new: 12, Code(pl("    @"), ty("Environment"), pl("(\\.colorScheme) "), kw("private"), pl(" "), kw("var"), pl(" scheme"))),
        .line(old: 13, new: 13, Code(pl("    "), kw("let"), pl(" spaces: ["), ty("Space"), pl("]"))),
        .line(old: 14, new: 14, Code(pl("    "), kw("let"), pl(" selection: "), ty("Space"), pl("."), ty("ID"), pl("?"))),
        .line(old: nil, new: 15, Code(pl("    @"), ty("State"), pl(" "), kw("private"), pl(" "), kw("var"), pl(" contrast = "), ty("Contrast"), pl(".standard"))),
        .line(old: 15, new: 16, Code(plain: "")),
        .line(old: 16, new: 17, Code(pl("    "), kw("var"), pl(" body: some "), ty("View"), pl(" {"))),
        .line(old: 17, new: nil, Code(pl("        "), ty("List"), pl("(spaces) { "), ty("SpaceRow"), pl("(space: $"), nu("0"), pl(") }"))),
        .line(old: nil, new: 18, Code(pl("        "), ty("List"), pl("(spaces) { "), ty("SpaceRow"), pl("(space: $"), nu("0"), pl(", contrast: contrast) }"))),
        .line(old: nil, new: 19, Code(pl("            ."), fn("background"), pl("("), ty("Palette"), pl("."), fn("sidebar"), pl("("), kw("for"), pl(": scheme))"))),
        .comment(location: "Line 19", text: "Use Palette.sidebar only in dark mode; light already gets the system material."),
        .line(old: 18, new: 20, Code(pl("    }"))),
        .line(old: 19, new: 21, Code(pl("}"))),
        .line(old: 20, new: 22, Code(plain: "")),
        .gap(1),
        .hunk("@@ -22,8 +24,11 @@", "struct Sidebar: View {"),
        .line(old: 22, new: 24, Code(plain: "")),
        .line(old: 23, new: 25, Code(kw("struct"), pl(" "), ty("SpaceRow"), pl(": "), ty("View"), pl(" {"))),
        .line(old: 24, new: 26, Code(pl("    "), kw("let"), pl(" space: "), ty("Space"))),
        .line(old: nil, new: 27, Code(pl("    "), kw("var"), pl(" contrast: "), ty("Contrast"), pl(" = .standard"))),
        .line(old: 25, new: 28, Code(plain: "")),
        .line(old: 26, new: 29, Code(pl("    "), kw("var"), pl(" body: some "), ty("View"), pl(" {"))),
        .line(old: 27, new: 30, Code(pl("        "), ty("Text"), pl("(space.name)"))),
        .line(old: nil, new: 31, Code(pl("            ."), fn("foregroundStyle"), pl("(contrast.text)")), hoverPlus: true),
        .line(old: nil, new: 32, Code(pl("            ."), fn("fontWeight"), pl("(contrast == .high ? .semibold : .regular)")), draft: true),
        .composer(location: "Comment on line 32", draft: "Raise the branch label too, not only the name."),
        .line(old: 28, new: 33, Code(pl("    }"))),
        .line(old: 29, new: 34, Code(pl("}"))),
    ]
}

/// ReviewFinish in its popover: the overview of the comments, the overall comment, Copy review and Send to this tab's
/// agent, the other agent tabs in a menu. 14 in, 520 wide.
struct FinishReview: View {
    static let width: CGFloat = 520
    /// The arrow's x, under Create review's middle.
    let arrow: CGFloat
    /// macOS's popover arrow.
    private let arrowSize = CGSize(width: 20, height: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish your review").font(t.font(.content, weight: .semibold)).foregroundStyle(theme.ink)
            Text("3 comments on 2 files").font(t.font(.body)).foregroundStyle(theme.muted)
            // overview: every comment in the review's order (by file, then line), 22 tall.
            VStack(alignment: .leading, spacing: 0) {
                row("Palette.swift", "Line 9", "Take the contrast here too, so high contrast gets its own background.")
                row("Palette.swift", "Line 21", "0.8 still reads faint over bright wallpapers; try 0.9.")
                row("Sidebar.swift", "Line 19", "Use Palette.sidebar only in dark mode; light already gets the system material.")
            }
            .font(t.font(.body))
            Editor(text: "Close. Fix these, then run the tests.", minimum: 54)
            HStack(spacing: 8) {
                Text("Then clears the comments").font(t.font(.caption)).foregroundStyle(theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                previewButton("Cancel", prominent: false)
                // Not prominent while this tab has an agent to send to.
                previewButton("Copy Review", prominent: false)
                previewButton("Send to Claude Code")
                // Another tab's agent (Theme contrast): a borderless menu, as AppKit draws it.
                Menu {
                    Button("Claude Code · Theme contrast — app") {}
                } label: {
                    Text("Other agent…")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(t.font(.body))
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .padding(.top, arrowSize.height)
        .background {
            // An NSPopover on macOS 26: Liquid Glass, drawn as GlassTone's regular glass, with its window's shadow.
            let shape = PopoverShape(arrow: arrow, arrowSize: arrowSize, corner: 16)
            shape.fill(GlassTone.track)
                .overlay(shape.stroke(GlassTone.trackEdge, lineWidth: 0.5))
                .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.18), radius: 18, y: 8)
        }
    }

    private func row(_ file: String, _ location: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(file).foregroundStyle(theme.ink)
            Text(location).foregroundStyle(theme.blue)
            Text(text).foregroundStyle(theme.muted).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .lineLimit(1).frame(height: 22)
    }
}

/// A popover's outline: a rounded panel with its arrow up at `arrow`.
nonisolated private struct PopoverShape: Shape {
    let arrow: CGFloat
    let arrowSize: CGSize
    let corner: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + arrowSize.height, width: rect.width,
                                            height: rect.height - arrowSize.height), cornerRadius: corner, style: .continuous)
        let x = min(max(arrow, corner + arrowSize.width / 2), rect.width - corner - arrowSize.width / 2)
        var tip = Path()
        tip.move(to: CGPoint(x: x - arrowSize.width / 2, y: rect.minY + arrowSize.height + 0.5))
        tip.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - arrowSize.width / 6, y: rect.minY + arrowSize.height * 0.25))
        tip.addQuadCurve(to: CGPoint(x: x + arrowSize.width / 2, y: rect.minY + arrowSize.height + 0.5),
                         control: CGPoint(x: x + arrowSize.width / 6, y: rect.minY + arrowSize.height * 0.25))
        tip.closeSubpath()
        path.addPath(tip)
        return path.normalized()
    }
}

// MARK: Files

struct FileNode {
    let name: String
    var depth = 0
    var folder = false
    var open = false
    var modified = ""
    var size = ""
    var selected = false
}

struct FilesTab: View {
    /// ~/src/app with Sources and Sources/Theme open; ages as FilesFormatting.age ("6m", "2h", "13d"), sizes as
    /// FilesFormatting.size, folders "—".
    let nodes = [
        FileNode(name: "Sources", folder: true, open: true, modified: "6m", size: "—"),
        FileNode(name: "Billing", depth: 1, folder: true, modified: "2d", size: "—"),
        FileNode(name: "Theme", depth: 1, folder: true, open: true, modified: "6m", size: "—"),
        FileNode(name: "Contrast.swift", depth: 2, modified: "6m", size: "812 B"),
        FileNode(name: "Palette.swift", depth: 2, modified: "6m", size: "572 B", selected: true),
        FileNode(name: "Typography.swift", depth: 2, modified: "40m", size: "2.6 KB"),
        FileNode(name: "Views", depth: 1, folder: true, modified: "6m", size: "—"),
        FileNode(name: "Tests", folder: true, modified: "1h", size: "—"),
        FileNode(name: "docs", folder: true, modified: "2d", size: "—"),
        FileNode(name: "assets", folder: true, modified: "5d", size: "—"),
        FileNode(name: ".gitignore", modified: "13d", size: "84 B"),
        FileNode(name: "Package.swift", modified: "3d", size: "1.2 KB"),
        FileNode(name: "README.md", modified: "2d", size: "3.4 KB"),
    ]
    /// Proposal (J1g): the rows and the code run under the files header and the pinned column headers, `scrolled`
    /// points past the top; no fills or rules on the headers, the footer and the transfer.
    var floating = false
    var scrolled: CGFloat = 0
    var body: some View {
        if floating { floatingBody } else { barsBody }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Modified").frame(width: t.expanded(64), alignment: .trailing)
            Text("Size").frame(width: t.expanded(72), alignment: .trailing)
        }
        .font(t.font(.caption)).foregroundStyle(p.detail)
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: Self.headerHeight)
    }

    private var previewTitle: some View {
        HStack(spacing: 10) {
            Text("Palette.swift").font(t.font(.content)).foregroundStyle(theme.ink).lineLimit(1).layoutPriority(1)
            IconButton { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
            Text("572 B · modified 6m ago").font(t.font(.body)).foregroundStyle(theme.muted).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton { WrapGlyph() }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
    }

    private var floatingBody: some View {
        let top = FilesHeader.height
        return FilesSplit {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in row(node) }
                    Spacer(minLength: 0)
                }
                .padding(.top, top + Self.headerHeight - scrolled)
                ScrollEdge(solid: top + Self.headerHeight)
                columns.padding(.top, top)
                // The transfer and the count float over the rows' bottom edge: a glass capsule, and words on it.
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    transferCapsule
                    HStack(spacing: 0) { Text("7 items · 1 selected"); Spacer(minLength: 12) }
                        .lineLimit(1).font(t.font(.caption)).foregroundStyle(p.detail)
                        .padding(.leading, 14).padding(.trailing, 12).frame(height: t.expanded(24))
                }
                .background(alignment: .bottom) { ScrollEdge(solid: t.expanded(24), bottom: true) }
            }
        } detail: {
            ZStack(alignment: .top) {
                SourcePreview(lines: Self.palette).padding(.top, top + Self.headerHeight - scrolled)
                ScrollEdge(solid: top + Self.headerHeight)
                previewTitle.padding(.top, top)
            }
        }
    }

    private var transferCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.accent)
            Text("Sending").foregroundStyle(p.secondary).lineLimit(1)
            Text("31 of 48 MB · 12 MB/s").foregroundStyle(p.muted).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "xmark").font(t.symbol(.caption, weight: .semibold)).foregroundStyle(p.sidebarDetail)
        }
        .font(t.font(.label))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(GlassCapsule())
        .padding(.horizontal, 10)
    }

    private var barsBody: some View {
        FilesSplit {
            VStack(spacing: 0) {
                // FilesColumnHeader: the caption size `detail`, as tall as the preview's header with its rule
                // (FilesColumns.headerHeight + 1), a `separator` rule.
                HStack(spacing: 0) {
                    Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Modified").frame(width: t.expanded(64), alignment: .trailing)
                    Text("Size").frame(width: t.expanded(72), alignment: .trailing)
                }
                .font(t.font(.caption)).foregroundStyle(p.detail)
                .padding(.leading, 14).padding(.trailing, 12)
                .frame(height: Self.headerHeight + 1)
                .overlay(alignment: .bottom) { p.separator.frame(height: 1) }
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in row(node) }
                Spacer(minLength: 0)
                transfer
                // FilesFooter: the root level's entries and the selected rows, expanded(24) tall.
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
        } detail: {
            VStack(spacing: 0) {
                // FilePreviewDetail.header: one line, 10 apart: the name, Copy path, the meta (FilesFormatting.meta),
                // then wrap (off: Settings › Files › Wrap lines); a `border` rule under it.
                HStack(spacing: 10) {
                    Text("Palette.swift").font(t.font(.content)).foregroundStyle(theme.ink).lineLimit(1).layoutPriority(1)
                    IconButton { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    Text("572 B · modified 6m ago").font(t.font(.body)).foregroundStyle(theme.muted).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton { WrapGlyph() }
                }
                .padding(.horizontal, 14)
                .frame(height: Self.headerHeight)
                theme.border.frame(height: 1)
                SourcePreview(lines: Self.palette)
            }
        }
    }

    /// FilesColumns.headerHeight: max(40, expanded(34)), rounded.
    static var headerHeight: CGFloat { max(40, t.expanded(34)).rounded() }

    /// FilesOutlineView's row: the native disclosure at 14 − 3 + level × indent, the name cell at 14 + level × indent +
    /// (indent − 3); in it the icon (expanded(14), the symbol at 86%) and 7 on the name (its label 2 in); Modified and
    /// Size right-aligned (FilesOutlineStyle's fonts and inks).
    func row(_ node: FileNode) -> some View {
        let indent = t.expanded(20), iconSize = t.expanded(14)
        let level = CGFloat(node.depth)
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if node.folder {
                    // NSOutlineView's own disclosure button.
                    Image(systemName: node.open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 13)
                        .padding(.leading, 14 - 3 + level * indent)
                }
                HStack(spacing: 0) {
                    Image(systemName: node.folder ? "folder" : "doc").font(.system(size: iconSize * 0.86))
                        .foregroundStyle(p.muted).frame(width: iconSize, height: iconSize)
                    Text(node.name).font(t.font(.content)).foregroundStyle(node.selected ? p.ink : p.secondary)
                        .lineLimit(1).padding(.leading, 7 + 2)
                }
                .padding(.leading, 14 + level * indent + indent - 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(node.modified).frame(width: t.expanded(64), alignment: .trailing)
                Text(node.size).frame(width: t.expanded(72), alignment: .trailing)
            }
            .font(t.font(.body)).foregroundStyle(node.selected ? p.sidebarHostLabel : p.sidebarDetail)
        }
        .padding(.trailing, 12)
        .frame(height: t.expanded(24))
        .background(node.selected ? selection : .clear)
    }

    /// FileTransferRow while it sends 3 items (packed): the arrow, "Sending" and its progress (FileTransferText), the
    /// stage dots and Cancel; 34 tall at the label size, on `window` under a `separator` rule. Its 2-point bar
    /// (`fraction`, 62% here) sits at y −1…1 under that rule, and FileTransferRows clips its stack at 0: the code draws
    /// it, but it doesn't show.
    private var transfer: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(p.accent)
            Text("Sending").foregroundStyle(p.secondary).lineLimit(1)
            Text("31 of 48 MB · 12 MB/s").foregroundStyle(p.muted).lineLimit(1)
            Spacer(minLength: 0)
            // StageDots: pack done (green), send running (accent), unpack ahead (`controlBorder`).
            HStack(spacing: 5) {
                ForEach(Array(["pack", "send", "unpack"].enumerated()), id: \.offset) { index, name in
                    Circle().fill(index < 1 ? p.green : index == 1 ? p.accent : p.controlBorder).frame(width: 5, height: 5)
                    Text(name)
                }
            }
            .font(t.font(.caption)).foregroundStyle(p.detail)
            Image(systemName: "xmark").font(t.symbol(.caption, weight: .semibold))
                .frame(minWidth: 22, minHeight: 22)
                .foregroundStyle(p.sidebarDetail)
        }
        .font(t.font(.label))
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.window)
        .overlay(alignment: .top) { p.separator.frame(height: 1) }
    }

    /// Palette.swift as it is now (572 bytes).
    static let palette: [Code] = [
        Code(kw("import"), pl(" "), ty("SwiftUI")),
        Code(plain: ""),
        Code(cm("/// The sidebar's colours by role, for each contrast level.")),
        Code(kw("struct"), pl(" "), ty("Palette"), pl(" {")),
        Code(pl("    "), kw("var"), pl(" text: "), ty("Color")),
        Code(pl("    "), kw("var"), pl(" detail: "), ty("Color")),
        Code(pl("    "), kw("var"), pl(" selection: "), ty("Color")),
        Code(plain: ""),
        Code(pl("    "), kw("static"), pl(" "), kw("func"), pl(" "), fn("sidebar"), pl("("), kw("for"), pl(" scheme: "), ty("ColorScheme"), pl(") -> "), ty("Color"), pl(" {")),
        Code(pl("        scheme == .dark ? "), ty("Color"), pl("("), st("\"SidebarDark\""), pl(") : .clear")),
        Code(pl("    }")),
        Code(plain: ""),
        Code(pl("    "), kw("static"), pl(" "), kw("let"), pl(" standard = "), ty("Palette"), pl("(")),
        Code(pl("        text: .primary,")),
        Code(pl("        detail: .secondary,")),
        Code(pl("        selection: .accentColor."), fn("opacity"), pl("("), nu("0.18"), pl(")")),
        Code(pl("    )")),
        Code(plain: ""),
        Code(pl("    "), kw("static"), pl(" "), kw("let"), pl(" high = "), ty("Palette"), pl("(")),
        Code(pl("        text: .primary,")),
        Code(pl("        detail: .primary."), fn("opacity"), pl("("), nu("0.8"), pl("),")),
        Code(pl("        selection: .accentColor."), fn("opacity"), pl("("), nu("0.32"), pl(")")),
        Code(pl("    )")),
        Code(pl("}")),
    ]
}

/// FileTextPreview with line numbers (Settings › Files, on): numbers right-aligned in two digits' room, 24 before the
/// code, in the code font and `muted`; rows FilePreviewMetrics' height, 10 down; a 1-point `border` rule 10 after them.
struct SourcePreview: View {
    let lines: [Code]
    var body: some View {
        let gutter = CGFloat(max(2, String(lines.count).count)) * CodeMetrics.digitWidth
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(index + 1)").foregroundStyle(theme.muted)
                        .frame(width: gutter, alignment: .trailing)
                        .padding(.trailing, 10 + 14)
                    line.text.lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, (CodeMetrics.rowHeight - CodeMetrics.lineHeight) / 2)
                .frame(minHeight: CodeMetrics.rowHeight, alignment: .topLeading)
                .padding(.horizontal, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .topLeading) {
            theme.border.frame(width: 1).padding(.leading, 14 + gutter + 10)
        }
        .font(CodeMetrics.font())
        .clipped()
    }
}

// MARK: Commits

struct Commit {
    let subject: String
    var lane = 0
    var refs: [Ref] = []
    var signed = false
    let author: String
    let age: String
    var selected = false
}

struct Ref {
    enum Kind { case current, branch, remote, tag }
    let name: String
    let kind: Kind
}

/// One row of the graph (GitGraph.Row as GitGraphCell draws it): lines through it, from the row above into its dot, out
/// of its dot to the row below; `current` lines are HEAD's first parents.
struct GraphRow {
    enum Kind { case pass, into, out }
    struct Line { let kind: Kind; let from: Int; let to: Int; var current = true }
    let lane: Int
    var current = true
    let lines: [Line]
}

struct CommitsTab: View {
    static let commits = [
        Commit(subject: "Theme: high-contrast sidebar rows",
               refs: [Ref(name: "dark-mode", kind: .current), Ref(name: "origin/dark-mode", kind: .remote)],
               signed: true, author: "Alex Rivera", age: "35m", selected: true),
        Commit(subject: "Palette: name colours by role", signed: true, author: "Alex Rivera", age: "2h"),
        Commit(subject: "Merge branch 'main' into dark-mode", author: "Alex Rivera", age: "3h"),
        Commit(subject: "Billing: round once, half-even", lane: 1,
               refs: [Ref(name: "main", kind: .branch), Ref(name: "v0.4.2", kind: .tag)],
               signed: true, author: "Sam Example", age: "5h"),
        Commit(subject: "Sidebar: host discs in group headings", author: "Alex Rivera", age: "1d"),
        Commit(subject: "Docs: theming guide", lane: 1, author: "Priya Example", age: "1d"),
        Commit(subject: "Theme: start the dark mode", author: "Alex Rivera", age: "2d"),
        Commit(subject: "Billing: invoice totals in minor units", lane: 1, author: "Sam Example", age: "2d"),
        Commit(subject: "Release 0.4.1", refs: [Ref(name: "v0.4.1", kind: .tag)], signed: true, author: "Sam Example", age: "4d"),
        Commit(subject: "Files: drop folders onto hosts", author: "Priya Example", age: "5d"),
        Commit(subject: "Tests: cover the empty invoice", author: "Sam Example", age: "6d"),
    ]

    /// The uncommitted row, then the commits: dark-mode on lane 0, main's commits merged from lane 1 back down to
    /// v0.4.1, where dark-mode left it.
    static let graph: [GraphRow] = {
        typealias L = GraphRow.Line
        let straight = [L(kind: .into, from: 0, to: 0), L(kind: .out, from: 0, to: 0)]
        let side = [L(kind: .into, from: 1, to: 1, current: false), L(kind: .out, from: 1, to: 1, current: false)]
        return [
            GraphRow(lane: 0, lines: [L(kind: .out, from: 0, to: 0)]),
            GraphRow(lane: 0, lines: straight),
            GraphRow(lane: 0, lines: straight),
            GraphRow(lane: 0, lines: straight + [L(kind: .out, from: 0, to: 1, current: false)]),
            GraphRow(lane: 1, current: false, lines: [L(kind: .pass, from: 0, to: 0)] + side),
            GraphRow(lane: 0, lines: straight + [L(kind: .pass, from: 1, to: 1, current: false)]),
            GraphRow(lane: 1, current: false, lines: [L(kind: .pass, from: 0, to: 0)] + side),
            GraphRow(lane: 0, lines: straight + [L(kind: .pass, from: 1, to: 1, current: false)]),
            GraphRow(lane: 1, current: false, lines: [L(kind: .pass, from: 0, to: 0), L(kind: .into, from: 1, to: 1, current: false),
                                                      L(kind: .out, from: 1, to: 0, current: false)]),
            GraphRow(lane: 0, lines: straight),
            GraphRow(lane: 0, lines: straight),
            GraphRow(lane: 0, lines: straight),
        ]
    }()

    var body: some View {
        FilesSplit {
            VStack(spacing: 0) {
                GeometryReader { geometry in rows(width: geometry.size.width) }
                footer
            }
        } detail: {
            CommitDetail()
        }
    }

    /// GitCommitsList.rows: expanded(28) rows, the graph `GitGraphCell.width` wide (two lanes, × expanded(1)), the author
    /// column by the list's width (GitAuthorColumn.style).
    func rows(width: CGFloat) -> some View {
        let height = t.expanded(28), scale = t.expanded(1)
        let graphWidth = max(56, 42 + 14 * CGFloat(2 - 1)) * scale
        let author: AuthorStyle = width >= t.expanded(760) ? .name : width >= t.expanded(460) ? .initials : .hidden
        return VStack(spacing: 0) {
            // GitUncommittedRow: the hollow dot, "Uncommitted changes" in `sidebarHostLabel`, the changed files.
            HStack(spacing: 0) {
                GraphCell(row: Self.graph[0], hollow: true, width: graphWidth, height: height)
                HStack(spacing: 8) {
                    Text("Uncommitted changes").font(t.font(.content)).foregroundStyle(p.sidebarHostLabel)
                    Spacer(minLength: 8)
                    Text("3 files").font(t.font(.caption)).foregroundStyle(p.detail)
                }
                .lineLimit(1).padding(.trailing, 12)
            }
            .frame(height: height)
            ForEach(Array(Self.commits.enumerated()), id: \.offset) { index, commit in
                commitRow(commit, graph: Self.graph[index + 1], graphWidth: graphWidth, height: height,
                          refsWidth: max(64, (width / 3).rounded()), author: author)
            }
            Spacer(minLength: 0)
        }
    }

    enum AuthorStyle { case hidden, initials, name }

    /// GitCommitRow: the subject at the content size, its refs (GitRefChips, a third of the list at most), the seal, then
    /// the author column and the age at the caption size.
    private func commitRow(_ commit: Commit, graph: GraphRow, graphWidth: CGFloat, height: CGFloat, refsWidth: CGFloat,
                           author: AuthorStyle) -> some View {
        // GitAuthorColumn.width and ageWidth: 0.6 em of the size 2 under content, 3 or 20 characters, and 4.
        let character = t.size(offset: -2) * 0.6
        return HStack(spacing: 0) {
            GraphCell(row: graph, hollow: false, width: graphWidth, height: height)
            HStack(spacing: 8) {
                Text(commit.subject).font(t.font(.content)).foregroundStyle(commit.selected ? p.ink : p.secondary)
                    .truncationMode(.tail)
                if !commit.refs.isEmpty { RefChips(refs: commit.refs).frame(maxWidth: refsWidth, alignment: .leading).fixedSize().layoutPriority(1) }
                if commit.signed {
                    // GitSignatureSeal: `seal` in `detail` until checked; selecting a commit checks it (a good,
                    // certified signature: `checkmark.seal.fill` in green).
                    Image(systemName: commit.selected ? "checkmark.seal.fill" : "seal").font(t.symbol(.body))
                        .foregroundStyle(commit.selected ? p.green : p.detail)
                }
                Spacer(minLength: 8)
                if author != .hidden {
                    Text(author == .name ? commit.author : initials(commit.author))
                        .font(t.font(.caption)).foregroundStyle(commit.selected ? p.muted : p.detail)
                        .frame(width: (character * (author == .name ? 20 : 3)).rounded(.up), alignment: .leading)
                }
                Text(commit.age).font(t.font(.caption)).foregroundStyle(commit.selected ? p.muted : p.detail)
                    .fixedSize()
                    .frame(minWidth: author == .hidden ? nil : (character * 4).rounded(.up), alignment: .trailing)
            }
            .lineLimit(1).padding(.trailing, 12)
        }
        .frame(height: height)
        .background(commit.selected ? selection : .clear)
    }

    /// GitAuthorColumn.initials: the first letters of the first and last words.
    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ").compactMap(\.first)
        return words.count > 1 ? "\(words[0])\(words[words.count - 1])" : words.first.map(String.init) ?? ""
    }

    /// GitCommitsFooter: how much of the log is loaded, and the scope (FilesSession.logScope, "This branch") as a
    /// borderless menu; expanded(24) tall at the caption size.
    var footer: some View {
        HStack(spacing: 8) {
            Text("200 loaded · scroll for more")
            Spacer(minLength: 0)
            Menu {
                Button("This branch") {}
                Button("All branches") {}
            } label: {
                (Text("This branch ") + Text(Image(systemName: "chevron.down"))
                    .font(.system(size: t.size(offset: -5), weight: .semibold)))
                    .font(t.font(.caption)).foregroundStyle(p.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .lineLimit(1)
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(height: t.expanded(24))
        .font(t.font(.caption)).foregroundStyle(p.detail)
        .background(Chrome.window)
        .overlay(alignment: .top) { p.separator.frame(height: 1) }
    }
}

/// GitRefChip: the checked-out branch green on its 18% capsule; tags `warning`, other branches and remotes `muted`, in a
/// `selectedControl` outline; the caption size, 6 in, expanded(16) tall, 6 apart (GitRefChips).
struct RefChips: View {
    let refs: [Ref]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                let filled = ref.kind == .current
                Text(ref.name).font(t.font(.caption))
                    .foregroundStyle(filled ? p.green : ref.kind == .tag ? p.warning : p.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 6).frame(height: t.expanded(16))
                    .background { if filled { Capsule().fill(p.green.opacity(0.18)) } }
                    .overlay { if !filled { Capsule().strokeBorder(p.selectedControl) } }
            }
        }
    }
}

/// GitGraphCell: lanes on a 14-point grid from x 22, × expanded(1); 2-point lines, 4.5-point dots, `graphCurrent` for
/// HEAD's first parents and `graphMerged` for the rest; the uncommitted dot hollow on the terminal's ground.
struct GraphCell: View {
    let row: GraphRow
    let hollow: Bool
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        let green = p.graphCurrent, slate = p.graphMerged, background = theme.terminal
        let scale = t.expanded(1)
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { (22 + 14 * CGFloat(lane)) * scale }
            let middle = size.height / 2
            for line in row.lines {
                let from = x(line.from), to = x(line.to)
                var path = Path()
                switch line.kind {
                case .pass:
                    path.move(to: CGPoint(x: from, y: 0))
                    path.addLine(to: CGPoint(x: from, y: size.height))
                case .into:
                    path.move(to: CGPoint(x: from, y: 0))
                    let end = CGPoint(x: to, y: middle)
                    if from == to { path.addLine(to: end) } else {
                        path.addCurve(to: end, control1: CGPoint(x: from, y: middle), control2: CGPoint(x: from, y: middle))
                    }
                case .out:
                    path.move(to: CGPoint(x: from, y: middle))
                    let end = CGPoint(x: to, y: size.height)
                    if from == to { path.addLine(to: end) } else {
                        path.addCurve(to: end, control1: CGPoint(x: to, y: middle), control2: CGPoint(x: to, y: middle))
                    }
                }
                context.stroke(path, with: .color(line.current ? green : slate), lineWidth: 2 * scale)
            }
            let radius = 4.5 * scale
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - radius, y: middle - radius, width: radius * 2, height: radius * 2))
            if hollow {
                context.fill(dot, with: .color(background))
                context.stroke(dot, with: .color(row.current ? green : slate), lineWidth: 2 * scale)
            } else {
                context.fill(dot, with: .color(row.current ? green : slate))
            }
        }
        .frame(width: width, height: height)
    }
}

/// GitCommitDetailPane: the summary and the files at their own height (GitCommitDetailStack), then the picked file's
/// diff under a `controlBorder` rule.
struct CommitDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            files
            p.controlBorder.frame(height: 1)
            DiffHeader(path: "Sources/Theme/Palette.swift", added: 6, removed: 0, review: false)
            DiffBody(rows: Self.diff, review: false)
        }
    }

    /// GitCommitSummary: the subject (system face, 1.5 over content, semibold), the meta line with the refs while they
    /// fit, the body (system face, 0.5 under content, `secondary`, 3 between lines, expanded(480) at most); 14 · 16 · 12 ·
    /// 16 in, 8 apart, a `separator` rule.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CommitsTab.commits[0].subject)
                .font(.system(size: t.size(offset: 1.5), weight: .semibold)).foregroundStyle(p.ink)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                metaLine(refs: true)
                VStack(alignment: .leading, spacing: 8) {
                    metaLine(refs: false)
                    RefChips(refs: CommitsTab.commits[0].refs)
                }
            }
            Text("Adds the high-contrast palette: details at 80% and a stronger selection, so the sidebar stays readable over bright wallpapers.")
                .font(.system(size: t.size(offset: -0.5))).lineSpacing(3).foregroundStyle(p.secondary)
                .frame(maxWidth: t.expanded(480), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .overlay(alignment: .bottom) { p.separator.frame(height: 1) }
    }

    /// GitCommitSummary.metaLine: the hash and its copy glyph in green, the author with GitSignatureBadge (checked: good),
    /// the age (GitCommitsText.ago), the refs; 10 apart, "·" `faint`, the body size `muted`.
    private func metaLine(refs: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("a41c9e2")
                Image(systemName: "doc.on.doc").font(t.symbol(.caption))
            }
            .foregroundStyle(p.green).fixedSize()
            Text("·").foregroundStyle(p.faint)
            HStack(spacing: 6) {
                Text("Alex Rivera")
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill").font(t.symbol(.caption))
                    Text("Signed")
                }
                .foregroundStyle(p.green).fixedSize()
            }
            .layoutPriority(1)
            Text("·").foregroundStyle(p.faint)
            Text("35 min ago").fixedSize()
            if refs {
                Text("·").foregroundStyle(p.faint)
                RefChips(refs: CommitsTab.commits[0].refs).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .font(t.font(.body)).foregroundStyle(p.muted).lineLimit(1)
    }

    /// GitCommitFiles: "CHANGED FILES" and its count, the totals; each file a GitCommitFileRow (the tinted letter, the
    /// path at the content size, the counts; 10 apart, expanded(32) tall); 6 under them.
    var files: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("CHANGED FILES").tracking(0.4)
                Text(" 2").foregroundStyle(p.muted)
                Spacer(minLength: 8)
                Counts(added: 9, removed: 1).font(t.font(.body))
            }
            .font(t.font(.caption)).foregroundStyle(p.detail)
            .padding(.horizontal, 16)
            .frame(height: t.expanded(28))
            file("M", "Sources/Theme/Palette.swift", 6, 0, selected: true)
            file("M", "Sources/Theme/Typography.swift", 3, 1)
        }
        .padding(.bottom, 6)
    }

    private func file(_ letter: String, _ path: String, _ added: Int, _ removed: Int, selected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Badge(letter: letter)
            Text(path).font(t.font(.content)).foregroundStyle(p.ink).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Counts(added: added, removed: removed).font(t.font(.body))
        }
        .lineLimit(1)
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: t.expanded(32))
        .background(selected ? selection : .clear)
    }

    /// Palette.swift in the commit: the high-contrast palette added (4 → 10 lines, +6).
    static let diff: [DiffRow] = [
        .hunk("@@ -15,4 +15,10 @@", "struct Palette {"),
        .line(old: 15, new: 15, Code(pl("        detail: .secondary,"))),
        .line(old: 16, new: 16, Code(pl("        selection: .accentColor."), fn("opacity"), pl("("), nu("0.18"), pl(")"))),
        .line(old: 17, new: 17, Code(pl("    )"))),
        .line(old: nil, new: 18, Code(plain: "")),
        .line(old: nil, new: 19, Code(pl("    "), kw("static"), pl(" "), kw("let"), pl(" high = "), ty("Palette"), pl("("))),
        .line(old: nil, new: 20, Code(pl("        text: .primary,"))),
        .line(old: nil, new: 21, Code(pl("        detail: .primary."), fn("opacity"), pl("("), nu("0.8"), pl("),"))),
        .line(old: nil, new: 22, Code(pl("        selection: .accentColor."), fn("opacity"), pl("("), nu("0.32"), pl(")"))),
        .line(old: nil, new: 23, Code(pl("    )"))),
        .line(old: 18, new: 24, Code(pl("}"))),
    ]
}

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


// MARK: J1g, Files on Liquid Glass

/// macOS 26's soft scroll edge, as the kit draws glass offscreen (materials do not render): the content's background
/// almost solid behind the pinned rows (`solid` points from the top, or the bottom), then fading out over `fade`, so
/// what scrolls under the header dims and blurs away rather than meeting a bar's edge.
struct ScrollEdge: View {
    let solid: CGFloat
    var fade: CGFloat = 18
    var bottom = false
    var body: some View {
        let bg = ChatColors.current.terminal, height = solid + fade
        LinearGradient(stops: [.init(color: bg.opacity(0.96), location: 0), .init(color: bg.opacity(0.9), location: solid / height),
                               .init(color: bg.opacity(0), location: 1)],
                       startPoint: bottom ? .bottom : .top, endPoint: bottom ? .top : .bottom)
            .frame(height: height).allowsHitTesting(false)
            .frame(maxHeight: .infinity, alignment: bottom ? .bottom : .top)
    }
}

/// Today's three bars (the header, the column and preview headers, each with its fill and rule; the transfer and the
/// footer as bars) beside the proposal: one glass band, at rest and with the list and the code scrolled under it.
struct FilesGlassBoard: View {
    var body: some View {
        let colors = ChatColors.current
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 28) {
                tile("Today", "Three opaque bands with hard edges: the header, then the list's and the preview's own header rows; the transfer and the count are bars too.") {
                    FilesModes.window(tab: "Theme/Palette.swift", segment: .files, width: 1000, height: 560) { FilesTab() }
                }
                tile("Proposed, at rest", "One band: the header and the pinned column headers float on the content, no fills or rules; the transfer is a glass capsule.") {
                    FilesModes.window(tab: "Theme/Palette.swift", segment: .files, width: 1000, height: 560, floating: true) {
                        FilesTab(floating: true)
                    }
                }
            }
            tile("Proposed, scrolled", "The rows and the code pass under the band and fade into its soft edge, as in Finder and Xcode on macOS 26.") {
                FilesModes.window(tab: "Theme/Palette.swift", segment: .files, width: 1000, height: 560, floating: true) {
                    FilesTab(floating: true, scrolled: 46)
                }
            }
        }
        .padding(32)
        .background(colors.terminal.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tile(_ title: String, _ note: String, @ViewBuilder _ content: () -> some View) -> some View {
        let colors = ChatColors.current
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.ink)
                Text(note).font(.system(size: 12)).foregroundStyle(colors.muted)
                    .lineLimit(2, reservesSpace: true).frame(maxWidth: 900, alignment: .leading)
            }
            content()
        }
        .fixedSize()
    }
}
