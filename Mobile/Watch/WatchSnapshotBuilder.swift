import SwiftUI
import UIKit

/// The lists as the phone shows them now, in the watch's terms (docs/watch.md, Pushing the snapshot): the hosts, the
/// Agents rows in the phone's order and every host's spaces and tabs. Reads only observable state of the composition
/// (so `withObservationTracking` around `build` sees every change that matters) plus what the caller passes: the clock
/// and whether protected data is available, which no model observes.
@MainActor
struct WatchSnapshotBuilder {
    let composition: MobileComposition
    /// False between `protectedDataWillBecomeUnavailable` and `DidBecomeAvailable`: the phone is locked. Information
    /// only (`WatchPhone.locked`): passwords read after first unlock, so the lock blocks no host by itself.
    var protectedDataAvailable = true

    func build(at now: Date = Date()) -> WatchSnapshot {
        let hosts = composition.hosts, conversations = composition.conversations
        let phone = WatchPhone(foreground: hosts.active, locked: !protectedDataAvailable, offline: hosts.networkUnavailable,
                               knownHostsUnreadable: hosts.knownHosts.unreadable, needsYou: conversations.needsYouCount)
        // Plain SSH hosts (no helper: no agents, no server spaces, docs/ios.md) are not the watch's.
        let sessions = hosts.ordered.filter { !$0.plainSSH }
        let sameMachine = MobileComposition.sameMachine(sessions)
        return WatchSnapshot(generated: now, phone: phone,
                             hosts: sessions.map { host($0, sameMachine: sameMachine[$0.id]) },
                             conversations: conversations.conversations.map(conversation),
                             spaces: spaces(), tabs: tabs())
    }

    // MARK: Hosts

    func host(_ session: HostSession, sameMachine: String?) -> WatchHost {
        let record = session.host, summary = HostSummary(session: session)
        var problem = session.problem
        if case .failed(let reason) = session.link { problem = reason }
        return WatchHost(id: record.id.uuidString, name: record.name, order: record.order,
                         state: WatchHostState(SpacesHostState(session.link)),
                         tint: summary.offline ? nil : Self.tint(record.tint),
                         system: record.system.map { $0.os == "Darwin" ? "macos" : "linux" }, osLabel: summary.osLabel,
                         problem: problem.map { Self.redact($0, host: record) }, blocked: blocked(session), chat: record.chat,
                         live: session.topologyIsLive && !session.switchingMultiplexer, multiplexer: session.spacesMultiplexer,
                         sameMachine: sameMachine, lastConnected: record.lastConnected)
    }

    /// A text bound for the watch with the host's address, port and user (which the phone's connection failures name:
    /// "studio.local refused the connection on port 2222") replaced by its display name: nothing that reaches a host
    /// crosses to the watch (docs/security.md, Apple Watch).
    static func redact(_ text: String, host record: HostRecord) -> String {
        var text = text
        let address = record.address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return text }
        let forms = [record.user.isEmpty ? nil : record.user + "@" + address, "[" + address + "]:\(record.port)",
                     address + ":\(record.port)", address].compactMap { $0 }
        for form in forms {
            // Whole names only: an address "pi" leaves "pipe" alone.
            let pattern = "(?<![\\w.-])" + NSRegularExpression.escapedPattern(for: form) + "(?![\\w-])"
            text = text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: record.name),
                                             options: [.regularExpression, .caseInsensitive])
        }
        return text.replacingOccurrences(of: "port \(record.port)", with: "its SSH port")
    }

    /// Why only the phone's screen can connect a host that is not connected, most pressing first: a changed host key, a
    /// host key to trust, a login question, then a key behind Face ID while the phone is not in the foreground (or a
    /// quiet attempt that met any of these). Never `phoneLocked` (reserved): a locked phone still logs in with a
    /// password, and a Face ID key is `faceID` either way.
    func blocked(_ session: HostSession) -> WatchHostBlock? {
        guard session.link != .connected else { return nil }
        let hosts = composition.hosts, id = session.id
        let quiet = hosts.quietRefusals[id]
        let trust = hosts.trustRequests.filter { $0.hostID == id }
        if session.hostKeyMismatch != nil || trust.contains(where: { $0.kind != .unknown }) { return .hostKeyChanged }
        if quiet == .hostKey || !trust.isEmpty { return .trustHostKey }
        if quiet == .login || hosts.loginPrompts.contains(where: { $0.hostID == id }) { return .login }
        if quiet == .faceID || session.link == .failed(SecretVaultError.interactionNotAllowed.localizedDescription) { return .faceID }
        if !hosts.active, needsFaceID(session.host) { return .faceID }
        return nil
    }

    /// The host logs in with a key that cannot be used without a prompt: a Secure Enclave key, or a key stored behind
    /// biometry (`KeyStore.keyProtection`).
    func needsFaceID(_ record: HostRecord) -> Bool {
        guard case .key(let id) = record.auth, let key = composition.hosts.keys.key(id) else { return false }
        if case .secureEnclaveP256 = key.kind { return true }
        return composition.hosts.keys.keyProtection == .biometry
    }

    /// `HostSummary.tint` of a host that is not offline, as the phone draws it in the dark appearance
    /// (`HostTint.color` with the dark tone), in sRGB.
    static func tint(_ tint: HostTint) -> String {
        let tone = HostTint.Tone.darkColor
        let color = HostTint.oklch(tone.lightness, HostColorStore.shared.enabled ? tone.chroma : 0, (tint.choice ?? tint.automatic).hue)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return WatchTint.hex(red: red, green: green, blue: blue)
    }

    // MARK: Agents

    func conversation(_ row: ChatConversation) -> WatchConversation {
        let summary = row.summary
        return WatchConversation(
            host: row.key.host.uuidString, node: row.key.node, name: row.name, space: row.space,
            tab: composition.tab(for: row.key)?.key, agent: agent(row.key, binding: row.binding),
            preview: summary.preview.map(WatchText.preview), attention: summary.attention, dot: row.dot.map(WatchDot.init),
            needsYou: summary.needsYou, busy: summary.busy, muted: row.muted, lastActivity: summary.lastActivity, stale: row.stale)
    }

    /// The agent's key once its thread named it (`MobileChatSession.agentKey`), else the bound executable's file name.
    func agent(_ key: ChatConversationKey, binding: HelperTopology.Binding?) -> String? {
        if let known = composition.conversations.sessions[key]?.agentKey { return known }
        guard let executable = binding?.executable, !executable.isEmpty else { return nil }
        return (executable as NSString).lastPathComponent
    }

    // MARK: Spaces

    /// The workspaces shown: a host that names an earlier one's machine (`sameMachine`) shows its spaces there, and a plain
    /// SSH host's Shell space stays on the phone.
    private var workspaces: [MobileWorkspace] {
        let plain = Set(composition.hosts.ordered.filter(\.plainSSH).map(\.id))
        return composition.tabs.workspaces.filter { $0.host.sameMachine == nil && !plain.contains($0.id) }
    }

    /// Every host's spaces in the phone's order (`MobileTabs.orderedSpaces`), unfiltered: Spaces' filter is the phone's
    /// view, not the watch's.
    func spaces() -> [WatchSpace] {
        let model = composition.tabs
        return workspaces.flatMap { workspace in
            // A helper host's leftover Shell space (ended shell cards) stays on the phone too.
            model.orderedSpaces(workspace).filter { $0.kind != .plainShell }.map { space in
                let urgencies = space.tabs.compactMap { model.urgency(of: $0) }
                return WatchSpace(host: workspace.id.uuidString, key: space.ref.key, name: space.name,
                                  folder: workspace.host.abbreviate(space.cwd), unread: urgencies.filter(\.unread).count,
                                  working: urgencies.contains(.working), activity: model.activity(of: space))
            }
        }
    }

    /// Each space's tabs in server order (`MobileSpace.tabs`), spaces as `spaces()` orders them.
    func tabs() -> [WatchTab] {
        let model = composition.tabs
        return workspaces.flatMap { workspace in
            model.orderedSpaces(workspace).flatMap { space in
                space.tabs.map { tab in
                    let label = model.label(of: tab, host: workspace.host)
                    let pane = tab.agentPane
                    return WatchTab(host: workspace.id.uuidString, space: space.ref.key, key: tab.ref.key, name: label,
                                    program: tab.program, folder: workspace.host.abbreviate(tab.cwd), chat: tab.isChat,
                                    agent: pane.flatMap { agent(ChatConversationKey(host: workspace.id, node: $0.key), binding: $0.agent) },
                                    conversation: pane?.key, urgency: model.urgency(of: tab).map(WatchUrgency.init),
                                    status: TabsTabRow.line(tab, label: label, status: model.status), activity: model.activity(of: tab))
                }
            }
        }
    }
}

extension WatchHostState {
    init(_ state: SpacesHostState) {
        switch state {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .offline: self = .offline
        }
    }
}

extension WatchDot {
    init(_ dot: MobileRowDot) {
        switch dot {
        case .working: self = .working
        case .unread: self = .unread
        }
    }
}

extension WatchUrgency {
    init(_ urgency: TabUrgency) {
        switch urgency {
        case .unseen: self = .unseen
        case .working: self = .working
        case .needsYou: self = .needsYou
        }
    }
}
