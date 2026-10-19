import SwiftUI

/// How the Agents list draws a host: its tint and its glyph. The Hosts stream supplies both (HostTint, HostGlyph from
/// its records); the default is the shared tint of the host id and a display glyph.
struct ChatHostLook {
    var tint: @MainActor (UUID) -> Color = { HostTint(hostID: $0.uuidString).color }
    var glyph: @MainActor (UUID) -> AnyView = { _ in AnyView(Image(systemName: "display").resizable().scaledToFit()) }
}

/// M3a: the Agents tab, one row per agent conversation across hosts, sorted by activity. The glass filter by the title
/// toggles Unread only (rows with a dot) and fills with the app tint when on. Swipe a row to mute it or close it; tap
/// opens the thread in Chat.
struct AgentsScreen: View {
    @Bindable var conversations: ChatConversations
    var look = ChatHostLook()
    /// Opens the conversation's tab in Chat (the shell pushes Tabs' `TabScreen`).
    var open: (ChatConversation) -> Void
    /// Closes the conversation's tab; Tabs owns the close policy (`close.request` with check).
    var close: (ChatConversation) -> Void
    /// Its own title and filter button; off in the app, whose shared stack's bar carries them (`AgentsToolbar`).
    var chrome = true

    var body: some View {
        let rows = conversations.visible
        List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, conversation in
                Button { open(conversation) } label: {
                    MobileRow(
                        dot: conversation.dot, tint: look.tint(conversation.key.host),
                        name: conversation.name,
                        detail: conversation.hostName + (conversation.muted ? " · muted" : ""),
                        time: TabsTime.label(conversation.summary.lastActivity),
                        subtitle: conversation.summary.preview ?? conversation.summary.attention,
                        lines: 2, separator: index < rows.count - 1, stale: conversation.stale) {
                            look.glyph(conversation.key.host)
                        }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { close(conversation) } label: { Label("Close", systemImage: "xmark") }
                    Button { conversations.setMuted(!conversation.muted, conversation) } label: {
                        Label(conversation.muted ? "Unmute" : "Mute", systemImage: conversation.muted ? "bell" : "bell.slash")
                    }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(conversations.unreadOnly ? "No unread conversations" : "No agents yet")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(conversations.unreadOnly ? "Conversations that need you or have a new result show up here."
                         : "Agents running in a space's tabs show up here as conversations you can pick up on the go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 44)
            }
        }
        .modifier(AgentsChrome(conversations: conversations, on: chrome))
    }
}

private struct AgentsChrome: ViewModifier {
    let conversations: ChatConversations
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content
                .navigationTitle("Agents")
                .toolbarTitleDisplayMode(.large)
                .toolbar { AgentsToolbar(conversations: conversations) }
        } else {
            content
        }
    }
}

/// M3a's Unread-only filter by the title: plain glass, filled with the app tint while on. In the app it sits in the
/// shared stack's navigation bar (`MobileRoot`); a standalone `AgentsScreen` (the Debug demo) carries it itself.
struct AgentsToolbar: ToolbarContent {
    @Bindable var conversations: ChatConversations

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            let on = conversations.unreadOnly
            Button { conversations.unreadOnly.toggle() } label: {
                // M3a's funnel (no SF Symbol draws one; Spaces' sort menu keeps the lines).
                Image("Funnel")
                    .foregroundStyle(on ? Color.onAccent : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Its own glass, as Spaces' capsule has: the bar's shared glass ignored the prominent style, so the pill
            // stayed grey with a dark glyph when on (a screen recording showed it).
            .glassEffect(on ? .regular.tint(Color.dispatchPink).interactive() : .regular.interactive(), in: Circle())
            .accessibilityLabel("Unread only")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
        .sharedBackgroundVisibility(.hidden)
    }
}
