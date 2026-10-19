import AppKit

/// A fresh install's first question, in the SSH consent sheet's style: will agents run on this Mac? Yes installs
/// the integrations of the agent CLIs found here, or, with none found, shows how to install Claude Code and Codex
/// and sets up the first one a later launch finds. No turns this Mac's agent hooks off. Later asks next launch.
@MainActor
enum LocalAgentsConsent {
    /// "pending" from a fresh install's first launch until answered; "waiting" after a yes that found no CLI;
    /// then "yes" or "no".
    static let key = "localAgentsChoice"

    /// Before the main window saves its frame: no saved frame and no answer is a fresh install.
    static func noteLaunch(frame: String, defaults: UserDefaults? = .app) {
        guard let defaults, defaults.string(forKey: key) == nil,
              defaults.object(forKey: "NSWindow Frame " + frame) == nil else { return }
        defaults.set("pending", forKey: key)
    }

    /// Asks over `window` while the question is pending; after a yes that found nothing, looks again quietly.
    static func start(over window: NSWindow, chat: ChatCoordinator, defaults: UserDefaults? = .app) async {
        guard let defaults else { return }
        switch defaults.string(forKey: key) {
        case "pending":
            let sheet = Sheet(chat: chat)
            await withCheckedContinuation { continuation in
                window.beginSheet(sheet) { _ in continuation.resume() }
                sheet.makeFirstResponder(sheet.yes)
            }
            sheet.orderOut(nil)
            if let answer = sheet.answer { defaults.set(answer, forKey: key) }
        case "waiting":
            guard let found = await installedAgents(), !found.isEmpty else { return }
            chat.adoptLocalAgents(found)
            defaults.set("yes", forKey: key)
        default: return
        }
    }

    /// Launch keys whose CLI runs in the login shell (`--version` succeeds); nil when the shell cannot be asked.
    static func installedAgents() async -> Set<String>? {
        let launches = (try? await HelperClient(HelperApp.shared.connection()).launches()) ?? []
        var programs: [String: String] = [:]
        for launch in launches {
            let program = launch.program ?? launch.key
            if !program.isEmpty, program.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) { programs[program] = launch.key }
        }
        guard !programs.isEmpty else { return [] }
        let probe = """
        for name in \(programs.keys.sorted().joined(separator: " ")); do
          if command -v "$name" >/dev/null 2>&1 && "$name" --version </dev/null >/dev/null 2>&1; then printf 'dispatch-agent:%s\\n' "$name"; fi
        done
        printf 'dispatch-agent:complete\\n'
        """
        // The account's interactive login PATH (zprofile/zshrc, npm's global bin), then the portable probe in sh.
        let login = "exec \"${SHELL:-/bin/zsh}\" -lic " + HerdrLaunch.quote("exec /bin/sh -c " + HerdrLaunch.quote(probe))
        guard let result = try? await SSHCommand.run(executable: "/bin/sh", arguments: ["-c", login], timeout: 30),
              result.status == 0 else { return nil }
        let lines = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.contains("dispatch-agent:complete") else { return nil }
        return Set(programs.filter { lines.contains(Substring("dispatch-agent:" + $0.key)) }.map(\.value))
    }

    /// The npm installs the warning shows when no CLI is found.
    static let guide = [("Claude Code", "npm install -g @anthropic-ai/claude-code"), ("Codex", "npm install -g @openai/codex")]

    typealias Style = SSHIntegrationConsent

    final class Sheet: NSPanel {
        private let chat: ChatCoordinator
        /// The stored answer once the user gave one.
        private(set) var answer: String?
        private(set) var yes: Style.ChoiceButton!
        private var no: Style.ChoiceButton!
        private var stack: NSStackView!
        private var warning: NSStackView!
        private var later: Style.FooterButton!
        private var proceed: Style.FooterButton!
        private var again: Style.FooterButton!
        private var done: Style.FooterButton!
        private var checking = false

        override var canBecomeKey: Bool { true }

        init(chat: ChatCoordinator) {
            self.chat = chat
            super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            appearance = NSAppearance(named: Chrome.palette.isDark ? .darkAqua : .aqua)
            title = "Agents on this Mac"
            let width: CGFloat = 460, inset: CGFloat = 20, contentWidth = width - inset * 2
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = Style.background.cgColor
            content.layer?.cornerRadius = 10
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor(Chrome.border).cgColor
            content.identifier = NSUserInterfaceItemIdentifier("local-agents-options")
            stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "This Mac")
            icon.contentTintColor = NSColor(srgbRed: 126/255, green: 166/255, blue: 201/255, alpha: 1)
            icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            icon.wantsLayer = true
            icon.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.21, alpha: 1).cgColor
            icon.layer?.cornerRadius = 7
            icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
            let heading = Style.label("Agents on this Mac", size: 13, bold: true)
            heading.textColor = Style.foreground
            let subtitle = Style.label("Will you run Claude Code or Codex here?", size: 11)
            for text in [heading, subtitle] { text.widthAnchor.constraint(equalToConstant: contentWidth - 38).isActive = true }
            let titles = NSStackView(views: [heading, subtitle])
            titles.orientation = .vertical
            titles.alignment = .leading
            titles.spacing = 2
            let header = NSStackView(views: [icon, titles])
            header.spacing = 10
            header.alignment = .centerY
            stack.addArrangedSubview(header)

            let rows = NSStackView()
            rows.orientation = .vertical
            rows.spacing = 0
            rows.wantsLayer = true
            rows.layer?.backgroundColor = NSColor(Chrome.sidebar).cgColor
            rows.layer?.cornerRadius = 8
            rows.layer?.borderWidth = 1
            rows.layer?.borderColor = Style.accent.withAlphaComponent(0.35).cgColor
            yes = Style.ChoiceButton(title: "Yes, I’ll use agents on this Mac", detail: "sets up Chat hooks for the agents installed here",
                                     parent: true, note: nil, radio: true)
            no = Style.ChoiceButton(title: "No, only remotely or not at all", detail: "leaves this Mac’s agent settings untouched",
                                    parent: true, last: true, note: nil, radio: true)
            for (button, identifier) in [(yes!, "local-agents-yes"), (no!, "local-agents-no")] {
                button.target = self
                button.action = #selector(choose(_:))
                button.setAccessibilityIdentifier(identifier)
                button.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
                button.heightAnchor.constraint(equalToConstant: 56).isActive = true
                rows.addArrangedSubview(button)
            }
            yes.state = .on
            stack.addArrangedSubview(rows)
            let explanation = Style.label("SSH hosts ask for themselves. Change this later in Settings › Agents & Hosts.", size: 11)
            explanation.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(explanation)

            warning = Self.warning(width: contentWidth)
            warning.isHidden = true
            stack.addArrangedSubview(warning)

            let separator = NSBox()
            separator.boxType = .separator
            separator.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(separator)
            let footer = NSStackView()
            footer.spacing = 8
            footer.alignment = .centerY
            footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            later = Style.FooterButton(title: "Ask later", shortcut: "esc", identifier: "local-agents-later")
            later.target = self
            later.action = #selector(cancelOperation(_:))
            footer.addArrangedSubview(later)
            footer.addArrangedSubview(NSView())
            again = Style.FooterButton(title: "Check again", identifier: "local-agents-check")
            again.target = self
            again.action = #selector(checkAgain(_:))
            again.isHidden = true
            footer.addArrangedSubview(again)
            proceed = Style.FooterButton(title: "Continue", shortcut: "⏎", identifier: "local-agents-continue", primary: true)
            proceed.target = self
            proceed.action = #selector(save(_:))
            footer.addArrangedSubview(proceed)
            done = Style.FooterButton(title: "Done", shortcut: "⏎", identifier: "local-agents-done", primary: true)
            done.target = self
            done.action = #selector(finish(_:))
            done.isHidden = true
            footer.addArrangedSubview(done)
            stack.addArrangedSubview(footer)
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

        /// No CLI found: what to install, as commands to copy.
        private static func warning(width: CGFloat) -> NSStackView {
            let title = Style.label("⚠ No Claude Code or Codex CLI found on this Mac", size: 12, bold: true)
            title.textColor = NSColor(Chrome.palette.warning)
            let detail = Style.label("Dispatch looked in your login shell’s PATH. Install one with npm, then check again:", size: 11)
            let commands = NSTextField(labelWithString: guide.map { $0.1 }.joined(separator: "\n"))
            commands.font = Style.font(size: 11.5, bold: false)
            commands.textColor = Style.foreground
            commands.isSelectable = true
            commands.maximumNumberOfLines = 0
            commands.setAccessibilityIdentifier("local-agents-guide")
            commands.translatesAutoresizingMaskIntoConstraints = false
            let code = NSStackView(views: [commands])
            code.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            code.wantsLayer = true
            code.layer?.backgroundColor = NSColor(Chrome.sidebar).cgColor
            code.layer?.cornerRadius = 6
            code.layer?.borderWidth = 1
            code.layer?.borderColor = NSColor(Chrome.border).cgColor
            let footnote = Style.label("npm comes with Node.js (brew install node). Dispatch sets up the first agent it finds on a later launch.", size: 11)
            for view in [title, detail, code, footnote] { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
            let warning = NSStackView(views: [title, detail, code, footnote])
            warning.orientation = .vertical
            warning.alignment = .leading
            warning.spacing = 6
            warning.setAccessibilityIdentifier("local-agents-warning")
            return warning
        }

        @objc private func choose(_ sender: NSButton) {
            guard !checking, done.isHidden else { return }
            yes.state = sender === yes ? .on : .off
            no.state = sender === no ? .on : .off
            yes.needsDisplay = true; no.needsDisplay = true
        }

        @objc private func save(_ sender: Any?) {
            guard !checking, !proceed.isHidden else { return }
            guard yes.state == .on else {
                chat.adoptLocalAgents(nil)
                return end("no")
            }
            check()
        }

        @objc private func checkAgain(_ sender: Any?) { if !checking { check() } }

        /// Yes: the agents found are set up and the sheet closes; with none, it warns and stays.
        private func check() {
            checking = true
            for button in [proceed, again, done, later] { button?.isEnabled = false }
            Task { @MainActor in
                let found = await LocalAgentsConsent.installedAgents()
                checking = false
                for button in [proceed, again, done, later] { button?.isEnabled = true }
                if let found, !found.isEmpty {
                    chat.adoptLocalAgents(found)
                    return end("yes")
                }
                // Unknown (the shell could not be asked) warns like none found; a later launch looks again.
                answer = "waiting"
                showWarning()
            }
        }

        private func showWarning() {
            guard warning.isHidden else { return }
            warning.isHidden = false
            proceed.isHidden = true; later.isHidden = true
            again.isHidden = false; done.isHidden = false
            yes.isEnabled = false; no.isEnabled = false
            stack.layoutSubtreeIfNeeded()
            let height = ceil(stack.fittingSize.height) + 32
            var frame = self.frame
            frame.origin.y -= height - frame.height
            frame.size.height = height
            setFrame(frame, display: true, animate: false)
            makeFirstResponder(done)
        }

        @objc private func finish(_ sender: Any?) { end("waiting") }

        private func end(_ value: String) {
            answer = value
            sheetParent?.endSheet(self)
        }

        override func cancelOperation(_ sender: Any?) {
            guard !checking else { return }
            if !done.isHidden { return end("waiting") }
            answer = nil
            sheetParent?.endSheet(self, returnCode: .cancel)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if event.keyCode == 36 || event.keyCode == 76 { done.isHidden ? save(nil) : finish(nil); return true }
                if event.keyCode == 53 { cancelOperation(nil); return true }
                if event.keyCode == 125 || event.keyCode == 126, done.isHidden {
                    choose(event.keyCode == 125 ? no : yes); makeFirstResponder(event.keyCode == 125 ? no : yes); return true
                }
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
