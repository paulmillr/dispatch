import SwiftUI

/// The children are rendered as separate lazy transcript rows, not in this view.
struct ChatToolGroupHeader: View {
    @Environment(\.chatTheme) private var theme
    let group: ChatToolGroup
    var replyTime: Date? = nil
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summary = ""
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.12), value: expanded)
                    .frame(width: 8)
                Text("\(group.children.count.formatted()) \(group.children.count == 1 ? "step" : "steps")").fixedSize()
                    .foregroundStyle(theme.muted.opacity(0.75))
                if !summary.isEmpty {
                    Text(summary).lineLimit(1).truncationMode(.tail)
                }
                if let replyTime {
                    Spacer(minLength: 8)
                    ChatReplyTime(date: replyTime)
                }
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, minHeight: theme.typography.detailLineHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.children.count) tool runs")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("tool-group-header-\(group.id)")
        .task(id: group.presentationID) {
            // Categorize small input descriptions off the UI thread. Hidden tools'
            // output, diffs and syntax highlighting remain completely untouched.
            let items = group.children.compactMap(\.item)
            let value = await Task.detached(priority: .utility) { Self.summarize(items) }.value
            guard !Task.isCancelled else { return }
            summary = value
        }
    }

    nonisolated static func summarize(_ items: [ChatItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items { if let category = category(item) { counts[category, default: 0] += 1 } }
        return ["Patch", "Browse web"].compactMap { name in
            guard let count = counts[name] else { return nil }
            return name + (count > 1 ? " ×\(count)" : "")
        }.joined(separator: " · ")
    }

    /// The operations a collapsed group names: edits and web browsing.
    nonisolated static func category(_ item: ChatItem) -> String? {
        if WebToolPresentation.matches(item.title) { return "Browse web" }
        let name = item.title.components(separatedBy: ".").last?.lowercased()
        if ChatPatch.isPatchOperation(item) || name == "write_file" { return "Patch" }
        return nil
    }
}

struct ChatReplyTime: View {
    @Environment(\.chatTheme) private var theme
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.hour().minute())
            .font(theme.typography.detail).monospacedDigit()
            .foregroundStyle(theme.muted.opacity(0.75)).fixedSize()
            .accessibilityLabel("Reply time " + date.formatted(.dateTime.hour().minute()))
    }
}
