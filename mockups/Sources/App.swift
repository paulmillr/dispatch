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
        // Graph colour candidates over a log with two merged branches; H3x is today's green and amber on it.
        case "H3x-commits-status": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .status)
        case "H3d-commits-vivid": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .vivid)
        case "H3f-commits-vivid-blue": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .vividBlue)
        case "H3g-commits-vivid-rose": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .vividRose)
        case "H3i-commits-vivid-gray": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .vividGray)
        case "H3h-commits-vivid-cyan": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .vividCyan)
        case "H3e-commits-saturated": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .saturated)
        case "H3a-commits-tint": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .tint)
        case "H3b-commits-hues": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .hues)
        case "H3c-commits-ink": HybridCommitsScreen(rows: MockLog.twoBranches, palette: .ink)
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
        // Spaces reworked.
        case "P1-spaces": SpacesRootScreen()
        case "P1b-spaces-needs-you": SpacesRootScreen(filter: 1)
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
        // Host stats widget.
        case "W0-spaces-tree": SpacesTreeMock()
        case "W0b-offline-collapsed": SpacesTreeMock(offlineCollapsed: true)
        case "W0c-offline-menu": SpacesTreeMock(menuOpen: true)
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
