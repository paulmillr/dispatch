import AppKit

/// The permission store owns prompt deduplication and persistence. Only Save or
/// Connect commits the draft; closing the sheet never implies an installation grant.
@MainActor
enum SSHIntegrationConsent {
    static func presentHooks(_ agent: SSHHookAgent, scope: SSHIntegrationScope) async -> Bool? {
        guard !Task.isCancelled, let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let alert = NSAlert()
        alert.messageText = "Set up \(agent.rawValue) Chat on \(scope.destination)?"
        alert.informativeText = "\(agent.rawValue) is installed. Dispatch can add its Chat hooks to this remote account’s agent configuration before it starts. Your choice is remembered for this agent and SSH configuration."
        alert.addButton(withTitle: "Install hooks")
        alert.addButton(withTitle: "Don’t install")
        alert.addButton(withTitle: "Cancel")
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                if Task.isCancelled { window.endSheet(alert.window, returnCode: .cancel) }
            }
        } onCancel: {
            Task { @MainActor in window.endSheet(alert.window, returnCode: .cancel) }
        }
        guard !Task.isCancelled else { return nil }
        switch response {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    struct ConnectionState: Equatable {
        var grants: [SSHIntegrationGrant] = []
        var requirements: Set<SSHIntegrationFeature> = []
        var status: String {
            grants.first.map { "Connected · helper running · \($0.selectedFeatures.count) features on" }
                ?? "Disconnected · remembered for this SSH config"
        }
    }

    static func present(_ scope: SSHIntegrationScope, current: SSHIntegrationGrant? = nil,
                        agents: [SSHHookAgent: Bool] = [:],
                        window requestedWindow: NSWindow? = nil,
                        status: String? = nil, reconnect: (() -> Void)? = nil,
                        reconnectRequirements: Set<SSHIntegrationFeature> = [],
                        activeGrants: [SSHIntegrationGrant]? = nil,
                        connectionState: (() -> ConnectionState)? = nil) async -> SSHIntegrationSelection? {
        let candidate = requestedWindow ?? NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard !Task.isCancelled, let window = candidate else { return nil }
        let sheet = ConsentSheet(scope: scope, current: current, agents: agents, status: status, allowsReconnect: reconnect != nil, reconnectRequirements: reconnectRequirements, activeGrants: activeGrants, connectionState: connectionState)
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak sheet] _ in
            MainActor.assumeIsolated { sheet?.cancelOperation(nil) }
        }
        defer { NotificationCenter.default.removeObserver(closing) }
        // Sessions and native consumers can change in other tabs while this
        // AppKit sheet is open. Poll only for its lifetime; unchanged snapshots
        // do not update controls. Activation also revalidates synchronously.
        let updates = connectionState.map { _ in Task { @MainActor in
            while !Task.isCancelled {
                sheet.updateConnectionState()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        } }
        defer { updates?.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                window.beginSheet(sheet) { _ in continuation.resume() }
                sheet.makeFirstResponder(sheet.helper)
                if Task.isCancelled { sheet.cancelOperation(nil) }
            }
        } onCancel: {
            Task { @MainActor in sheet.cancelOperation(nil) }
        }
        sheet.orderOut(nil)
        guard !Task.isCancelled else { return nil }
        if sheet.reconnectRequested { reconnect?() }
        return sheet.selection
    }

    private static var background: NSColor { NSColor(Chrome.window) }
    private static var foreground: NSColor { NSColor(Chrome.ink) }
    private static var muted: NSColor { Chrome.palette.isDark ? NSColor(srgbRed: 111/255, green: 111/255, blue: 120/255, alpha: 1) : NSColor(Chrome.muted) }
    private static var accent: NSColor { NSColor(Chrome.accent) }

    private static func font(size: CGFloat, bold: Bool) -> NSFont { AppFont.native(size: size, semibold: bold) }

    private static func label(_ text: String, size: CGFloat, bold: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font(size: size, bold: bold)
        label.textColor = muted
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private final class ConsentSheet: NSPanel {
        /// Two permissions, then one row per agent answering its Chat-hook
        /// question up front. Chat transcripts, tmux and herdr come with the helper.
        private typealias Row = SSHIntegrationDraft.Choice
        private(set) var selection: SSHIntegrationSelection?
        private(set) var reconnectRequested = false
        private(set) var helper: ChoiceButton!
        private var choices: [Row: ChoiceButton] = [:]
        private var draft: SSHIntegrationDraft
        private var reconnectButton: NSButton?
        private var defaultsButton: NSButton?
        private var reconnectRequirements: Set<SSHIntegrationFeature>
        private var activeGrants: [SSHIntegrationGrant]
        private let connectionState: (() -> ConnectionState)?
        private var lastConnectionState: ConnectionState?
        private var connectionLabel: NSTextField?
        private var liveBadge: NSTextField?

        override var canBecomeKey: Bool { true }

        init(scope: SSHIntegrationScope, current: SSHIntegrationGrant?, agents: [SSHHookAgent: Bool], status: String?, allowsReconnect: Bool, reconnectRequirements: Set<SSHIntegrationFeature>, activeGrants: [SSHIntegrationGrant]?, connectionState: (() -> ConnectionState)?) {
            self.connectionState = connectionState
            self.reconnectRequirements = reconnectRequirements
            self.activeGrants = activeGrants ?? current.map { [$0] } ?? []
            draft = SSHIntegrationDraft(current: current, agents: agents)
            super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            appearance = NSAppearance(named: Chrome.palette.isDark ? .darkAqua : .aqua)
            title = "SSH integration for \(scope.destination)"
            let width: CGFloat = 460, inset: CGFloat = 20, contentWidth = width - inset * 2
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = background.cgColor
            content.layer?.cornerRadius = 10
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor(Chrome.border).cgColor
            content.identifier = NSUserInterfaceItemIdentifier("ssh-integration-options")
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: "SSH host")
            icon.contentTintColor = NSColor(srgbRed: 126/255, green: 166/255, blue: 201/255, alpha: 1)
            icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
            icon.wantsLayer = true
            icon.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.21, alpha: 1).cgColor
            icon.layer?.cornerRadius = 7
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            // Keep the full account and configuration in the authorization scope.
            let host = scope.destination.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? scope.destination
            let heading = label(current == nil ? "Connect to \(host)" : "Helper on \(host)", size: 13, bold: true)
            heading.textColor = foreground
            heading.maximumNumberOfLines = 2
            heading.lineBreakMode = .byTruncatingMiddle
            heading.toolTip = scope.destination
            let account = label(status ?? "Remembered for this SSH config", size: 11)
            connectionLabel = account
            account.toolTip = "SSH account: \(scope.account)"
            account.maximumNumberOfLines = 2
            let titles = NSStackView(views: [heading, account])
            titles.orientation = .vertical
            titles.alignment = .leading
            titles.spacing = 2
            let live = status?.hasPrefix("Connected") == true || connectionState != nil
            for text in [heading, account] { text.widthAnchor.constraint(equalToConstant: contentWidth - (live ? 88 : 38)).isActive = true }
            let header = NSStackView(views: [icon, titles])
            header.spacing = 10
            header.alignment = .centerY
            if live {
                let badge = label("● live", size: 11)
                liveBadge = badge
                badge.textColor = NSColor(srgbRed: 127/255, green: 211/255, blue: 161/255, alpha: 1)
                badge.setAccessibilityLabel("Helper connected")
                header.addArrangedSubview(badge)
            }
            stack.addArrangedSubview(header)

            let rows = NSStackView()
            rows.orientation = .vertical
            rows.spacing = 0
            rows.wantsLayer = true
            rows.layer?.backgroundColor = NSColor(Chrome.sidebar).cgColor
            rows.layer?.cornerRadius = 8
            rows.layer?.borderWidth = 1
            rows.layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
            helper = ChoiceButton(title: "Upload the Dispatch helper", detail: "to ~/.dispatch/bin/<hash>/dsptch", parent: true)
            let helperPathHelp = "Installed in your home directory on the SSH host. <hash> is the helper binary’s SHA-256 hash, used to verify and reuse cached copies."
            helper.toolTip = helperPathHelp
            helper.setAccessibilityHelp(helperPathHelp)
            helper.target = self
            helper.action = #selector(toggleHelper(_:))
            helper.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            helper.heightAnchor.constraint(equalToConstant: 76).isActive = true
            rows.addArrangedSubview(helper)
            for row in Row.all {
                let button = ChoiceButton(title: row.title, detail: row.detail, last: row == Row.all.last)
                button.target = self
                button.action = #selector(toggleFeature(_:))
                button.setAccessibilityIdentifier(Self.identifier(row))
                if case .agent(let agent) = row {
                    button.toolTip = "Install \(row.title) Chat hooks in this account’s \(agent.rawValue) configuration when it starts."
                }
                button.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
                button.heightAnchor.constraint(equalToConstant: 36).isActive = true
                choices[row] = button
                rows.addArrangedSubview(button)
            }
            stack.addArrangedSubview(rows)
            let explanation = label((current == nil ? "Uncheck the helper to connect with plain SSH." :
                "Reductions apply now. Additions apply on your next connection. The helper stays cached when disabled.")
                + " Chat transcripts, tmux and herdr integration come with the helper.", size: 11)
            explanation.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(explanation)
            let separator = NSBox()
            separator.boxType = .separator
            separator.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(separator)
            let footer = NSStackView()
            footer.spacing = 8
            footer.alignment = .centerY
            footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            if current != nil {
                let defaults = FooterButton(title: "Use defaults", identifier: "ssh-consent-reset")
                defaultsButton = defaults
                defaults.target = self
                defaults.action = #selector(useDefaults(_:))
                footer.addArrangedSubview(defaults)
            }
            footer.addArrangedSubview(NSView())
            if current == nil {
                let cancel = FooterButton(title: "Don't connect", shortcut: "esc", identifier: "ssh-consent-cancel")
                cancel.target = self
                cancel.action = #selector(cancelOperation(_:))
                cancel.keyEquivalent = "\u{1b}"
                cancel.keyEquivalentModifierMask = []
                footer.addArrangedSubview(cancel)
            } else if allowsReconnect {
                let reconnect = FooterButton(title: "Save & reconnect", identifier: "ssh-consent-reconnect")
                reconnectButton = reconnect
                reconnect.target = self
                reconnect.action = #selector(saveAndReconnect(_:))
                footer.addArrangedSubview(reconnect)
            }
            let save = FooterButton(title: current == nil ? "Connect" : "Save", shortcut: "⏎",
                                    identifier: "ssh-consent-save", primary: true)
            save.target = self
            save.action = #selector(save(_:))
            save.keyEquivalent = "\r"
            save.keyEquivalentModifierMask = []
            footer.addArrangedSubview(save)
            defaultButtonCell = save.cell as? NSButtonCell
            stack.addArrangedSubview(footer)
            refresh()
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
            ])
            content.frame = NSRect(x: 0, y: 0, width: width, height: ceil(stack.fittingSize.height) + 32)
            contentView = content
            setContentSize(content.frame.size)
        }

        private static func identifier(_ row: Row) -> String {
            switch row {
            case .stats: "ssh-feature-statistics"
            case .files: "ssh-feature-files"
            case .agent(let agent): "ssh-agent-" + agent.rawValue
            }
        }
        func updateConnectionState() {
            guard let value = connectionState?(), value != lastConnectionState else { return }
            lastConnectionState = value
            activeGrants = value.grants; reconnectRequirements = value.requirements
            connectionLabel?.stringValue = value.status
            liveBadge?.isHidden = value.grants.isEmpty
            refresh()
        }

        private func refresh() {
            let focusedButton = firstResponder as? NSButton
            let usingDefaults = draft.isDefault
            defaultsButton?.isEnabled = !usingDefaults
            defaultsButton?.toolTip = usingDefaults ? "Already using defaults" : "Select all features. Save to apply."
            defaultsButton?.needsDisplay = true
            let needsReconnect = draft.needsReconnect(activeGrants)
            reconnectButton?.isHidden = !needsReconnect
            reconnectButton?.isEnabled = needsReconnect && reconnectRequirements.isSubset(of: draft.features)
            reconnectButton?.toolTip = reconnectButton?.isEnabled == true ? nil :
                "Save these settings for a new SSH connection. Reconnecting existing native sessions requires their helper features."
            helper.state = draft.helper ? .on : .off
            helper.needsDisplay = true
            for (row, button) in choices {
                button.state = draft.checked.contains(row) ? .on : .off
                button.isEnabled = draft.helper
                button.needsDisplay = true
            }
            if let focusedButton, focusedButton.isHiddenOrHasHiddenAncestor || !focusedButton.isEnabled { makeFirstResponder(helper) }
        }

        @objc private func toggleHelper(_ sender: NSButton) {
            draft.toggleHelper()
            refresh()
        }

        @objc private func toggleFeature(_ sender: NSButton) {
            guard let row = choices.first(where: { $0.value === sender })?.key else { return }
            draft.toggle(row)
            refresh()
        }

        @objc private func useDefaults(_ sender: Any?) {
            draft.useDefaults()
            refresh()
        }

        @objc private func save(_ sender: Any?) {
            guard let parent = sheetParent else { return }
            selection = draft.selection
            parent.endSheet(self)
        }

        @objc private func saveAndReconnect(_ sender: Any?) {
            updateConnectionState()
            guard reconnectButton?.isHidden == false, reconnectButton?.isEnabled == true else { return }
            reconnectRequested = true
            save(sender)
        }

        override func cancelOperation(_ sender: Any?) {
            guard let parent = sheetParent else { return }
            selection = nil
            parent.endSheet(self, returnCode: .cancel)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if [36, 76, 53].contains(event.keyCode),
               !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { return true }
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if event.keyCode == 36 || event.keyCode == 76 { save(nil); return true }
                if event.keyCode == 53 { cancelOperation(nil); return true }
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                if [36, 76, 53].contains(event.keyCode) { return }
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 { save(nil) }
            else if event.keyCode == 53 { cancelOperation(nil) }
            else { super.keyDown(with: event) }
        }
    }

    private final class FooterButton: NSButton {
        private let shortcut: String?
        private let primary: Bool
        init(title: String, shortcut: String? = nil, identifier: String, primary: Bool = false) {
            self.primary = primary
            self.shortcut = shortcut
            super.init(frame: .zero)
            self.title = title
            isBordered = false
            setButtonType(.momentaryPushIn)
            setAccessibilityLabel(title)
            setAccessibilityIdentifier(identifier)
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: ceil((title as NSString).size(withAttributes: [.font: AppFont.native(size: 12)]).width) + 24 + (shortcut == nil ? 0 : 26)).isActive = true
            heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            (primary ? accent : NSColor(Chrome.palette.control)).setFill(); path.fill()
            NSColor(Chrome.palette.controlBorder).setStroke(); path.stroke()
            let text = title as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.native(size: 12), .foregroundColor: primary ? background : foreground]
            let height = text.size(withAttributes: attributes).height
            text.draw(at: NSPoint(x: 12, y: bounds.midY - height / 2), withAttributes: attributes)
            if let shortcut {
                (shortcut as NSString).draw(at: NSPoint(x: bounds.maxX - 32, y: bounds.midY - height / 2),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: primary ? background.withAlphaComponent(0.7) : muted])
            }
        }
    }

    /// Real AppKit buttons provide keyboard and accessibility activation. The
    /// whole row is clickable, including its explanatory text.
    private final class ChoiceButton: NSButton {
        private let detail: String
        private let parent: Bool
        private let last: Bool
        private var hovered = false
        private var tracking: NSTrackingArea?

        init(title: String, detail: String, parent: Bool = false, last: Bool = false) {
            self.detail = detail
            self.parent = parent
            self.last = last
            super.init(frame: .zero)
            self.title = title
            isBordered = false
            setButtonType(.switch)
            // The row draws its own focus outline; the native switch ring is
            // positioned at the cell's checkbox, outside our custom checkbox.
            focusRingType = .none
            setAccessibilityLabel(title)
            setAccessibilityHelp(detail)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { isEnabled }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 {
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
                performClick(nil)
            }
            else { super.keyDown(with: event) }
        }
        override func draw(_ dirtyRect: NSRect) {
            let enabled: CGFloat = isEnabled ? 1 : 0.35
            if parent || (hovered && isEnabled) {
                (parent ? accent.withAlphaComponent(state == .on ? 0.08 : 0.02) : foreground.withAlphaComponent(0.03)).setFill()
                bounds.fill()
            }
            if parent {
                accent.withAlphaComponent(0.25).setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5)); line.line(to: NSPoint(x: bounds.width, y: bounds.maxY - 0.5)); line.stroke()
            } else {
                accent.withAlphaComponent(0.35 * enabled).setStroke()
                let tree = NSBezierPath()
                tree.lineWidth = 1.5
                tree.move(to: NSPoint(x: 28, y: 0))
                tree.line(to: NSPoint(x: 28, y: last ? bounds.midY : bounds.maxY))
                tree.move(to: NSPoint(x: 28, y: bounds.midY)); tree.line(to: NSPoint(x: 39, y: bounds.midY))
                tree.stroke()
            }
            let box = NSRect(x: parent ? 22 : 52, y: bounds.midY - 8, width: 16, height: 16)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            if state == .on {
                accent.withAlphaComponent(enabled).setFill(); path.fill()
                background.withAlphaComponent(enabled).setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.move(to: NSPoint(x: box.minX + 4, y: box.minY + 8))
                check.line(to: NSPoint(x: box.minX + 7, y: box.minY + 11))
                check.line(to: NSPoint(x: box.minX + 12, y: box.minY + 5)); check.stroke()
            } else {
                foreground.withAlphaComponent(0.25 * enabled).setStroke(); path.lineWidth = 1.5; path.stroke()
            }
            let x: CGFloat = parent ? 50 : 80
            let nameAttributes: [NSAttributedString.Key: Any] = [.font: SSHIntegrationConsent.font(size: 12.5, bold: parent),
                .foregroundColor: (state == .on ? foreground : NSColor(Chrome.muted)).withAlphaComponent(enabled)]
            let detailAttributes: [NSAttributedString.Key: Any] = [.font: SSHIntegrationConsent.font(size: 11, bold: false), .foregroundColor: muted.withAlphaComponent(enabled)]
            let nameHeight = (title as NSString).size(withAttributes: nameAttributes).height
            (title as NSString).draw(at: NSPoint(x: x, y: parent ? bounds.midY - 27 : bounds.midY - nameHeight / 2), withAttributes: nameAttributes)
            if parent {
                (detail as NSString).draw(at: NSPoint(x: x, y: bounds.midY - 9), withAttributes: detailAttributes)
                ("opens no ports · writes no files" as NSString).draw(at: NSPoint(x: x, y: bounds.midY + 7), withAttributes: detailAttributes)
            } else {
                let size = (detail as NSString).size(withAttributes: detailAttributes)
                (detail as NSString).draw(at: NSPoint(x: bounds.maxX - 14 - size.width, y: bounds.midY - size.height / 2), withAttributes: detailAttributes)
            }
            if window?.firstResponder === self {
                accent.withAlphaComponent(0.7).setStroke()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).stroke()
            }
        }
    }
}
