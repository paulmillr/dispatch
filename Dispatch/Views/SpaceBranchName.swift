import SwiftUI

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
struct SpaceBranchObserver: View {
    let space: Space
    @State private var value: String?
    @State private var resolved: SpaceBranchSource.Key?

    var body: some View {
        let source = SpaceBranchSource.firstTab(in: space, runtime: .shared)
        let branch = resolved == source?.key ? value : nil
        Color.clear
            .preference(key: SpaceBranchNames.self, value: branch.map { [space.id: $0] } ?? [:])
            .task(id: source?.key) {
                value = nil; resolved = nil
                guard let source else { return }
                while !Task.isCancelled {
                    let next = await SpaceBranchReader.shared.branch(source)
                    guard !Task.isCancelled else { return }
                    resolved = source.key
                    if value != next { value = next }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
    }
}

struct SpaceBranchNames: PreferenceKey {
    static let defaultValue: [UUID: String] = [:]
    static func reduce(value: inout [UUID: String], nextValue: () -> [UUID: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
