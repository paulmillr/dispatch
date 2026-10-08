import SwiftUI
import AppKit

struct SpaceBranchName: View {
    let space: Space
    let showBranch: Bool
    let fontSize: CGFloat
    var inline = false
    var branchFontSize: CGFloat? = nil
    var branch: String?
    var branchColor: Color = Chrome.muted

    var body: some View {
        let layout = inline ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            name
            branchLine
        }
    }

    var name: some View {
        Text(space.name).lineLimit(1).layoutPriority(1)
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
            .accessibilityIdentifier("space-branch-\(space.id)")
    }
}

/// Keep discovery mounted while the row switches between compact and tile layouts.
/// Polls only while branches are shown and the app is active; activation refreshes at once.
struct SpaceBranchObserver: View {
    let space: Space
    var enabled = true
    @State private var value: String?
    @State private var resolved: SpaceBranchSource.Key?
    @State private var appActive = NSApp?.isActive ?? true
    private struct Polling: Equatable { let key: SpaceBranchSource.Key?; let active: Bool }

    var body: some View {
        let source = enabled ? SpaceBranchSource.firstTab(in: space, runtime: .shared) : nil
        let branch = resolved == source?.key ? value : nil
        Color.clear
            .preference(key: SpaceBranchNames.self, value: branch.map { [space.id: $0] } ?? [:])
            .task(id: Polling(key: source?.key, active: appActive)) {
                // A new source starts blank; resuming the same one keeps its branch.
                if resolved != source?.key { value = nil; resolved = nil }
                guard let source else { return }
                while !Task.isCancelled {
                    let next = await SpaceBranchReader.shared.branch(source)
                    guard !Task.isCancelled else { return }
                    resolved = source.key
                    if value != next { value = next }
                    guard appActive else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
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
