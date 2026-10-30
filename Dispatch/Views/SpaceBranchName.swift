import SwiftUI
import AppKit

struct SpaceBranchName: View {
    /// The row's id (a space's, or a tabs-only row's tab) and name.
    let id: UUID
    let title: String
    let showBranch: Bool
    let fontSize: CGFloat
    var inline = false
    var branchFontSize: CGFloat? = nil
    var branch: String?
    var branchColor: Color = Chrome.muted

    init(space: Space, showBranch: Bool, fontSize: CGFloat, inline: Bool = false, branchFontSize: CGFloat? = nil,
         branch: String? = nil, branchColor: Color = Chrome.muted) {
        self.init(id: space.id, name: space.name, showBranch: showBranch, fontSize: fontSize, inline: inline,
                  branchFontSize: branchFontSize, branch: branch, branchColor: branchColor)
    }

    init(id: UUID, name: String, showBranch: Bool, fontSize: CGFloat, inline: Bool = false, branchFontSize: CGFloat? = nil,
         branch: String? = nil, branchColor: Color = Chrome.muted) {
        self.id = id; self.title = name; self.showBranch = showBranch; self.fontSize = fontSize; self.inline = inline
        self.branchFontSize = branchFontSize; self.branch = branch; self.branchColor = branchColor
    }

    var body: some View {
        let layout = inline ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            name
            branchLine
        }
    }

    var name: some View {
        Text(title).lineLimit(1).layoutPriority(1)
    }

    @ViewBuilder var branchLine: some View {
        if showBranch {
            // Keep the first row stationary while the branch loads or is unavailable.
            branchText(branch ?? " ")
                .opacity(branch == nil ? 0 : 1)
                .accessibilityHidden(branch == nil)
        }
    }

    private func branchText(_ branch: String) -> some View {
        Text(branch).font(AppFont.ui(size: branchFontSize ?? max(8, fontSize - 2), design: .monospaced))
            .foregroundStyle(branchColor).lineLimit(1).truncationMode(.middle)
            .accessibilityLabel("Git branch: \(branch)")
            .accessibilityIdentifier("space-branch-\(id)")
    }
}

/// Keep discovery mounted while the row switches between compact and tile layouts.
/// Reads only while branches are shown: at once when it appears, the app activates or one of its terminals finishes a
/// command (a `git checkout` there), else every `interval` (each read of a remote space is a helper request on its link).
struct SpaceBranchObserver: View {
    /// One rule for local and remote spaces: 10 s while Dispatch is shown (AppPresence), 60 s otherwise.
    static func interval(shown: Bool) -> Duration { shown ? .seconds(10) : .seconds(60) }

    let space: Space
    /// One of the space's tabs, for a tabs-only row, keyed by that tab; the space's first tab otherwise.
    var tab: TerminalTab? = nil
    var enabled = true
    private var id: UUID { tab?.id ?? space.id }
    /// The terminals whose finished commands read again: the row's tab, or every tab of the space.
    private var prompting: Set<UUID> { tab.map { [$0.id] } ?? Set(space.tabs.map(\.id)) }
    @State private var value: String?
    @State private var resolved: SpaceBranchSource.Key?
    @State private var appActive = NSApp?.isActive ?? true
    private struct Polling: Equatable { let key: SpaceBranchSource.Key?; let active: Bool }

    /// Where the branch is read: the tab's own directory on its machine, or the space's first tab's.
    private var source: SpaceBranchSource? {
        guard enabled else { return nil }
        if let tab { return SpaceBranchSource.tab(in: space, tab, runtime: .shared) }
        return SpaceBranchSource.firstTab(in: space, runtime: .shared)
    }

    var body: some View {
        let source = source
        let branch = resolved == source?.key ? value : nil
        Color.clear
            .preference(key: SpaceBranchNames.self, value: branch.map { [id: $0] } ?? [:])
            .task(id: Polling(key: source?.key, active: appActive)) {
                // A new source starts blank; resuming the same one keeps its branch. A row mounted again (another
                // layout) or shown again starts from the last branch read there while it reads anew: blank, it would
                // wait for that read, which can come long after (a replay holds a read's answer until the test's step).
                if resolved != source?.key { value = nil; resolved = nil }
                guard let source else { return }
                if resolved == nil, let last = await SpaceBranchReader.shared.last(source.key), !Task.isCancelled {
                    value = last; resolved = source.key
                }
                var prompted = false
                while !Task.isCancelled {
                    // After a finished command the 2 s cache may hold the branch from before it.
                    let next = await SpaceBranchReader.shared.branch(source, fresh: prompted)
                    guard !Task.isCancelled else { return }
                    resolved = source.key
                    if value != next { value = next }
                    do {
                        prompted = try await SpaceBranchPrompts.shared.nap(for: prompting,
                                                                           Self.interval(shown: AppPresence.shown))
                    } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }
}

struct SpaceBranchNames: PreferenceKey {
    static let defaultValue: [UUID: String] = [:]
    static func reduce(value: inout [UUID: String], nextValue: () -> [UUID: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
