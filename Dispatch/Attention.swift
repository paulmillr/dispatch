import AppKit
import Observation
import Term
@preconcurrency import UserNotifications

enum PaneUrgency: Int, CaseIterable {
    case waiting, unread, running, idle
    var symbol: String {
        switch self { case .waiting: "●"; case .unread: "◆"; case .running: "◐"; case .idle: "·" }
    }

    /// `programs`: the surface's visible OSC 7501 records.
    @MainActor init(session: ChatSession?, programs: [ProgramStatus] = []) {
        let waiting = session?.approvals.contains(where: \.pending) == true || programs.contains { $0.state == .blocked }
        let working = session?.active == true && session?.busy == true || programs.contains { $0.state == .working }
        let unread = session?.hasNewMessages == true || programs.contains(where: \.finished)
        self = waiting ? .waiting : working ? .running : unread ? .unread : .idle
    }
}

struct AttentionEntry: Identifiable {
    let id: UUID
    let title: String
    let path: String
    let urgency: PaneUrgency

    @MainActor
    static func entries(workspace: Workspace, sessions: [UUID: ChatSession], programs: ProgramStatusStore? = nil, automaticNames: Bool = false) -> [Self] {
        var result: [Self] = []
        for space in workspace.presentationSpaces {
            for tab in space.tabs {
                for surface in tab.surfaceIDs {
                    let session = sessions[surface]
                    let urgency = PaneUrgency(session: session, programs: programs?.visible(surface) ?? [])
                    let host = workspace.hosts.record(workspace.hosts.terminals[surface]?.host ?? space.hostID)
                    // Only panes that want attention are shown or announced, so only theirs follow title changes.
                    let shown = urgency == .idle ? tab : workspace.liveTab(tab.id) ?? tab
                    let title = shown.displayLabel(automatic: automaticNames, conversation: session?.active == true ? session?.conversationTitle : nil)
                    let window = space.windows.first { $0.terminals.contains { $0.id == tab.id } }
                    let name = urgency == .idle ? space.name : workspace.liveName(space)
                    let path = ([host.id == .local ? "local" : host.name, name] + [window?.name].compactMap { $0 }).joined(separator: " › ")
                    result.append(Self(id: surface, title: title, path: path, urgency: urgency))
                }
            }
        }
        // Preserve workspace order within a group; background activity must not
        // arbitrarily reshuffle equally urgent panes.
        return result.enumerated().sorted {
            $0.element.urgency == $1.element.urgency ? $0.offset < $1.offset : $0.element.urgency.rawValue < $1.element.urgency.rawValue
        }.map(\.element)
    }
}

/// Attention follows reported session state. Marking a response read never answers or
/// dismisses a live approval, and repeated observations never repeat an alert.
@MainActor @Observable
final class AttentionCoordinator: NSObject, UNUserNotificationCenterDelegate {
    @ObservationIgnored private weak var controller: AppDelegate?
    @ObservationIgnored private var previous: [UUID: String] = [:]
    @ObservationIgnored private var announced: [UUID: [PaneUrgency: String]] = [:]
    @ObservationIgnored private var notificationsEnabled = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    var notificationError: String?

    init(controller: AppDelegate) { self.controller = controller }

    var entries: [AttentionEntry] {
        guard let controller else { return [] }
        return AttentionEntry.entries(workspace: controller.workspace, sessions: TerminalRuntime.shared.chat.sessions,
                                       programs: TerminalRuntime.shared.programs, automaticNames: controller.settings.values.automaticTabNames)
            .filter { $0.urgency == .waiting || $0.urgency == .unread }
    }
    var waitingCount: Int { entries.filter { $0.urgency == .waiting }.count }
    var unreadCount: Int { entries.filter { $0.urgency == .unread }.count }
    var readyResponses: [AttentionEntry] {
        entries.filter { $0.urgency == .unread && eventKey($0) != nil }
    }
    var banner: AttentionEntry? {
        entries.first { $0.urgency == .waiting && $0.id != controller?.workspace.activeSurfaceID }
    }

    func start() {
        guard !started else { return }
        started = true
        generation += 1
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "pane-attention", actions: [
            UNNotificationAction(identifier: "show-pane", title: "Show", options: [.foreground])
        ], intentIdentifiers: [], options: [.customDismissAction])])
        observe()
    }

    func stop() {
        started = false
        notificationsEnabled = false
        generation += 1
        notificationTasks.values.forEach { $0.cancel() }
        notificationTasks.removeAll()
        NSApp.dockTile.badgeLabel = nil
    }

    private func observe() {
        guard started else { return }
        let generation = generation
        withObservationTracking {
            guard let controller else { return }
            let preferences = controller.settings.values
            let rows = entries
            let events = transitions(rows)
            NSApp.dockTile.badgeLabel = preferences.attentionDockBadge && waitingCount > 0 ? String(waitingCount) : nil
            if preferences.attentionNotifications && !notificationsEnabled {
                Task { [weak self] in
                    do {
                        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                        self?.notificationError = allowed ? nil : "Notifications are disabled in macOS System Settings → Notifications → Dispatch."
                    } catch { self?.notificationError = error.localizedDescription }
                }
            }
            notificationsEnabled = preferences.attentionNotifications
            if !notificationsEnabled { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
            for entry in events where !(NSApp.isActive && controller.workspace.isSurfacePresented(entry.id)) {
                if preferences.attentionSound { NSSound(named: "Glass")?.play() }
                if preferences.attentionNotifications { notify(entry) }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.observe()
            }
        }
    }

    /// Unread output includes progress and tool updates; only an ended response
    /// can produce a completion alert. Unknown or disconnected activity cannot.
    private func eventKey(_ row: AttentionEntry) -> String? {
        guard let session = TerminalRuntime.shared.chat.sessions[row.id] else { return nil }
        if row.urgency == .waiting {
            return session.approvals.first(where: \.pending).map { "waiting-" + $0.id.uuidString }
        }
        guard row.urgency == .unread, session.active, !session.busy, !session.inputBlocked,
              !session.loadingHistory, session.activityCheck == nil,
              !session.awaitingPromptAck, session.submissionID == nil, session.interruptionID == nil,
              let turn = session.turns.last, turn.ended != nil,
              session.activeTurnID == nil || session.activeTurnID == turn.id,
              let response = turn.items.last(where: { $0.kind != .notice }),
              response.kind == .assistant, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "response-" + (session.sessionID ?? "") + ":" + turn.id
    }

    /// Keep the last alert per kind across temporary activity changes, so the
    /// same response or approval does not alert again when its row reappears.
    func transitions(_ rows: [AttentionEntry]) -> [AttentionEntry] {
        var current: [UUID: String] = [:]
        var fresh: [AttentionEntry] = []
        for row in rows {
            guard let key = eventKey(row) else { continue }
            current[row.id] = key
            if announced[row.id]?[row.urgency] != key {
                fresh.append(row)
                announced[row.id, default: [:]][row.urgency] = key
            }
        }
        let retired = previous.keys.filter { previous[$0] != current[$0] }
        for id in retired { notificationTasks[id]?.cancel() }
        if started {
            let identifiers = retired.map { "attention-\($0)" }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        previous = current
        let surfaces = Set(controller?.workspace.allSurfaceIDs ?? [])
        announced = announced.filter { surfaces.contains($0.key) }
        notificationTasks = notificationTasks.filter { surfaces.contains($0.key) }
        return fresh
    }

    func navigate(_ delta: Int) {
        let rows = entries.filter { $0.urgency == .waiting } + readyResponses
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == controller?.workspace.activeSurfaceID }
        let next: Int = index.map { (index: Int) -> Int in
            (index + delta % rows.count + rows.count) % rows.count
        } ?? (delta < 0 ? rows.count - 1 : 0)
        let entry = rows[next]
        if entry.urgency == .unread, let request = notificationRequest(for: entry) {
            openNotification(request.content.userInfo)
        } else { focus(entry.id) }
    }

    func focus(_ id: UUID) {
        guard let controller, controller.workspace.allSurfaceIDs.contains(id) else { return }
        controller.workspace.selectSurface(id)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
    }

    /// Native banners choose their own wrapping; keep the excerpt short enough
    /// for roughly two lines, without changing or summarizing the agent's words.
    static func preview(_ text: String) -> String {
        let blocks = ChatMarkdownBlock.parse(String(text.prefix(8192)))
        let plain = blocks.compactMap { block -> String? in
            let source: String
            switch block.kind {
            case .rule: return nil
            case .code: return block.text
            case .table(let rows): source = rows.map { $0.joined(separator: " · ") }.joined(separator: " ")
            default: source = block.text
            }
            let value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return value.map { String($0.characters) } ?? source
        }.joined(separator: " ")
        let compact = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 160 ? String(compact.prefix(159)) + "…" : compact
    }

    func notificationRequest(for entry: AttentionEntry) -> UNNotificationRequest? {
        guard let key = eventKey(entry), let session = TerminalRuntime.shared.chat.sessions[entry.id] else { return nil }
        let content = UNMutableNotificationContent()
        let rowID: String
        if let approval = session.approvals.first(where: \.pending), entry.urgency == .waiting {
            content.title = entry.title + (approval.questions == nil ? " · Permission needed" : " · Question for you")
            content.body = Self.preview(approval.questions?.questions.map(\.text).joined(separator: " ") ?? approval.operation)
            rowID = "approval-\(approval.id)"
        } else {
            guard let turn = session.turns.last,
                  let response = turn.items.last(where: { $0.kind == .assistant }) else { return nil }
            content.title = entry.title + " · Response ready"
            content.body = Self.preview(response.text)
            rowID = response.rowID ?? "\(turn.id.utf8.count):\(turn.id):\(response.id)"
        }
        content.subtitle = entry.path
        content.categoryIdentifier = "pane-attention"
        content.threadIdentifier = "pane-\(entry.id)"
        content.userInfo = ["surface": entry.id.uuidString, "conversation": session.sessionID ?? "", "row": rowID, "event": key]
        return UNNotificationRequest(identifier: "attention-\(entry.id)", content: content, trigger: nil)
    }

    private func isCurrentNotification(_ info: [AnyHashable: Any]) -> Bool {
        guard let raw = info["surface"] as? String, let id = UUID(uuidString: raw),
              let key = info["event"] as? String, let entry = entries.first(where: { $0.id == id }) else { return false }
        return eventKey(entry) == key
    }

    func openNotification(_ info: [AnyHashable: Any]) {
        guard let raw = info["surface"] as? String, let id = UUID(uuidString: raw),
              controller?.workspace.allSurfaceIDs.contains(id) == true else { return }
        let current = isCurrentNotification(info)
        focus(id)
        guard let session = TerminalRuntime.shared.chat.sessions[id],
              info["conversation"] as? String == (session.sessionID ?? ""),
              let rowID = info["row"] as? String,
              session.visibleTranscriptRows.contains(where: { $0.id == rowID }) else { return }
        session.followRevision = nil
        session.atBottom = false
        session.scrollAnchor = rowID
        TerminalRuntime.shared.chat.chooseChat(true, session: session)
        session.scrollPosition.restore(.init(id: rowID, offset: 0))
        session.scrollPosition.realizeAnchor?(rowID)
        if current { session.hasNewMessages = false }
    }

    private func notify(_ entry: AttentionEntry) {
        guard let key = eventKey(entry) else { return }
        let generation = generation
        // Serialize replacements for a pane. If work resumes while add() is
        // pending, retire that alert before a newer request can replace it.
        let predecessor = notificationTasks[entry.id]
        notificationTasks[entry.id] = Task { [weak self] in
            await predecessor?.value
            do {
                try Task.checkCancellation()
                let center = UNUserNotificationCenter.current()
                let allowed = try await center.requestAuthorization(options: [.alert])
                try Task.checkCancellation()
                guard let self, allowed, self.notificationsEnabled, self.generation == generation,
                      let current = self.entries.first(where: { $0.id == entry.id }),
                      self.eventKey(current) == key, let request = self.notificationRequest(for: current) else { return }
                if NSApp.isActive, self.controller?.workspace.isSurfacePresented(entry.id) == true { return }
                try await center.add(request)
                if Task.isCancelled || !self.notificationsEnabled || !self.isCurrentNotification(request.content.userInfo) {
                    center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
                }
            } catch is CancellationError { }
            catch { self?.notificationError = error.localizedDescription }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            let info = Self.notificationInfo(response.notification.request.content)
            Task { @MainActor [weak self] in self?.openNotification(info) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = Self.notificationInfo(notification.request.content)
        return await MainActor.run { [weak self] in
            guard let self, self.notificationsEnabled, self.isCurrentNotification(info) else { return [] }
            if let raw = info["surface"] as? String, let id = UUID(uuidString: raw),
               NSApp.isActive, self.controller?.workspace.isSurfacePresented(id) == true { return [] }
            return [.banner, .list]
        }
    }

    private nonisolated static func notificationInfo(_ content: UNNotificationContent) -> [String: String] {
        ["surface", "conversation", "row", "event"].reduce(into: [:]) { result, key in
            result[key] = content.userInfo[key] as? String
        }
    }
}
