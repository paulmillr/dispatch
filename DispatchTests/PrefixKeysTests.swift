import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class PrefixKeysTests: XCTestCase {
    private func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [], up: Bool = false,
                     repeating: Bool = false, at time: TimeInterval = 0) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0,
                         context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeating, keyCode: code)!
    }
    private var prefix: NSEvent { key(11, "b", .control) }

    /// ⌃B arms only its terminal; the next key runs a binding or cancels, and every consumed key's
    /// release and repeats stay out of the terminal. ⌃B twice and Command chords are not consumed.
    func testPrefixSequencesRunBindingsAndLeaveOtherKeysToTheTerminal() {
        let keys = PrefixKeys(), surface = UUID(), other = UUID()
        var table = PrefixStyle.tmux.table
        var performed: [PrefixAction] = []
        keys.table = { _ in table }
        keys.perform = { action, target in XCTAssertEqual(target, surface); performed.append(action) }

        XCTAssertFalse(keys.handle(key(8, "c"), surface: surface), "Unarmed keys belong to the terminal")
        XCTAssertTrue(keys.handle(prefix, surface: surface))
        XCTAssertEqual(keys.armed, surface)
        XCTAssertTrue(keys.handle(key(11, "b", .control, repeating: true), surface: surface), "Holding ⌃B does not send it")
        XCTAssertEqual(keys.armed, surface)
        XCTAssertTrue(keys.handle(key(23, "%", .shift), surface: surface))
        XCTAssertNil(keys.armed)
        XCTAssertEqual(performed, [.splitRight])
        XCTAssertTrue(keys.swallowsKeyUp(key(23, "%", up: true)))
        XCTAssertFalse(keys.swallowsKeyUp(key(23, "%", up: true)), "Only the consumed press's release is swallowed")

        XCTAssertTrue(keys.handle(prefix, surface: surface))
        XCTAssertFalse(keys.handle(prefix, surface: surface), "⌃B twice sends ⌃B to the terminal")
        XCTAssertNil(keys.armed)
        for cancel in [key(53, "\u{1B}"), key(7, "y")] {
            XCTAssertTrue(keys.handle(prefix, surface: surface))
            XCTAssertTrue(keys.handle(cancel, surface: surface), "Escape and unbound keys cancel without reaching the terminal")
        }
        XCTAssertTrue(keys.handle(prefix, surface: surface))
        XCTAssertFalse(keys.handle(key(17, "t", .command), surface: surface), "Command chords stay the app's")
        XCTAssertNil(keys.armed)
        XCTAssertTrue(keys.handle(prefix, surface: other))
        XCTAssertFalse(keys.handle(key(8, "c"), surface: surface), "Another terminal's prefix does not complete here")
        XCTAssertEqual(performed, [.splitRight])

        // A repeatable binding repeats without the prefix within repeat-time; then keys are typed again.
        XCTAssertTrue(keys.handle(prefix, surface: surface))
        XCTAssertTrue(keys.handle(key(126, "\u{F700}", at: 10), surface: surface))
        XCTAssertTrue(keys.handle(key(126, "\u{F700}", at: 10.3), surface: surface))
        XCTAssertFalse(keys.handle(key(126, "\u{F700}", at: 11), surface: surface))
        XCTAssertEqual(performed.suffix(2), [.tmux("select-pane -U"), .tmux("select-pane -U")])

        // The same keys differ by tool, and no table leaves ⌃B to the terminal.
        for (tool, event, action): (PrefixTable?, NSEvent, PrefixAction) in [
            (PrefixStyle.tmux.table, key(18, "1", .option), .layout(.columns)),
            (PrefixStyle.tmux.table, key(29, "0"), .selectWindow(0)),
            (PrefixStyle.herdr.table, key(9, "v"), .splitRight), (PrefixStyle.herdr.table, key(7, "X", .shift), .closeTab),
            (PrefixStyle.herdr.table, key(48, "\t", .shift), .previousPane),
        ] {
            table = tool
            XCTAssertTrue(keys.handle(prefix, surface: surface))
            XCTAssertTrue(keys.handle(event, surface: surface))
            XCTAssertEqual(performed.last, action)
        }
        table = nil
        XCTAssertFalse(keys.handle(prefix, surface: surface))
    }

    /// A tmux server's own prefix, repeat time and prefix table, as `show-options` and
    /// `list-keys -T prefix` print them: escaped keys, confirmed kills, and server commands that
    /// keep one control reply; command lists and client UI stay unbound.
    func testTmuxTableFollowsTheServersBindings() throws {
        let table = try XCTUnwrap(PrefixTable.tmux(prefix: "C-a\n", repeatTime: "300", keys: [
            "bind-key    -T prefix \\\"      split-window",
            "bind-key    -T prefix \\%      split-window -h -c \"#{pane_current_path}\"",
            "bind-key    -T prefix x       confirm-before -p \"kill-pane #P? (y/n)\" kill-pane",
            "bind-key    -T prefix \\;      last-pane",
            "bind-key -r -T prefix M-Up    resize-pane -U 5",
            "bind-key    -T prefix 3       select-window -t :=3",
            "bind-key    -T prefix r       source-file ~/.tmux.conf \\; display-message reloaded",
            "bind-key    -T prefix :       command-prompt",
            "bind-key    -T copy-mode-vi v send-keys -X begin-selection",
        ]))
        XCTAssertEqual(table.prefix, PrefixKey("a", control: true))
        XCTAssertEqual(table.repeatTime, 0.3)
        XCTAssertEqual(table.bindings, [
            PrefixKey("\""): PrefixBinding(action: .splitDown),
            PrefixKey("%"): PrefixBinding(action: .splitRight),
            PrefixKey("x"): PrefixBinding(action: .closePane),
            PrefixKey(";"): PrefixBinding(action: .tmux("last-pane")),
            PrefixKey("Up", option: true): PrefixBinding(action: .tmux("resize-pane -U 5"), repeats: true),
            PrefixKey("3"): PrefixBinding(action: .selectWindow(3)),
        ])
        XCTAssertNil(PrefixTable.tmux(prefix: "None", repeatTime: "500", keys: []), "No prefix, no prefix keys")
    }

    /// herdr's config.toml [keys] replaces the defaults it names, including unbinding with "".
    func testHerdrTableAppliesConfigOverrides() throws {
        let table = try XCTUnwrap(PrefixTable.herdr(config: """
            [ui]
            prefix = "ctrl+q"
            [keys]
            prefix = "ctrl+a" # tmux muscle memory
            new_tab = "prefix+t"
            close_pane = ""
            switch_workspace = "prefix+alt+1..9"
            next_tab = "ctrl+alt+n"
            [[keys.command]]
            key = "prefix+g"
            """))
        XCTAssertEqual(table.prefix, PrefixKey("a", control: true))
        XCTAssertEqual(table.bindings[PrefixKey("t")]?.action, .newTab)
        XCTAssertNil(table.bindings[PrefixKey("c")], "A rebound action leaves its default key")
        XCTAssertNil(table.bindings[PrefixKey("x")], "An empty binding unbinds")
        XCTAssertEqual(table.bindings[PrefixKey("4", option: true)]?.action, .selectSpace(4))
        XCTAssertNil(table.bindings[PrefixKey("n")], "Direct shortcuts stay with the terminal")
        XCTAssertEqual(table.bindings[PrefixKey("g")]?.action, .searchSpaces, "Custom commands do not replace goto")
        XCTAssertNil(PrefixTable.herdr(config: "[keys]\nprefix = \"cmd+b\""), "A Command prefix is the app's")
    }
}
