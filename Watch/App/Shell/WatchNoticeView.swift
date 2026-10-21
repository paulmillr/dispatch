import SwiftUI

/// What a notice says: its symbol, a title and an optional second line, and the colour of its symbol.
struct WatchNoticeContent: Equatable {
    let symbol: String
    let title: String
    var detail: String?
    /// The one-line form over Agents, whose banner stays put above the rows (`WatchRoot`).
    var short: String?
    /// The symbol's colour: orange for what the user can fix on the phone, secondary for plain information.
    var caution = true
}

extension WatchNotice {
    /// The banner's words at `now` (docs/watch.md, Behaviour, States): a title short enough for one or two lines on a
    /// 42 mm screen, then the reason (`WatchFailure.phoneLocked`'s wording, split).
    func content(now: Date) -> WatchNoticeContent {
        switch self {
        case .waiting:
            WatchNoticeContent(symbol: "iphone.radiowaves.left.and.right", title: "Waiting for your iPhone",
                               detail: "Keep it nearby with Dispatch installed.", caution: false)
        case .unreachable(let since):
            WatchNoticeContent(symbol: "iphone.slash", title: "iPhone out of reach",
                               detail: "Updated \(WatchTime.ago(since, now: now))", short: "Updated \(WatchTime.ago(since, now: now))")
        case .phoneLocked:
            WatchNoticeContent(symbol: "lock.fill", title: "Unlock your iPhone",
                               detail: "Dispatch can't reach your hosts while it's locked.")
        case .openPhone:
            WatchNoticeContent(symbol: "iphone", title: "Open Dispatch on your iPhone",
                               detail: "It can't read its trusted host keys.", short: "Open Dispatch on iPhone")
        case .phoneOffline:
            WatchNoticeContent(symbol: "wifi.slash", title: "iPhone offline", detail: "Hosts connect when it's back online.")
        case .noHosts:
            WatchNoticeContent(symbol: "server.rack", title: "No hosts", detail: "Add a host on your iPhone.",
                               short: "Add a host on your iPhone", caution: false)
        case .stale(let since):
            WatchNoticeContent(symbol: "clock", title: "Updated \(WatchTime.ago(since, now: now))",
                               detail: "Open Dispatch on your iPhone to update.", caution: false)
        }
    }
}

/// The model's notice (`WatchModel.notice(at:)`) over Agents: one short line pinned above the rows (the Agents list is
/// the Agents screen's own, so the banner cannot be its first row as in Spaces, and a two-line card would hold 40 % of
/// a 42 mm screen). `waiting` is left to Agents' empty state, which says the same. Re-read every 30 s so "Updated 25
/// min ago" and staleness follow the clock.
struct WatchNoticeView: View {
    let model: WatchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let notice = model.notice(at: context.date), notice != .waiting {
                WatchNoticeBanner(content: notice.content(now: context.date), compact: true)
            }
        }
    }
}

/// A notice: the symbol, the title and its second line; `compact`, the short title alone on one line.
struct WatchNoticeBanner: View {
    let content: WatchNoticeContent
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: content.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(content.caution ? Color.orange : Color.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(compact ? content.short ?? content.title : content.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(compact ? 1 : nil)
                    .minimumScaleFactor(compact ? 0.8 : 1)
                    .fixedSize(horizontal: false, vertical: !compact)
                if !compact, let detail = content.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 4 : 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A host's own line when only the phone can bring it back (`WatchModel.blockedMessage`), or its problem while offline.
struct WatchHostProblemLine: View {
    let symbol: String
    let text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.caption2).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
