import SwiftUI

/// The strip and the sparkline in one grouped card; dimmed and without the line when the host is not connected, dimmed
/// with the line while the phone's numbers are not current (`stale`: the phone in the background, a new connection's
/// first sample not in yet).
struct HostStatsCard: View {
    let stats: WatchHostStats?
    let tint: Color
    let live: Bool

    private var current: Bool { live && stats?.stale != true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                stat("CPU", HostStatsText.cpu(stats), warn: stats?.warnings.contains(.cpu) == true)
                divider
                stat("Memory", HostStatsText.bytes(stats?.memoryUsed), warn: stats?.warnings.contains(.memory) == true)
                divider
                stat("Disk", HostStatsText.bytes(stats?.diskFree), warn: stats?.warnings.contains(.disk) == true)
            }
            .padding(.vertical, 8)
            if live, let stats, stats.history.compactMap({ $0 }).count > 1 {
                Sparkline(values: stats.history, color: tint)
                    .frame(height: 36)
                    .padding(.horizontal, 10)
                HStack {
                    Text("CPU · 15 min")
                    Spacer()
                    if let peak = stats.peak { Text("peak \(Int(peak.rounded()))%") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .background(AgentsColor.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(current ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HostStatsText.accessibilityLabel(stats))
    }

    private var divider: some View { Rectangle().fill(.quaternary).frame(width: 0.5, height: 30) }

    private func stat(_ title: String, _ value: (value: String, unit: String), warn: Bool) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(warn ? AgentsColor.destructive : .primary)
                Text(value.unit).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The words of a host's card and lines in Spaces, pure for the tests.
enum HostStatsText {
    /// "34" "%"; "—" without a reading.
    static func cpu(_ stats: WatchHostStats?) -> (value: String, unit: String) {
        guard let cpu = stats?.cpu else { return ("—", "%") }
        return ("\(Int(cpu.rounded()))", "%")
    }

    /// Bytes in the phone's units: "11" "GB", "7.5" "GB" under ten, "1.2" "TB" from a thousand gigabytes, "512" "MB"
    /// under one.
    static func bytes(_ value: Int64?) -> (value: String, unit: String) {
        guard let value, value >= 0 else { return ("—", "GB") }
        let gigabytes = Double(value) / 1_073_741_824
        if gigabytes >= 1000 { return (String(format: "%.1f", gigabytes / 1024), "TB") }
        if gigabytes >= 10 { return ("\(Int(gigabytes.rounded()))", "GB") }
        if gigabytes >= 1 { return (String(format: "%.1f", gigabytes), "GB") }
        return ("\(Int((gigabytes * 1024).rounded()))", "MB")
    }

    /// The header's state: "18 ms" connected, "Connecting…", "Offline".
    static func state(_ host: WatchHost) -> String {
        switch host.state {
        case .connected: host.latency.map { "\(max(1, Int($0.rounded()))) ms" } ?? "Connected"
        case .connecting: "Connecting…"
        case .offline, .unknown: "Offline"
        }
    }

    /// "Offline since 2:02 PM" today, "Offline since Tuesday" this week, else the date; nothing when the phone does not
    /// know when the connection dropped (not since its launch).
    static func offlineSince(_ host: WatchHost, now: Date, calendar: Calendar = .current) -> String? {
        guard host.state == .offline || host.state == .unknown, let since = host.offlineSince else { return nil }
        let when: String
        if calendar.isDate(since, inSameDayAs: now) {
            when = since.formatted(date: .omitted, time: .shortened)
        } else if now.timeIntervalSince(since) < 6 * 86_400 {
            when = since.formatted(.dateTime.weekday(.wide))
        } else {
            when = since.formatted(date: .abbreviated, time: .omitted)
        }
        return "Offline since " + when
    }

    /// "2 spaces · 5 tabs".
    static func counts(spaces: Int, tabs: Int) -> String {
        "\(spaces) \(spaces == 1 ? "space" : "spaces") · \(tabs) \(tabs == 1 ? "tab" : "tabs")"
    }

    static func accessibilityLabel(_ stats: WatchHostStats?) -> String {
        guard let stats else { return "No statistics" }
        var parts: [String] = []
        if let cpu = stats.cpu { parts.append("CPU \(Int(cpu.rounded())) percent") }
        if stats.memoryUsed != nil { let memory = bytes(stats.memoryUsed); parts.append("Memory \(memory.value) \(memory.unit) used") }
        if stats.diskFree != nil { let disk = bytes(stats.diskFree); parts.append("Disk \(disk.value) \(disk.unit) free") }
        if let peak = stats.peak { parts.append("peak \(Int(peak.rounded())) percent in 15 minutes") }
        if stats.stale, !parts.isEmpty { parts.append("not current") }
        return parts.joined(separator: ", ")
    }
}
