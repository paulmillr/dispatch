import SwiftUI

/// The queue folds to one line: the message that runs next, its actions written out, and how many follow. "+N queued"
/// opens every message as a one-line row; only the row under the pointer (or the keyboard's) shows its actions.
/// Queue motion is scoped to these rows; streamed transcript updates never animate the message stack or its scroll
/// position.
struct ChatQueueView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ChatSession
    let coordinator: ChatCoordinator
    /// The opened list's height; more rows scroll.
    var maximumHeight: CGFloat = 180
    /// Opened with "+N queued", or because the keyboard selected a message the folded bar doesn't show.
    @State private var opened = false
    /// Opened by a selection: it folds again when the selection clears.
    @State private var openedBySelection = false

    private var messages: [ChatQueuedMessage] { session.queuedMessages }
    /// A selection the bar doesn't show opens the list even before `opened` latches (a view mounted with it set).
    private var open: Bool {
        messages.count > 1 && (opened || session.selectedQueuedID.map { $0 != messages.first?.id } ?? false)
    }
    /// The message whose actions show: under the pointer, else the keyboard's.
    private var activeID: UUID? { session.hoveredQueuedID ?? session.selectedQueuedID }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            status
            if open { list } else if let first = messages.first { bar(first) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: messages.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
        .accessibilityIdentifier("chat-queued-messages")
        .onAppear { if open, !opened { opened = true; openedBySelection = true } }
        .onDisappear { session.hoveredQueuedID = nil }
        .onChange(of: messages.map(\.id)) { _, ids in
            if let id = session.hoveredQueuedID, !ids.contains(id) { session.hoveredQueuedID = nil }
            if ids.count < 2 { opened = false; openedBySelection = false }
        }
        .onChange(of: session.selectedQueuedID) { _, id in
            if let id, id != messages.first?.id, !opened { setOpen(true, bySelection: true) }
            else if id == nil, openedBySelection { setOpen(false) }
        }
    }

    private func setOpen(_ open: Bool, bySelection: Bool = false) {
        withAnimation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2)) {
            opened = open; openedBySelection = open && bySelection
        }
        // Folded, only the first message has a row: a selection elsewhere would act on a hidden one.
        if !open, let selected = session.selectedQueuedID, selected != messages.first?.id { session.selectedQueuedID = nil }
    }

    private var rowHeight: CGFloat { max(theme.typography.replyLineHeight, buttonHeight) + 6 }
    private var buttonHeight: CGFloat { theme.typography.detailLineHeight + 8 }

    private func count(_ count: Int) -> String { "\(count) \(theme.radioLog ? "standing by" : "queued")" }

    // MARK: Folded

    private func bar(_ message: ChatQueuedMessage) -> some View {
        let editing = session.editingQueuedID == message.id
        let active = activeID == message.id && !editing
        return HStack(spacing: 10) {
            Text("Next").font(theme.typography.detail).foregroundStyle(theme.muted)
                .padding(.horizontal, 6).frame(height: theme.typography.detailLineHeight + 4)
                .overlay(Capsule().strokeBorder(theme.muted.opacity(0.45)))
                .fixedSize()
            messageText(message, editing: editing, active: active)
                .frame(maxWidth: .infinity, alignment: .leading)
            attachmentCount(message)
            if active { actions(message, index: 0) }
            if messages.count > 1 {
                Rectangle().fill(theme.border).frame(width: 1, height: theme.typography.detailLineHeight + 2)
                toggle
            }
        }
        .padding(.horizontal, 6).frame(minHeight: rowHeight)
        .opacity(rowOpacity(message))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: flown(message) || sending(message))
        .contentShape(Rectangle())
        .onHover { hover(message.id, $0) }
        .onTapGesture { select(message.id) }
        .modifier(QueuedRowAccessibility(message: message, index: 0, editing: editing, session: session, coordinator: coordinator))
    }

    /// "+N queued": opens the list. A message queued while folded flies into it.
    private var toggle: some View {
        Button { setOpen(true) } label: {
            HStack(spacing: 4) {
                Text("+\(count(messages.count - 1))")
                Image(systemName: "chevron.up").font(.system(size: theme.typography.detailSize - 3, weight: .bold))
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .contentShape(Rectangle())
            .background {
                ForEach(messages.dropFirst()) { hidden in
                    ChatFlightAnchor(place: .queued(hidden.id), frames: session.flightFrames, absorbing: true)
                }
            }
        }
        .buttonStyle(.plain).fixedSize()
        .help("Show every queued message")
        .accessibilityLabel("Show all \(messages.count) queued messages")
        .accessibilityIdentifier("chat-queue-toggle")
    }

    // MARK: Opened

    private var list: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(count(messages.count) + (coordinator.canReorderQueue(session) ? " · drag to reorder" : ""))
                    .font(theme.typography.detail).foregroundStyle(theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                Button { setOpen(false) } label: {
                    HStack(spacing: 4) {
                        Text("Collapse")
                        Image(systemName: "chevron.down").font(.system(size: theme.typography.detailSize - 3, weight: .bold))
                    }.font(theme.typography.detail).foregroundStyle(theme.muted).contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Collapse queued messages")
                .accessibilityIdentifier("chat-queue-toggle")
            }
            .padding(.horizontal, 6).frame(height: theme.typography.detailLineHeight + 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            row(message, index: index).id(message.id)
                                .transition(reduceMotion ? .opacity : .asymmetric(
                                    insertion: .offset(y: 8).combined(with: .opacity),
                                    removal: .offset(y: -8).combined(with: .opacity)))
                        }
                    }
                }
                // Rows are one fixed line, so the list's height is known before it lays out: it opens at its size.
                .frame(height: min(maximumHeight, CGFloat(messages.count) * (rowHeight + 1) - 1))
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: session.selectedQueuedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ message: ChatQueuedMessage, index: Int) -> some View {
        let editing = session.editingQueuedID == message.id
        let active = activeID == message.id && !editing
        return HStack(spacing: 8) {
            numberGrip(message, index: index, active: active)
            messageText(message, editing: editing, active: active)
                .frame(maxWidth: .infinity, alignment: .leading)
            attachmentCount(message)
            if active { actions(message, index: index) }
        }
        .padding(.horizontal, 6).frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On glass, a faint highlight like the sidebar's hover rather than an opaque panel inside the glass.
        .background(active ? theme.ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(rowOpacity(message))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: flown(message) || sending(message))
        .contentShape(Rectangle())
        .onHover { hover(message.id, $0) }
        .onTapGesture { select(message.id) }
        // Drop target only (no item): clicks and hover pass through to the row.
        .overlay { reorder(item: nil, target: message.id) }
        .contextMenu { moveButtons(message, index: index) }
        .modifier(QueuedRowAccessibility(message: message, index: index, editing: editing, session: session, coordinator: coordinator))
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if let paused = session.queuePaused {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pause.circle.fill")
                Text(paused).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if messages.first?.pause == .stopped {
                    Button { coordinator.resumeQueue(session) } label: {
                        QueueActionLabel(title: "Resume queue", symbol: "play.fill", height: buttonHeight)
                    }
                    .buttonStyle(.plain).fixedSize()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + theme.typography.detailSize * 0.35 }
                }
            }
            .font(theme.typography.detail).foregroundStyle(theme.yellow)
            .padding(.horizontal, 6).padding(.top, 2)
        } else if session.inputBlocked || session.queueWaiting != nil {
            Text(session.queueWaiting ?? "Waiting for the terminal to be ready…")
                .font(theme.typography.detail).foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6).padding(.top, 2)
        }
    }

    // MARK: Pieces

    private func hover(_ id: UUID, _ inside: Bool) {
        session.hoveredQueuedID = inside ? id : (session.hoveredQueuedID == id ? nil : session.hoveredQueuedID)
    }

    private func select(_ id: UUID) { session.selectedQueuedID = id; session.focusRequest = System.uuid() }

    private func sending(_ message: ChatQueuedMessage) -> Bool { session.queuedSubmissionID == message.id }

    private func rowOpacity(_ message: ChatQueuedMessage) -> Double { flown(message) ? 0 : sending(message) ? 0.55 : 1 }

    /// The row's text: where a message flies to from the composer (hidden until it lands) and from here to its bubble.
    private func messageText(_ message: ChatQueuedMessage, editing: Bool, active: Bool) -> some View {
        Text(editing ? "editing below…" : Self.text(message))
            .font(theme.typography.body).italic(editing)
            .foregroundStyle(editing ? theme.muted.opacity(0.65) : active ? theme.ink : theme.muted)
            .lineLimit(1).truncationMode(.tail)
            .background(ChatFlightAnchor(place: .queued(message.id), frames: session.flightFrames))
            // Hidden at once while a flight carries it (the flight's copy stands exactly in its place); the row around
            // it fades.
            .opacity(session.sendFlight?.to == .queued(message.id) || flown(message) ? 0 : 1)
            .animation(nil, value: flown(message))
    }

    /// A message that flew out of its row to its bubble, still sending: the row leaves no copy behind.
    private func flown(_ message: ChatQueuedMessage) -> Bool {
        session.queuedSubmissionID == message.id && session.flownQueuedIDs.contains(message.id)
    }

    /// What was typed; a message of attachments alone shows their names.
    static func text(_ message: ChatQueuedMessage) -> String {
        message.text.isEmpty && !message.attachments.isEmpty ? message.attachments.map(\.name).joined(separator: ", ") : message.text
    }

    static func spoken(_ message: ChatQueuedMessage) -> String {
        let count = message.attachments.count
        return count == 0 ? message.text : text(message) + (count == 1 ? ", 1 attachment" : ", \(count) attachments")
    }

    /// A paperclip and how many attachments the message carries, their names on hover.
    @ViewBuilder private func attachmentCount(_ message: ChatQueuedMessage) -> some View {
        if !message.attachments.isEmpty {
            HStack(spacing: 2) {
                Image(systemName: "paperclip")
                Text("\(message.attachments.count)").monospacedDigit()
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .fixedSize()
            .help(message.attachments.map(\.name).joined(separator: "\n"))
            .accessibilityHidden(true)
            .accessibilityIdentifier("chat-queue-attachments-\(message.id)")
        }
    }

    /// The row's number is its drag grip: it turns into a handle under the pointer, while the queue can be reordered.
    private func numberGrip(_ message: ChatQueuedMessage, index: Int, active: Bool) -> some View {
        let reorderable = coordinator.canReorderQueue(session)
        return ZStack {
            Text("\(index + 1)").font(theme.typography.detail).monospacedDigit()
                .foregroundStyle(theme.muted.opacity(0.7))
                .opacity(active && reorderable ? 0 : 1)
            Image(systemName: "line.3.horizontal")
                .font(theme.typography.detail).foregroundStyle(theme.muted)
                .opacity(active && reorderable ? 1 : 0)
        }
        .frame(minWidth: theme.typography.detailSize + 4, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay { if reorderable { reorder(item: .queued(message.id), target: message.id) } }
        .help(reorderable ? "Drag to reorder; right-click for Move up or Move down" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reorder queued message")
        .accessibilityIdentifier("chat-queue-drag-\(message.id)")
    }

    /// Local, pasteboard-free reordering, shared with the sidebar's space and host drags.
    private func reorder(item: ReorderItem?, target: UUID) -> some View {
        LocalReorder(item: item, edge: .vertical,
                     dragLabel: messages.first { $0.id == target }.map { String($0.text.prefix(40)) },
                     select: { select(target) },
                     accepts: { item in
            guard case .queued(let id) = item else { return false }
            return id != target && coordinator.canReorderQueue(session)
        }) { item, after in
            guard case .queued(let id) = item else { return }
            let ids = messages.map(\.id)
            guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
            // moveQueued places the message at the target's index after removal.
            var destination = to + (after ? 1 : 0)
            if from < destination { destination -= 1 }
            guard destination != from, ids.indices.contains(destination) else { return }
            coordinator.moveQueued(id, to: ids[destination], in: session, expectedOrder: ids)
        }
    }

    @ViewBuilder private func moveButtons(_ message: ChatQueuedMessage, index: Int) -> some View {
        Button("Move up", systemImage: "arrow.up") { coordinator.moveQueued(message.id, by: -1, in: session) }
            .disabled(index == 0 || !coordinator.canReorderQueue(session))
        Button("Move down", systemImage: "arrow.down") { coordinator.moveQueued(message.id, by: 1, in: session) }
            .disabled(index == messages.count - 1 || !coordinator.canReorderQueue(session))
    }

    /// Send now, Edit and Delete, each written out with its shortcut while the composer would take it.
    private func actions(_ message: ChatQueuedMessage, index: Int) -> some View {
        let shortcuts = session.drafts.shape.isEmpty && !session.drafts.shape.multiline && session.editingQueuedID == nil
        return HStack(spacing: 6) {
            Button { coordinator.sendNow(session, queuedID: message.id) } label: {
                QueueActionLabel(title: "Send now", shortcut: shortcuts ? "⌥⏎" : nil, role: .primary, height: buttonHeight)
            }
            .disabled(steerDisabled(message))
            .help("Steer: interrupt the current turn and send this now")
            .accessibilityLabel("Steer with queued message \(index + 1)")
            Button { coordinator.editQueued(message.id, in: session) } label: {
                QueueActionLabel(title: "Edit", shortcut: shortcuts ? "E" : nil, height: buttonHeight)
            }
            .disabled(editDisabled(message))
            .accessibilityLabel("Edit queued message \(index + 1)")
            Button { coordinator.removeQueued(message.id, from: session) } label: {
                QueueActionLabel(title: "Delete", role: .destructive, height: buttonHeight)
            }
            .help("Delete · ⌘⌫")
            .accessibilityLabel("Discard queued message \(index + 1)")
        }
        .buttonStyle(.plain).fixedSize()
        .disabled(sending(message))
    }

    private func steerDisabled(_ message: ChatQueuedMessage) -> Bool {
        message.pause != nil || !message.matches(session) || message.pending || (session.busy && !message.editable)
    }

    private func editDisabled(_ message: ChatQueuedMessage) -> Bool {
        !session.drafts.shape.isEmpty || session.editingQueuedID != nil || !message.editable || !message.attachments.isEmpty
            || !session.draftUploads.isEmpty
    }
}

/// A queued row's accessibility: its text and every action, whether or not its buttons show.
private struct QueuedRowAccessibility: ViewModifier {
    let message: ChatQueuedMessage
    let index: Int
    let editing: Bool
    let session: ChatSession
    let coordinator: ChatCoordinator

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Queued message \(index + 1): \(editing ? "editing below" : ChatQueueView.spoken(message))")
            .accessibilityAction(named: "Move up") { coordinator.moveQueued(message.id, by: -1, in: session) }
            .accessibilityAction(named: "Move down") { coordinator.moveQueued(message.id, by: 1, in: session) }
            .accessibilityAction(named: "Steer") { coordinator.sendNow(session, queuedID: message.id) }
            .accessibilityAction(named: "Edit") { coordinator.editQueued(message.id, in: session) }
            .accessibilityAction(named: "Discard") { coordinator.removeQueued(message.id, from: session) }
    }
}

/// A labelled queue action: a small capsule, the title and its shortcut in a fainter weight; brighter under the
/// pointer, dimmed when it can't act.
private struct QueueActionLabel: View {
    enum Role { case plain, primary, destructive }
    @Environment(\.chatTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    var shortcut: String? = nil
    var symbol: String? = nil
    var role = Role.plain
    let height: CGFloat
    @State private var hovered = false

    var body: some View {
        let active = hovered && isEnabled
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: theme.typography.detailSize - 2, weight: .semibold)) }
            Text(title)
            if let shortcut {
                Text(shortcut).font(AppFont.shortcut(size: theme.typography.codeDetailSize)).opacity(0.6)
            }
        }
        .font(theme.typography.font(offset: -2, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).frame(height: height)
        .background(background(active), in: Capsule())
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onHover { hovered = $0 }
    }

    private var foreground: Color {
        switch role {
        case .primary: isEnabled ? theme.terminal : theme.muted
        case .destructive: theme.red
        case .plain: theme.ink
        }
    }

    private func background(_ active: Bool) -> Color {
        switch role {
        case .primary: isEnabled ? theme.accent.opacity(active ? 1 : 0.85) : theme.ink.opacity(0.08)
        case .destructive: theme.red.opacity(active ? 0.22 : 0.12)
        case .plain: theme.ink.opacity(active ? 0.14 : 0.08)
        }
    }
}

/// The queue's surface: the floating glass panel, else a bordered panel of the same insets.
struct ChatQueueSurface: ViewModifier {
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active { content.floatingGlassPanel() }
        else { content.padding(.horizontal, 10).padding(.vertical, 6).chatPanel(cornerRadius: 10) }
    }
}
