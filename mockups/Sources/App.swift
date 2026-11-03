import SwiftUI

@main
struct MockupsApp: App {
    var body: some Scene {
        WindowGroup { Root() }
    }
}

/// `-screen <id>` picks the screen (`mockups/shoot.py list` names them); `-scheme dark|light` the appearance.
struct Root: View {
    private let screen = UserDefaults.standard.string(forKey: "screen") ?? "index"
    private let scheme = UserDefaults.standard.string(forKey: "scheme") ?? "dark"
    var body: some View {
        Screens.view(screen)
            .preferredColorScheme(scheme == "light" ? .light : .dark)
            .tint(.dispatchPink)
    }
}

enum Screens {
    @ViewBuilder static func view(_ id: String) -> some View {
        switch id {
        // Tab screen: Terminal / Chat / Files capsule on top; inside Files the system bottom tab bar.
        case "H0-terminal": HybridTerminalScreen()
        case "H1-files": HybridFilesScreen()
        case "H2-review": HybridReviewScreen()
        case "H3-commits": HybridCommitsScreen()
        // Pushed from them.
        case "F2-file": FilePreviewScreen()
        case "R2-diff-comments": GlassDiffScreen(mode: .comments)
        case "R3-diff-select": GlassDiffScreen(mode: .selecting)
        case "R4-diff-compose": GlassDiffScreen(mode: .composing)
        case "R5-review-sheet": ReviewSheetHost()
        case "R5b-review-sheet-swipe": ReviewSheetHost(swiped: true)
        case "R5c-review-sheet-noagent": ReviewSheetHost(agent: false)
        case "C2-commit": CommitDetailScreen()
        // States the Mac has.
        case "S1-no-helper": FilesUnavailableScreen(reason: .noHelper)
        case "S2-no-grant": FilesUnavailableScreen(reason: .noGrant)
        case "S3-offline": FilesUnavailableScreen(reason: .offline)
        case "S4-review-sent": ReviewSentScreen()
        case "S5-diff-fold-outdated": DiffFoldOutdatedScreen()
        case "S6-chat-entry": ChatEntryScreen()
        case "S6b-chat-corner-meta": ChatCornerMetaScreen()
        case "S6c-chat-corner-meta-phrased": ChatCornerMetaScreen(phrased: true)
        case "S6d-chat-corner-time": ChatCornerTimeScreen()
        case "S6e-chat-corner-working": ChatCornerTimeScreen(working: true)
        // Spaces reworked.
        case "P1-spaces": SpacesTabBar { SpacesRootScreen() }
        case "P1b-spaces-needs-you": SpacesTabBar { SpacesRootScreen(filter: 1) }
        case "P2-space": SpaceScreen()
        case "P2b-space-swipe": SpaceScreen(swiped: true)
        case "P2c-space-menu": SpaceScreen(menuOpen: true)
        case "P2d-space-edit": SpaceScreen(editing: true)
        case "P2e-space-new-tab": SpaceScreen(newTabMenu: true)
        case "P3-space-switcher": SpaceSwitcherHost()
        // Settings.
        case "G1-settings": SettingsScreen()
        case "G2-terminal-font": SettingsPush(title: "Terminal font") { TerminalFontScreen() }
        case "G3-chat-font": SettingsPush(title: "Chat font") { ChatFontScreen() }
        case "G4-theme": SettingsPush(title: "Theme") { AppThemeScreen() }
        case "G5-notifications": SettingsPush(title: "Notifications") { NotificationsScreen() }
        // Terminal.
        case "T1-terminal-search": TerminalSearchScreen()
        case "T2-terminal-menu": TerminalMenuScreen()
        // Chat.
        case "C1-chat-search": ChatSearchScreen()
        case "C2-chat-slash": ChatSlashScreen()
        case "C3-chat-side": ChatSideScreen()
        case "C4-chat-goal": ChatGoalScreen()
        case "C4b-chat-goal-sheet": ChatGoalScreen(sheet: true)
        case "C5-chat-conversation": ChatConversationScreen()
        case "C6-chat-jump": ChatJumpScreen()
        // The queue in the working row.
        case "Q0-queue-today": QueueRowScreen(style: .today)
        case "Q1-queue-capsule": QueueRowScreen(style: .capsule)
        case "Q1b-queue-capsule-open": QueueRowScreen(style: .capsule, open: true)
        case "Q2-queue-controls": QueueRowScreen(style: .controls)
        case "Q3-queue-inline": QueueRowScreen(style: .inline)
        case "Q4-queue-bubbles": QueueRowScreen(style: .bubbles)
        case "Q5-queue-glyphs": QueueGlyphsScreen()
        case "Q6-queue-paused": QueuePausedScreen()
        // Message details.
        case "M1-message-info": MessageInfoScreen()
        case "M1b-message-info-unfolded": MessageInfoScreen(variant: .unfolded)
        case "M1c-message-info-short": MessageInfoScreen(variant: .short)
        case "M1d-message-info-stopped": MessageInfoScreen(variant: .interrupted)
        // One mode button left of the host disc, as the Mac strip's.
        case "B1-mode-chat": ModeChatScreen()
        case "B1b-mode-chat-held": ModeChatScreen(menu: true)
        case "B2-mode-agent-terminal": ModeAgentTerminalScreen()
        case "B2b-mode-agent-terminal-held": ModeAgentTerminalScreen(menu: true)
        case "B3-mode-shell-terminal": ModeShellTerminalScreen()
        case "B3b-mode-shell-terminal-held": ModeShellTerminalScreen(menu: true)
        case "B4-mode-files": ModeFilesScreen()
        case "B4b-mode-review": ModeFilesScreen(agent: true, tab: .review)
        case "B5-mode-states": ModeStatesScreen()
        case "B6-mode-styles": ModeStylesScreen()
        case "B7-host-leading-chat": ModeChatScreen(layout: .hostLeading)
        case "B7b-host-leading-terminal": ModeAgentTerminalScreen(layout: .hostLeading)
        case "B7c-host-leading-states": ModeStatesScreen(layout: .hostLeading)
        case "B7d-host-leading-apart-states": ModeStatesScreen(layout: .hostLeadingApart)
        case "B8-info-chat": ModeChatScreen(layout: .info("info.circle"))
        case "B8b-info-terminal": ModeAgentTerminalScreen(layout: .info("info.circle"))
        case "B8c-info-states": ModeStatesScreen(layout: .info("info.circle"))
        case "B8d-ellipsis-states": ModeStatesScreen(layout: .info("ellipsis"))
        // Tab header options.
        case "X0-header-today": HeaderOptionScreen(option: .today)
        case "X1-header-menu": HeaderOptionScreen(option: .menu)
        case "X2-header-host-leading": HeaderOptionScreen(option: .hostLeading)
        case "X3-header-two-line": HeaderOptionScreen(option: .twoLineTitle)
        case "X4-header-two-line-small": HeaderOptionScreen(option: .twoLineSmall)
        case "X5-header-host-trailing": HeaderOptionScreen(option: .hostTrailing)
        case "X6-header-switch-in-bar": HeaderOptionScreen(option: .switchInBar)
        case "X7-header-two-line-top": HeaderOptionScreen(option: .twoLineTop)
        case "X9-header-disc-chevron": HeaderOptionScreen(option: .discBadge("chevron.down"))
        case "X9b-header-disc-ellipsis": HeaderOptionScreen(option: .discBadge("ellipsis"))
        case "X9c-header-disc-chevron-long": HeaderOptionScreen(option: .discBadge("chevron.down"), title: "Chat mode narrow pane footer fix and the composer overflow in split view")
        case "X8-header-adaptive": HeaderOptionScreen(option: .adaptive)
        case "X8b-header-adaptive-long": HeaderOptionScreen(option: .adaptive, title: "Chat mode narrow pane footer fix and the composer overflow in split view")
        case "X7b-header-two-line-top-long":
            HeaderOptionScreen(option: .twoLineTop, title: "Chat mode narrow pane footer fix and the composer overflow in split view")
        // Agent icons.
        case "Y0-icons-today": AgentIconsSpaceScreen(style: .today)
        case "Y1-icons-tinted": AgentIconsSpaceScreen(style: .tinted)
        case "Y2-icons-tiles": AgentIconsSpaceScreen(style: .tiles)
        case "Y3-icons-soft": AgentIconsSpaceScreen(style: .soft)
        case "Y4-icons-compare": AgentIconsCompareScreen()
        case "Y5-chat-text-bubble": AgentIconsSpaceScreen(style: .chatTextBubble)
        case "Y6-chat-text-bubble-primary": AgentIconsSpaceScreen(style: .chatTextBubblePrimary)
        case "Y7-chat-bubble": AgentIconsSpaceScreen(style: .chatBubble)
        case "Y8-chat-conversation": AgentIconsSpaceScreen(style: .chatConversation)
        case "Y9-chat-compare": AgentIconsCompareScreen(styles: AgentIconStyle.chats, title: "Chat icon")
        // Host stats widget.
        case "W0-spaces-tree": SpacesTabBar { SpacesTreeMock() }
        case "W0b-offline-collapsed": SpacesTabBar { SpacesTreeMock(offlineCollapsed: true) }
        case "W0c-offline-menu": SpacesTabBar { SpacesTreeMock(menuOpen: true) }
        case "W1a-host-small": HostStatsCompactHost()
        case "W1b-host-dragging": HostStatsCompactHost(dragging: true)
        case "W1c-host-small-offline": HostStatsCompactHost(state: .stale)
        case "W1-host-cpu": HostSheetHost(mode: .cpu)
        case "W2-host-mem": HostSheetHost(mode: .mem)
        case "W3-host-scrub": HostSheetHost(mode: .scrub)
        case "W4-host-detail": HostDetailStatsScreen()
        case "W5-host-stale": HostSheetHost(mode: .cpu, state: .stale)
        case "W6-host-plain": HostSheetHost(mode: .cpu, state: .plain)
        case "W7-host-lowpower": HostSheetHost(mode: .cpu, state: .lowPower)
        // iPad.
        case "I1-split-files": PadStripScreen(detail: .files)
        case "I2-split-review": PadStripScreen(detail: .review)
        case "I2b-split-review-empty": PadStripScreen(detail: .review, empty: true)
        case "I3-split-commits": PadStripScreen(detail: .commits)
        case "I3b-split-commits-empty": PadStripScreen(detail: .commits, empty: true)
        case "I4-split-chat": PadStripScreen(detail: .chat)
        case "I5-host-popover": PadStripScreen(detail: .files, popover: true)
        case "I7-full-width-terminal": PadStripScreen(detail: .terminal)
        case "I8-sidebar-hidden": PadStripScreen(detail: .chat, sidebarHidden: true)
        // iPhone on its side (shoot.py rotate landscape first).
        case "L1-terminal": LandscapeTerminalScreen()
        case "L2-terminal-keyboard": LandscapeTerminalKeyboardScreen()
        case "L3-chat": LandscapeChatScreen()
        case "L4-chat-review": LandscapeChatReviewScreen()
        case "L5-review": LandscapeReviewScreen()
        case "L6-commits": LandscapeCommitsScreen()
        case "L7-spaces-split": LandscapeSpacesSplitScreen()
        case "L8-agents-board": LandscapeAgentsBoardScreen()
        // On its side with the full height: the chrome in rails beside the content.
        case "L9-full-chat": FullHeightChatScreen()
        case "L9b-full-chat-typing": FullHeightChatTypingScreen()
        case "L9c-full-chat-draft": FullHeightChatDraftScreen()
        case "L10-full-terminal": FullHeightTerminalScreen()
        case "L10b-full-terminal-chip": FullHeightTerminalScreen(chip: true)
        case "L11-full-review": FullHeightReviewScreen()
        // One rail: the mode's action at the leading rail's foot, nothing on the trailing side.
        case "L12-one-rail-chat": OneRailChatScreen()
        case "L12b-one-rail-chat-typing": OneRailChatTypingScreen()
        case "L12c-one-rail-chat-draft": OneRailChatScreen(draft: true)
        case "L13-one-rail-review": OneRailReviewScreen()
        case "L14-one-rail-terminal": OneRailTerminalScreen()
        case "L14b-one-rail-terminal-typing": OneRailTerminalTypingScreen()
        case "L14c-one-rail-terminal-keys": OneRailTerminalScreen(menu: true)
        case "L15-edge-terminal": OneRailTerminalScreen(edgeToEdge: true)
        case "L15b-edge-chat": OneRailChatScreen(edgeToEdge: true)
        case "I6-half-width": PadHalfWidth { HybridFilesScreen() }
        case "I6b-half-width-spaces": PadHalfWidth { PadSidebarTabs(width: 507) }
        default: Text("screen \(id)").font(.title)
        }
    }
}

extension Color {
    static let dispatchPink = Color("AccentColor")
    static let canvas = Color("Canvas")
    static let groupedRow = Color("GroupedRow")
    static let raisedRow = Color("RaisedRow")
    static let added = Color("Added")
    static let destructive = Color("Destructive")
    static let caution = Color("Caution")
    static let stateUnread = Color("StateUnread")
    static let stateWorking = Color("StateWorking")
    static let stateConnected = Color("StateFinished")
    static let chipFill = Color("ChipFill")
    static let chipBorder = Color("ChipBorder")
    static let faintFill = Color("FaintFill")
    static let codePanel = Color("CodePanel")
    static let codeInk = Color("CodeInk")
    static let codeComment = Color("CodeComment")
    static let codeKeyword = Color("CodeKeyword")
    static let codeString = Color("CodeString")
    static let codeType = Color("CodeType")
    static let codeNumber = Color("CodeNumber")
    static let onAccent = Color("OnAccent")
    static let bubbleAgent = Color("BubbleAgent")
    static let lens = Color("Lens")
}
