import SwiftUI

/// The queue (M5c): while the agent works, sent messages stack on the user's side under the thinking row. Collapsed it
/// is one line, "Queued · 3"; tapped it opens to inset rows: tap one to edit it in place, tap its ↑ (or long-press for
/// its menu) to send it now (interrupting the turn), swipe it left to delete, drag ≡ to reorder. Done folds it back.
/// Under the working row (`inRow`, Q1) the row's capsule is the folded queue: there is no line, and the card opens from
/// the capsule above it.
struct ChatQueueCard: View {
    let session: MobileChatSession
    @Binding var expanded: Bool
    var inRow = false
    @State private var editing: String?
    @State private var text = ""
    @State private var dragging: String?
    @State private var dragOffset: CGFloat = 0
    /// Where the row being dragged would land: the rows between move aside for it, and each step ticks.
    @State private var dragTarget: Int?
    /// The rows' ids as last drawn: a change to the same rows is a reorder, which slides (`body`).
    @State private var laidOut: [String] = []
    @State private var swiped: String?
    @FocusState private var focused: Bool
    @Environment(\.chatColumnWidth) private var column
    @Environment(\.chatMeasure) private var measure
    @Environment(\.dynamicTypeSize) private var typeSize
    @ReduceMotion private var reduceMotion
    private static let rowHeight: CGFloat = 52

    /// The card opening, rows moving (a reorder, the drag) and the swipe's Delete; nil with Reduce Motion.
    private var motion: Animation? { reduceMotion ? nil : .snappy(duration: 0.28) }

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
                .frame(width: ChatMeasure.queueCard(column: column, measure: measure))
                .frame(maxWidth: .infinity, alignment: .trailing)
                // Rows reordered here, from another device or the helper's answer, slide to their places. Rows coming and
                // going change the card's height, which the thread around it lays out at once: animated, the card drew
                // over the composer while it shrank, so those land at once.
                .transaction(value: rows.map(\.id)) { [laidOut] transaction in
                    transaction.animation = Set(rows.map(\.id)) == Set(laidOut) ? motion : nil
                }
                // Opened, the thread lays out at once and follows its end; the card fades in growing from its line. An
                // animated layout drew it over the composer while the scroll caught up.
                .transition(.asymmetric(insertion: reduceMotion ? .opacity.animation(.easeOut(duration: 0.15))
                                            : .opacity.combined(with: .scale(scale: 0.96, anchor: inRow ? .topTrailing : .bottomTrailing))
                                                .animation(motion),
                                        removal: .identity))
            } else if !inRow {
                Button { expanded = true } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        count(rows.count)
                        Text(subtitle(held: held)).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the queued messages")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15)), removal: .identity))
            }
        }
        .padding(.top, inRow && !expanded ? 0 : 4)
        .onAppear { laidOut = rows.map(\.id) }
        .sensoryFeedback(trigger: dragTarget) { old, new in
            // A light tap as a row lifts, a tick for each place it passes.
            switch (old, new) {
            case (nil, _?): .impact(weight: .light)
            case (_?, _?): .selection
            default: nil
            }
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            laidOut = ids
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

    /// "Queued · 3", its number rolling as messages come and go.
    private func count(_ count: Int) -> some View {
        Text("Queued · \(count)").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
            .animation(.snappy(duration: 0.25), value: count)
    }

    /// The row being dragged's landing place, by how far it is dragged in rows.
    private func target(from index: Int, count: Int) -> Int {
        max(0, min(count - 1, index + Int((dragOffset / Self.rowHeight).rounded())))
    }

    /// How far the row at `index` moves aside for the one being dragged (`dragTarget`): a row's height up or down for
    /// those it passed, so the gap shows where it will land.
    private func aside(_ index: Int) -> CGFloat {
        guard let dragging, let from = session.queueRows.firstIndex(where: { $0.id == dragging }), let to = dragTarget,
              index != from else { return 0 }
        if from < index, index <= to { return -Self.rowHeight }
        if to <= index, index < from { return Self.rowHeight }
        return 0
    }

    private func header(_ count: Int, held: Bool) -> some View {
        HStack(spacing: 8) {
            self.count(count)
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
                    } else if !row.text.isEmpty {
                        Text(row.text).font(.subheadline).lineSpacing(1).lineLimit(typeSize > .large ? 6 : 2)
                    }
                    if !row.attachments.isEmpty, !isEditing {
                        ChatQueuedAttachments(attachments: row.attachments, host: session.key.host,
                                              read: { [session] in try await session.attachmentBytes($0) })
                    }
                    if let status = row.status {
                        Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Send now, in sight: a long press also opens the row's menu, which has it too.
                if !isEditing, !held, session.canSendNow(row) {
                    Button { session.sendQueuedNow(row) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.dispatchPink)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            dragging = row.id; dragOffset = value.translation.height
                            let target = target(from: index, count: count)
                            if dragTarget != target { withAnimation(motion) { dragTarget = target } }
                        }
                        .onEnded { value in
                            dragOffset = value.translation.height
                            let target = target(from: index, count: count)
                            // The row settles from under the finger into its place, the others from aside into theirs.
                            withAnimation(motion) {
                                dragging = nil; dragOffset = 0; dragTarget = nil
                                if target != index { session.moveQueued(from: index, to: target) }
                            }
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
            .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.width < -40, abs(value.translation.height) < 30 { withAnimation(motion) { swiped = row.id } }
                else if value.translation.width > 20 { withAnimation(motion) { swiped = nil } }
            })
            .contextMenu {
                if session.canResend(row) {
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
        // Clipped to its place for the swipe's Delete, before the drag moves it out of it.
        .clipped()
        .offset(y: dragging == row.id ? dragOffset : aside(index))
        .zIndex(dragging == row.id ? 1 : 0)
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
    /// "Run the migration, paused after Stop": the message, its attachments, then its status.
    static func accessibilityLabel(_ row: MobileChatSession.QueueRow) -> String {
        [row.text.isEmpty ? nil : row.text, row.attachments.isEmpty ? nil : ChatAttachmentSummary.text(row.attachments),
         row.status].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A queue row's attachments: small thumbnails, then how many files.
private struct ChatQueuedAttachments: View {
    let attachments: [ChatAttachment]
    var host: UUID?
    var read: (@MainActor (String) async throws -> Data?)?

    var body: some View {
        let images = attachments.filter { $0.kind == .image }
        let files = attachments.count - images.count
        HStack(spacing: 4) {
            ForEach(images.prefix(6)) { ChatAttachmentTile(attachment: $0, host: host, read: read, side: 28, corner: 6) }
            if files > 0 {
                Label(files == 1 ? "1 file" : "\(files) files", systemImage: "doc").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// M4c: while the link is down, queued messages show as faded bubbles on the user's side with a caption.
struct ChatQueuedBubbles: View {
    let session: MobileChatSession
    @ReduceMotion private var reduceMotion

    var body: some View {
        let rows = session.queueRows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            VStack(spacing: 5) {
                ChatUserMessage(text: row.text, attachments: row.attachments, host: session.key.host,
                                read: { [session] in try await session.attachmentBytes($0) }, faded: true)
                    .contextMenu {
                        if session.canResend(row) { Button("Send", systemImage: "paperplane") { session.resendQueued(row) } }
                        if case .device = row.source { Button("Edit", systemImage: "pencil") { session.editInComposer(row) } }
                        Button("Discard", systemImage: "trash", role: .destructive) { session.removeQueued(row) }
                    }
                if let status = row.status {
                    ChatCaption(text: status, trailing: true)
                } else if index == rows.count - 1 {
                    ChatCaption(text: "Queued · sends when \(session.hostName) is back", trailing: true)
                }
            }
            // One queued while the host is away rises from the composer as a sent one does.
            .transition(.asymmetric(insertion: ChatSendRise.transition(reduceMotion: reduceMotion), removal: .identity))
        }
    }
}
