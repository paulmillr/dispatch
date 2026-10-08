import SwiftUI

extension HostRecord {
    var tint: HostTint? {
        id == .local ? nil : HostTint(hostID: id.rawValue.hasPrefix("ssh:") ? String(id.rawValue.dropFirst(4)) : id.rawValue)
    }
}

struct HostGlyph: View {
    let host: HostRecord
    var size: CGFloat = 15
    /// Overrides the SF Symbol point size, e.g. to match the local Mac's glyph.
    var symbolSize: CGFloat?
    var body: some View {
        Group {
            if host.system?.distribution == "ubuntu" {
                Canvas { context, size in Self.ubuntu(context, size: size) }
            } else if host.system?.distribution == "debian" {
                Image("HostDebian").resizable().scaledToFit()
            } else if host.system?.os == "FreeBSD" {
                Image("HostFreeBSD").resizable().scaledToFit()
            } else {
                Image(systemName: host.system?.os == "Darwin" ? "apple.logo" : "server.rack")
                    .font(.system(size: symbolSize ?? (size == 15 ? 12 : size)))
            }
        }.frame(width: size, height: size).accessibilityLabel(host.system?.label ?? "Remote host, OS unavailable")
    }

    private static func ubuntu(_ context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.28
        let scale = min(size.width, size.height) / 15
        for index in 0..<3 {
            let angle = Double(index) * 120 + 180
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(angle + 24), endAngle: .degrees(angle + 96), clockwise: false)
            context.stroke(arc, with: .foreground, lineWidth: 1.7 * scale)
            let x = center.x + CGFloat(cos(angle * .pi / 180)) * radius * 1.5
            let y = center.y + CGFloat(sin(angle * .pi / 180)) * radius * 1.5
            let dot = Path(ellipseIn: CGRect(x: x - 1.6 * scale, y: y - 1.6 * scale, width: 3.2 * scale, height: 3.2 * scale))
            context.fill(dot, with: .foreground)
        }
    }
}

struct HostInformationView: View {
    @Environment(\.appTypography) private var typography
    let host: HostRecord
    let state: HostConnectionState
    var disconnect: (() -> Void)? = nil
    var reconnect: (() -> Void)? = nil
    var forget: (() -> Void)? = nil
    var preferred: SSHConnectionID? = nil
    var machine: TerminalMachine? = nil
    var attachedBackends: Set<SpaceBackend> = []
    @State private var footerHovered: String?
    @State private var selectedStatistics: SSHStatisticsStore.Key?

    private struct BackendRequest: Equatable {
        let host: HostID
        let machine: TerminalMachine?
    }
    private var backendRequest: BackendRequest {
        .init(host: host.id, machine: state == .connected ? machine : nil)
    }
    private var backends: Set<SpaceBackend>? {
        var detected = HostBackendCache.shared.cached(for: host.id)
        // An attached backend is direct evidence even if a separate SSH probe
        // cannot authenticate or has not finished yet.
        if !attachedBackends.isEmpty { detected = (detected ?? [.native]).union(attachedBackends) }
        return detected
    }

    private var statisticsSource: HostStatisticsStore.Source {
        HostStatisticsStore().source(host: host.id, preferred: preferred, selected: selectedStatistics)
    }
    private var latency: SSHLatency? {
        guard case .ssh(let key) = statisticsSource else { return nil }
        return SSHStatisticsStore.shared.series[key]?.latency
    }

    private func hasStats(at now: Date) -> Bool {
        guard case .ssh(let key) = statisticsSource,
              let entry = SSHStatisticsStore.shared.series[key] else { return false }
        guard state == .disconnected else { return true }
        guard let date = entry.latest?.date else { return false }
        return now.timeIntervalSince(date) <= 5 * 60
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(at: timeline.date)
        }
        .task(id: statisticsSource) {
            guard case .ssh(let key) = statisticsSource,
                  let token = SSHStatisticsStore.shared.subscribeLatency(key, preferred: preferred) else { return }
            defer { SSHStatisticsStore.shared.unsubscribeLatency(token, from: key) }
            do { while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) } } catch {}
        }
        .task(id: backendRequest) {
            let request = backendRequest
            guard let machine = request.machine else { return }
            let cache = HostBackendCache.shared
            do {
                while !Task.isCancelled {
                    _ = await cache.installed(for: request.host, on: machine)
                    try Task.checkCancellation()
                    try await Task.sleep(for: cache.refreshDelay(for: request.host))
                }
            } catch {}
        }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Keep connection actions reachable even with many saved accounts.
            FittingPopoverContent(maxHeight: typography.popoverHeight(1000) - 32 - footerHeight) {
                details(at: now)
            }
            let actions = footerActions
            // On glass the actions share one row, like a popover's buttons; otherwise each is a full-width row.
            if StatsStyle.glass, !actions.isEmpty {
                HStack(spacing: 8) { ForEach(actions) { footerButton($0) } }
            } else {
                ForEach(actions) { footerButton($0) }
            }
        }.font(typography.font(offset: -0.5)).foregroundStyle(Chrome.ink)
            .padding(.horizontal, 18).padding(.vertical, 16).frame(width: typography.expanded(356))
            .statsPopoverBackground().preferredColorScheme(Chrome.colorScheme)
            .accessibilityIdentifier("host-information-popover")
    }

    private struct FooterAction: Identifiable {
        let id: String
        let title: String
        let help: String
        var destructive = false
        let action: () -> Void
    }

    private var footerActions: [FooterAction] {
        var actions: [FooterAction] = []
        if state == .disconnected, let reconnect {
            actions.append(.init(id: "host-reconnect", title: "Reconnect", help: "Reconnect SSH spaces on \(host.name)", action: reconnect))
        } else if let disconnect {
            actions.append(.init(id: "host-disconnect", title: "Disconnect", help: "Disconnect all SSH spaces on \(host.name)", action: disconnect))
        }
        if state == .disconnected, let forget {
            actions.append(.init(id: "host-forget", title: "Forget host",
                                 help: "Remove this host and its saved tabs. Remote processes keep running.", destructive: true, action: forget))
        }
        return actions
    }

    private var footerHeight: CGFloat {
        let rows = StatsStyle.glass ? min(footerActions.count, 1) : footerActions.count
        return CGFloat(rows) * (typography.expanded(28) + 18)
    }

    private func details(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HostIdentityHeader(host: host, state: state, latency: latency)
            if !host.id.isProvisional, HostColorStore.shared.enabled, let tint = host.tint {
                HostColorPicker(tint: tint)
            }
            // On glass, spacing alone separates the connection facts; only the stats keep a rule.
            HostConnectionDetails(host: host, backends: backends,
                checkingBackends: state == .connected && machine != nil && !HostBackendCache.shared.probeFailed(for: host.id),
                integrations: TerminalRuntime.shared.ssh.integrationEntries(for: host.id),
                changeIntegration: { TerminalRuntime.shared.ssh.editIntegration($0.scope) },
                resetIntegration: { TerminalRuntime.shared.ssh.permissions.reset($0.scope) })
                .padding(.top, 8).padding(.bottom, 4)
                .overlay(alignment: .top) { if !StatsStyle.glass { Rectangle().fill(StatsStyle.track).frame(height: 1) } }
            if host.id.isProvisional {
                Text("Machine identity unavailable").foregroundStyle(Chrome.muted)
            }
            if hasStats(at: now) {
                HostStatsView(host: host, preferred: preferred, showsIdentity: false, sourceChanged: { source in
                    if case .ssh(let key) = source { selectedStatistics = key }
                })
                    .padding(.top, 12)
                    .overlay(alignment: .top) { Rectangle().fill(StatsStyle.track).frame(height: 1) }
            }
        }
    }

    @ViewBuilder private func footerButton(_ action: FooterAction) -> some View {
        Group {
            if StatsStyle.glass {
                // The system's capsule buttons; Forget host takes the destructive role's red.
                Button(role: action.destructive ? .destructive : nil, action: action.action) {
                    // The popover's inherited ink would otherwise override the role's red.
                    Text(action.title).font(typography.font(offset: -0.5)).frame(maxWidth: .infinity)
                        .foregroundStyle(action.destructive ? Color(nsColor: .systemRed) : Chrome.ink)
                }.buttonStyle(.bordered).controlSize(.large).padding(.top, 4)
            } else {
                flatFooterButton(action.title, action: action.action)
            }
        }
        .help(action.help)
        .accessibilityIdentifier(action.id)
    }

    private func flatFooterButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(typography.font(offset: -0.5))
                .foregroundStyle(Chrome.ink)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(minHeight: typography.expanded(28))
                .background(footerHovered == title ? Chrome.palette.controlBorder : Chrome.palette.control,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Chrome.palette.controlBorder, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .onHover { footerHovered = $0 ? title : nil }
            .padding(.top, 4)
    }

}

/// Compact connection facts; backend and integration badges describe
/// availability, while the integration label opens its chooser.
struct HostConnectionDetails: View {
    @Environment(\.appTypography) private var typography
    let host: HostRecord
    let backends: Set<SpaceBackend>?
    let checkingBackends: Bool
    let integrations: [SSHIntegrationPermissions.Entry]
    let changeIntegration: (SSHIntegrationPermissions.Entry) -> Void
    let resetIntegration: (SSHIntegrationPermissions.Entry) -> Void
    @State private var hoveredIntegration: String?
    private var accent: Color { Chrome.accent }

    private var destinations: [String] {
        host.destinations.isEmpty ? [host.hostname ?? host.name] : host.destinations
    }
    private var backendNames: [String] {
        SpaceBackend.allCases.filter { $0 != .native && backends?.contains($0) == true }.map(\.rawValue)
    }
    private var backendHelp: String {
        if backends == nil { return checkingBackends ? "Checking available backends…" : "Backend availability unknown" }
        return backendNames.isEmpty ? "No tmux or herdr backend detected" : "Available backends: " + backendNames.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                HStack(spacing: 8) {
                    ConnectionRouteView(remote: host.id != .local, route: destination, fontSize: typography.size(offset: -0.5))
                        .textSelection(.enabled).help(destination)
                    Spacer(minLength: 0)
                    if index == 0 { backendBadges }
                }.frame(minHeight: typography.expanded(20))
            }
            if integrations.isEmpty {
                Text("Integration unavailable")
                    .foregroundStyle(StatsStyle.muted).font(typography.font(offset: -1.5))
                    .frame(minHeight: typography.expanded(26))
            } else {
                ForEach(integrations) { entry in helperRow(entry) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backendBadges: some View {
        HStack(spacing: 4) {
            if backends == nil {
                Text(checkingBackends ? "…" : "—")
                    .foregroundStyle(StatsStyle.muted)
            } else if backendNames.isEmpty {
                Text("no tmux or herdr")
                    .foregroundStyle(Chrome.palette.warning)
            } else {
                ForEach(backendNames, id: \.self) { name in
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: typography.size(offset: -4), weight: .medium))
                        Text(name)
                    }.foregroundStyle(accent)
                        .padding(.horizontal, StatsStyle.glass ? 7 : 5).padding(.vertical, 2)
                        .background(accent.opacity(0.07), in: StatsStyle.chip(radius: 4))
                        .overlay { StatsStyle.chip(radius: 4).strokeBorder(accent.opacity(0.18)) }
                }
            }
        }.font(typography.font(offset: -2)).fixedSize()
            .help(backendHelp)
            .accessibilityElement(children: .ignore).accessibilityLabel(backendHelp)
            .accessibilityIdentifier("host-available-backends")
    }

    private func helperRow(_ entry: SSHIntegrationPermissions.Entry) -> some View {
        let destination = entry.scope.destination.replacingOccurrences(of: "ssh://", with: "")
        let address = entry.scope.account + "@" + (destination.split(separator: "@").last.map(String.init) ?? destination)
        return Button { changeIntegration(entry) } label: {
            HStack(spacing: 8) {
                Text(integrations.count > 1 ? address : "Integration")
                    .foregroundStyle(Color(red: 126/255, green: 166/255, blue: 201/255))
                    .underline(hoveredIntegration == entry.id)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                integrationBadge(entry)
            }.font(typography.font(offset: -1.5))
                .frame(minHeight: typography.expanded(26))
                // A capsule highlight needs more room at its ends to clear the text.
                .padding(.horizontal, StatsStyle.glass ? 10 : 6)
                .background(Chrome.ink.opacity(hoveredIntegration == entry.id ? 0.04 : 0), in: StatsStyle.chip(radius: 5))
                .contentShape(Rectangle())
                .padding(.horizontal, StatsStyle.glass ? -10 : -6)
        }.buttonStyle(.plain)
            .onHover { hoveredIntegration = $0 ? entry.id : nil }
            .help("Change SSH integration for \(address). Right-click to reset." + (entry.grant.profile == .ordinary ? "" : " Helper: ~/.dispatch/bin/<digest>/dsptch"))
            .accessibilityLabel("SSH integration: \(entry.grant.shortLabel). Change settings for \(address)")
            .accessibilityIdentifier("host-integration-settings")
            .contextMenu {
                Button("Reset integration") { resetIntegration(entry) }
                    .help("Forget this SSH config's helper choice and stop its integrations. Asked again on next connect.")
                    .accessibilityIdentifier("host-reset-permissions")
            }
    }

    @ViewBuilder private func integrationBadge(_ entry: SSHIntegrationPermissions.Entry) -> some View {
        if entry.grant.profile == .ordinary {
            Text(entry.grant.shortLabel)
                .foregroundStyle(Chrome.palette.warning)
                .fixedSize()
        } else {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: typography.size(offset: -4), weight: .medium))
                Text(entry.grant.shortLabel)
            }.foregroundStyle(accent)
                .padding(.horizontal, StatsStyle.glass ? 7 : 5).padding(.vertical, 2)
                .background(accent.opacity(0.07), in: StatsStyle.chip(radius: 4))
                .overlay { StatsStyle.chip(radius: 4).strokeBorder(accent.opacity(0.18)) }
                .font(typography.font(offset: -2)).fixedSize()
        }
    }
}

/// Automatic, or one fixed color for this machine in every theme.
struct HostColorPicker: View {
    let tint: HostTint
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color").foregroundStyle(StatsStyle.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: HostColor.allCases.count + 1), alignment: .leading, spacing: 4) {
                swatch(nil)
                ForEach(HostColor.allCases, id: \.self) { swatch($0) }
            }
        }
    }

    private func swatch(_ color: HostColor?) -> some View {
        let selected = tint.choice == color, title = color?.title ?? "Automatic (\(tint.automatic.title))"
        return Button { HostColorStore.shared.choose(color, for: tint.machine) } label: {
            Circle().fill(tint.showing(color).edge)
                .frame(width: 14, height: 14)
                .overlay {
                    // The automatic swatch is marked so it never reads as a fixed color.
                    if color == nil { Image(systemName: "wand.and.stars").font(.system(size: 7, weight: .bold)).foregroundStyle(.white) }
                }
                .padding(2)
                .overlay { Circle().strokeBorder(selected ? Chrome.ink : .clear, lineWidth: 1.5) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("\(title) host color")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("host-color-\(color?.rawValue ?? "automatic")")
    }
}

struct HostIdentityHeader: View {
    @Environment(\.appTypography) private var typography
    let host: HostRecord
    let state: HostConnectionState
    var latency: SSHLatency? = nil
    private var visibleLatency: SSHLatency? {
        host.id != .local && state != .disconnected ? latency : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            HostGlyph(host: host)
                .foregroundStyle(host.tint?.foreground ?? Chrome.ink)
                .frame(width: 28, height: 28)
                .background((host.tint?.foreground ?? Chrome.muted).opacity(0.15),
                            in: StatsStyle.glass ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 7)))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.id == .local ? "local" : host.name).font(typography.font(offset: 0.5, weight: .semibold))
                Text(host.system?.label ?? "Operating system unavailable")
                    .font(typography.font(offset: -1.5)).foregroundStyle(StatsStyle.muted)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Circle().fill(state == .connected ? Chrome.palette.green : Chrome.muted)
                    .frame(width: 5, height: 5)
                if let latency = visibleLatency {
                    Text(latency.state == .stale ? "\(latency.label) · stale" : latency.label)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(latency.state == .ready ? StatsStyle.secondary : StatsStyle.muted)
                        .help(latency.help)
                        .accessibilityLabel("\(state.label). \(latency.help) \(latency.label)")
                        .accessibilityIdentifier("host-ssh-latency")
                } else {
                    Text(host.id == .local ? "local" : state.label)
                }
            }.font(typography.font(offset: -1.5)).foregroundStyle(StatsStyle.secondary)
                .frame(width: visibleLatency != nil ? typography.expanded(112) : nil, alignment: .trailing)
        }
    }
}

/// Tree headings and the host strip share the same information and actions.
struct HostInformationButton<Label: View>: View {
    @Environment(\.appTypography) private var typography
    let host: HostRecord
    let workspace: Workspace
    let label: Label
    var rowAlignment: VerticalAlignment = .center
    /// Drag the header onto another host header to reorder (tree sidebar only).
    var reorder: ((HostID, Bool) -> Void)?
    @State private var presented = false

    private var reconnectAction: (() -> Void)? {
        guard workspace.hosts.state(host.id) == .disconnected else { return nil }
        let controller = TerminalRuntime.shared.hosts.reconnect
        let surfaces = workspace.hosts.terminals.filter { $0.value.host == host.id }.keys
        guard !surfaces.contains(where: { controller.state(for: $0)?.reconnecting == true }),
              let surface = surfaces.first(where: { controller.state(for: $0) != nil }) else { return nil }
        return {
            presented = false
            controller.reconnect(hostID: host.id, sourceSurfaceID: surface)
        }
    }

    var body: some View {
        HStack(alignment: rowAlignment, spacing: 0) {
            informationButton
            if TerminalRuntime.shared.hosts.canForget(host.id) {
                Button {
                    presented = false
                    TerminalRuntime.shared.hosts.forget(host.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(typography.font(offset: -3)).foregroundStyle(Chrome.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove host and all its cached spaces from the sidebar; keep remote processes running")
                .accessibilityLabel("Remove \(host.name) and its cached spaces from sidebar")
                .accessibilityIdentifier("remove-host-\(host.id.rawValue)")
                .padding(.top, rowAlignment == .top ? 4 : 0)
            }
        }
    }

    private var informationButton: some View {
        Button { presented = true } label: { label }
            .overlay { HostSecondaryClick(identifier: "host-card-" + host.id.rawValue) { presented = true } }
            .overlay {
                if let reorder {
                    LocalReorder(item: .host(host.id), edge: .vertical,
                                 dragLabel: host.id == .local ? "local" : host.name,
                                 select: { presented = true },
                                 accepts: { if case .host = $0 { return true }; return false }) { item, after in
                        if case .host(let dragged) = item { reorder(dragged, after) }
                    }
                }
            }
            // A bottom attachment keeps the card's top fixed as processes expand,
            // while AppKit can still place it above when screen space is limited.
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                if host.id == .local {
                    LocalHostStatsPopover()
                } else {
                    HostInformationView(host: workspace.hosts.record(host.id), state: workspace.hosts.state(host.id),
                        disconnect: TerminalRuntime.shared.hosts.canDisconnect(host.id) ? {
                            presented = false
                            TerminalRuntime.shared.hosts.disconnect(host.id)
                        } : nil,
                        reconnect: reconnectAction,
                        forget: TerminalRuntime.shared.hosts.canForget(host.id) ? {
                            presented = false
                            TerminalRuntime.shared.hosts.forget(host.id)
                        } : nil,
                        preferred: TerminalRuntime.shared.ssh.statisticsConnection(for: workspace.activeSurfaceID),
                        machine: workspace.newSpaceMachine(on: host.id),
                        attachedBackends: Set(workspace.spaces.filter { $0.hostID == host.id && $0.structured }.compactMap { space in
                            space.backend.flatMap { workspace.helper(space)?.multiplexer(of: $0) }.flatMap(SpaceBackend.init(rawValue:))
                        }))
                        .fittedPopoverPresentation()
                }
            }
    }
}

/// Leave primary clicks to SwiftUI, while secondary clicks open the same popover.
struct HostSecondaryClick: NSViewRepresentable {
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> HostSecondaryClickView { HostSecondaryClickView() }
    func updateNSView(_ view: HostSecondaryClickView, context: Context) {
        view.action = action
        view.setAccessibilityIdentifier(identifier)
    }
}

final class HostSecondaryClickView: NSView {
    var action: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
        return super.hitTest(point)
    }
    override func rightMouseDown(with event: NSEvent) { action() }
    override func mouseDown(with event: NSEvent) { action() }
}
