import SwiftUI
import UIKit

// The iPhone Duo, after docs/ios.md (Windows) and MobileSplit's book posture, as the app draws it on the simulator.
// Unfolded (V1–V3, the inner screen, 951 × 669 points): the Spaces tree in the iPad's 320-point sidebar (the phone's
// Spaces · Agents bar and New at its foot) beside the tab, across the fold. The tab's header is the phone's without
// Back: the title capsule (the host's disc, the title over host · folder; it opens the tab's menu, the conversation's
// items too) and the mode button before the status. Files is the phone's: no tab bar, its modes in the button's menu.
// Inside a space (V7) the sidebar is the space's screen (P2: Back to Spaces, its tabs, New tab; no tab bar, the push
// covers it), its rows without chevrons, the tab beside it. With no tab open (V8) the column says so. The sidebar marks
// neither the space nor the tab shown beside it, as the app's Duo (the iPad's sidebar does).
// Folded (V4–V6, the cover screen, 466 points wide): the phone's stack, its tab header, the status in the bar's row.

enum DuoMock {
    /// The sidebar's width in book posture (`MobileSplit.bookSidebar`).
    static let sidebar: CGFloat = 320
    /// The tab's column beside it.
    static let tab: CGFloat = 951 - sidebar - 0.5
}

enum DuoDetail { case chat, terminal, files }

/// V1–V3, V7, V8: the unfolded inner screen. `detail` nil: no tab open.
struct DuoSplitScreen: View {
    let detail: DuoDetail?
    /// The sidebar inside the tab's space rather than at Spaces.
    var inSpace = false
    var body: some View {
        HStack(spacing: 0) {
            Group {
                if inSpace {
                    // The chat shown beside it is one of the space's tabs.
                    SpaceScreen(sidebar: DuoMock.sidebar, tabs: MockSpaces.appTabs.dropLast() + [
                        .init(name: "Billing webhook retries", kind: "claude",
                              line: "Moving the check into a shared middleware so both routes get it.", time: "1:12 AM"),
                    ])
                } else {
                    // The phone's tab bar (Spaces · Agents, New apart), the title on the bar's row beside Edit.
                    SpacesTabBar { SpacesRootScreen(titleInBar: true) }
                }
            }
            .frame(width: DuoMock.sidebar)
            .environment(\.horizontalSizeClass, .compact)
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5).ignoresSafeArea()
            Group {
                if let detail {
                    DuoTab(detail: detail)
                } else {
                    ContentUnavailableView {
                        Label("No tab open", systemImage: "square.on.square")
                    } description: {
                        Text("Open a tab in Spaces, or a conversation in Agents.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.canvas)
        // As the app (`MobileVerticalBar`): no iOS 27 vertical bar on a window wide enough for the split.
        .background(DuoVerticalBarOff().allowsHitTesting(false))
    }
}

/// Turns iOS 27.1's vertical bar off at the root, as the app's `MobileVerticalBar` does for the split.
private struct DuoVerticalBarOff: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        private var done = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !done, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.done, let root = self.window?.rootViewController else { return }
                self.done = true
                guard #available(iOS 27.1, *) else { return }
                let behavior = #selector(getter: UIViewController.preferredVerticalBarBehavior)
                let child = #selector(getter: UIViewController.childForPreferredVerticalBarBehavior)
                let off: @convention(block) (UIViewController) -> Int = { _ in UIVerticalBarBehavior.disabled.rawValue }
                let none: @convention(block) (UIViewController) -> UIViewController? = { _ in nil }
                for type in [UIViewController.self, Swift.type(of: root)] {
                    if let method = class_getInstanceMethod(type, behavior) { method_setImplementation(method, imp_implementationWithBlock(off)) }
                    if let method = class_getInstanceMethod(type, child) { method_setImplementation(method, imp_implementationWithBlock(none)) }
                }
                root.setNeedsUpdateOfVerticalBarConfiguration()
            }
        }
    }
}

/// The tab's column beside the sidebar.
private struct DuoTab: View {
    let detail: DuoDetail
    var body: some View {
        switch detail {
        case .chat:
            column {
                Transcript()
                    .scrollEdgeEffectStyle(.soft, for: .bottom)
                    .safeAreaBar(edge: .bottom) { Composer() }
            }
        case .terminal:
            column { AgentTerminalMock().safeAreaBar(edge: .bottom) { KeyBar() } }
                .environment(\.colorScheme, .dark)
        case .files:
            // The phone's Files: the mode's row under the header, no tab bar (the modes are the mode button's menu).
            column { DuoFilesList() }
        }
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(detail == .terminal ? Color.black : Color.canvas)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { DuoTabHeader(detail: detail) }
        }
    }
}

/// The tab's bar beside the sidebar: the phone's header without Back (the title capsule, the mode button), the room
/// the bar leaves the capsule the column less its margins, the mode button and the status in the bar's row (100), and
/// what this bar keeps besides (measured: about 60 more and it moves its items into its "…").
private struct DuoTabHeader: ToolbarContent {
    let detail: DuoDetail
    var body: some ToolbarContent {
        CapsuleTabHeader(title: "Billing webhook retries",
                         subtitle: AnyView(TabSubtitle(folder: "app", shell: detail == .terminal ? "claude" : nil)),
                         state: ModeButtonState(shown: detail == .chat ? .chat : detail == .files ? .files : .terminal, agent: true),
                         back: false, room: DuoMock.tab - 52 - 52 - 100 - 60)
    }
}

/// Files' list in the tab's column: the folder's row, then the entries.
private struct DuoFilesList: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Breadcrumb(crumbs: ["web", "src"])
                    Spacer(minLength: 0)
                    BarButton(symbol: "magnifyingglass"); BarButton(symbol: "ellipsis")
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                ForEach(Array(MockFiles.src.enumerated()), id: \.element.id) { index, file in
                    FileRow(file: file, last: index == MockFiles.src.count - 1)
                }
                Text("9 items").font(.footnote).foregroundStyle(.tertiary).padding(.top, 14)
            }
        }
    }
}
