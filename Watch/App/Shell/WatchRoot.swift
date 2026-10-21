import SwiftUI

/// The app's two lists, Agents and Spaces, as vertical pages (`.verticalPage`): watchOS 26's own apps page this way, the
/// Digital Crown scrolls a list and then pages on at its end, and Agents (what needs the wrist most) is on screen at
/// launch with no tap. A root list of two links would cost a tap before every row.
///
/// One navigation stack around the pages, as Apple's watchOS 10+ samples do: a stack per page crashed at launch on
/// watchOS 26 (`PUICStackedNavigationBar`: "possibly from a client attempt to nest wrapped navigation controllers"). A
/// push covers both pages; Back returns to the page it came from.
struct WatchRoot: View {
    enum Page: Hashable { case agents, spaces }

    let model: WatchModel
    var router: WatchRouter = .shared
    @State private var page: Page = .agents
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            TabView(selection: $page) {
                AgentsScreen(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        WatchNoticeView(model: model).padding(.horizontal, 4).padding(.bottom, 2)
                    }
                    .toolbar {
                        if model.needsYou > 0 {
                            ToolbarItem(placement: .topBarTrailing) { WatchNeedsYouBadge(count: model.needsYou) }
                        }
                    }
                    .tag(Page.agents)
                SpacesScreen(model: model)
                    .tag(Page.spaces)
            }
            .tabViewStyle(.verticalPage)
            .navigationDestination(for: WatchConversationKey.self) { ThreadScreen(model: model, key: $0) }
            .navigationDestination(for: WatchSpaceRoute.self) { SpaceScreen(model: model, route: $0) }
            .navigationDestination(for: WatchTabRoute.self) { TabDetailScreen(model: model, route: $0) }
        }
        .onAppear(perform: route)
        .onChange(of: router.pending) { route() }
        .onChange(of: router.show) { route() }
    }

    /// A notification's thread: Agents comes forward with the thread pushed on it.
    private func route() {
        if let show = router.show {
            router.show = nil
            var next = NavigationPath()
            page = .spaces
            switch show {
            case .spaces(let host): router.scrollTarget = host
            case .space(let route): next.append(route)
            case .tab(let route):
                if let tab = model.tab(host: route.host, key: route.tab) {
                    next.append(WatchSpaceRoute(host: tab.host, space: tab.space))
                }
                next.append(route)
            }
            path = next
        }
        guard let key = router.take() else { return }
        page = .agents
        var next = NavigationPath()
        next.append(key)
        path = next
    }
}

/// The phone's needs-you count in the Agents page's corner: a vertical page has no tab bar, and `badge` is unavailable
/// on watchOS.
struct WatchNeedsYouBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(WatchDots.needsYou, in: Capsule())
            .accessibilityLabel("\(count) need you")
    }
}
