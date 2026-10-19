import AppKit
import SwiftUI

// The pieces the Changes and Commits tabs and the diff view share: the status badge,
// the line counts, the delayed spinner and the centred note, so both tabs draw a change the same way.

/// A change's status letter on its tint (`.bd`): M and T amber, A, U and C green, D and X red, R blue.
struct GitChangeBadge: View {
    let kind: GitChangeKind
    var side: CGFloat = 20
    var corner: CGFloat = 5
    @Environment(\.appTypography) private var typography

    var body: some View {
        let color = Self.color(kind)
        Text(verbatim: kind.rawValue)
            .font(AppFont.ui(size: typography.size(offset: -2)))
            .foregroundStyle(color)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: corner).fill(color.opacity(kind == .deleted ? 0.14 : 0.12)))
            .accessibilityLabel(Self.name(kind))
    }

    @MainActor static func color(_ kind: GitChangeKind) -> Color {
        let palette = Chrome.palette
        switch kind {
        case .modified, .typeChanged: return palette.warning
        case .added, .untracked, .copied: return palette.green
        case .deleted, .conflicted: return Color(red: 236 / 255, green: 161 / 255, blue: 154 / 255)
        case .renamed: return SyntaxHighlight.function
        case .ignored: return palette.detail
        }
    }

    static func name(_ kind: GitChangeKind) -> String {
        switch kind {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "Untracked"
        case .ignored: "Ignored"
        case .conflicted: "Conflicted"
        }
    }
}

/// A spinner that shows only once a load has taken 300 ms, so an answer that comes at once never flashes one.
struct GitDelayedSpinner: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Wall time, as FilesLoadingView's: a visual delay that starts whenever SwiftUI draws, never a recorded timer.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            shown = true
        }
    }
}

/// A short centred line in the body: loading failed, nothing to show, nothing selected.
struct GitCentredNote: View {
    let text: String
    let identifier: String
    @Environment(\.appTypography) private var typography

    var body: some View {
        Text(verbatim: text)
            .font(AppFont.ui(size: typography.size(offset: -1)))
            .foregroundStyle(Chrome.palette.detail)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(identifier)
    }
}

/// A file's or a commit's "+8 −5" in the add and remove colours (F3a, F4a): "0" for a change of no lines, a binary's
/// `binary` text in its place ("binary · 48 KB → 51 KB"), nothing before the counts load. `totals` shows both signs,
/// "+26 −0", as the Changes header sums them. The caller sets the font.
struct GitCounts: View {
    let additions: Int?
    let deletions: Int?
    var binary: String?
    var totals = false

    var body: some View {
        let palette = Chrome.palette
        if let binary {
            Text(verbatim: binary).foregroundStyle(palette.detail)
        } else if let counts = GitChangesText.counts(additions: additions, deletions: deletions) {
            HStack(spacing: 4) {
                if let plus = counts.plus ?? (totals ? "+0" : nil) { Text(verbatim: plus).foregroundStyle(palette.green) }
                if let minus = counts.minus ?? (totals ? "−0" : nil) {
                    Text(verbatim: minus).foregroundStyle(GitChangeBadge.color(.deleted))
                }
                if counts.plus == nil && counts.minus == nil && !totals { Text(verbatim: "0").foregroundStyle(palette.detail) }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }
}

/// The git tabs' one pasteboard writer: a path, a hash, a diff or a file's text, as plain text.
enum GitPasteboard {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    /// ⌘C while `active` (the tab's list or files have the keyboard): `text()` goes to the pasteboard. A hidden button
    /// so the shortcut reaches the list before Edit › Copy, as the preview's ⌥⌘C does; the filter field keeps its own
    /// ⌘C because `active` is false while it has the keyboard.
    func gitCopyShortcut(active: Bool, _ text: @escaping @MainActor () -> String?) -> some View {
        background {
            Button { if let text = text() { GitPasteboard.copy(text) } } label: { Color.clear.frame(width: 0, height: 0) }
                .buttonStyle(.plain).opacity(0).allowsHitTesting(false)
                .keyboardShortcut(active ? KeyboardShortcut("c", modifiers: .command) : nil)
                .accessibilityHidden(true)
        }
    }
}
