import SwiftUI

// The host stats sheet, second pass: iOS rather than the Mac popover. Three rings in the host's tint for cpu, memory
// and disk, grouped cards for processes and the hour's history with a Battery-style chart, Health-style numerals.

struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct ProcessRow: View {
    let name: String
    let value: String
    let fraction: Double
    var color: Color = hostTint
    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(.body).lineLimit(1).truncationMode(.middle)
            Spacer()
            Capsule().fill(color.opacity(0.25)).frame(width: 70, height: 6)
                .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 70 * fraction) }
            Text(value).font(.body).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }
}

struct HostSheet: View {
    enum Mode { case cpu, mem, scrub }
    enum State { case live, stale, plain, lowPower }
    var mode: Mode = .cpu
    var state: State = .live
    private var live: Bool { state == .live || state == .lowPower }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if state == .lowPower {
                        HStack(spacing: 8) {
                            Image(systemName: "battery.25percent")
                            Text("Low Power Mode · sampling every 15 s")
                            Spacer()
                        }
                        .font(.subheadline).foregroundStyle(Color.caution)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if state == .stale {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.slash")
                            Text("Offline · last sample 2:02 PM")
                            Spacer()
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if state == .plain {
                        Card {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Stats need the helper").font(.headline)
                                    Text("This login is plain SSH. Install the helper on mba2 to see CPU, memory, disk and processes.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text("Install helper…").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dispatchPink).padding(.top, 4)
                                }
                            }
                        }
                    } else {
                    StatStripCard(selected: mode == .mem ? 1 : 0)
                        .opacity(state == .stale ? 0.5 : 1)
                    // Processes.
                    Card(title: "Top processes", trailing: mode == .mem ? "by memory" : "by CPU") {
                        VStack(spacing: 12) {
                            if mode == .mem {
                                ProcessRow(name: "fixture-helper", value: "2.3 GB", fraction: 1)
                                ProcessRow(name: "postgres", value: "1.9 GB", fraction: 0.83)
                                ProcessRow(name: "rust-analyzer", value: "1.4 GB", fraction: 0.61)
                            } else {
                                ProcessRow(name: "node", value: "50%", fraction: 1)
                                ProcessRow(name: "cargo", value: "41%", fraction: 0.82)
                                ProcessRow(name: "rust-analyzer", value: "32%", fraction: 0.64)
                            }
                        }
                    }

                    }
                    // Connection.
                    VStack(spacing: 0) {
                        row("Address", "alex@mba2.tail3f.ts.net")
                        Hairline()
                        row("Latency", "18 ms")
                        Hairline()
                        row("Multiplexer", "herdr 0.9.5")
                        Hairline()
                        row("Helper", "Full features", chevron: true)
                        Hairline()
                        row("Color", "Automatic", chevron: true, swatch: true)
                    }
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))

                    Color.clear.frame(height: 56)
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 10) {
                    if state == .stale {
                        Text("Forget host").font(.body.weight(.semibold)).foregroundStyle(Color.destructive)
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                        Label("Connect", systemImage: "bolt.fill").font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
                    } else {
                        Label("Edit", systemImage: "pencil").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                        Text("Disconnect").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
            .background(Color.canvas)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.logo").font(.system(size: 17)).foregroundStyle(hostTint)
                            .frame(width: 34, height: 34).background(hostTint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text("mba2").font(.headline)
                            HStack(spacing: 5) {
                                Circle().fill(live ? Color.stateConnected : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                                Text(state == .stale ? "macOS 26.1 · offline" : state == .plain ? "macOS 26.1 · Plain SSH" : "macOS 26.1 · 18 ms").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "xmark") } }
                if state == .stale {
                    ToolbarItem(placement: .topBarTrailing) { Button {} label: { Image(systemName: "pencil") } }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ label: String, _ value: String, chevron: Bool = false, swatch: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.body)
            Spacer()
            if swatch { Circle().fill(hostTint).frame(width: 14, height: 14) }
            Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// The sheet at its small detent: the nav bar header, the rings, one action. The same content continues below the
/// fold; dragging the grabber up shows the chart, processes and connection.
struct HostStatsCompact: View {
    var state: HostSheet.State = .live
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if state == .stale {
                    // Offline: the connection facts instead of stale numbers.
                    VStack(spacing: 0) {
                        compactRow("Address", "mba2.tail3f.ts.net")
                        Hairline()
                        compactRow("Port", "22")
                        Hairline()
                        compactRow("User", "alex")
                        Hairline()
                        compactRow("Key", "ED25519 · Face ID")
                        Hairline()
                        compactRow("Multiplexer", "herdr 0.9.5")
                    }
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
                } else {
                    StatStripCard()
                }
                HStack(spacing: 10) {
                    if state == .stale {
                        Label("Connect", systemImage: "bolt.fill").font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
                    } else {
                        Text("Disconnect").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .background(Color.canvas)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.logo").font(.system(size: 17)).foregroundStyle(hostTint)
                            .frame(width: 34, height: 34).background(hostTint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text("mba2").font(.headline)
                            HStack(spacing: 5) {
                                Circle().fill(state == .stale ? Color.secondary.opacity(0.5) : Color.stateConnected).frame(width: 6, height: 6)
                                Text(state == .stale ? "Offline since 2:02 PM" : "macOS 26.1 · 18 ms").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "xmark") } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension HostStatsCompact {
    func compactRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

struct HostStatsCompactHost: View {
    var state: HostSheet.State = .live
    /// A mid-drag frame: the sheet between the detents, the chart card entering.
    var dragging = false
    var body: some View {
        SpacesTreeMock()
            .sheet(isPresented: .constant(true)) {
                if dragging {
                    HostSheet(mode: .cpu, state: state)
                        .presentationDetents([.fraction(0.62)])
                        .presentationDragIndicator(.visible)
                } else {
                    HostStatsCompact(state: state)
                        .presentationDetents([.height(state == .stale ? 372 : 360)])
                        .presentationDragIndicator(.visible)
                        .presentationBackgroundInteraction(.enabled(upThrough: .height(state == .stale ? 372 : 360)))
                }
            }
    }
}

struct HostSheetHost: View {
    var mode: HostSheet.Mode = .cpu
    var state: HostSheet.State = .live
    var body: some View {
        SpacesTreeMock()
            .sheet(isPresented: .constant(true)) {
                HostSheet(mode: mode, state: state)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}
