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

/// The Spaces tree behind the sheet: the host glyph at the trailing edge is the stats button (C); offline hosts
/// gather under an Offline group at the end with their last-known spaces dimmed.
struct SpacesTreeMock: View {
    /// The Offline group folded to its header line.
    var offlineCollapsed = false
    /// The Offline header held: its menu, the "Show offline hosts" switch (Settings has it too).
    var menuOpen = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    FilterRow(selected: 0)
                    hostSection("mba2", glyph: "apple.logo", tint: hostTint, mux: "herdr", spaces: [("app", "1", true), ("e2e", "", false)])
                    hostSection("studio", glyph: "apple.logo", tint: .primary, mux: "tmux", spaces: [], collapsed: "2 spaces · 1")
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            Text("Offline").textCase(.uppercase)
                            Text("2").foregroundStyle(.tertiary)
                            Spacer()
                            Image(systemName: offlineCollapsed ? "chevron.right" : "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                        .overlay(alignment: .topLeading) {
                            if menuOpen {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).frame(width: 18)
                                    Text("Show offline hosts").font(.body)
                                    Spacer()
                                    Image(systemName: "wifi.slash").font(.body)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .frame(width: 270)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                                .offset(x: 8, y: 26)
                            }
                        }
                        .zIndex(1)
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
            .navigationTitle("Spaces")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Text("Edit").fixedSize().padding(.horizontal, 18).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule()) }
            }
        }
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
