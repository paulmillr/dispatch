import AppKit

/// Resolve numbered navigation by physical key so shifted symbols and keyboard
/// layouts keep selecting the expected tab, pane, or space.
final class ApplicationMenu: NSMenu {
    static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// The digit chords of Settings › Keys (⇧⌘1…9 spaces, ⌘1…9 tabs, ⌃1…4 layouts by default) and
    /// ⌃⇥ / ⌃⇧⇥ cycling tabs; a focused terminal yields these to the app instead of sending them to the shell.
    @MainActor static func claimsShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                          groups: KeyGroups = KeyGroupsStore.shared.current) -> Bool {
        let flags = modifiers.intersection(KeyGroups.modifierMask)
        // An unbound group (no modifiers) claims nothing: its digits are typing.
        return (digitKeyCodes.contains(keyCode) && [groups.spaces, groups.tabs, groups.splits].contains { !$0.isEmpty && $0 == flags })
            || (keyCode == 48 && (flags == .control || flags == [.control, .shift]))
    }

    /// The digits (with `modifiers`, ⌃ by default) that Mission Control's enabled "Switch to Desktop N"
    /// shortcuts (symbolic hot keys 118…126: [character, key code, modifiers]; no value means the default ⌃N)
    /// take before Dispatch sees them.
    static func desktopShortcutConflicts(_ hotKeys: [String: Any]? = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
        .dictionary(forKey: "AppleSymbolicHotKeys"), modifiers: NSEvent.ModifierFlags = .control) -> [Int] {
        let control = Int(NSEvent.ModifierFlags.control.rawValue)
        return (118...126).compactMap { id -> Int? in
            guard let entry = hotKeys?[String(id)] as? [String: Any], (entry["enabled"] as? Bool) == true else { return nil }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int]
                ?? [65535, Int(digitKeyCodes[id - 118]), control]
            guard parameters.count == 3,
                  NSEvent.ModifierFlags(rawValue: UInt(clamping: parameters[2])).intersection(KeyGroups.modifierMask) == modifiers,
                  let index = digitKeyCodes.firstIndex(of: UInt16(clamping: parameters[1])) else { return nil }
            return index + 1
        }
    }
    private let navigationHandler: @MainActor @Sendable (UInt16, NSEvent.ModifierFlags) -> Bool?

    init(navigationHandler: @escaping @MainActor @Sendable (UInt16, NSEvent.ModifierFlags) -> Bool?) {
        self.navigationHandler = navigationHandler
        super.init(title: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit dispatches menu key events on the main thread; NSMenu's
        // Objective-C declaration does not carry that actor annotation.
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags
        if MainActor.assumeIsolated({
            (NSApp.keyWindow?.firstResponder as? ChatEditorTextView)?
                .reservesMultilineShortcut(keyCode: keyCode, modifiers: modifiers) == true
        }) { return false }
        let handler = navigationHandler
        if let handled = MainActor.assumeIsolated({ handler(keyCode, modifiers) }) { return handled }
        return super.performKeyEquivalent(with: event)
    }
}

extension AppDelegate {
    func buildMenus() {
        let main = ApplicationMenu { [weak self] keyCode, modifiers in
            self?.handleNavigationKey(keyCode: keyCode, modifiers: modifiers)
        }
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let result = NSMenu(title: title); item.submenu = result; main.addItem(item); return result
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, tag: Int = 0, hidden: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            item.tag = tag
            item.isHidden = hidden
            item.allowsKeyEquivalentWhenHidden = hidden
            menu.addItem(item)
        }
        let app = menu("Dispatch")
        add(app, "About Dispatch", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings), ",", target: self)
        app.addItem(.separator())
        add(app, "Hide Dispatch", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Quit Dispatch", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("File")
        add(file, "New Space", #selector(newSpace), "n", target: self)
        add(file, "New Local Space", #selector(newLocalSpace), "N", [.command, .shift], target: self)
        add(file, "New Tab", #selector(newTab), "t", target: self)
        file.addItem(.separator())
        add(file, "Rename Space…", #selector(renameSpace), target: self)
        add(file, "Rename Tab…", #selector(renameTab), target: self)
        file.addItem(.separator())
        add(file, "Close Tab", #selector(closeCurrentTab), "w", target: self)
        add(file, "Close Space", #selector(closeCurrentSpace), "W", [.command, .shift], target: self)
        add(file, "Detach Session", #selector(detachCurrent), target: self)
        let edit = menu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(findInContent), "f", target: self)
        add(edit, "Find Next", #selector(findNext), "g", target: self)
        add(edit, "Find Previous", #selector(findPrevious), "G", [.command, .shift], target: self)
        edit.addItem(.separator())
        add(edit, "Clear Screen", #selector(clearScreen), "k", target: self)
        let view = menu("View")
        add(view, "Increase Font Size", #selector(increaseFontSize), "+", target: self)
        add(view, "Increase Font Size", #selector(increaseFontSize), "=", target: self, hidden: true)
        add(view, "Increase Font Size", #selector(increaseFontSize), "+", [.command, .shift], target: self, hidden: true)
        add(view, "Decrease Font Size", #selector(decreaseFontSize), "-", target: self)
        add(view, "Reset Font Size", #selector(resetFontSize), "0", target: self)
        view.addItem(.separator())
        add(view, "Toggle Sidebar", #selector(toggleSidebar), "s", [.control, .command], target: self)
        add(view, "Toggle Sidebar", #selector(toggleSidebar), "\\", target: self, hidden: true)
        for (index, preset) in LayoutPreset.allCases.enumerated() {
            add(view, preset.title.capitalized, #selector(applyLayout(_:)), preset.shortcutKey ?? "", [], target: self, tag: index)
        }
        view.addItem(.separator())
        add(view, "Switch Terminal / Chat", #selector(toggleChat), "C", [.command, .shift], target: self)
        add(view, "Split Right", #selector(splitColumns), "d", target: self)
        add(view, "Split Down", #selector(splitRows), "D", [.command, .shift], target: self)
        add(view, "Move Tab to Next Pane", #selector(moveTabToNextPane), target: self)
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        let navigate = menu("Navigate")
        add(navigate, "Search Spaces", #selector(focusSpaceSearch), "p", target: self)
        navigate.addItem(.separator())
        add(navigate, "Next Attention", #selector(nextAttention), "j", target: self)
        add(navigate, "Previous Attention", #selector(previousAttention), "J", [.command, .shift], target: self)
        navigate.addItem(.separator())
        // Their keys follow Settings › Keys (applyKeyGroups).
        add(navigate, "Previous Space", #selector(previousSpace), "[", target: self)
        add(navigate, "Next Space", #selector(nextSpace), "]", target: self)
        navigate.addItem(.separator())
        add(navigate, "Previous Tab", #selector(previousTab), "[", target: self)
        add(navigate, "Next Tab", #selector(nextTab), "]", target: self)
        add(navigate, "Previous Pane", #selector(previousPane), "[", KeyGroups.paneStep, target: self)
        add(navigate, "Next Pane", #selector(nextPane), "]", KeyGroups.paneStep, target: self)
        navigate.addItem(.separator())
        for number in 1...9 {
            add(navigate, number == 9 ? "Last Space" : "Space \(number)", #selector(selectSpace(_:)), String(number), [], target: self, tag: number - 1)
        }
        navigate.addItem(.separator())
        for number in 1...9 {
            add(navigate, "Tab \(number)", #selector(selectNumberedItem(_:)), String(number), [], target: self, tag: number - 1)
        }
        let windows = menu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = windows
        let help = menu("Help")
        add(help, "Keyboard Shortcuts", #selector(showKeyboardShortcuts), "/", target: self)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
        applyKeyGroups(settings.values.keyGroups)
    }

    /// Settings › Keys' modifiers on the numbered Space, Tab and layout items, and on stepping through spaces and tabs
    /// with [ and ] (KeyGroups.steps); an item whose chord is taken has none.
    func applyKeyGroups(_ groups: KeyGroups) {
        let steps = groups.steps
        func digit(_ item: NSMenuItem, _ modifiers: NSEvent.ModifierFlags, key: String) {
            // An unbound group's items have no key, so its digits keep typing.
            item.keyEquivalent = modifiers.isEmpty ? "" : key
            item.keyEquivalentModifierMask = modifiers
        }
        func step(_ item: NSMenuItem, _ modifiers: NSEvent.ModifierFlags?, next: Bool) {
            // With ⇧ the key is the shifted bracket, the character AppKit matches.
            let shifted = modifiers?.contains(.shift) == true
            item.keyEquivalent = modifiers == nil ? "" : next ? (shifted ? "}" : "]") : (shifted ? "{" : "[")
            item.keyEquivalentModifierMask = modifiers ?? []
        }
        for item in NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? [] {
            switch item.action {
            case #selector(selectSpace(_:)): digit(item, groups.spaces, key: String(item.tag + 1))
            case #selector(selectNumberedItem(_:)): digit(item, groups.tabs, key: String(item.tag + 1))
            case #selector(applyLayout(_:)): digit(item, groups.splits, key: LayoutPreset.allCases[item.tag].shortcutKey ?? "")
            case #selector(previousSpace): step(item, steps.spaces, next: false)
            case #selector(nextSpace): step(item, steps.spaces, next: true)
            case #selector(previousTab): step(item, steps.tabs, next: false)
            case #selector(nextTab): step(item, steps.tabs, next: true)
            default: break
            }
        }
    }

    @objc func increaseFontSize() { setFontSize(settings.values.fontSize + 1) }
    @objc func findInContent() {
        guard let id = workspace.activeSurfaceID else { return }
        let runtime = TerminalRuntime.shared, session = runtime.chat.session(for: id)
        if session.showChat { session.search.open() }
        else { runtime.views[id]?.performBindingAction("start_search") }
    }
    @objc func findNext() {
        guard let id = workspace.activeSurfaceID else { return }
        let session = TerminalRuntime.shared.chat.session(for: id)
        (session.showChat ? session.search : session.terminalSearch).move(1)
    }
    @objc func clearScreen() {
        guard let id = workspace.activeSurfaceID else { return }
        _ = TerminalRuntime.shared.views[id]?.performBindingAction("clear_screen")
    }
    @objc func findPrevious() {
        guard let id = workspace.activeSurfaceID else { return }
        let session = TerminalRuntime.shared.chat.session(for: id)
        (session.showChat ? session.search : session.terminalSearch).move(-1)
    }
    @objc func decreaseFontSize() { setFontSize(settings.values.fontSize - 1) }
    @objc func resetFontSize() { setFontSize(Preferences().fontSize) }

    private func setFontSize(_ size: Double) {
        let old = settings.values
        var next = old
        next.fontSize = min(32, max(8, size))
        guard next != old else { return }
        do {
            try TerminalRuntime.shared.apply(next)
            do { try settings.save(next) }
            catch { try? TerminalRuntime.shared.apply(old); throw error }
        } catch {
            settings.error = error.localizedDescription
            NSApp.presentError(error)
        }
    }

    func handleNavigationKey(keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags) -> Bool? {
        let modifiers = flags.intersection(KeyGroups.modifierMask), groups = settings.values.keyGroups
        // Claimed even when there is nothing to select, so these chords never reach a shell.
        if keyCode == 48 && (modifiers == .control || modifiers == [.control, .shift]) {
            guard NSApp.keyWindow === window else { return nil }
            workspace.cycleTab(modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        guard let index = ApplicationMenu.digitKeyCodes.firstIndex(of: keyCode) else { return nil }
        // Unbound groups (no modifiers) never match: plain digits are typing.
        if !groups.spaces.isEmpty, modifiers == groups.spaces {
            guard NSApp.keyWindow === window else { return nil }
            workspace.selectSpace(at: index)
            return true
        }
        // Layouts (⌃1…4 by default) always apply here, even when they do not fit.
        if !groups.splits.isEmpty, modifiers == groups.splits, let preset = LayoutPreset.shortcut(keyCode: keyCode) {
            guard NSApp.keyWindow === window else { return nil }
            workspace.applyLayout(preset)
            return true
        }
        guard !groups.tabs.isEmpty, modifiers == groups.tabs else { return nil }
        guard NSApp.keyWindow === window else { return false }
        guard workspace.current?.usesPaneShortcuts != true || index < 4 else { return nil }
        workspace.selectNumberedItem(at: index)
        return true
    }
}
