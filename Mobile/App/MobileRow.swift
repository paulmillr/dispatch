import SwiftUI

/// The gutter dot: blue unread (needs you, or a result not yet seen, as Mail marks unread), amber working, none when
/// idle or read. One type for every row (`MobileRow<Glyph>.Dot` names it too), so the areas that compute urgency need
/// no glyph type.
enum MobileRowDot: Equatable, Sendable, Comparable {
    // Least to most urgent: `max()` over a host's or a space's rows is the dot it shows.
    case working, unread
    var color: Color {
        switch self { case .unread: .stateUnread; case .working: .stateWorking }
    }
    var accessibilityLabel: String {
        switch self { case .unread: "Unread"; case .working: "Working" }
    }
}

/// The one row grammar of Spaces and Agents (M2a, M3a): a gutter dot that works like Mail unread, a 46 pt disc in
/// the host's tint with the host glyph, the name with a small detail after it ("space · host", or the host), the
/// time, a chevron, and a line (or two) of what the tab is doing, over a hairline inset to the text column.
struct MobileRow<Glyph: View>: View {
    typealias Dot = MobileRowDot

    static var gutter: CGFloat { 14 }
    static var dotSize: CGFloat { 10 }
    static var disc: CGFloat { 46 }
    static var glyphSize: CGFloat { 24 }
    static var spacing: CGFloat { 10 }
    /// The lists' own leading inset (Spaces and Agents pad their rows by 6 pt, as the mockup's list does).
    static var listInset: CGFloat { 6 }
    /// The row's leading inset inside the list: the dot starts 16 pt from the screen's edge (M2a, M3a).
    static var leading: CGFloat { 10 }
    /// Where the text column (and the separator) starts: the list's 6 pt plus the row's 10 pt, the gutter, the disc.
    static var textInset: CGFloat { listInset + leading + gutter + spacing + disc + spacing }

    var dot: Dot?
    var tint: Color
    var name: String
    /// 13 pt tertiary, right after the name: "space · host" in Spaces (M2a), the host in Agents (M3a).
    var detail: String?
    var time: String?
    /// Line two (15 pt, secondary): what the tab is doing, or the message preview.
    var subtitle: String?
    /// How many lines the subtitle may take: one in Spaces, two in Agents.
    var lines = 1
    /// Off for the last row.
    var separator = true
    /// Off in a space's own list (M2c): the rows there are name, time and line, after the gutter dot.
    var disc = true
    /// From the launch cache, not yet confirmed by the live host (Resilience): the time dims, nothing animates.
    var stale = false
    @ViewBuilder var glyph: Glyph

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: Self.spacing) {
            Circle()
                .fill(dot?.color ?? .clear)
                .frame(width: Self.dotSize, height: Self.dotSize)
                // At the gutter's leading edge, as the mockup's grid places it.
                .frame(width: Self.gutter, alignment: .leading)
                // Level with the name's first line when the text column stacks (accessibility sizes).
                .padding(.top, typeSize.isAccessibilitySize ? 14 : 0)
                .accessibilityHidden(true)
            // At the accessibility sizes the text takes the disc's room: the host is in the detail already.
            if disc, !typeSize.isAccessibilitySize {
                glyph
                    .frame(width: Self.glyphSize, height: Self.glyphSize)
                    .foregroundStyle(tint)
                    .frame(width: Self.disc, height: Self.disc)
                    .background(tint.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
            }
            Group {
                if typeSize.isAccessibilitySize { stacked } else { regular }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
                }
            }
        }
        .padding(.top, 10)
        .padding(.leading, Self.leading)
        .contentShape(Rectangle())
        // One element: what the row is (name, detail, time, then its line) and, as its value, what the dot means.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(dot?.accessibilityLabel ?? "")
    }

    /// VoiceOver's label: the name, the detail, the time, then the line.
    var accessibilityText: String {
        [name, detail, time, subtitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }

    /// Up to xxxLarge: name, detail, time and chevron on one line, the line(s) under them (M2a, M3a).
    private var regular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let time {
                    Text(time)
                        .font(.subheadline)
                        .foregroundStyle(stale ? .tertiary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                chevron
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(lines)
                    .truncationMode(.tail)
                    // The mockup sets the line at 20 points on 15-point type, about 2 more than the font's own.
                    .lineSpacing(lineGap)
                    .padding(.vertical, lineGap / 2)
            }
        }
    }

    @ScaledMetric(relativeTo: .subheadline) private var lineGap: CGFloat = 2

    /// The accessibility sizes: the name wraps beside the chevron, the detail and the time below it, the line after.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.headline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                chevron
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let time {
                Text(time)
                    .font(.subheadline)
                    .foregroundStyle(stale ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(lines + 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

#Preview("M2a rows") {
    let mba2 = Color(red: 0x7e / 255, green: 0xa6 / 255, blue: 0xc9 / 255)
    let studio = Color(red: 0xc9 / 255, green: 0xc9 / 255, blue: 0xce / 255)
    let ai = Color(red: 0xa9 / 255, green: 0x8a / 255, blue: 0xe0 / 255)
    return ScrollView {
        VStack(spacing: 0) {
            MobileRow(dot: .unread, tint: mba2, name: "codex", detail: "e2e · mba2", time: "9:31", subtitle: "astra-6 · needs approval") {
                HostGlyph(host: HostRecord(name: "mba2", address: "mba2", user: "alex", auth: .password, system: .mac), size: 24)
            }
            MobileRow(dot: .working, tint: mba2, name: "claude", detail: "app · mba2", time: "now", subtitle: "fable-5.1 · thinking 48s") {
                HostGlyph(host: HostRecord(name: "mba2", address: "mba2", user: "alex", auth: .password, system: .mac), size: 24)
            }
            MobileRow(dot: nil, tint: studio, name: "zsh", detail: "docs · studio", time: "Yesterday", subtitle: nil) {
                HostGlyph(host: HostRecord(name: "studio", address: "studio", user: "alex", auth: .password, system: .mac), size: 24)
            }
            MobileRow(dot: .unread, tint: ai, name: "claude", detail: "curves · ai", time: "Yesterday", subtitle: "fable-5.1 · finished", separator: false) {
                Image(systemName: "hurricane").resizable().scaledToFit()
            }
        }
    }
    .background(Color.canvas)
}
