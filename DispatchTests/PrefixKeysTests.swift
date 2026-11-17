import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class PrefixKeysTests: XCTestCase {
    /// The indicator and the ⌘/ sheet name keys as the Mac writes them, the server's own prefix included.
    func testPrefixKeysAreNamedAndListedForTheSheet() throws {
        XCTAssertEqual(PrefixKey(tmux: "C-a")?.symbol, "⌃A")
        XCTAssertEqual(PrefixKey(tmux: "S-Up")?.symbol, "⇧↑")
        XCTAssertEqual(PrefixKey(tmux: "%")?.symbol, "%")
        let table = try XCTUnwrap(PrefixTable.tmux(prefix: "C-a", repeatTime: "500", keys: [
            "bind-key -T prefix c new-window", "bind-key -T prefix 0 select-window -t :=0",
            "bind-key -T prefix 1 select-window -t :=1", "bind-key -T prefix y run-shell true",
        ]))
        let rows = ShortcutRow.prefixRows(table)
        XCTAssertEqual(rows.first?.key, "⌃A 0…1")
        XCTAssertTrue(rows.contains { $0.key == "⌃A c" && $0.explanation == "new tab" })
        XCTAssertTrue(rows.contains { $0.key == "⌃A y" && $0.explanation.contains("can't run") })
        XCTAssertEqual(rows.last?.key, "⌃A ⌃A")
    }

    /// The ⌘/ sheet's key names: modifiers join their key with "+", a word's hyphen and a sentence's space stay.
    func testShortcutSheetNamesKeys() {
        let named = ShortcutKeyStyle.named
        XCTAssertEqual(named("⇧⌘C"), "shift+cmd+C")
        XCTAssertEqual(named("⌃⌘1…5"), "ctrl+cmd+1…5")
        XCTAssertEqual(named("⌘[ / ⌘]"), "cmd+[ / cmd+]")
        XCTAssertEqual(named("⌃⇥ / ⌃⇧⇥"), "ctrl+tab / ctrl+shift+tab")
        XCTAssertEqual(named("⌘+ / ⌘- / ⌘0"), "cmd++ / cmd+- / cmd+0")
        XCTAssertEqual(named("⌘-click"), "cmd-click")
        XCTAssertEqual(named("open a link · hold ⌘ to see where"), "open a link · hold cmd to see where")
        XCTAssertEqual(named("⌥↓ / ⌥↑"), "opt+down / opt+up")
        XCTAssertEqual(named("⇧⌘⏎"), "shift+cmd+return")
        XCTAssertEqual(named("↑↓ / ⎋"), "up down / esc")
        XCTAssertEqual(named("right-click"), "right-click")
    }

    /// The sheet's two key columns: modifiers flush against the key, shared modifiers once, a prefix in the modifiers'
    /// place; a pair with different modifiers spans both, and a word with ⌘ in it is all key.
    func testShortcutSheetSplitsChordsIntoColumns() {
        func chord(_ key: String) -> [String]? { ShortcutRow(key, "").chord.map { [$0.modifiers, $0.key] } }
        XCTAssertEqual(chord("⇧⌘1…9"), ["⇧⌘", "1…9"])
        XCTAssertEqual(chord("⌥⌘[ ]"), ["⌥⌘", "[ ]"])
        XCTAssertEqual(chord("⌘\\"), ["⌘", "\\"])
        XCTAssertEqual(chord("⌥↓ / ⌥↑"), ["⌥", "↓ / ↑"])
        XCTAssertEqual(chord("⌘+ / ⌘- / ⌘0"), ["⌘", "+ / - / 0"])
        XCTAssertEqual(chord("⌃B c"), ["⌃B", "c"])
        XCTAssertEqual(chord("⌘-click"), ["", "⌘-click"])
        XCTAssertEqual(chord("right ⌘"), ["right ⌘", ""])
        XCTAssertEqual(chord("⌃1…4, 6, 8"), ["⌃", "1…4, 6, 8"])
        XCTAssertEqual(chord("⌃B 0…9"), ["⌃B", "0…9"])
        XCTAssertEqual(chord("⎋ twice"), ["", "⎋ twice"])
        XCTAssertNil(chord("⌥⏎ / ⇧⏎"))
        XCTAssertNil(chord("⇥ / ⇧⇥"))
    }

    /// The sheet's first rows are the everyday ones; the rest wait under More.
    func testShortcutSheetSplitsEverydayKeysFromMore() {
        let main = ShortcutRow.navigation.map(\.key), more = ShortcutRow.windowRows(KeyGroups()).map(\.key)
        for key in ["⌘N", "⇧⌘N", "⌘T", "⌘W", "⌘D", "⇧⌘D", "⇧⌘C", "⇧⌘F", "⌘\\"] {
            XCTAssertTrue(main.contains(key), key); XCTAssertFalse(more.contains(key), key)
        }
        // Left out to keep the sheet short: pane stepping, close space, the sidebar's second key, "9 the last".
        for key in ["⌥⌘[ ]", "⇧⌘W", "⌃⌘S"] { XCTAssertFalse(main.contains(key), key) }
        XCTAssertFalse(ShortcutRow.navigation.contains { $0.explanation.contains("the last") })
        for key in ["⌃⇥", "⌃⇧⇥", "⌘P", "⌃⌘1…5"] {
            XCTAssertTrue(more.contains(key), key); XCTAssertFalse(main.contains(key), key)
        }
        XCTAssertFalse(ShortcutRow.navigation.contains { $0.explanation.contains("prefix") }, "prefix keys are More's")
    }

    private func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [], up: Bool = false,
                     repeating: Bool = false, at time: TimeInterval = 0) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: time, windowNumber: 0,
                         context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeating, keyCode: code)!
    }
    private var prefix: NSEvent { key(11, "b", .control) }

    /// ⌃B arms only its terminal; the next key runs a binding or cancels, and every consumed key's
    /// release and repeats stay out of the terminal. ⌃B twice and Command chords are not consumed.
    func testPrefixSequencesRunBindingsAndLeaveOtherKeysToTheTerminal() {
        let keys = PrefixKeys(), surface = System.uuid(), other = System.uuid()
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

/// The 2026-10-31 tmux configuration audit (test/tmux-config-audit.py has the live-server side).
extension PrefixKeysTests {
    /// T5: a server binding maps to Dispatch's action only when it does what tmux would; operands Dispatch has no
    /// equivalent for (a name, a program, a size, a target) leave the key refused, never mapped to something else.
    func testTmuxActionsMapOnlyEquivalentCommands() {
        for command in [#"new-window -n logs "tail -f /tmp/app.log""#, "new-window -d", "split-window -h -l 15 -c /tmp",
                        "split-window -b", "kill-pane -t %42", "kill-window -a", "next-window -t :3", "detach-client -a",
                        "switch-client -T custom", "copy-mode -e", "paste-buffer -b named", "break-pane -d",
                        #"command-prompt -T window-target -p index { select-window -t ":%%" }"#,
                        #"command-prompt { rename-window -t :1 "%%" }"#, #"confirm-before -p "kill?" "kill-pane -t %3""#,
                        #"source-file ~/.tmux.conf \; display-message reloaded"#, "display-panes", "command-prompt"] {
            XCTAssertNil(PrefixTable.tmuxAction(command), command)
        }
        for (command, action): (String, PrefixAction) in [
            ("new-window", .newTab), (##"new-window -c "#{pane_current_path}""##, .newTab),
            (##"split-window -h -c "#{pane_current_path}""##, .splitRight), ("split-window -v", .splitDown), ("split-window", .splitDown),
            ("kill-pane", .closePane), (##"confirm-before -p "kill-window #W? (y/n)" kill-window"##, .closeTab),
            (##"command-prompt -I "#W" { rename-window "%%" }"##, .renameTab), (#"command-prompt "rename-session '%%'""#, .renameSpace),
            (#"command-prompt { find-window -Z "%%" }"#, .searchSpaces), ("choose-tree -Zs", .searchSpaces),
            ("next-window -a", .nextAttention), ("copy-mode -u", .scrollPageUp), ("paste-buffer -p", .paste),
            ("list-keys -N", .shortcuts), ("select-window -t :=7", .selectWindow(7)), ("select-layout tiled", .layout(.grid)),
            ("resize-pane -U 5", .tmux("resize-pane -U 5")), ("send-prefix", .tmux("send-prefix")),
        ] {
            XCTAssertEqual(PrefixTable.tmuxAction(command), action, command)
        }
        // tmux's own default table keeps every mapping it had, and refuses nothing.
        XCTAssertTrue(PrefixTable.tmuxDefaults.rejected.isEmpty, "\(PrefixTable.tmuxDefaults.rejected)")
        XCTAssertEqual(PrefixTable.tmuxDefaults.bindings.count, 59)
        XCTAssertEqual(PrefixTable.tmuxDefaults.bindings[PrefixKey(",")]?.action, .renameTab)
        XCTAssertEqual(PrefixTable.tmuxDefaults.bindings[PrefixKey("s")]?.action, .searchSpaces)
    }

    /// T1, T4: the helper's reply for a session (backends.prefix) becomes the table: its prefix and prefix2 arm it,
    /// its bindings run, and a key bound to a command Dispatch cannot run ends the sequence refused.
    func testServerTableArmsOnBothPrefixesAndRefusesUnsupportedBindings() throws {
        let reply = HelperClient.Prefix(key: "C-a", repeatMilliseconds: 1234, bindings: [
            .init(key: "c", command: "split-window -h", repeat: false),
            .init(key: "h", command: #"new-window -n logs "tail -f /tmp/app.log""#, repeat: false),
            .init(key: "\\%", command: "split-window -h", repeat: false),
            .init(key: "Up", command: "select-pane -U", repeat: true),
        ], prefix2: "F12")
        let table = try XCTUnwrap(PrefixTable.tmux(server: reply))
        XCTAssertEqual(table.prefix, PrefixKey("a", control: true))
        XCTAssertEqual(table.prefix2, PrefixKey("F12"))
        XCTAssertEqual(table.repeatTime, 1.234, accuracy: 0.0001)
        XCTAssertEqual(table.bindings[PrefixKey("c")], PrefixBinding(action: .splitRight))
        XCTAssertEqual(table.bindings[PrefixKey("%")], PrefixBinding(action: .splitRight))
        XCTAssertEqual(table.bindings[PrefixKey("Up")], PrefixBinding(action: .tmux("select-pane -U"), repeats: true))
        XCTAssertEqual(table.rejected, [PrefixKey("h"): #"new-window -n logs "tail -f /tmp/app.log""#])
        XCTAssertNil(PrefixTable.tmux(server: .init(key: "None", repeatMilliseconds: 500, bindings: [], prefix2: nil)))
        XCTAssertNil(PrefixTable.tmux(server: .init(key: "C-a", repeatMilliseconds: nil, bindings: [], prefix2: "None"))?.prefix2)

        let keys = PrefixKeys(), surface = System.uuid()
        var performed: [PrefixAction] = [], refused: [String] = []
        keys.table = { _ in table }
        keys.perform = { action, _ in performed.append(action) }
        keys.reject = { command, _ in refused.append(command) }
        var ended = 0
        keys.finished = { _ in ended += 1 }
        XCTAssertFalse(keys.handle(prefix, surface: surface), "⌃B is not this server's prefix")
        XCTAssertTrue(keys.handle(key(0, "a", .control), surface: surface))
        XCTAssertTrue(keys.handle(key(8, "c"), surface: surface))
        XCTAssertTrue(keys.handle(key(111, "\u{F70F}"), surface: surface), "prefix2 arms the same table")
        XCTAssertTrue(keys.claims(key(4, "h"), surface: surface))
        XCTAssertTrue(keys.handle(key(4, "h"), surface: surface))
        XCTAssertNil(keys.armed)
        XCTAssertEqual(performed, [.splitRight])
        XCTAssertEqual(refused, [#"new-window -n logs "tail -f /tmp/app.log""#])
        XCTAssertTrue(keys.handle(key(111, "\u{F70F}"), surface: surface))
        XCTAssertFalse(keys.handle(key(111, "\u{F70F}"), surface: surface), "prefix2 twice sends it to the terminal")
        XCTAssertTrue(keys.handle(key(0, "a", .control), surface: surface))
        XCTAssertTrue(keys.handle(key(53, "\u{1B}"), surface: surface))
        XCTAssertTrue(keys.handle(key(0, "a", .control), surface: surface))
        XCTAssertTrue(keys.handle(key(7, "y"), surface: surface), "An unbound key ends the sequence")
        XCTAssertEqual(ended, 5, "Every ended sequence is reported, so the server's table is read again")
    }
}
