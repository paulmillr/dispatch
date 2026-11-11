import SwiftUI

// The tab header as the app ships it (2026-11-10, `TabScreenHeader`, `TabsTitleCapsuleView`), as Messages heads a
// conversation: Back alone in its glass circle with the needs-you count; beside it one glass capsule holding the host's
// glyph on a disc of its colour, the tab's title and host · folder under it, one line each; the mode button alone on
// the right (B7's). A tap on the capsule opens the tab's one menu (`TabMenuItems`): on Chat Search, the host's Stats, Side
// Conversation; the pane picker when there are several; Rename…, Detach, Close Tab.

/// The capsule: the host's disc, the title over host · folder.
struct TitleCapsuleMock: View {
    let title: String
    var subtitle: AnyView = AnyView(TabSubtitle())
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.logo")
                .font(.system(size: 18))
                .foregroundStyle(hostTint)
                .frame(width: 36, height: 36)
                .background(hostTint.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// Back's circle, the title capsule, the mode button.
struct CapsuleTabHeader: ToolbarContent {
    let title: String
    var subtitle: AnyView = AnyView(TabSubtitle())
    let state: ModeButtonState
    /// In the mode button's place (conversation mode's waveform).
    var trailing: AnyView? = nil
    /// False beside the Duo's sidebar, where Back would return.
    var back = true
    /// The bar's room for Back and the capsule: the phone's width less its margins and the mode button.
    var room: CGFloat = 402 - 52 - 52
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                if back { BackPill(count: 2).fixedSize() }
                TitleCapsuleMock(title: title, subtitle: subtitle).layoutPriority(1)
                Spacer(minLength: 0)
            }
            .frame(width: room, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            if let trailing { trailing } else { ModeToggle(state: state) }
        }
    }
}

/// Chat shown (the Duo's cover, V4).
struct CapsuleChatScreen: View {
    var title = "Billing webhook retries"
    var body: some View {
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    CapsuleTabHeader(title: title, subtitle: AnyView(TabSubtitle(folder: "app")),
                                     state: ModeButtonState(shown: .chat, agent: true))
                }
        }
    }
}

/// B8c: the capsule tapped on Chat: the tab's menu under it.
struct CapsuleMenuScreen: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            CapsuleChatScreen()
            Color.black.opacity(0.18).ignoresSafeArea().allowsHitTesting(false)
            TabMenuMock()
                // Under the capsule's leading edge, as the system opens a menu from its button (iPhone Air's 874 points).
                .padding(.leading, 76)
                .padding(.top, 58)
        }
    }
}

/// The menu (`TabMenuItems`): the glyph first, as the system draws a menu's labels.
struct TabMenuMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("Search", "magnifyingglass")
            item("Stats", "gauge.with.dots.needle.33percent")
            item("Side Conversation", "bubble.left.and.text.bubble.right")
            divider
            Text("Tab").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 2)
            item("Rename…", "pencil")
            divider
            item("Detach", "eject")
            item("Close Tab", "xmark")
        }
        .padding(.vertical, 10)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5).padding(.horizontal, 20).padding(.vertical, 6)
    }

    private func item(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.body).frame(width: 22)
            Text(title).font(.body)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
    }
}

/// B8d: a long title (a Claude tab named after its prompt): one line, cut, host · folder still under it.
struct CapsuleLongTitleScreen: View {
    var body: some View {
        CapsuleChatScreen(title: "See how we can speed-up sha3 without writing new code yet")
    }
}
