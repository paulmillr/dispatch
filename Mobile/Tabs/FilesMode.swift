import SwiftUI

/// The Files segment's three modes, the system tab bar's tabs inside it (H1, H2, H3): Files, Review (the uncommitted
/// changes, which take comments for an agent) and Commits. Glyphs as the Mac's.
enum FilesMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case files, review, commits
    var id: Self { self }

    var title: String {
        switch self {
        case .files: "Files"
        case .review: "Review"
        case .commits: "Commits"
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder"
        case .review: "pencil.and.list.clipboard"
        case .commits: "clock.arrow.circlepath"
        }
    }

    /// The modes a tab offers: all three inside a git repository, Files alone outside one (the bar then hides).
    static func available(repository: Bool) -> [FilesMode] { repository ? allCases : [.files] }
}

/// A screen a Files mode pushes over the tab (a file's preview, a change's diff, a commit), on the app's one stack
/// (`TabsRoute.files`): it covers the whole tab, its header, the capsule and the modes' tab bar, as every push does.
/// Each mode names its screens by what they show; the mode's `FilesModeContent.destination` builds them.
struct FilesRoute: Hashable, Sendable {
    let mode: FilesMode
    /// A path on the host (a file to preview, a change to diff): absolute, or relative to the repository's root.
    var path: String? = nil
    /// A commit (its full or abbreviated name), or another revision the screen compares against.
    var revision: String? = nil
    /// Anything else the screen needs to tell two pushes apart (a change's staged or unstaged side).
    var detail: String? = nil
}

/// Whether a tab's host can serve Files, from the host as Spaces sees it (`TabsHost`): a plain SSH login has no helper
/// (S1), a helper without the Files & git grant may not read (S2), a link that is down shows the last listing dimmed
/// with Reconnect (S3). The phone's version of the Mac's `FilesAvailability` (`Dispatch/Files/FilesModels.swift`).
enum MobileFilesAvailability: Equatable {
    case available
    /// The tab connected as plain SSH: no helper on that host.
    case plainSSH(host: String)
    /// The helper runs, but the host's Files & git switch is off.
    case notGranted(host: String)
    /// The host's link is down or reconnecting after a drop; `since` is when it went (nil: never connected).
    case offline(host: String, since: Date?)

    init(_ host: TabsHost) {
        if host.plain {
            self = .plainSSH(host: host.name)
        } else if !host.files {
            self = .notGranted(host: host.name)
        } else if host.state == .offline || host.reconnecting {
            // Down, or reconnecting after a drop; a connection being made (the foreground's) is not offline.
            self = .offline(host: host.name, since: host.offlineSince)
        } else {
            self = .available
        }
    }

    /// The modes can show (offline: the last listing, dimmed); S1 and S2 replace them with their explanation.
    var showsModes: Bool {
        switch self {
        case .available, .offline: true
        case .plainSSH, .notGranted: false
        }
    }

    var isOffline: Bool { if case .offline = self { true } else { false } }
}

/// What a Files mode sees of its tab.
struct FilesModeContext {
    let tab: MobileTab
    let host: TabsHost
    let mode: FilesMode
    /// The folder the tab is in (its active pane's).
    let directory: String?
    /// The tab's repository and branch (`SpaceGitFacts`), nil until read.
    let git: SpaceGitFacts.Facts?
    let availability: MobileFilesAvailability
    /// Pushes a screen over the tab.
    let push: (FilesRoute) -> Void
    /// Shows another mode of the segment (Commits' uncommitted row opens Review).
    var select: (FilesMode) -> Void = { _ in }
}

/// One mode's part of the Files segment: its body, the row under the capsule (a breadcrumb or the branch, and round
/// `MobileBarButton`s), the tab bar's accessory, the screens it pushes (`FilesRoute` with its `mode`), and for Review the
/// tab's comment count (the capsule's Files badge and the Review tab's badge; the other modes' counts are not shown).
/// The defaults are placeholders.
struct FilesModeSlot {
    var body: @MainActor (FilesModeContext) -> AnyView = { AnyView(FilesModePlaceholder(mode: $0.mode)) }
    /// The row under the capsule; nil: none.
    var bar: @MainActor (FilesModeContext) -> AnyView? = { _ in nil }
    /// The modes' tab bar accessory (Review's Create review); nil: none. While the host is offline the offline
    /// accessory takes the slot (`FilesOfflineAccessory`).
    var accessory: @MainActor (FilesModeContext) -> AnyView? = { _ in nil }
    var destination: @MainActor (TabRef, FilesRoute) -> AnyView = { _, route in AnyView(FilesModePlaceholder(mode: route.mode)) }
    /// Review's: the tab's review comments.
    var count: @MainActor (TabRef) -> Int = { _ in 0 }
    /// The iPad's pane beside the mode's list (`PadListPane`: a change's diff, a commit) for a route that opens there;
    /// nil: `destination`'s screen.
    var pane: (@MainActor (TabRef, FilesRoute) -> AnyView)? = nil
    /// Whether the pane's route still shows something (Review's change is still among the changes); false empties the
    /// pane and forgets the route.
    var paneShows: @MainActor (TabRef, FilesRoute) -> Bool = { _, _ in true }
    /// The iPad's line under the context row, where the phone has the accessory (`PadBanner`); nil: the accessory.
    /// Review's Create review is a pill in its row there instead, so only its sent and notice lines are banners.
    var banner: (@MainActor (FilesModeContext) -> AnyView?)? = nil
}

/// The seam the Files, Review and Commits areas fill, one slot each, so no two areas write the same lines: each
/// installs its slot from its own file (`MobileComposition+FilesMode.swift`, `+ReviewMode.swift`, `+CommitsMode.swift`),
/// as the composition wires Terminal and Chat. The host actions are the foundation's (S1's Install helper…, S3's
/// Reconnect).
struct FilesModeContent {
    var files = FilesModeSlot()
    var review = FilesModeSlot()
    var commits = FilesModeSlot()
    /// S1's Install helper…: turns the host's Helper switch on (a reconnect).
    var installHelper: @MainActor (UUID) -> Void = { _ in }
    /// S3's Reconnect.
    var reconnect: @MainActor (UUID) -> Void = { _ in }

    func slot(_ mode: FilesMode) -> FilesModeSlot {
        switch mode {
        case .files: files
        case .review: review
        case .commits: commits
        }
    }

    /// The tab's review comments (Review's count).
    @MainActor func reviewCount(_ tab: TabRef) -> Int { review.count(tab) }

    @MainActor func body(_ context: FilesModeContext) -> AnyView { slot(context.mode).body(context) }
    @MainActor func bar(_ context: FilesModeContext) -> AnyView? { slot(context.mode).bar(context) }
    @MainActor func accessory(_ context: FilesModeContext) -> AnyView? { slot(context.mode).accessory(context) }
    @MainActor func destination(_ tab: TabRef, _ route: FilesRoute) -> AnyView { slot(route.mode).destination(tab, route) }
    @MainActor func paneShows(_ tab: TabRef, _ route: FilesRoute) -> Bool { slot(route.mode).paneShows(tab, route) }
    @MainActor func pane(_ tab: TabRef, _ route: FilesRoute) -> AnyView {
        slot(route.mode).pane?(tab, route) ?? destination(tab, route)
    }
    @MainActor func banner(_ context: FilesModeContext) -> AnyView? {
        if let banner = slot(context.mode).banner { return banner(context) }
        return accessory(context)
    }
}

/// A mode its area has not filled yet.
struct FilesModePlaceholder: View {
    let mode: FilesMode

    var body: some View {
        ContentUnavailableView {
            Label(mode.title, systemImage: mode.symbol)
        } description: {
            Text("Coming soon.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Files segment (H1, H2, H3; S1, S2, S3): the system tab bar with the modes, each mode's body under the capsule,
/// Review's badge, the accessory slot. Outside a git repository only Files, and no bar. S1 and S2 take the whole
/// segment, with no bar: the host has no modes to offer.
struct TabFilesSegment: View {
    let context: FilesModeContext
    let content: FilesModeContent
    @Binding var mode: FilesMode
    /// The tab's git repository (`SpaceGitFacts`): the modes' bar shows only inside one.
    let repository: Bool
    let notNow: () -> Void
    /// S2's Change integration…: the host's settings.
    let changeIntegration: () -> Void

    var body: some View {
        if context.availability.showsModes {
            modes
        } else {
            FilesUnavailableView(availability: context.availability, notNow: notNow,
                                 installHelper: { content.installHelper(context.host.id) },
                                 changeIntegration: changeIntegration)
        }
    }

    private var modes: some View {
        let available = FilesMode.available(repository: repository)
        let shown = available.contains(mode) ? mode : .files
        let accessory = accessoryView(shown)
        let count = content.reviewCount(context.tab.ref)
        // The system tab bar's pages get the navigation bar's inset but not the tab's `safeAreaBar` (the capsule and the
        // mode's row): each page is inset by the difference, read in the same layout pass (`FilesPageInset`), so its
        // content starts below the bar and scrolls beneath it.
        return GeometryReader { segment in
        TabView(selection: Binding(get: { shown }, set: { mode = $0 })) {
            ForEach(available) { item in
                Tab(item.title, systemImage: item.symbol, value: item) {
                    Group {
                        if item == shown { content.body(context.with(mode: item)) } else { Color.canvas }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(FilesPageInset(top: segment.safeAreaInsets.top))
                    .opacity(context.availability.isOffline ? 0.45 : 1)
                    .background(Color.canvas)
                    .toolbarVisibility(available.count > 1 ? .visible : .hidden, for: .tabBar)
                }
                .badge(item == .review ? count : 0)
            }
        }
        .tint(.dispatchPink)
        .modifier(FilesAccessory(accessory: accessory))
        }
    }

    private func accessoryView(_ mode: FilesMode) -> AnyView? {
        if case .offline(let host, let since) = context.availability {
            return AnyView(FilesOfflineAccessory(host: host, since: since) { content.reconnect(context.host.id) })
        }
        return content.accessory(context.with(mode: mode))
    }
}

extension FilesModeContext {
    func with(mode: FilesMode) -> FilesModeContext {
        FilesModeContext(tab: tab, host: host, mode: mode, directory: directory, git: git, availability: availability, push: push,
                         select: select)
    }
}

/// A page's missing top inset: the segment's (`top`, under the tab's bar) less what the page was given.
private struct FilesPageInset: ViewModifier {
    let top: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { page in
            content.safeAreaPadding(.top, max(0, top - page.safeAreaInsets.top))
        }
    }
}

/// The tab bar's accessory, present only while there is one. iOS 26.0 has no `isEnabled`, so its TabView is rebuilt
/// when the accessory comes and goes.
private struct FilesAccessory: ViewModifier {
    let accessory: AnyView?

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: accessory != nil) { accessory }
        } else if let accessory {
            content.tabViewBottomAccessory { accessory }
        } else {
            content
        }
    }
}

/// S3's accessory: "mba2 is offline · 2m ago" in amber, and Reconnect in the app tint. The modes' content dims under
/// it (`TabFilesSegment`); a mode that wants it elsewhere uses this view.
struct FilesOfflineAccessory: View {
    let host: String
    let since: Date?
    let reconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").accessibilityHidden(true)
            Text("\(host) is offline")
                .font(.body.weight(.semibold))
                .lineLimit(1)
            if let since {
                TimelineView(.periodic(from: since, by: 30)) { timeline in
                    Text(Self.ago(since, now: timeline.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button("Reconnect", action: reconnect)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.dispatchPink)
                .buttonStyle(.plain)
        }
        .foregroundStyle(Color.caution)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
    }

    /// "2m ago", "just now", "3h ago", "2d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

/// S1 and S2: what Files needs on this host, Not now (back to the segment shown before) and the one thing that fixes it.
struct FilesUnavailableView: View {
    let availability: MobileFilesAvailability
    let notNow: () -> Void
    let installHelper: () -> Void
    let changeIntegration: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    struct Copy: Equatable {
        let symbol: String
        let title: String
        let message: String
        let action: String
    }

    static func copy(_ availability: MobileFilesAvailability) -> Copy? {
        switch availability {
        case .plainSSH(let host):
            Copy(symbol: "shippingbox", title: "Files needs the helper on \(host)",
                 message: "This login is plain SSH. Install the helper to browse files, review changes and read the log.",
                 action: "Install helper…")
        case .notGranted(let host):
            Copy(symbol: "lock.shield", title: "Files is not allowed on \(host)",
                 message: "The helper runs here, but its integration does not grant reading files or git. Change it to allow Files.",
                 action: "Change integration…")
        case .available, .offline:
            nil
        }
    }

    var body: some View {
        if let copy = Self.copy(availability) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 14) {
                        Image(systemName: copy.symbol)
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(copy.title)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(copy.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, typeSize.isAccessibilitySize ? 4 : 24)
                        actions(copy)
                            .padding(.top, 8)
                    }
                    .padding(.horizontal, 16)
                    // The mockup's: a third of the way down (one spacer above, two below).
                    .padding(.bottom, geometry.size.height * 0.24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("files-unavailable")
        }
    }

    @ViewBuilder private func actions(_ copy: Copy) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button(action: notNow) {
                Text("Not now")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityHint("Shows the tab’s previous view")
            Button(action: { if case .plainSSH = availability { installHelper() } else { changeIntegration() } }) {
                Text(copy.action)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.onAccent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
            .accessibilityHint(availability == .plainSSH(host: hostName) ? "Turns the helper on for \(hostName) and reconnects"
                                                                           : "Opens \(hostName)’s settings")
        }
    }

    private var hostName: String {
        switch availability {
        case .plainSSH(let host), .notGranted(let host), .offline(let host, _): host
        case .available: ""
        }
    }
}
