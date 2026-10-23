import SwiftUI

/// The diff's sizes: rows 20 points with 12.5 point monospaced code, numbers in 30 point columns, a 16 point marker
/// column, folds and gaps 26 points; all grow with Dynamic Type.
struct ReviewDiffMetrics: Equatable {
    var code: CGFloat = 12.5
    var row: CGFloat = 20
    var fold: CGFloat = 26
    var number: CGFloat = 30
    var marker: CGFloat = 16

    func height(_ row: ReviewDiffRow) -> CGFloat { row.tall ? fold : self.row }

    /// The top of each row and the end of the last, in the rows' column (no card open among them).
    func offsets(_ rows: [ReviewDiffRow]) -> [CGFloat] {
        var result: [CGFloat] = [0]
        result.reserveCapacity(rows.count + 1)
        for row in rows { result.append(result[result.count - 1] + height(row)) }
        return result
    }

    /// The row at `y` in the rows' column, clamped to the rows.
    static func row(at y: CGFloat, offsets: [CGFloat]) -> Int {
        guard offsets.count > 1 else { return 0 }
        var low = 0, high = offsets.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

/// How a row is lit: under a comment (tint and a leading bar), or selected for a new one.
enum ReviewDiffTint: Equatable {
    case none, commented, selected
}

/// One line of the diff (R2): old and new numbers, the +/− marker, the code in the file's colours; added and removed
/// lines tinted, hunk headers in the unread blue.
struct ReviewDiffLineView: View {
    let row: ReviewDiffRow
    let text: AttributedString
    /// Source: one number column, the new side's.
    let source: Bool
    let tint: ReviewDiffTint
    let metrics: ReviewDiffMetrics

    var body: some View {
        content
            .font(.system(size: metrics.code, design: .monospaced))
            .frame(height: metrics.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay { overlay }
            .clipped()
    }

    @ViewBuilder private var content: some View {
        switch row.content {
        case .hunk(let header):
            Text(header)
                .foregroundStyle(Color.stateUnread)
                .lineLimit(1)
                .padding(.leading, 12)
        case .code(let kind, let old, let new):
            HStack(spacing: 0) {
                if !source {
                    Text(old.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: metrics.number, alignment: .trailing)
                }
                Text(new.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: metrics.number, alignment: .trailing)
                Text(kind == .added ? "+" : kind == .removed ? "−" : " ")
                    .foregroundStyle(kind == .added ? Color.added : Color.destructive)
                    .frame(width: metrics.marker)
                Text(text).lineLimit(1)
            }
        case .noNewline:
            note("No newline at end of file")
        case .omitted(let count):
            note("\(FilesFormatting.count(count)) \(count == 1 ? "line" : "lines") not in the diff")
        case .truncated:
            note("The diff is cut here: the rest is larger than the helper sends")
        case .fold, .gap:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .italic()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.leading, (source ? 1 : 2) * metrics.number + metrics.marker)
    }

    private var background: Color {
        switch row.content {
        case .hunk: Color.stateUnread.opacity(0.10)
        case .code(.added, _, _): Color.added.opacity(0.16)
        case .code(.removed, _, _): Color.destructive.opacity(0.16)
        default: .clear
        }
    }

    @ViewBuilder private var overlay: some View {
        switch tint {
        case .none: EmptyView()
        case .commented:
            Rectangle().fill(Color.stateUnread.opacity(0.12))
                .overlay(alignment: .leading) { Rectangle().fill(Color.stateUnread).frame(width: 3) }
                .allowsHitTesting(false)
        case .selected:
            Rectangle().fill(Color.stateUnread.opacity(0.22)).allowsHitTesting(false)
        }
    }

    /// What VoiceOver reads: "Line 42, added: <nav className…".
    static func spoken(_ row: ReviewDiffRow) -> String {
        switch row.content {
        case .hunk(let header): return "Hunk \(header)"
        case .code(let kind, let old, let new):
            let text = row.text.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .added: return "Line \(new ?? 0), added: \(text)"
            case .removed: return "Removed line \(old ?? 0): \(text)"
            case .context: return "Line \(new ?? old ?? 0): \(text)"
            }
        case .noNewline: return "No newline at end of file"
        case .omitted(let count): return "\(count) lines not in the diff"
        case .truncated: return "The diff is cut here"
        case .fold(let count), .gap(let count): return GitChangesText.unmodified(count)
        }
    }
}

/// S5's "31 unmodified lines" row: a fold inside a hunk or the lines between hunks; a tap opens it in place.
struct ReviewDiffFoldRow: View {
    let count: Int
    /// A gap opens only once the file is read.
    let enabled: Bool
    let metrics: ReviewDiffMetrics
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                Text(GitChangesText.unmodified(count))
                    .font(.system(size: metrics.code, design: .monospaced))
                    .foregroundStyle(Color.stateUnread)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
            .frame(height: metrics.fold)
            .frame(maxWidth: .infinity)
            .background(Color.stateUnread.opacity(0.06))
            .overlay(alignment: .top) { Rectangle().fill(Color.stateUnread.opacity(0.25)).frame(height: 0.5) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.stateUnread.opacity(0.25)).frame(height: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Show \(GitChangesText.unmodified(count))")
        .accessibilityHint(enabled ? "" : "The file could not be read")
    }
}

/// A commented range's floating glass chip at the trailing edge of its first row: the bubble and how many comments
/// start there; filled while its card is open.
struct ReviewCommentChip: View {
    let count: Int
    let open: Bool
    /// "line 42", "lines 45–48": the first comment's place, for VoiceOver.
    let location: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: open ? "text.bubble.fill" : "text.bubble").font(.caption.weight(.semibold))
                Text("\(count)").font(.caption.weight(.bold)).monospacedDigit()
            }
            .foregroundStyle(open ? Color.onAccent : Color.stateUnread)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(open ? .regular.tint(.stateUnread).interactive() : .regular.interactive(), in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("\(count) \(count == 1 ? "comment" : "comments") on \(location)")
        .accessibilityHint(open ? "Closes the comment" : "Shows the comment")
    }
}

/// The text-selection style handle (R3): a dot and a stem in the unread blue; the bottom one stem first.
struct ReviewSelectionHandle: View {
    var bottom = false

    var body: some View {
        VStack(spacing: 0) {
            if !bottom { Circle().fill(Color.stateUnread).frame(width: 12, height: 12) }
            Rectangle().fill(Color.stateUnread).frame(width: 2.5, height: 22)
            if bottom { Circle().fill(Color.stateUnread).frame(width: 12, height: 12) }
        }
    }

    /// The handle's height: its dot and stem.
    static let height: CGFloat = 34
}
