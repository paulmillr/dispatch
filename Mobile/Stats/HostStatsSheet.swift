import SwiftUI

/// What the stats surfaces say about a host session (W1–W7), in one place for the sheet, the popover and the tests.
@MainActor
struct HostStatsPresentation {
    let session: HostSession

    enum Phase: Equatable {
        /// Connected through the helper: samples come.
        case live
        /// Not connected (or on its way): the last sample, if any, is stale.
        case offline
        /// No helper (the Helper switch off, or a connection that fell back): stats need the helper (W6).
        case plain
    }

    var phase: Phase {
        if session.plainSSH && (session.link.isConnected || !session.host.helper) { return .plain }
        return session.link.isConnected ? .live : .offline
    }

    var stats: HostStatistics { session.stats }
    private var os: String? { HostSummary(session: session).osLabel }

    /// The title's second line: "macOS 26.1 · 18 ms", "macOS 26.1 · offline", "macOS 26.1 · Plain SSH",
    /// "macOS 26.1 · Connecting…".
    var line: String {
        let state: String
        switch session.link {
        case .connected:
            if session.isPlain { state = HostSummary.plainSSH }
            else if let latency = session.latency { state = HostSummary.milliseconds(latency) }
            else { state = "connected" }
        case .disconnected, .failed: state = session.host.helper ? "offline" : HostSummary.plainSSH
        default: state = HostSummary(session: session).status
        }
        return [os, state].compactMap { $0 }.joined(separator: " · ")
    }

    /// The small offline sheet's line (W1c): "Offline since 2:02 PM", from when the host last answered.
    var offlineLine: String {
        guard !session.link.isPending else { return HostSummary(session: session).status }
        guard let updated = session.updated else { return "Offline" }
        return "Offline since \(HostStatsFormat.time(updated))"
    }

    /// The large sheet's banner while offline (W5): why, when the transport said, else the last sample's time.
    var offlineBanner: String? {
        guard phase == .offline else { return nil }
        if let problem = session.problem { return problem }
        if case .failed(let reason) = session.link { return reason }
        if session.link.isPending { return HostSummary(session: session).status }
        guard let date = stats.sample?.date else { return "Offline" }
        return "Offline · last sample \(HostStatsFormat.time(date))"
    }

    /// W7's banner while Low Power Mode slows sampling.
    var lowPowerBanner: String? {
        let seconds = HostStatistics.cadence(viewing: true, lowPower: true).components.seconds
        return phase == .live && stats.lowPower ? "Low Power Mode · sampling every \(seconds) s" : nil
    }

    /// "alex@studio.local", with the port when it is not SSH's ("alex@studio.local:2222").
    var address: String {
        let host = session.host
        return "\(host.user)@\(host.address)" + (host.port == 22 ? "" : ":\(host.port)")
    }
    var multiplexer: String { session.multiplexerLine ?? (session.host.helper ? session.host.multiplexer.title : "—") }

    /// The plain card's text (W6).
    var plainText: String {
        let name = session.host.name
        if session.host.helper, case .plain(let reason?) = session.mode {
            return "The helper could not start on \(name): \(reason)"
        }
        return "This login is plain SSH. Install the helper on \(name) to see CPU, memory, disk and processes."
    }

    /// The plain card's action: turn the Helper switch on, or try the helper again after a fallback.
    var plainAction: String { session.host.helper ? "Try again" : "Install helper…" }
}

/// The host sheet (W1a–W7, docs/ios.md, Host stats), the host's one screen besides Edit host: the host's disc, name and
/// status as its title with Edit (the pencil) at both detents, the stat strip over the 15-minute sparkline, the top
/// processes and the connection list, with one action: Disconnect, or Connect while offline. Its small detent shows the
/// strip and Disconnect, or offline the connection list and Connect, with the screen behind it still usable; the large
/// one everything. Everything the user sets (the switches, the colour, Remove host) is Edit host's. Present it with
/// `hostStatsSheet(host:)`.
struct HostStatsSheet: View {
    let hostID: UUID
    var launch = HostStatsLaunch()

    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent
    @State private var metric: HostStatistics.Metric
    @State private var scrub: Int?
    @State private var editing = false

    /// The small detent: the strip and one action, or the connection list and Connect.
    nonisolated static let small = PresentationDetent.height(372)
    /// Debug screenshots of a sheet mid-drag (W1b).
    nonisolated static let dragging = PresentationDetent.fraction(0.62)

    init(hostID: UUID, launch: HostStatsLaunch = HostStatsLaunch()) {
        self.hostID = hostID
        self.launch = launch
        _detent = State(initialValue: launch.detent)
        _metric = State(initialValue: launch.metric)
        _scrub = State(initialValue: launch.scrub)
    }

    private var detents: Set<PresentationDetent> {
        launch.detent == Self.dragging ? [Self.small, Self.dragging, .large] : [Self.small, .large]
    }

    var body: some View {
        Group {
            if let session = sessions.session(hostID) {
                NavigationStack { content(session) }
                    .hostStatsViewing(session.stats)
                    // Remove host in Edit host closes this sheet too (the session goes: the branch below).
                    .sheet(isPresented: $editing) {
                        NewHostSheet(editing: session.host).tint(.dispatchPink)
                    }
            } else {
                // Removed elsewhere while open.
                Color.clear.onAppear { dismiss() }
            }
        }
        .tint(.dispatchPink)
        .presentationDetents(detents, selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.small))
        .presentationBackground(Color.canvas)
    }

    private var large: Bool { detent != Self.small }

    private func content(_ session: HostSession) -> some View {
        let presentation = HostStatsPresentation(session: session)
        let phase = presentation.phase
        return ScrollView {
            VStack(spacing: 14) {
                if phase == .offline && !large {
                    HostConnectionList(session: session)
                } else {
                    HostStatsBody(session: session, metric: $metric, scrub: $scrub, expanded: large)
                }
                // At the small detent the action sits right under the strip or the facts (W1a, W1c); at the large one
                // in the bottom bar, under the rest of the sheet.
                if !large {
                    actions(session).padding(.horizontal, -16)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .animation(.snappy, value: large)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollDisabled(!large)
        .safeAreaBar(edge: .bottom) { if large { actions(session) } }
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HostStatsIdentity(session: session,
                                  line: phase == .offline && !large ? presentation.offlineLine : presentation.line,
                                  live: phase == .live)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .accessibilityLabel("Edit")
            }
        }
    }

    /// The one action, the same at both detents: Disconnect, also while connecting or reconnecting (it stops the
    /// retries); offline Connect.
    private func actions(_ session: HostSession) -> some View {
        HostStatsAction(session: session)
            .padding(.horizontal, 16).padding(.bottom, 4)
    }
}

/// The sheet's and the popover's action: Disconnect while connected or on its way, else Connect.
struct HostStatsAction: View {
    let session: HostSession

    var body: some View {
        if session.link.isConnected || session.link.isPending {
            HostStatsActionButton(title: "Disconnect") { session.park() }
        } else {
            HostStatsConnectButton(session: session)
        }
    }
}

/// What a stats surface shows below its title (the sheet and the popover): the banners, the strip (or the plain card),
/// the processes and the connection list. Not `expanded` (the sheet's small detent) only the strip or the plain card
/// shows, with the action under it.
struct HostStatsBody: View {
    let session: HostSession
    @Binding var metric: HostStatistics.Metric
    @Binding var scrub: Int?
    var expanded = true

    var body: some View {
        let presentation = HostStatsPresentation(session: session)
        let phase = presentation.phase
        let tint = session.host.tint.color
        VStack(spacing: 14) {
            if expanded, let banner = presentation.lowPowerBanner {
                HostStatsBanner(text: banner, symbol: "battery.25percent", caution: true)
            }
            if expanded, let banner = presentation.offlineBanner {
                HostStatsBanner(text: banner, symbol: session.link.isPending ? "arrow.triangle.2.circlepath" : "wifi.slash")
            }
            if phase == .plain {
                HostPlainStatsCard(session: session)
            } else {
                StatStripCard(stats: session.stats, metric: $metric, tint: tint, dimmed: phase != .live || !session.stats.live, scrub: $scrub)
                if expanded { HostProcessesCard(stats: session.stats, metric: metric, tint: tint) }
            }
            if expanded { HostConnectionList(session: session) }
        }
    }
}

/// W5's offline line and W7's Low Power Mode line.
struct HostStatsBanner: View {
    let text: String
    let symbol: String
    var caution = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.subheadline).foregroundStyle(caution ? Color.caution : .secondary)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(caution ? Color.caution.opacity(0.12) : Color.groupedRow, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// W6: a host without its helper has no stats; "Install helper…" turns its Helper switch on (which reconnects), and
/// after a fallback "Try again" connects once more or "Use plain SSH" turns the switch off (`HostSummary.offersPlainSSH`).
struct HostPlainStatsCard: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        let presentation = HostStatsPresentation(session: session)
        HostStatsCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shippingbox").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stats need the helper").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(presentation.plainText)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        Button(presentation.plainAction) {
                            if session.host.helper {
                                session.disconnect()
                                session.connectByUser()
                            } else {
                                sessions.setHelper(true, host: session.id)
                                session.connectByUser()
                            }
                        }
                        if HostSummary(session: session).offersPlainSSH {
                            Button(Self.usePlainSSH) { sessions.setHelper(false, host: session.id) }
                                .accessibilityHint("Turns the helper off: \(session.host.name) connects with plain SSH from now on")
                        }
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                    .padding(.top, 4)
                }
            }
        }
    }

    static let usePlainSSH = "Use plain SSH"
}

/// The connection list (W1, and offline W1c instead of stale numbers): Address ("user@host", with a port that is not
/// 22), Key and Multiplexer; with no multiplexer on the host its row leads to the install hint. The latency is the
/// title's line; the switches and the colour are Edit host's.
struct HostConnectionList: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        let presentation = HostStatsPresentation(session: session)
        VStack(spacing: 0) {
            HostStatsListRow(label: "Address", value: presentation.address)
            HostStatsHairline()
            HostStatsListRow(label: "Key", value: sessions.keyName(session.host))
            HostStatsHairline()
            if session.multiplexerLine == "none" {
                NavigationLink { MultiplexerHint(hostID: session.id) } label: {
                    HostStatsListRow(label: "Multiplexer", value: presentation.multiplexer, chevron: true)
                }
                .buttonStyle(.plain)
            } else {
                HostStatsListRow(label: "Multiplexer", value: presentation.multiplexer)
            }
        }
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// A glass capsule button of the sheet's bottom bar.
struct HostStatsActionButton: View {
    let title: String
    var symbol: String? = nil
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(role == .destructive ? Color.destructive : Color.primary)
            .frame(maxWidth: .infinity).frame(height: 50)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// Connect (pink): lifts a Disconnect and connects (`HostSession.connectByUser`); while on its way the bars show
/// Disconnect instead.
struct HostStatsConnectButton: View {
    let session: HostSession

    var body: some View {
        Button { session.connectByUser() } label: {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                Text("Connect")
            }
            .font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity).frame(height: 50)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
        .disabled(session.hostKeyMismatch != nil)
        .accessibilityLabel("Connect")
    }
}

/// Edit host's Color (docs/ios.md, Hosts and trust): Automatic (the colour it was given, the one the fewest hosts show)
/// or one of the palette's eight, as `choice` (nil: Automatic), which Save puts in `HostRecord.color` (`setColor`).
struct HostColorPicker: View {
    let host: HostRecord
    @Binding var choice: HostColor?
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        // Colours are drawn by machine: another host of the same machine earlier in the list sets this one's.
        let owner = sessions.colorOwner(of: host.id)
        List {
            Section {
                row("Automatic", swatch: host.tint.showing(sessions.automaticColor(of: host.id)).color, chosen: choice == nil) {
                    choice = nil
                }
            }
            Section {
                ForEach(HostColor.allCases, id: \.self) { color in
                    row(color.title, swatch: host.tint.showing(color).color, chosen: choice == color) { choice = color }
                }
            } footer: {
                if let owner {
                    Text("\(host.name) is the same machine as \(owner.name), whose colour both show. Choose it when editing \(owner.name).")
                } else {
                    Text("Spaces, Agents and this \(MobileDevice.name)'s tabs draw \(host.name) in this colour."
                         + (HostColorStore.shared.enabled ? "" : " Color-code hosts is off in Settings: every host is gray until it is on."))
                }
            }
        }
        .disabled(owner != nil)
        .navigationTitle("Color")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, swatch: Color, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(swatch).frame(width: 18, height: 18).accessibilityHidden(true)
                Text(title).foregroundStyle(Color.primary)
                Spacer()
                if chosen { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink) }
            }
        }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

extension HostSessions {
    /// The Key fact: the key's label, "Password", or "Missing key".
    func keyName(_ host: HostRecord) -> String {
        switch host.auth {
        case .password: "Password"
        case .key(let id): keys.key(id)?.label ?? "Missing key"
        }
    }

    /// The colour Automatic gives the host: the one it has while not picked, else the one the fewest other hosts show
    /// (`HostStore.freeColor`, as a new host gets).
    func automaticColor(of id: UUID) -> HostColor? {
        guard let record = store.record(id) else { return nil }
        if !record.colorPicked { return record.color }
        return HostStore.freeColor(seed: record.tint.seed, among: store.hosts.filter { $0.id != id })
    }

    /// The host whose colour this one shows: an earlier host of the same machine (`HostTint.machine`; the colours are
    /// published by machine, the first host's winning), nil when it is this one's own.
    func colorOwner(of id: UUID) -> HostRecord? {
        guard let record = store.record(id),
              let first = store.hosts.first(where: { $0.tint.machine == record.tint.machine }), first.id != id else { return nil }
        return first
    }

    /// The Color picker's choice put in `record`: a colour (`colorPicked`), or nil for Automatic, which gives the host
    /// the colour the fewest other hosts show, as a new host gets (`HostStore.freeColor`).
    func setColor(_ color: HostColor?, in record: inout HostRecord) {
        if let color {
            record.color = color
            record.colorPicked = true
        } else if record.colorPicked {
            record.color = automaticColor(of: record.id)
            record.colorPicked = false
        }
    }
}

extension View {
    /// Asks `stats` for 2 s samples while this view is on screen (`HostStatistics.beginViewing`). Keyed by the store, so
    /// an edit that replaces the host's session (and its stats) moves the request to the new one.
    func hostStatsViewing(_ stats: HostStatistics) -> some View {
        task(id: ObjectIdentifier(stats)) {
            let token = stats.beginViewing()
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            stats.endViewing(token)
        }
    }
}

/// Presents a host's stats sheet.
private struct HostStatsItem: Identifiable {
    let id: UUID
}

extension View {
    /// Presents the stats sheet of host `host` while it is set (W1, docs/ios.md, Host stats); dismissing it clears it.
    /// What other areas call from a host's glyph or row (Spaces' host glyph, the space switcher's host row, host
    /// detail, Settings). The host's `HostSessions` must be in the environment.
    func hostStatsSheet(host: Binding<UUID?>) -> some View {
        sheet(item: Binding(get: { host.wrappedValue.map(HostStatsItem.init) }, set: { host.wrappedValue = $0?.id })) { item in
            HostStatsSheet(hostID: item.id)
        }
    }
}

/// Where a sheet opens (Debug screenshots: `-DispatchHostStats`): its detent, chart and a bar being read.
struct HostStatsLaunch {
    var detent: PresentationDetent = HostStatsSheet.small
    var metric: HostStatistics.Metric = .cpu
    var scrub: Int? = nil
}

/// I5: the host sheet as a popover from a host's glyph on an iPad (the iPad stream presents it): its content at 360
/// points without its bar or grabber, the Edit pencil in its header, Disconnect (Connect offline) last.
struct HostStatsPopoverContent: View {
    let hostID: UUID
    @Environment(HostSessions.self) private var sessions
    @State private var metric: HostStatistics.Metric = .cpu
    @State private var scrub: Int?
    @State private var editing = false

    static let width: CGFloat = 360

    var body: some View {
        if let session = sessions.session(hostID) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            HostStatsIdentity(session: session, line: HostStatsPresentation(session: session).line,
                                              live: session.link.isConnected)
                            Spacer()
                            Button { editing = true } label: {
                                Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .accessibilityLabel("Edit")
                        }
                        .padding(.top, 2)
                        HostStatsBody(session: session, metric: $metric, scrub: $scrub)
                    }
                    .padding(16)
                }
                // The action stays whole at the popover's foot, the rest scrolling above it (in the scroll view the
                // popover's height cut it).
                .safeAreaBar(edge: .bottom) {
                    HostStatsAction(session: session)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
            .frame(width: Self.width)
            .frame(minHeight: 480, idealHeight: 628)
            .tint(.dispatchPink)
            .hostStatsViewing(session.stats)
            .sheet(isPresented: $editing) { NewHostSheet(editing: session.host).tint(.dispatchPink) }
        }
    }
}
