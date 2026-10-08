import SwiftUI

/// Queue motion is scoped to these rows; streamed transcript updates never
/// animate the message stack or its scroll position.
struct ChatQueueView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ChatSession
    let coordinator: ChatCoordinator
    var maximumHeight: CGFloat = 180
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let maximumHeight = glass ? min(maximumHeight, glassHeightCap) : maximumHeight
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if glass {
                        // One column: a small header over plain rows, so the queue reads as part of the composer.
                        VStack(alignment: .leading, spacing: 2) {
                            glassHeader
                            messages
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                summary.fixedSize(horizontal: true, vertical: true)
                                Spacer(minLength: 0)
                                messages.frame(minWidth: 260, maxWidth: 540)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                summary
                                messages.frame(maxWidth: 540)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }.padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: QueueContentHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(maximumHeight, contentHeight > 0 ? contentHeight : maximumHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(QueueContentHeight.self) { contentHeight = $0 }
            .onChange(of: session.selectedQueuedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: session.queuedMessages.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
        .accessibilityIdentifier("chat-queued-messages")
        .onDisappear { session.hoveredQueuedID = nil }
        .onChange(of: session.queuedMessages.map(\.id)) { _, ids in
            if let id = session.hoveredQueuedID, !ids.contains(id) { session.hoveredQueuedID = nil }
        }
    }

    /// Liquid Glass: rows are single lines (the selected one opens to three) under a one-line header.
    private var glass: Bool { LiquidGlassStore.shared.active }
    /// About four one-line rows below the header; more scroll.
    private var glassHeightCap: CGFloat {
        theme.typography.detailLineHeight + 6 + 4 * (theme.typography.replyLineHeight + 10)
    }

    private var glassHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(session.queuedMessages.count) queued")
                .font(theme.typography.detail).foregroundStyle(theme.muted).fixedSize()
            status
        }.padding(.horizontal, 8).padding(.bottom, 2)
    }

    private var title: some View {
        Text("\(session.queuedMessages.count) \(session.queuedMessages.count == 1 ? "message" : "messages") queued")
            .font(theme.typography.detail)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(theme.muted)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            status
        }
    }

    private var messages: some View {
        VStack(spacing: glass ? 2 : 6) {
            ForEach(Array(session.queuedMessages.enumerated()), id: \.element.id) { index, message in
                row(message, index: index).id(message.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 8).combined(with: .opacity),
                        removal: .offset(y: -8).combined(with: .opacity)))
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let paused = session.queuePaused {
            VStack(alignment: .leading, spacing: 4) {
                Text(paused).fixedSize(horizontal: false, vertical: true)
                if session.queuedMessages.first?.pause == .stopped {
                    Button("Resume queue") { coordinator.resumeQueue(session) }
                }
            }.font(theme.typography.detail).foregroundStyle(theme.yellow)
        } else if session.inputBlocked || session.queueWaiting != nil {
            Text(session.queueWaiting ?? "Waiting for the terminal to be ready…")
                .font(theme.typography.detail).foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ message: ChatQueuedMessage, index: Int) -> some View {
        let selected = (session.hoveredQueuedID ?? session.selectedQueuedID) == message.id
        let editing = session.editingQueuedID == message.id
        let sending = session.queuedSubmissionID == message.id
        return rowContent(message, index: index, selected: selected, editing: editing)
        .padding(.horizontal, 8).padding(.vertical, glass ? 4 : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // On glass, a faint highlight like the sidebar's hover rather than an opaque panel inside the glass.
        .background(selected ? (glass ? theme.ink.opacity(0.06) : theme.sidebar) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .opacity(sending ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { session.hoveredQueuedID = $0 ? message.id : (session.hoveredQueuedID == message.id ? nil : session.hoveredQueuedID) }
        .onTapGesture { session.selectedQueuedID = message.id; session.focusRequest = UUID() }
        // Drop target only (no item): clicks and hover pass through to the row.
        .overlay { reorder(item: nil, target: message.id) }
        .contextMenu { moveButtons(message, index: index) }
        .accessibilityAction(named: "Move up") { coordinator.moveQueued(message.id, by: -1, in: session) }
        .accessibilityAction(named: "Move down") { coordinator.moveQueued(message.id, by: 1, in: session) }
        .accessibilityAction(named: "Steer") { coordinator.sendNow(session, queuedID: message.id) }
        .accessibilityAction(named: "Edit") { coordinator.editQueued(message.id, in: session) }
        .accessibilityAction(named: "Discard") { coordinator.removeQueued(message.id, from: session) }
    }

    @ViewBuilder private func rowContent(_ message: ChatQueuedMessage, index: Int, selected: Bool, editing: Bool) -> some View {
        if glass {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                dragHandle(message)
                Text("\(index + 1)")
                    .font(theme.typography.detail).monospacedDigit()
                    .foregroundStyle(theme.muted.opacity(0.7))
                    .fixedSize()
                Text(editing ? "editing below…" : message.text)
                    .font(theme.typography.body).italic(editing)
                    .foregroundStyle(editing ? theme.muted.opacity(0.65) : selected ? theme.ink : theme.muted)
                    .lineLimit(selected && !editing ? 3 : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Reserved while hidden, so hover never changes the text's width.
                glassActions(message, index: index)
                    .opacity(selected && !editing ? 1 : 0)
                    .allowsHitTesting(selected && !editing)
                    .accessibilityHidden(!selected || editing)
                    .disabled(!selected || editing)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Queued message \(index + 1): \(editing ? "editing below" : message.text)")
        } else {
            let controls = actions(message, index: index)
                .opacity(selected && !editing ? 1 : 0)
                .allowsHitTesting(selected && !editing)
                .accessibilityHidden(!selected || editing)
                .disabled(!selected || editing)
            // Reserve the controls' space in both layouts: hover only changes
            // visibility, never the message width or the queue's scroll geometry.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    controls.fixedSize()
                    bubble(message, index: index, selected: selected, editing: editing)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    bubble(message, index: index, selected: selected, editing: editing)
                    controls
                }
            }
        }
    }

    private func bubble(_ message: ChatQueuedMessage, index: Int, selected: Bool, editing: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            dragHandle(message)
            Text("\(index + 1)")
                .font(theme.typography.detail).monospacedDigit()
                .foregroundStyle(theme.muted.opacity(0.7))
                .fixedSize()
            Text(editing ? "editing below…" : message.text)
                .font(theme.typography.body).italic(editing)
                .foregroundStyle(editing ? theme.muted.opacity(0.65) : selected ? theme.ink : theme.muted)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10)
                .strokeBorder(selected && !editing ? theme.muted.opacity(0.6) : theme.border,
                              style: StrokeStyle(lineWidth: 1, dash: selected && !editing ? [] : [4, 3]))
        }
        .accessibilityLabel("Queued message \(index + 1): \(editing ? "editing below" : message.text)")
    }

    @ViewBuilder private func dragHandle(_ message: ChatQueuedMessage) -> some View {
        let handle = Image(systemName: "line.3.horizontal")
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            .padding(.vertical, 4).contentShape(Rectangle())
            .accessibilityLabel("Reorder queued message")
            .accessibilityIdentifier("chat-queue-drag-\(message.id)")
        if coordinator.canReorderQueue(session) {
            handle.overlay { reorder(item: .queued(message.id), target: message.id) }
                .help("Drag to reorder; right-click for Move up or Move down")
        } else { handle.opacity(0.3) }
    }

    /// Local, pasteboard-free reordering, shared with the sidebar's space and host drags.
    private func reorder(item: ReorderItem?, target: UUID) -> some View {
        LocalReorder(item: item, edge: .vertical,
                     dragLabel: session.queuedMessages.first { $0.id == target }.map { String($0.text.prefix(40)) },
                     select: { session.selectedQueuedID = target; session.focusRequest = UUID() },
                     accepts: { item in
            guard case .queued(let id) = item else { return false }
            return id != target && coordinator.canReorderQueue(session)
        }) { item, after in
            guard case .queued(let id) = item else { return }
            let ids = session.queuedMessages.map(\.id)
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
            .disabled(index == session.queuedMessages.count - 1 || !coordinator.canReorderQueue(session))
    }

    private func actions(_ message: ChatQueuedMessage, index: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { actionButtons(message, index: index) }
            VStack(alignment: .leading, spacing: 6) { actionButtons(message, index: index) }
        }.font(theme.typography.detail).buttonStyle(.plain)
            .disabled(actionsDisabled(message))
    }

    /// Glass: icons with their shortcuts in tooltips instead of text links.
    private func glassActions(_ message: ChatQueuedMessage, index: Int) -> some View {
        HStack(spacing: 2) {
            QueueIconButton(symbol: "arrow.up", help: "Steer: send now · ⌥⏎") { coordinator.sendNow(session, queuedID: message.id) }
                .disabled(steerDisabled(message))
                .accessibilityLabel("Steer with queued message \(index + 1)")
            QueueIconButton(symbol: "pencil", help: "Edit · e") { coordinator.editQueued(message.id, in: session) }
                .disabled(editDisabled(message))
                .accessibilityLabel("Edit queued message \(index + 1)")
            QueueIconButton(symbol: "xmark", help: "Delete · ⌘⌫", destructive: true) { coordinator.removeQueued(message.id, from: session) }
                .accessibilityLabel("Discard queued message \(index + 1)")
        }
        .fixedSize().buttonStyle(.plain)
        .disabled(actionsDisabled(message))
        // Center the icons on the first line's text rather than resting them on its baseline.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + theme.typography.detailSize * 0.4 }
    }

    private func actionsDisabled(_ message: ChatQueuedMessage) -> Bool {
        session.queuedSubmissionID == message.id
    }

    private func steerDisabled(_ message: ChatQueuedMessage) -> Bool {
        message.pause != nil || !message.matches(session) || message.pending || (session.busy && !message.editable)
    }

    private func editDisabled(_ message: ChatQueuedMessage) -> Bool {
        !session.drafts.shape.isEmpty || session.editingQueuedID != nil || !message.editable
    }

    @ViewBuilder private func actionButtons(_ message: ChatQueuedMessage, index: Int) -> some View {
        let shortcuts = (session.hoveredQueuedID ?? session.selectedQueuedID) == message.id && session.drafts.shape.isEmpty
            && !session.drafts.shape.multiline && session.editingQueuedID == nil
        Button { coordinator.sendNow(session, queuedID: message.id) } label: {
            actionLabel("send now", shortcut: "⌥⏎", showShortcut: shortcuts)
        }
            .disabled(steerDisabled(message))
            .accessibilityLabel("Steer with queued message \(index + 1)")
        Button { coordinator.editQueued(message.id, in: session) } label: {
            actionLabel("edit", shortcut: "e", showShortcut: shortcuts)
        }
            .disabled(editDisabled(message))
            .accessibilityLabel("Edit queued message \(index + 1)")
        Button { coordinator.removeQueued(message.id, from: session) } label: {
            actionLabel("delete", shortcut: "⌘⌫", showShortcut: shortcuts)
        }
            .foregroundStyle(theme.red).accessibilityLabel("Discard queued message \(index + 1)")
    }

    private func actionLabel(_ title: String, shortcut: String, showShortcut: Bool) -> some View {
        QueueActionLabel(title: title, shortcut: shortcut, showShortcut: showShortcut)
    }
}

/// Underlines only the action under the pointer, and only when it can act.
private struct QueueActionLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let shortcut: String
    let showShortcut: Bool
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            Text("\(title) \(shortcut)").hidden().accessibilityHidden(true)
            (Text(title).underline(hovered && isEnabled) + Text(showShortcut ? " \(shortcut)" : ""))
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// A queued message's glass-mode action: a muted icon that brightens under the pointer (red for delete).
private struct QueueIconButton: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let active = hovered && isEnabled
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: theme.typography.detailSize, weight: .medium))
                .foregroundStyle(active ? (destructive ? theme.red : theme.ink) : theme.muted.opacity(isEnabled ? 1 : 0.4))
                .frame(width: theme.typography.replyLineHeight + 4, height: theme.typography.replyLineHeight + 4)
                .background(active ? theme.ink.opacity(0.08) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct QueueContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
