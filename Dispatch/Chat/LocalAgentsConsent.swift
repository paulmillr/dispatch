import AppKit
import SwiftUI

/// The first-launch setup sheet, in the SSH consent sheet's style. A fresh install pages through what to type for Chat
/// (an agent in any tab), for tabs (`tmux -CC`, `herdr`, `ssh`), then answers two questions: will agents run on this Mac,
/// and should Dispatch keep itself up to date. Back, the steps (Chat · Tabs · Prefs) and Next move between the pages;
/// Skip (Escape) on the first two goes to the questions. Yes to agents installs the integrations of the agent CLIs found
/// here, or, with none found, shows how to install Claude Code and Codex and sets up the first one a later launch
/// finds; no turns this Mac's agent hooks off. Automatic updates come checked, but nothing is requested until Let's
/// roll! saves the choice. Skip on the questions saves neither; Settings answers them later (Updates; Hosts › This
/// Mac). An existing installation that has not answered the updates question gets that question alone, with Continue.
/// Either sheet shows once per Mac (`shouldAsk`). The pages are Onboarding's (OnboardingPages.swift), drawn after
/// mockups/Mac's Onboarding screens.
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

    /// Asks over `window` once (`shouldAsk`); after a yes that found nothing, looks again quietly.
    static func start(over window: NSWindow, chat: ChatCoordinator, settings: SettingsStore, defaults: UserDefaults? = .app) async {
        let choice = defaults?.string(forKey: key)
        if shouldAsk(settings) {
            markShown(settings)
            let sheet = Sheet(chat: chat, settings: settings, agents: choice == "pending")
            await withCheckedContinuation { continuation in
                window.beginSheet(sheet) { _ in continuation.resume() }
                sheet.makeFirstResponder(sheet.initial)
            }
            sheet.orderOut(nil)
            if let answer = sheet.answer { defaults?.set(answer, forKey: key) }
        }
        guard let defaults, choice == "waiting", let found = await installedAgents(), !found.isEmpty else { return }
        chat.adoptLocalAgents(found)
        defaults.set("yes", forKey: key)
    }

    /// The sheet shows once per Mac: while updates are unanswered and it was never shown, here or by another build
    /// sharing these settings (Release and Debug keep separate defaults, so their fresh-install checks differ). Settings
    /// that could not be read ask nothing: they most likely answered it already (SettingsStore keeps them aside).
    static func shouldAsk(_ settings: SettingsStore) -> Bool {
        !settings.unreadable && settings.values.automaticUpdates == nil && !settings.values.setupShown
    }

    /// Recorded as the sheet opens, so neither Skip nor quitting with it open brings it back.
    static func markShown(_ settings: SettingsStore) {
        var values = settings.values
        values.setupShown = true
        do { try settings.save(values) }
        catch { settings.error = error.localizedDescription }
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

    /// One-line installs by launch key, which Hosts settings show for a CLI this Mac lacks.
    static let installs = [
        "claude": "npm install -g @anthropic-ai/claude-code",
        "codex": "npm install -g @openai/codex",
        "pi": "npm install -g @earendil-works/pi-coding-agent",
    ]

    /// The npm installs the warning shows when no CLI is found.
    static let guide = [("Claude Code", installs["claude"] ?? ""), ("Codex", installs["codex"] ?? "")]

    typealias Style = SSHIntegrationConsent

    final class Sheet: NSPanel {
        private let chat: ChatCoordinator
        private let settings: SettingsStore
        /// The agents question is asked (a fresh install, three pages); without it, the sheet only asks about updates.
        private let agents: Bool
        /// The stored agents answer once the user gave one.
        private(set) var answer: String?
        private(set) var yes: Style.ChoiceButton!
        private var no: Style.ChoiceButton!
        private(set) var updates: Style.ChoiceButton!
        /// The page shown: 0 Chat, 1 Tabs, 2 the choices (Prefs). The updates-only sheet is its choices alone.
        private(set) var page = 0
        private var header: NSHostingView<Onboarding.Header>!
        /// The pages, laid over each other in `pagesView`, which is as tall as the tallest so the footer never moves.
        private var pages: [NSView] = []
        private var pagesView: NSView!
        private var pagesHeight: NSLayoutConstraint!
        private var choices: NSStackView!
        private var warning: NSStackView!
        private var column: NSStackView!
        private let footer = Onboarding.FooterModel()
        private var checking = false { didSet { footer.busy = checking } }

        static let width: CGFloat = 500

        /// The row that has focus when the sheet opens: the updates-only sheet's checkbox; the pages start on Chat.
        var initial: NSView? { agents ? nil : updates }
        override var canBecomeKey: Bool { true }

        init(chat: ChatCoordinator, settings: SettingsStore, agents: Bool) {
            self.chat = chat
            self.settings = settings
            self.agents = agents
            super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            appearance = NSAppearance(named: Chrome.palette.isDark ? .darkAqua : .aqua)
            title = agents ? "Welcome to Dispatch" : "Keep Dispatch up to date"
            let inset: CGFloat = 20, contentWidth = Self.width - inset * 2
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = Style.background.cgColor
            content.layer?.cornerRadius = 12
            content.layer?.masksToBounds = true
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor(Chrome.border).cgColor
            content.identifier = NSUserInterfaceItemIdentifier("local-agents-options")

            header = NSHostingView(rootView: Self.header(page: 0, agents: agents))
            choices = NSStackView()
            choices.orientation = .vertical
            choices.alignment = .leading
            choices.spacing = 14
            if agents {
                yes = Style.ChoiceButton(title: "Yes, I’ll use agents on this Mac", detail: "sets up Chat hooks for the agents installed here",
                                         parent: true, note: nil, radio: true)
                no = Style.ChoiceButton(title: "No, only remotely or not at all", detail: "leaves this Mac’s agent settings untouched",
                                        parent: true, last: true, note: nil, radio: true)
                for (button, identifier) in [(yes!, "local-agents-yes"), (no!, "local-agents-no")] {
                    button.target = self
                    button.action = #selector(choose(_:))
                    button.setAccessibilityIdentifier(identifier)
                }
                yes.state = .on
                choices.addArrangedSubview(Self.section("Agents", width: contentWidth))
                choices.addArrangedSubview(Self.group([yes, no], width: contentWidth))
                choices.setCustomSpacing(6, after: choices.arrangedSubviews[choices.arrangedSubviews.count - 2])
            }
            updates = Style.ChoiceButton(title: agents ? "Keep Dispatch up to date" : "Enable automatic updates",
                                         detail: "checks daily and downloads; asks before restarting", parent: true, last: true, note: nil)
            updates.target = self
            updates.action = #selector(toggleUpdates(_:))
            updates.setAccessibilityIdentifier("onboarding-automatic-updates")
            updates.state = .on
            if agents {
                choices.addArrangedSubview(Self.section("Updates", width: contentWidth))
                choices.setCustomSpacing(6, after: choices.arrangedSubviews[choices.arrangedSubviews.count - 1])
            }
            choices.addArrangedSubview(Self.group([updates], width: contentWidth))
            let explanation = Style.label(agents ? "Change either later in Settings." : "Change this later in Settings › General › Updates.", size: 11)
            explanation.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            choices.addArrangedSubview(explanation)
            warning = Self.warning(width: contentWidth)
            warning.isHidden = true
            choices.addArrangedSubview(warning)

            // Laid out at the sheet's width, so text that wraps is measured wrapped.
            pages = (agents ? [NSHostingView(rootView: Onboarding.ChatPage().frame(width: contentWidth, alignment: .leading)),
                               NSHostingView(rootView: Onboarding.TabsPage().frame(width: contentWidth, alignment: .leading))] : []) + [choices]
            pagesView = NSView()
            for (index, view) in pages.enumerated() {
                view.translatesAutoresizingMaskIntoConstraints = false
                view.isHidden = index != 0
                pagesView.addSubview(view)
                NSLayoutConstraint.activate([
                    view.topAnchor.constraint(equalTo: pagesView.topAnchor),
                    view.leadingAnchor.constraint(equalTo: pagesView.leadingAnchor),
                    view.widthAnchor.constraint(equalToConstant: contentWidth),
                ])
            }
            pagesView.translatesAutoresizingMaskIntoConstraints = false
            pagesView.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            pagesHeight = pagesView.heightAnchor.constraint(equalToConstant: 0)
            pagesHeight.isActive = true

            let body = NSStackView(views: [header, pagesView])
            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = 14
            body.edgeInsets = NSEdgeInsets(top: 18, left: inset, bottom: 18, right: inset)
            header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            footer.mode = agents ? .pages : .updates
            footer.back = { [weak self] in self?.show((self?.page ?? 1) - 1) }
            footer.show = { [weak self] in self?.show($0) }
            footer.skip = { [weak self] in self?.cancelOperation(nil) }
            footer.next = { [weak self] in self?.advance() }
            footer.check = { [weak self] in self?.checkAgain(nil) }
            footer.done = { [weak self] in self?.finish(nil) }
            let bar = NSHostingView(rootView: Onboarding.Footer(model: footer))
            bar.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 54).isActive = true
            column = NSStackView(views: [body, bar])
            column.orientation = .vertical
            column.spacing = 0
            column.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                column.topAnchor.constraint(equalTo: content.topAnchor),
                column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            pagesHeight.constant = tallestPage()
            content.frame = NSRect(x: 0, y: 0, width: Self.width, height: ceil(column.fittingSize.height))
            contentView = content
            setContentSize(content.frame.size)
            show(agents ? 0 : pages.count - 1)
        }

        private static func header(page: Int, agents: Bool) -> Onboarding.Header {
            guard agents else {
                return Onboarding.Header(symbol: "arrow.down.circle", title: "Keep Dispatch up to date", subtitle: "New releases, downloaded for you")
            }
            return [Onboarding.Header(symbol: "text.bubble", title: "Chat with your agents", subtitle: "Welcome to Dispatch"),
                    Onboarding.Header(symbol: "square.split.2x1", title: "tmux, herdr and SSH", subtitle: "Type the commands you already know"),
                    Onboarding.Header(symbol: "laptopcomputer", title: "Set up this Mac", subtitle: "Two quick choices")][page]
        }

        /// The tallest page's height (hidden ones measured too), the warning included once it shows.
        private func tallestPage() -> CGFloat {
            ceil(pages.map { $0.fittingSize.height }.max() ?? 0)
        }

        /// Shows a page; the choices take the keyboard focus on their own page.
        private func show(_ index: Int) {
            guard !checking, footer.mode != .warning, pages.indices.contains(index) else { return }
            page = agents ? index : 2
            for (other, view) in pages.enumerated() { view.isHidden = other != index }
            header.rootView = Self.header(page: page, agents: agents)
            footer.page = page
            makeFirstResponder(index == pages.count - 1 ? (agents ? (yes.state == .on ? yes : no) : updates) : nil)
        }

        /// Next on the first two pages; on the choices, Let's roll! (Continue on the updates-only sheet) saves them.
        private func advance() {
            if page < 2 { show(page + 1) } else { save(nil) }
        }

        /// A small caps heading over a group of rows.
        private static func section(_ title: String, width: CGFloat) -> NSTextField {
            let label = Style.label(title.uppercased(), size: 10, bold: true)
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
            return label
        }

        /// Rows in one rounded, accent-bordered box.
        private static func group(_ buttons: [Style.ChoiceButton], width: CGFloat) -> NSStackView {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.spacing = 0
            rows.wantsLayer = true
            rows.layer?.backgroundColor = NSColor(Chrome.sidebar).cgColor
            rows.layer?.cornerRadius = 8
            rows.layer?.masksToBounds = true
            rows.layer?.borderWidth = 1
            rows.layer?.borderColor = Style.accent.withAlphaComponent(0.35).cgColor
            for button in buttons {
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
                button.heightAnchor.constraint(equalToConstant: 56).isActive = true
                rows.addArrangedSubview(button)
            }
            return rows
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
            guard !checking, footer.mode != .warning else { return }
            yes.state = sender === yes ? .on : .off
            no.state = sender === no ? .on : .off
            yes.needsDisplay = true; no.needsDisplay = true
        }

        @objc private func toggleUpdates(_ sender: Any?) {
            guard !checking, footer.mode != .warning else { return }
            updates.needsDisplay = true
        }

        /// Continue answers the updates question first: an answer saved elsewhere while the sheet was open stands.
        private func saveUpdates() {
            guard settings.values.automaticUpdates == nil else { return }
            var values = settings.values
            values.automaticUpdates = updates.state == .on
            do { try settings.save(values) }
            catch { settings.error = error.localizedDescription }
        }

        @objc private func save(_ sender: Any?) {
            guard !checking, footer.mode != .warning, page == 2 else { return }
            saveUpdates()
            guard agents else { return end(nil) }
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
            Task { @MainActor in
                let found = await LocalAgentsConsent.installedAgents()
                checking = false
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
            footer.mode = .warning
            yes.isEnabled = false; no.isEnabled = false; updates.isEnabled = false
            pagesHeight.constant = tallestPage()
            column.layoutSubtreeIfNeeded()
            let height = ceil(column.fittingSize.height)
            var frame = self.frame
            frame.origin.y -= height - frame.height
            frame.size.height = height
            setFrame(frame, display: true, animate: false)
            makeFirstResponder(nil)
        }

        @objc private func finish(_ sender: Any?) { end("waiting") }

        private func end(_ value: String?) {
            answer = value
            sheetParent?.endSheet(self)
        }

        /// Escape and Skip: on the first two pages, on to the choices; on them, close with nothing saved (the sheet is
        /// not shown again: `markShown`).
        override func cancelOperation(_ sender: Any?) {
            guard !checking, agents else { return }
            if footer.mode == .warning { return end("waiting") }
            if page < 2 { return show(2) }
            answer = nil
            sheetParent?.endSheet(self, returnCode: .cancel)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if event.keyCode == 36 || event.keyCode == 76 { footer.mode == .warning ? finish(nil) : advance(); return true }
                if event.keyCode == 53 { cancelOperation(nil); return true }
                if event.keyCode == 125 || event.keyCode == 126, agents, page == 2, footer.mode != .warning {
                    choose(event.keyCode == 125 ? no : yes); makeFirstResponder(event.keyCode == 125 ? no : yes); return true
                }
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
