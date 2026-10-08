import AppKit

extension AppDelegate {
    /// A multiplexer's space answers that tool's table (by the name its helper gives it; a local
    /// herdr's own config.toml), a native space the style chosen in Settings.
    func prefixTable(for surface: UUID) -> PrefixTable? {
        guard let space = workspace.spaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(surface) } }) else { return nil }
        guard space.structured else { return settings.values.prefixKeys.table }
        guard settings.values.backendPrefixKeys,
              let style = space.backend.flatMap({ workspace.helper(space)?.multiplexer(of: $0) }).flatMap(PrefixStyle.init(rawValue:))
        else { return nil }
        return style == .herdr && space.remote == nil ? HerdrKeyConfig.shared.table : style.table
    }

    /// Runs a binding through the menu action it names, keeping that action's safety rules.
    func performPrefix(_ action: PrefixAction, surface: UUID) {
        let space = workspace.current
        switch action {
        case .newSpace: newSpace()
        case .closeSpace: closeCurrentSpace()
        case .renameSpace: renameSpace()
        case .previousSpace: previousSpace()
        case .nextSpace: nextSpace()
        case .searchSpaces: focusSpaceSearch()
        case .selectSpace(let number): workspace.selectSpace(at: number - 1)
        case .newTab: newTab()
        case .closeTab: closeCurrentTab()
        case .renameTab: renameTab()
        case .previousTab: previousTab()
        case .nextTab: nextTab()
        case .selectWindow(let index):
            if index > 0 { workspace.selectNumberedItem(at: index - 1) }
        case .selectTab(let number): workspace.selectNumberedItem(at: number - 1)
        case .splitRight: splitColumns()
        case .splitDown: splitRows()
        case .closePane:
            guard let tab = workspace.activeTab else { return }
            closeTab(tab.id)
        case .breakPane: movePaneToNewSpace(surface)
        case .nextPane: nextPane()
        case .previousPane: previousPane()
        case .nextLayout:
            guard let space else { return }
            let presets = LayoutPreset.allCases, start = space.preset.flatMap(presets.firstIndex(of:)) ?? -1
            if let next = (1...presets.count).lazy.map({ presets[(start + $0) % presets.count] })
                .first(where: { self.workspace.canApplyLayout($0, in: space) }) { workspace.applyLayout(next) }
        case .layout(let preset):
            workspace.applyLayout(preset)
        // The multiplexer's own command, run on the server of the focused terminal (old app: tmux commands).
        case .tmux(let command):
            if let tab = workspace.spaces.flatMap(\.tabs).first(where: { $0.surfaceIDs.contains(surface) }), let node = tab.terminal {
                workspace.helper(containing: tab.id)?.command(node, command)
            }
        case .nextAttention: nextAttention()
        case .previousAttention: previousAttention()
        case .detach:
            // Native spaces have no server to detach from.
            detachCurrent()
        case .toggleSidebar: toggleSidebar()
        case .find: findInContent()
        case .scrollPageUp: _ = TerminalRuntime.shared.views[surface]?.performBindingAction("scroll_page_up")
        case .paste: TerminalRuntime.shared.views[surface]?.paste(nil)
        case .shortcuts: showKeyboardShortcuts()
        case .settings: showSettings()
        }
    }
}

/// herdr's local config.toml, re-read when it changes (checked at most every few seconds, since
/// the lookup runs for every key a herdr terminal receives).
@MainActor
final class HerdrKeyConfig {
    static let shared = HerdrKeyConfig()
    private var checked = Date.distantPast, modified: Date?, cached = PrefixTable.herdrDefaults as PrefixTable?

    /// HERDR_CONFIG_PATH, else $XDG_CONFIG_HOME/herdr, else ~/.config/herdr.
    static var url: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HERDR_CONFIG_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? Home.url.appendingPathComponent(".config")
        return base.appendingPathComponent("herdr/config.toml")
    }

    var table: PrefixTable? {
        let now = Date()
        guard now.timeIntervalSince(checked) > 3 else { return cached }
        checked = now
        let url = Self.url
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard date != modified else { return cached }
        modified = date
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cached = PrefixTable.herdr(config: text)
        return cached
    }
}
