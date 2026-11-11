import AppKit

extension AppDelegate {
    /// A multiplexer's space answers that tool's table (by the name its helper gives it): a tmux space its server's
    /// own table for the space's session (read by its helper when the session shows, until then tmux's defaults), a
    /// local herdr its config.toml; a native space tmux's defaults, as far as Settings lets them.
    func prefixTable(for surface: UUID) -> PrefixTable? {
        guard let space = workspace.spaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(surface) } }) else { return nil }
        let scope = settings.values.prefixKeys
        guard space.structured else { return scope == .all ? PrefixStyle.tmux.table : nil }
        guard scope != .off, let helper = workspace.helper(space),
              let style = space.backend.flatMap({ helper.multiplexer(of: $0) }).flatMap(PrefixStyle.init(rawValue:))
        else { return nil }
        switch style {
        case .tmux:
            // A server whose prefix is None (or a key Dispatch cannot see) has no prefix keys.
            if let node = space.node, let server = helper.prefixTable(session: node) { return server }
            return style.table
        case .herdr: return space.remote == nil ? HerdrKeyConfig.shared.table : style.table
        case .off: return nil
        }
    }

    /// A server binding Dispatch cannot run as tmux would (a program, a size, a target, tmux's own client UI): the
    /// sequence ends there, refused, rather than running something else.
    func rejectPrefix(_ command: String, surface: UUID) {
        let table = prefixTable(for: surface)
        let key = table?.rejected.first { $0.value == command }?.key
        let sequence = [table?.prefix.symbol, key?.symbol].compactMap { $0 }.joined(separator: " ")
        WindowNotes.shared.show("\(sequence.isEmpty ? "This key" : sequence) runs “\(command)”, which Dispatch can't run.")
    }

    /// After every ended sequence in a tmux space the server's table is read again, so a `bind` or `set prefix` made
    /// meanwhile applies from the next one (tmux tells a control client of no option or key table change).
    func refreshPrefixTable(_ surface: UUID) {
        guard let space = workspace.spaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(surface) } }),
              let node = space.node, let helper = workspace.helper(space),
              space.backend.flatMap({ helper.multiplexer(of: $0) }) == PrefixStyle.tmux.rawValue else { return }
        helper.readPrefixTable(session: node)
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
            // A tmux window index is the server's, in this terminal's session (base-index, gaps): the server selects it.
            // A tab still being created (no terminal yet) has no server window to go from.
            if let space = workspace.spaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(surface) } }),
               let helper = workspace.helper(space), space.structured,
               space.backend.flatMap({ helper.multiplexer(of: $0) }) == PrefixStyle.tmux.rawValue {
                if let node = space.tabs.first(where: { $0.surfaceIDs.contains(surface) })?.terminal {
                    helper.selectWindow(node, index: index)
                }
            } else if index > 0 {
                // A native space numbers its tabs as the Tabs number keys do.
                workspace.selectNumberedItem(at: index - 1)
            }
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
            applyLayoutOrExplain(preset)
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
        if let path = System.environment("HERDR_CONFIG_PATH"), !path.isEmpty { return URL(fileURLWithPath: path) }
        let base = System.environment("XDG_CONFIG_HOME").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? System.home.appendingPathComponent(".config")
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
