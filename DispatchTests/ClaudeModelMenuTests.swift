import XCTest
@testable import DispatchApp

final class ClaudeModelMenuTests: XCTestCase {
    /// Text typed into Terminal before Chat opened is read back from the plain composer only.
    func testComposerTextReadsOnlyTheOneLineComposer() {
        let empty = "Claude Code v2.1.287\n──── design ─\n❯ \n───\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent\n"
        XCTAssertEqual(ClaudeModelMenu.composerText(empty), "")
        XCTAssertEqual(ClaudeModelMenu.composerText(empty.replacingOccurrences(of: "❯ ", with: "❯ hello there  ")), "hello there")
        XCTAssertEqual(ClaudeModelMenu.composerText(empty.replacingOccurrences(of: "❯ ", with: "❯ привет")), "привет")
        // Captured from 2.1.285: a no-break space after the marker, and no shortcut hint while typing.
        let typing = "Claude Code v2.1.285\n───\n❯\u{a0}thinking hello \n───\n  ⏸ manual mode on\n"
        XCTAssertEqual(ClaudeModelMenu.composerText(typing), "thinking hello")
        for other in [empty.replacingOccurrences(of: "❯ ", with: "❯hello"),
                      empty.replacingOccurrences(of: "❯ \n", with: "❯ first\n  second\n"),
                      empty.replacingOccurrences(of: "───\n  ⏵⏵", with: "───\n❯ 1. Yes\n  ⏵⏵"),
                      empty + "───\n Do you want to proceed?\n",
                      empty.replacingOccurrences(of: "──── design ─", with: "")] {
            XCTAssertNil(ClaudeModelMenu.composerText(other), other)
        }
    }

    func testObservedComposerFooters() {
        // Footer text captured from the native 2.1.282 and 2.1.283 terminals.
        // Borders are shortened; the prompt and footer text are preserved.
        for (version, footer) in [
            ("2.1.282", "? for shortcuts"),
            ("2.1.283", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"),
            // With a listed agent, the hint becomes its count.
            ("agents", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"),
            ("agents", "  ⏸ manual mode on · ← 2 agents"),
            ("effort", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent          ● high · /effort"),
            // Notices below the footer (2.1.283 at 60 columns and in tmux; 2.1.287 text, wrapped).
            ("narrow", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents\n                    ● high · /effort"),
            ("tmux", "  ⏸ manual mode on · ? for shortcuts · ← for agents\n   tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf"),
            ("2.1.287", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent\n  tmux focus-events off · add 'set -g focus-events on' to\n  ~/.tmux.conf and reattach for focus tracking"),
            // A configured statusLine sits between the composer and the footer (2.1.287).
            ("status", "  model=x branch=main\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"),
            ("status", "  ~/Developer/dispatch main*\n  Opus 5.5 · 42% context\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent")
        ] {
            let empty = "Claude Code v\(version)\n───\n❯ \n───\n\(footer)\n"
            XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(empty), version)
            // A named session (/rename) labels the top border; captured from 2.1.287 in tmux.
            XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(empty.replacingOccurrences(of: "───\n❯", with: "──── design ─\n❯")), version)
            for text in ["Try \"fix lint errors\"", "Continue reviewing the changes"] {
                let draft = empty.replacingOccurrences(of: "❯ ", with: "❯ " + text)
                XCTAssertEqual(ClaudeModelMenu.removingPlaceholder(draft, column: 2, row: 2, faint: true),
                    empty.replacingOccurrences(of: "❯ ", with: "❯ "), version)
                XCTAssertEqual(ClaudeModelMenu.removingPlaceholder(draft, column: 2, row: 2, faint: false), draft, version)
            }
            for blocked in [empty.replacingOccurrences(of: "❯ ", with: "❯ draft"),
                            empty.replacingOccurrences(of: "───", with: ""), empty + "❯ 1. Yes"] {
                XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(blocked), version)
            }
        }
        // Native dialogs replace the composer and footer, so text Chat allows
        // around the footer never hides one. Captured from 2.1.287 through
        // scripts/claude_fixture.py; borders are shortened.
        let rule = "───────", dashes = "╌╌╌╌╌╌╌"
        let permission = """
            ❯ permission tool check
            ⏺ I’ll run the local fixture check.
              ⎿  $ python3 -c "from pathlib import Path; Path('dispatch-approval-marker').write_text('approved')"
            \(rule)
             Bash command
             Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
             Print the Dispatch fixture marker
            \(dashes)
             │ python3 -c "from pathlib import Path; Path('dispatch-approval-marker').write_text('approved')"
            \(dashes)
             This command requires approval
             Do you want to proceed?
             ❯ 1. Yes
               2. Yes, and don’t ask again for: python3 *
               3. Yes, and switch to auto mode · auto mode handles these prompts for you
               4. No
             Esc to cancel · Tab to amend
            """
        let question = """
            ❯ question please
            ⏺ I need a few choices before continuing.
            \(rule)
             ☐ Detail
            How much detail should the reply include?
              1. Compact
                 A short reply.
              2. Detailed
                 Include the reasoning.
            ❯ 3. Type something.
            \(rule)
              4. Chat about this
            Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel
            """
        for dialog in [permission, question] {
            XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(dialog, allowWorking: true))
        }
    }

    func testStartupScreenReportsModelAndLiveEffort() {
        // Banners and footers captured from native 2.1.283 terminals (120 and
        // 60 columns, tmux). Borders are shortened.
        let rule = "───────"
        func screen(_ banner: String, footer: String, between: String = "\n\n") -> String {
            " ▐▛███▛█   Claude Code v2.1.283\n▝▜██████▀  \(banner)\n ▝▝   ▝▝   ~/Developer/dispatch\(between)\(rule)\n❯ \n\(rule)\n\(footer)\n"
        }
        let auto = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        for (banner, footer, model, effort) in [
            ("Opus 5.5 with high effort · Claude Max", auto + "          ● high · /effort", "claude-opus-5-5", "high"),
            ("Sonnet 5 with low effort · Claude Max", auto + "           ○ low · /effort", "claude-sonnet-5", "low"),
            ("Opus 5.5 (1M context) with max effort · Claude Max", auto + "     ◈ max · /effort", "claude-opus-5-5", "max"),
            ("Opus 5.5 with high effort · Claude Max", auto + "\n                    ● high · /effort", "claude-opus-5-5", "high"),
            ("Haiku 4.5 · Claude Max", "  ⏸ manual mode on · ? for shortcuts · ← for agents\n   tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf",
             "claude-haiku-4-5", nil),
            // The live footer wins over the banner after /effort in terminal.
            ("Opus 5.5 with high effort · Claude Max", auto + "           ○ low · /effort", "claude-opus-5-5", "low")
        ] as [(String, String, String, String?)] {
            let startup = ClaudeStartupConfiguration(screen(banner, footer: footer))
            XCTAssertEqual(startup?.model, model, banner); XCTAssertEqual(startup?.effort, effort, banner)
        }
        let unknownModel = ClaudeStartupConfiguration(screen("claude-custom-proxy · API Usage Billing", footer: auto + "  ● high · /effort"))
        XCTAssertNotNil(unknownModel); XCTAssertNil(unknownModel?.model); XCTAssertEqual(unknownModel?.effort, "high")
        // A terminal /model does not redraw the banner, and menus hide the composer.
        let stale = screen("Opus 5.5 with high effort · Claude Max", footer: auto,
                           between: "\n\n❯ /model\n  ⎿  Set model to Sonnet 5\n\n")
        XCTAssertNil(ClaudeStartupConfiguration(stale))
        XCTAssertNil(ClaudeStartupConfiguration(" ▐▛███▛█   Claude Code v2.1.283\n▝▜██████▀  Opus 5.5 · Claude Max\n\nSelect model\n\n❯ 1. Default (recommended)\n  2. Sonnet\n"))
        XCTAssertNil(ClaudeStartupConfiguration("\(rule)\n❯ \n\(rule)\n\(auto)\n"))
        let named = screen("Opus 5.5 with high effort · Claude Max", footer: auto).replacingOccurrences(of: "\(rule)\n❯", with: "──── design ─\n❯")
        XCTAssertEqual(ClaudeStartupConfiguration(named)?.model, "claude-opus-5-5")
    }

    func testPlaceholderRequiresNativeStyleAndInputCursor() {
        let empty = "Claude Code\n───\n❯ \n───\n? for shortcuts"
        for suggestion in ["Try \"fix lint errors\"", "try a destructive git command", "Continue reviewing the changes"] {
            let screen = empty.replacingOccurrences(of: "❯ ", with: "❯ " + suggestion)
            XCTAssertEqual(ClaudeModelMenu.removingPlaceholder(screen, column: 2, row: 2, faint: true), empty)
            for (column, row, faint) in [(2, 2, false), (3, 2, true), (2, 1, true), (2, 5, true)] {
                XCTAssertEqual(ClaudeModelMenu.removingPlaceholder(screen, column: column, row: row, faint: faint), screen)
            }
            for blocked in [screen + "\n❯ 1. Yes", screen.replacingOccurrences(of: "───", with: "")] {
                XCTAssertEqual(ClaudeModelMenu.removingPlaceholder(blocked, column: 2, row: 2, faint: true), blocked)
            }
        }
        for text in ["draft", "Try \"fix lint errors\" plus my draft", "/command", ""] {
            let draft = empty.replacingOccurrences(of: "❯ ", with: "❯ " + text)
            XCTAssertEqual(ClaudeModelMenu.removingPlaceholder(draft, column: 2, row: 2, faint: false), draft)
        }
        XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(empty))
    }

    // Registration/input admission lives in the helper; the original complete oracle
    // remains in ClaudeAdapterTests.json and runs in moved::claude_adapter_tests.

    private let screen = """
    Select model
    Switch between Claude models.
      1. Default (recommended)  Use the default model
      2. Opus (1M context)      Description
    ❯ 3. dispatch-fixture ✔     Custom model

      ● High effort (default) ←/→ to adjust

    Enter to set as default · s to use this session only · Esc to cancel
    ▔▔▔▔▔▔▔▔▔▔
    """
    @MainActor
    func testCatalogWalkStopsAfterWrapAndStillHandlesClampedLists() async throws {
        for (wraps, counted, width) in [(true, true, 5), (false, true, 5), (true, false, 5), (false, false, 5),
                                        (true, true, 3), (false, true, 3), (true, false, 3), (false, false, 3)] {
            let names = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]
            var row = 1, opened = false, moves: [AgentMenuKey] = []
            func screen() -> String {
                guard opened else { return "" }
                let start = min(names.count - width, max(0, row - 1)), end = start + width
                return "Select model\n" + (start..<end).map { index in
                    let marker = index == row ? "❯" : index == start && start > 0 ? "↑" : index == end - 1 && end < names.count ? "↓" : " "
                    return "\(marker) \(index + 1). \(names[index])\(index == 1 ? " ✔" : "")  Description"
                }.joined(separator: "\n") + (counted && width < names.count ? "\n… +\(names.count - width) models" : "")
                    + "\nEnter to set as default · s to use this session only · Esc to cancel"
            }
            let picker = ChatModelPicker(agentID: "claude", model: "Beta", effort: nil, column: .model, screen: screen,
                send: { key in
                    switch key {
                    case nil: opened = true
                    case .up, .down:
                        moves.append(key!)
                        let next = row + (key == .down ? 1 : -1)
                        row = wraps ? (next + names.count) % names.count : min(names.count - 1, max(0, next))
                    case .escape: opened = false
                    default: XCTFail("Catalog browsing must not apply a selection")
                    }
                }, confirmed: { _, _ in XCTFail("Browsing must preserve selection") }, finished: { _ in })
            picker.start()
            try await TestSupport.eventually(timeout: .seconds(8)) { !picker.loading }
            XCTAssertNil(picker.error); XCTAssertEqual(picker.models.map(\.name), names)
            XCTAssertEqual(picker.models.filter(\.current).map(\.name), ["Beta"])
            XCTAssertTrue(picker.efforts.isEmpty)
            XCTAssertEqual(picker.highlightedModel, "Beta")
            let expected: [AgentMenuKey] = width == names.count ? [] : counted ? [.down, .down]
                : wraps ? Array(repeating: .down, count: names.count) : Array(repeating: .down, count: 4) + Array(repeating: .up, count: 5)
            XCTAssertEqual(moves, expected)
            picker.close()
            try await TestSupport.eventually { !opened }
        }
    }

    func testParsesLiveChoicesWithoutFixedModelCatalog() throws {
        let menu = try XCTUnwrap(ClaudeModelMenu(screen))
        XCTAssertEqual(menu.choices.map(\.name), ["Default", "Opus (1M context)", "dispatch-fixture"])
        XCTAssertEqual(menu.choices.first?.isDefault, true)
        XCTAssertEqual(menu.selected, "dispatch-fixture")
        XCTAssertEqual(menu.choices.first(where: \.current)?.name, "dispatch-fixture")
        XCTAssertEqual(menu.effort, "high")
        let future = try XCTUnwrap(ClaudeModelMenu(screen.replacingOccurrences(of: "High effort", with: "Future effort")))
        XCTAssertEqual(future.effort, "future")
        XCTAssertEqual(AgentModelMenu.Choice(number: 0, name: "Future", detail: "", current: false, isDefault: false, effortValue: "future").effort, "future")
    }
    func testRejectsAmbiguousOrIncompleteMenusAndOldOutput() {
        XCTAssertNil(ClaudeModelMenu(screen.replacingOccurrences(of: "✔", with: "")))
        XCTAssertNil(ClaudeModelMenu(screen.replacingOccurrences(of: "Description", with: "Description ✔").replacingOccurrences(of: "Opus (1M context)", with: "Opus ✔")))
        XCTAssertNil(ClaudeModelMenu(screen.replacingOccurrences(of: "s to use this session only", with: "")))
        XCTAssertNil(ClaudeModelMenu(screen + "\n❯ ordinary prompt"))
        XCTAssertNil(ClaudeModelMenu(String(repeating: "x", count: 65_537)))
    }
    func testRecognizesOnlyCurrentConfirmationAndEmptyComposer() throws {
        let confirmation = """
        Switch model?
        Your next response will be slower and use more tokens
        This conversation is cached for the current model.
        ❯ 1. Yes, switch to Custom
          2. No, go back
        """
        let value = try XCTUnwrap(ClaudeModelConfirmation(confirmation))
        XCTAssertEqual(value.selected, "Yes, switch to Custom")
        XCTAssertEqual(value.choices.count, 2)
        XCTAssertEqual(ClaudeModelConfirmation(confirmation.replacingOccurrences(of: "Switch model?", with: "Change effort level?"))?.title, "Change effort level?")
        XCTAssertNil(ClaudeModelConfirmation(confirmation + "\n❯ ordinary prompt"))
        let composer = "───\n❯\n───\n? for shortcuts"
        XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(composer))
        let working = composer.replacingOccurrences(of: "? for shortcuts", with: "esc to interrupt · ctrl+t to hide tasks")
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(working))
        XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(working, allowWorking: true))
        // Claude 2.1.287's working footer also lists agents.
        let busy = composer.replacingOccurrences(of: "? for shortcuts", with: "⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt · ← 1 agent")
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(busy))
        XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(busy, allowWorking: true))
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(working.replacingOccurrences(of: "❯", with: "❯ native draft"), allowWorking: true))
        let pasted = composer.replacingOccurrences(of: "? for shortcuts", with: "paste again to expand")
        XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(pasted))
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(pasted.replacingOccurrences(of: "❯", with: "❯ [Pasted text #1]")))
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(pasted + "\n❯ 1. Yes"))
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(composer.replacingOccurrences(of: "❯", with: "❯ unsent draft")))
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(composer + "\n───\n❯ 1. Yes"))
        // Claude 2.1.293 truncates the mode footer at 80 columns or fewer.
        for footer in ["⏵⏵ auto mode on (shift+tab to cycle) · gh auth login for", "⏸ manual mode on · gh auth login for PR",
                       "⏸ plan mode on · gh auth login for PR", "⏵⏵ accept edits on · gh auth login for PR"] {
            XCTAssertTrue(ClaudeModelMenu.isEmptyComposer(composer.replacingOccurrences(of: "? for shortcuts", with: footer)), footer)
        }
        XCTAssertFalse(ClaudeModelMenu.isEmptyComposer(composer.replacingOccurrences(of: "? for shortcuts", with: "⏵⏵ auto mode o…")))
    }
}
