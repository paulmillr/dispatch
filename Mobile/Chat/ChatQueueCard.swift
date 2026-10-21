import SwiftUI

/// The queue (M5c): while the agent works, sent messages stack on the user's side under the thinking row. Collapsed it
/// is one line, "Queued · 3"; tapped it opens to inset rows: tap one to edit it in place, swipe it left to delete,
/// drag ≡ to reorder, long-press to send it now (interrupting the turn). Done folds it back.
struct ChatQueueCard: View {
    let session: MobileChatSession
    @Binding var expanded: Bool
    @State private var editing: String?
    @State private var text = ""
    @State private var dragging: String?
    @State private var dragOffset: CGFloat = 0
    @State private var swiped: String?
    @FocusState private var focused: Bool
    @Environment(\.chatColumnWidth) private var column
    @Environment(\.dynamicTypeSize) private var typeSize
    private static let rowHeight: CGFloat = 52

    var body: some View {
        let rows = session.queueRows
        let held = session.phase != .verified
        VStack(alignment: .trailing, spacing: 6) {
            if expanded {
                VStack(spacing: 0) {
                    header(rows.count, held: held)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index, count: rows.count, held: held)
                        if index < rows.count - 1 { Rectangle().fill(Color.hairline).frame(height: 0.5) }
                    }
                }
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.dispatchPink.opacity(0.35), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(width: column * 0.92)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button { expanded = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Queued · \(rows.count)").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                        Text(subtitle(held: held)).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the queued messages")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.top, 4)
        .onChange(of: rows.map(\.id)) { _, ids in
            if let editing, !ids.contains(editing) { self.editing = nil }
            if ids.isEmpty { expanded = false }
        }
    }

    /// Resume and Done: footnote pink text in a 44 point target (the header is 36 points; the target overhangs it).
    private static func headerButton(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(Color.dispatchPink)
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func subtitle(held: Bool) -> String {
        held ? "held until \(session.hostName) is back" : session.queueStopped ? "paused after Stop" : "sends after this turn"
    }

    private func header(_ count: Int, held: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Queued · \(count)").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle(held: held)).font(.caption).foregroundStyle(.tertiary).lineLimit(typeSize > .large ? nil : 2)
            Spacer(minLength: 4)
            if session.queueStopped && !held {
                Button { session.resumeQueue() } label: { Self.headerButton("Resume") }
                    .padding(.vertical, -6)
            }
            Button { commit(); expanded = false } label: { Self.headerButton("Done") }
                .accessibilityHint("Folds the queue")
                .padding(.vertical, -6)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 0.5) }
    }

    @ViewBuilder
    private func rowView(_ row: MobileChatSession.QueueRow, index: Int, count: Int, held: Bool) -> some View {
        let isEditing = editing == row.id
        ZStack(alignment: .trailing) {
            if swiped == row.id {
                Button(role: .destructive) { swiped = nil; session.removeQueued(row) } label: {
                    Text("Delete").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 84).frame(maxHeight: .infinity)
                        .background(Color.red)
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if isEditing {
                        TextField("", text: $text, axis: .vertical)
                            .font(.subheadline)
                            .tint(Color.dispatchPink)
                            .focused($focused)
                            .onSubmit(commit)
                    } else {
                        Text(row.text).font(.subheadline).lineSpacing(1).lineLimit(typeSize > .large ? 6 : 2)
                    }
                    if let status = row.status {
                        Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in dragging = row.id; dragOffset = value.translation.height }
                        .onEnded { value in
                            let target = max(0, min(count - 1, index + Int((value.translation.height / Self.rowHeight).rounded())))
                            dragging = nil; dragOffset = 0
                            if target != index { session.moveQueued(from: index, to: target) }
                        })
                    .accessibilityHidden(true)
                    .disabled(held)
            }
            .padding(.vertical, 10)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(minHeight: Self.rowHeight)
            .background(isEditing ? Color.dispatchPink.opacity(0.08) : Color.groupedRow)
            .contentShape(Rectangle())
            .offset(x: swiped == row.id ? -84 : 0)
            .onTapGesture { edit(row, held: held) }
            .onLongPressGesture { if !held, session.canSendNow(row) { session.sendQueuedNow(row) } }
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.width < -40, abs(value.translation.height) < 30 { swiped = row.id }
                else if value.translation.width > 20 { swiped = nil }
            })
            .contextMenu {
                if row.status != nil, case .device = row.source {
                    Button("Send", systemImage: "paperplane") { session.resendQueued(row) }
                }
                if !held, session.canSendNow(row) {
                    Button("Send now", systemImage: "arrow.up.circle") { session.sendQueuedNow(row) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { session.removeQueued(row) }
            }
            .modifier(QueueRowAccessibility(row: row, editing: isEditing, edit: { edit(row, held: held) },
                                            sendNow: held || !session.canSendNow(row) ? nil : { session.sendQueuedNow(row) },
                                            moveUp: held || index == 0 ? nil : { session.moveQueued(from: index, to: index - 1) },
                                            moveDown: held || index == count - 1 ? nil : { session.moveQueued(from: index, to: index + 1) },
                                            delete: { session.removeQueued(row) }))
        }
        .offset(y: dragging == row.id ? dragOffset : 0)
        .zIndex(dragging == row.id ? 1 : 0)
        .clipped()
    }

    private func edit(_ row: MobileChatSession.QueueRow, held: Bool) {
        guard row.editable, !held || row.status != nil else { return }
        commit()
        editing = row.id; text = row.text; focused = true
    }

    private func commit() {
        guard let editing, let row = session.queueRows.first(where: { $0.id == editing }) else { self.editing = nil; return }
        if text != row.text { session.editQueued(row, text: text) }
        self.editing = nil
        focused = false
    }
}

/// One button for VoiceOver: the message and its status; a tap edits it, the gestures (send now, reorder, swipe to
/// delete) are its actions. While it is being edited its field is the element.
private struct QueueRowAccessibility: ViewModifier {
    let row: MobileChatSession.QueueRow
    let editing: Bool
    let edit: () -> Void
    let sendNow: (() -> Void)?
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?
    let delete: () -> Void

    func body(content: Content) -> some View {
        if editing {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ChatQueueCard.accessibilityLabel(row))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(row.editable ? "Edits the message" : "")
                .accessibilityAction { edit() }
                .accessibilityActions {
                    if let sendNow { Button("Send now", action: sendNow) }
                    if let moveUp { Button("Move up", action: moveUp) }
                    if let moveDown { Button("Move down", action: moveDown) }
                    Button("Delete", action: delete)
                }
        }
    }
}

extension ChatQueueCard {
    /// "Run the migration, paused after Stop": the message, then its status.
    static func accessibilityLabel(_ row: MobileChatSession.QueueRow) -> String {
        [row.text, row.status].compactMap { $0 }.joined(separator: ", ")
    }
}

/// M4c: while the link is down, queued messages show as faded bubbles on the user's side with a caption.
struct ChatQueuedBubbles: View {
    let session: MobileChatSession

    var body: some View {
        let rows = session.queueRows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            VStack(spacing: 5) {
                ChatBubble(side: .user, faded: true) { Text(row.text) }
                    .contextMenu {
                        if row.status != nil { Button("Send", systemImage: "paperplane") { session.resendQueued(row) } }
                        if case .device = row.source { Button("Edit", systemImage: "pencil") { session.editInComposer(row) } }
                        Button("Discard", systemImage: "trash", role: .destructive) { session.removeQueued(row) }
                    }
                if let status = row.status {
                    ChatCaption(text: status, trailing: true)
                } else if index == rows.count - 1 {
                    ChatCaption(text: "Queued · sends when \(session.hostName) is back", trailing: true)
                }
            }
        }
    }
}
