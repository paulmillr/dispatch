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
        phase == .live && stats.lowPower ? "Low Power Mode · sampling every 15 s" : nil
    }

    var address: String { "\(session.host.user)@\(session.host.address)" }
    var latency: String { session.latency.map(HostSummary.milliseconds) ?? "—" }
    var multiplexer: String { session.multiplexerLine ?? (session.host.helper ? session.host.multiplexer.title : "—") }

    /// The Helper row: "Full features" (the helper with Chat), "Without Chat", "Plain SSH" (the switch off).
    var helper: String {
        guard session.host.helper else { return HostSummary.plainSSH }
        return session.host.chat ? "Full features" : "Without Chat"
    }

    /// The Color row: "Automatic" unless the user picked one (`HostRecord.colorPicked`).
    var color: String {
        guard session.host.colorPicked, let color = session.host.color else { return "Automatic" }
        return color.title
    }

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

/// The host stats sheet (W1a–W7, docs/ios.md, Host stats): the host's disc, name and status as its title, the stat strip
/// over the 15-minute sparkline, the top processes and the connection, with Edit and Disconnect (Forget host and
/// Connect while offline). Its small detent shows the strip and Disconnect, or offline the connection facts and Connect,
/// with the screen behind it still usable; the large one everything. Present it with `hostStatsSheet(host:)`.
struct HostStatsSheet: View {
    let hostID: UUID
    var launch = HostStatsLaunch()

    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent
    @State private var metric: HostStatistics.Metric
    @State private var scrub: Int?
    @State private var editing = false
    @State private var confirmingForget = false
    @State private var forgetting = false

    /// The small detent: the strip and one action, or the five connection facts and Connect.
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
                    .onDisappear { if forgetting { sessions.remove(hostID) } }
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
                    HostConnectionFacts(session: session)
                } else {
                    HostStatsBody(session: session, metric: $metric, scrub: $scrub, compact: false, expanded: large)
                }
                // At the small detent the action sits right under the strip or the facts (W1a, W1c); at the large one
                // in the bottom bar, under the rest of the sheet.
                if !large {
                    actions(session, phase: phase).padding(.horizontal, -16)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .animation(.snappy, value: large)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollDisabled(!large)
        .safeAreaBar(edge: .bottom) { if large { actions(session, phase: phase) } }
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
            if phase == .offline && large {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Edit")
                }
            }
        }
        .navigationDestination(for: HostStatsRoute.self) { route in
            switch route {
            case .helper: HostHelperSettings(hostID: session.id)
            case .color: HostColorPicker(hostID: session.id)
            }
        }
        .confirmationDialog("Forget \(session.host.name)?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget host", role: .destructive) {
                forgetting = true
                dismiss()
            }
        } message: {
            Text(HostSessions.removalMessage)
        }
    }

    /// The bottom bar: Disconnect (small) or Edit and Disconnect; offline Connect (small) or Forget host and Connect.
    private func actions(_ session: HostSession, phase: HostStatsPresentation.Phase) -> some View {
        let connected = session.link.isConnected
        return HStack(spacing: 10) {
            if connected {
                if large {
                    HostStatsActionButton(title: "Edit", symbol: "pencil") { editing = true }
                }
                HostStatsActionButton(title: "Disconnect") { session.park() }
            } else {
                if large {
                    HostStatsActionButton(title: "Forget host", role: .destructive) { confirmingForget = true }
                }
                HostStatsConnectButton(session: session)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
        .animation(.snappy, value: large)
    }
}

/// Where the sheet pushes: the Helper and Color rows.
enum HostStatsRoute: Hashable {
    case helper, color
}

/// What a stats surface shows below its title (the sheet and the popover): the banners, the strip (or the plain card),
/// the processes and the connection list. `compact` is the popover's: Address, Multiplexer and Helper only. Not
/// `expanded` (the sheet's small detent) only the strip or the plain card shows, with the action under it.
struct HostStatsBody: View {
    let session: HostSession
    @Binding var metric: HostStatistics.Metric
    @Binding var scrub: Int?
    var compact: Bool
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
            if expanded { HostConnectionList(session: session, compact: compact) }
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
/// after a fallback "Try again" connects once more.
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
                    Button(presentation.plainAction) {
                        if session.host.helper {
                            session.disconnect()
                            session.connectByUser()
                        } else {
                            sessions.setHelper(true, host: session.id)
                            session.connectByUser()
                        }
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                    .padding(.top, 4)
                }
            }
        }
    }
}

/// The sheet's connection list (W1): Address, Latency, Multiplexer, Helper › and Color ›; the popover's (I5) Address,
/// Multiplexer and Helper ›.
struct HostConnectionList: View {
    let session: HostSession
    var compact = false

    var body: some View {
        let presentation = HostStatsPresentation(session: session)
        VStack(spacing: 0) {
            HostStatsListRow(label: "Address", value: presentation.address)
            HostStatsHairline()
            if !compact {
                HostStatsListRow(label: "Latency", value: presentation.latency)
                HostStatsHairline()
            }
            HostStatsListRow(label: "Multiplexer", value: presentation.multiplexer)
            HostStatsHairline()
            NavigationLink(value: HostStatsRoute.helper) {
                HostStatsListRow(label: "Helper", value: presentation.helper, chevron: true)
            }
            .buttonStyle(.plain)
            if !compact {
                HostStatsHairline()
                NavigationLink(value: HostStatsRoute.color) {
                    HostStatsListRow(label: "Color", value: presentation.color, chevron: true, swatch: session.host.tint.color)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// W1c: what the phone knows of an offline host, instead of stale numbers.
struct HostConnectionFacts: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        let host = session.host
        VStack(spacing: 0) {
            row("Address", host.address)
            HostStatsHairline()
            row("Port", String(host.port))
            HostStatsHairline()
            row("User", host.user)
            HostStatsHairline()
            row("Key", sessions.keyName(host))
            HostStatsHairline()
            row("Multiplexer", HostStatsPresentation(session: session).multiplexer)
        }
        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.body)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
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

/// Connect (pink): lifts a Disconnect and connects (`HostSession.connectByUser`); "Connecting…" while on its way.
struct HostStatsConnectButton: View {
    let session: HostSession

    var body: some View {
        let pending = session.link.isPending
        Button { session.connectByUser() } label: {
            HStack(spacing: 8) {
                if pending { ProgressView().tint(Color.onAccent) } else { Image(systemName: "bolt.fill") }
                Text(pending ? "Connecting…" : "Connect")
            }
            .font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity).frame(height: 50)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
        .disabled(pending || session.hostKeyMismatch != nil)
        .accessibilityLabel(pending ? "Connecting" : "Connect")
    }
}

/// The host's Helper and Chat switches (`HostHelperRows`) and its multiplexer, pushed from the stats' Helper row.
struct HostHelperSettings: View {
    let hostID: UUID
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        if let session = sessions.session(hostID) {
            Form {
                Section {
                    HostHelperRows(session: session)
                } footer: {
                    Text(session.host.helper
                         ? "Dispatch's helper runs on \(session.host.name) for spaces, Chat and stats."
                         : NewHostSheet.plainStatement)
                }
                if session.host.helper {
                    Section {
                        if session.multiplexerLine == "none" {
                            LabeledContent("Multiplexer") { Text("none").monospaced() }
                        } else {
                            HostMultiplexerPicker(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Helper")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// The host's colour (docs/ios.md, Hosts and trust): Automatic (the colour it was given, the one the fewest hosts
/// show) or one of the palette's eight, saved in `HostRecord.color`.
struct HostColorPicker: View {
    let hostID: UUID
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        if let session = sessions.session(hostID) {
            let host = session.host
            // Colours are drawn by machine: another host of the same machine earlier in the list sets this one's.
            let owner = sessions.colorOwner(of: hostID)
            List {
                Section {
                    row("Automatic", swatch: host.tint.showing(sessions.automaticColor(of: hostID)).color, chosen: !host.colorPicked) {
                        sessions.setColor(nil, host: hostID)
                    }
                }
                Section {
                    ForEach(HostColor.allCases, id: \.self) { color in
                        row(color.title, swatch: host.tint.showing(color).color, chosen: host.colorPicked && host.color == color) {
                            sessions.setColor(color, host: hostID)
                        }
                    }
                } footer: {
                    if let owner {
                        Text("\(host.name) is the same machine as \(owner.name), whose colour both show. Choose it in \(owner.name)'s stats.")
                    } else {
                        Text("Spaces, Agents and this \(MobileDevice.name)'s tabs draw \(host.name) in this colour.")
                    }
                }
            }
            .disabled(owner != nil)
            .navigationTitle("Color")
            .navigationBarTitleDisplayMode(.inline)
        }
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

    /// The Color picker's choice, saved at once: a colour (`colorPicked`), or nil for Automatic, which gives the host
    /// the colour the fewest other hosts show, as a new host gets (`HostStore.freeColor`).
    func setColor(_ color: HostColor?, host id: UUID) {
        guard var record = store.record(id) else { return }
        if let color {
            record.color = color
            record.colorPicked = true
        } else {
            guard record.colorPicked else { return }
            record.color = automaticColor(of: id)
            record.colorPicked = false
        }
        update(record)
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

/// I5: the stats as a popover from a host's glyph on an iPad (the iPad stream presents it): the sheet's content at
/// 360 points without its bar or grabber, the Edit pencil in its header, Edit and Disconnect (Connect offline) last.
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
                        HostStatsBody(session: session, metric: $metric, scrub: $scrub, compact: true)
                    }
                    .padding(16)
                }
                // Edit and Disconnect stay whole at the popover's foot, the rest scrolling above them (in the scroll
                // view the popover's height cut them).
                .safeAreaBar(edge: .bottom) {
                    HStack(spacing: 10) {
                        HostStatsActionButton(title: "Edit", symbol: "pencil") { editing = true }
                        if session.link.isConnected {
                            HostStatsActionButton(title: "Disconnect") { session.park() }
                        } else {
                            HostStatsConnectButton(session: session)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: HostStatsRoute.self) { route in
                    switch route {
                    case .helper: HostHelperSettings(hostID: hostID)
                    case .color: HostColorPicker(hostID: hostID)
                    }
                }
            }
            .frame(width: Self.width)
            .frame(minHeight: 480, idealHeight: 628)
            .tint(.dispatchPink)
            .hostStatsViewing(session.stats)
            .sheet(isPresented: $editing) { NewHostSheet(editing: session.host).tint(.dispatchPink) }
        }
    }
}
