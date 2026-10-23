import SwiftUI

// The host stats widget on the phone: the Mac popover's content (identity, tiles, top processes, 15-min history,
// connection facts, actions) as a sheet from the Spaces host header, and as a block in Host details.

enum MockStats {
    static let cpu = 34.0, load = 2.71, memUsed = 11.0, memTotal = 32.0, memPct = 34.0, diskPct = 90.0, diskFree = 48.0
    static let topCPU: [(String, String)] = [("node", "50.0%"), ("cargo", "41.0%"), ("rust-analyzer", "32.0%")]
    static let topMem: [(String, String)] = [("fixture-helper", "2.3 G"), ("postgres", "1.9 G"), ("rust-analyzer", "1.4 G")]
    /// 60 × 15 s buckets, peak per bucket; nil is a gap.
    static let history: [Double?] = {
        var seed: UInt64 = 11
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var out: [Double?] = []
        var v = 28.0
        for i in 0..<60 {
            v = max(4, min(96, v + (rnd() - 0.5) * 18))
            if (12...15).contains(i) { out.append(nil); continue }          // a sleep gap
            if (38...41).contains(i) { out.append(min(100, v + 45)); continue }
            out.append(i == 59 ? 34 : v)
        }
        return out
    }()
}

struct FactRow: View {
    let label: String
    let value: String
    var chevron = false
    var warning = false
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.subheadline, design: .monospaced)).foregroundStyle(warning ? Color.caution : .primary).lineLimit(1)
            if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 7)
    }
}

/// The Spaces tree behind the sheet: the host glyph at the trailing edge is the stats button (C); offline hosts
/// gather under an Offline group at the end with their last-known spaces dimmed.
struct SpacesTreeMock: View {
    /// The Offline group folded to its header line.
    var offlineCollapsed = false
    /// The sort / filter menu open, with "Show offline hosts".
    var menuOpen = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    hostSection("mba2", glyph: "apple.logo", tint: hostTint, mux: "herdr", spaces: [("e2e", "1", false), ("app", "", true)])
                    hostSection("studio", glyph: "apple.logo", tint: .primary, mux: "tmux", spaces: [], collapsed: "2 spaces · 1")
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            Text("Offline").textCase(.uppercase)
                            Text("2").foregroundStyle(.tertiary)
                            Spacer()
                            Image(systemName: offlineCollapsed ? "chevron.right" : "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                        if offlineCollapsed { EmptyView() } else {
                        hostSection("ai", glyph: "point.3.connected.trianglepath.dotted", tint: Color.codeType, mux: "herdr",
                                    spaces: [], offline: "2h ago")
                        hostSection("build", glyph: "server.rack", tint: Color.caution, mux: "tmux",
                                    spaces: [], offline: "yesterday")
                        }
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .background(Color.canvas)
            .overlay(alignment: .topLeading) {
                if menuOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        menuRow("Sort by activity", check: true)
                        menuRow("Sort by name", check: false)
                        Divider().padding(.vertical, 4)
                        menuRow("Chats only", check: false)
                        menuRow("Show offline hosts", check: true)
                    }
                    .padding(.vertical, 6)
                    .frame(width: 250)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.leading, 16)
                }
            }
            .navigationTitle("Spaces")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 0) {
                        Image(systemName: "list.bullet.indent").frame(width: 44, height: 44).background(Color.lens, in: Circle())
                        Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44)
                            .background { if menuOpen { Circle().fill(Color.lens) } }
                    }
                    .padding(2).glassEffect(.regular.interactive(), in: Capsule())
                }
                ToolbarItem(placement: .topBarTrailing) { Text("Edit").padding(.horizontal, 18).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule()) }
            }
        }
    }

    private func menuRow(_ title: String, check: Bool) -> some View {
        HStack {
            Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).opacity(check ? 1 : 0).frame(width: 20)
            Text(title).font(.body)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func hostSection(_ name: String, glyph: String, tint: Color, mux: String, spaces: [(String, String, Bool)],
                             collapsed: String? = nil, offline: String? = nil) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(offline == nil ? .primary : .secondary)
                Text(mux).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: 22).background(Color.chipFill, in: Capsule())
                if let collapsed { Text(collapsed).font(.subheadline).foregroundStyle(.tertiary) }
                if let offline { Text("as of \(offline)").font(.subheadline).foregroundStyle(.tertiary) }
                Spacer()
                Image(systemName: glyph).font(.subheadline).foregroundStyle(offline == nil ? tint : Color.secondary).frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(offline == nil ? Color.stateConnected : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.canvas, lineWidth: 1.5))
                    }
            }
            .padding(.horizontal, 16)
            if !spaces.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(spaces.enumerated()), id: \.offset) { i, s in
                        HStack {
                            Text(s.0).font(.body)
                            Spacer()
                            if s.2 { Circle().fill(Color.stateWorking).frame(width: 10, height: 10) }
                            else if !s.1.isEmpty { Text(s.1).font(.body).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        if i < spaces.count - 1 { Hairline() }
                    }
                }
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22))
                .opacity(offline == nil ? 1 : 0.55)
            }
        }
    }
}

/// W4: Host details with the stats block under the header, before Connection.
struct HostDetailStatsScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        Image(systemName: "apple.logo").font(.system(size: 44)).foregroundStyle(hostTint)
                            .frame(width: 84, height: 84).background(hostTint.opacity(0.15), in: Circle())
                        Text("mba2").font(.title2.bold()).foregroundStyle(hostTint)
                        HStack(spacing: 7) {
                            Circle().fill(Color.stateConnected).frame(width: 8, height: 8)
                            Text("Connected · mosh · 18 ms").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("macOS 26.1").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 8)
                    StatStripCard().padding(.horizontal, 12)
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Connection").padding(.leading, -16).padding(.top, -8)
                        VStack(spacing: 0) {
                            FactRow(label: "Address", value: "mba2.tail3f.ts.net").padding(.horizontal, 16)
                            Hairline()
                            FactRow(label: "Port", value: "22").padding(.horizontal, 16)
                            Hairline()
                            FactRow(label: "User", value: "alex").padding(.horizontal, 16)
                            Hairline()
                            FactRow(label: "Key", value: "ED25519 · Face ID").padding(.horizontal, 16)
                            Hairline()
                            FactRow(label: "Multiplexer", value: "herdr 0.9.5", chevron: true).padding(.horizontal, 16)
                        }
                        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 12)
                    Color.clear.frame(height: 40)
                }
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BackPill(count: nil, title: "Spaces") }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { Text("Edit").foregroundStyle(Color.dispatchPink).fixedSize().padding(.horizontal, 18).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule()) }.sharedBackgroundVisibility(.hidden)
            }
        }
    }
}
