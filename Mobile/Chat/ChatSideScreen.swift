import SwiftUI
import UIKit

/// C3: a side conversation, pushed over the main thread: "‹ Main" returns (the side stays open, a capsule over the main
/// composer comes back to it), the title is the command ("btw", "side") over the conversation and the agent, a banner
/// says what it may do, then its own thread and composer ("Ask on the side"). The ⋯ menu brings the last answer into
/// the main composer, turns a /btw into a /side ("Allow changes", asking its question again with full permissions,
/// where the agent offers /side), copies it, and ends it (its process too).
struct ChatSideScreen: View {
    let session: MobileChatSession
    @Bindable var side: MobileSideConversation
    /// The main conversation's title ("Billing webhook retries").
    var conversation: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tabsColumnWidth) private var columnWidth
    @FocusState private var focused: Bool
    @State private var column: CGFloat = 370
    @ScaledMetric(relativeTo: .callout) private var measure = ChatMeasure.standard

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(side.rows) { row in
                    switch row.kind {
                    case .user:
                        ChatUserMessage(text: row.item.text)
                    case .agent(let summary):
                        VStack(spacing: 5) {
                            ChatBubble(side: .agent) { MobileChatMarkdownView(text: row.item.text) }
                                .environment(\.openURL, MobileChatMarkdown.openURL)
                                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text } }
                            if let summary { ChatTurnFootnote(summary: summary) }
                        }
                    case .thinking:
                        MobileChatMarkdownView(text: row.item.text, muted: true)
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .notice:
                        Text(row.item.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                ForEach(side.pending) { item in
                    ChatUserMessage(text: item.text, faded: true)
                }
                if let permission = side.permission {
                    permissionCard(permission.display)
                }
                if side.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(session.agentName) is answering on the side…").font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 6)
                }
                if let failure = side.failure {
                    ChatNote(text: failure).onTapGesture { side.failure = nil }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 32 }) { column = $0 }
        .environment(\.chatColumnWidth, column)
        .environment(\.chatMeasure, measure)
        // The banner stays under the header, the thread meets the composer (C3).
        .safeAreaBar(edge: .top, spacing: 0) {
            banner
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
        .safeAreaBar(edge: .bottom) {
            CodeComposer(text: $side.draft, placeholder: "Ask on the side", working: false,
                         focus: $focused, send: { side.send() }, steer: nil, stop: {},
                         dictationOwner: ObjectIdentifier(side))
                .disabled(side.ended)
        }
        .background(Color.canvas)
        .tabsPushedScreen()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            TabsScreenHeader(title: side.title, column: columnWidth, trailingWidth: 44) {
                TabsBackPill(label: "Main") { dismiss() }
            } subtitle: {
                Text([conversation, session.agentKey ?? session.agentName].filter { !$0.isEmpty }.joined(separator: " · "))
            } trailing: {
                menu
            }
        }
        .onAppear { if side.question == nil { focused = true } }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold)).accessibilityHidden(true)
            Text(side.readOnly ? "Side conversation · read-only, kept out of the main thread"
                 : "Side conversation · can make changes, kept out of the main thread")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: measure)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-side-banner")
    }

    private var menu: some View {
        Menu {
            Button("Bring into Main Thread", systemImage: "arrow.turn.down.left") {
                if let answer = side.lastAnswer { session.bringIntoMain(answer) }
                dismiss()
            }
            .disabled(side.lastAnswer == nil)
            if side.readOnly, session.offersSide(.side) {
                Button("Allow Changes (/side)", systemImage: "pencil") { session.allowChanges() }
                    .disabled(side.question == nil || side.ended)
            }
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = side.lastAnswer }
                .disabled(side.lastAnswer == nil)
            Divider()
            Button("End Side Conversation", systemImage: "xmark", role: .destructive) { session.endSide() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(Color.primary)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Side conversation menu")
    }

    private func permissionCard(_ permission: ChatSidePermission) -> some View {
        VStack(spacing: 6) {
            ChatBubble(side: .agent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(permission.title)
                    Text(permission.operation)
                        .font(.footnote.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.approvalCode, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack(spacing: 8) {
                Spacer()
                ChatChip(title: "Deny", hint: "Refuses the side conversation’s request") { side.answer(allow: false) }
                if !side.readOnly {
                    ChatChip(title: "Allow", prominent: true, hint: "Allows the side conversation’s request") { side.answer(allow: true) }
                }
            }
        }
    }
}
