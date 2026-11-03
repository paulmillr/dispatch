import AppKit
import SwiftUI

/// What clicking a message's time shows: the exact time behind the minutes, the message's identities, and the helper
/// record it was read from, as the agent's transcript gave it.
struct ChatMessageInfo {
    struct Field: Equatable {
        let label: String
        let value: String
    }

    let date: Date
    let item: ChatItem
    let rowID: String
    var turnID: String? = nil
    var agent: String? = nil
    var conversation: String? = nil
    var host: String? = nil
    /// Where the item starts in its transcript file, when the index read it from one.
    var offset: UInt64? = nil

    /// In display order; unknown values are left out.
    var fields: [Field] {
        let local = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)
        let utc = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let recorded = item.source?.time_ms
        var fields = [
            Field(label: "Local", value: date.formatted(local) + " " + TimeZone.current.identifier),
            Field(label: "UTC", value: date.formatted(utc)),
            Field(label: "Epoch ms", value: String(recorded ?? Int64((date.timeIntervalSince1970 * 1000).rounded()))),
            Field(label: "Time from", value: recorded != nil ? "record time_ms" : "transcript index"),
            Field(label: "Kind", value: item.source?.kind ?? item.kind.rawValue),
            Field(label: "Item", value: item.id),
            Field(label: "Row", value: rowID),
        ]
        let optional: [(String, String?)] = [
            ("Turn", item.source?.turn ?? turnID), ("Agent", agent), ("Conversation", conversation), ("Host", host),
            ("Offset", offset.map { "\($0) bytes" }),
            ("Completed", item.kind == .tool || item.exitCode != nil ? (item.completed ? "yes" : "no") : nil),
            ("Exit code", item.exitCode.map(String.init)),
        ]
        fields += optional.compactMap { label, value in value.map { Field(label: label, value: $0) } }
        return fields
    }

    /// The helper record as sorted, indented JSON; nil for a message the app made itself (a prompt not yet read back).
    var record: String? {
        guard let source = item.source else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(source)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Everything shown, as text for the pasteboard.
    var text: String {
        let fields = fields, width = fields.map(\.label.count).max() ?? 0
        let lines = fields.map { $0.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.value }
        return (lines + ["", record ?? "No helper record."]).joined(separator: "\n")
    }
}

/// A message's time, which opens its `ChatMessageInfo` when it has one.
struct ChatMessageTime<Label: View>: View {
    @Environment(\.chatTheme) private var theme
    let info: ChatMessageInfo?
    @ViewBuilder let label: () -> Label
    @State private var presented = false

    var body: some View {
        if let info {
            Button { presented.toggle() } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the raw message")
                .popover(isPresented: $presented, arrowEdge: .bottom) {
                    ChatMessageInfoView(info: info)
                        // On glass the popover's own glass shows through instead of the sidebar fill.
                        .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
                        .preferredColorScheme(theme.isDark ? .dark : .light)
                }
        } else {
            label()
        }
    }
}

private struct ChatMessageInfoView: View {
    @Environment(\.chatTheme) private var theme
    let info: ChatMessageInfo
    /// A tool's record can carry megabytes of output: the popover shows its start, Copy takes all of it.
    private static let shownBytes = 64 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(info.fields, id: \.label) { field in
                    GridRow {
                        Text(field.label).foregroundStyle(theme.muted)
                        Text(field.value).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.middle).help(field.value)
                    }
                }
            }
            Rectangle().fill(theme.border).frame(height: 1)
            if let record = info.record {
                ScrollView {
                    Text(Self.shown(record)).foregroundStyle(theme.ink).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .accessibilityIdentifier("chat-message-record")
            } else {
                Text("No helper record: the app made this message and the agent hasn't recorded it yet.")
                    .foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.text, forType: .string)
                }
            }
        }
        .font(theme.typography.detail.monospaced())
        .textSelection(.enabled)
        .padding(14)
        .frame(width: 520, alignment: .leading)
    }

    private static func shown(_ record: String) -> String {
        let bytes = record.utf8.count
        guard bytes > shownBytes else { return record }
        return String(decoding: record.utf8.prefix(shownBytes), as: UTF8.self)
            + "\n… \((bytes - shownBytes).formatted()) more bytes (Copy has all of them)"
    }
}
