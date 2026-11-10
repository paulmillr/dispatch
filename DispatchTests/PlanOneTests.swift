import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class PlanOneTests: XCTestCase {
    func testSourcePreviewUsesBoundedTypedTextOperation() async throws {
        let root = System.temporary.appendingPathComponent(System.uuid().uuidString)
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = child.appendingPathComponent("source.swift")
        let document = ToolDocument(path: "source.swift", diff: "", workingDirectory: "child")
        let text = String(repeating: "let value = 42\n", count: 10000)
        for invalid in [false, true] {
            var bytes = Data(text.utf8)
            if invalid { bytes[0] = 0 }
            try bytes.write(to: file)
            let result = await Task { try await document.source(in: root.path) }.result
            if invalid { XCTAssertThrowsError(try result.get()) }
            else { XCTAssertEqual(try result.get(), text) }
        }
    }

    func testDiffContentCannotBecomeFileHeaders() {
        let hunk = "@@ -1 +1 @@\n--- old option\n+++ new option\n"
        let unified = "--- a/one.txt\n+++ b/one.txt\n" + hunk + "--- a/two.txt\n+++ b/two.txt\n@@ -0,0 +1 @@\n+added\n"
        let docs = ToolDocument.parse(ChatItem(id: "diff", kind: .tool, text: unified))
        XCTAssertEqual(docs.map(\.path), ["one.txt", "two.txt"])
        XCTAssertEqual(docs.first?.diff, hunk)
        let custom = "*** Begin Patch\n*** Update File: one.txt\n@@\n--- old option\n+++ new option\n*** End Patch"
        let patch = ToolDocument.parse(ChatItem(id: "patch", kind: .tool, text: custom))
        XCTAssertEqual(patch.map(\.path), ["one.txt"])
        XCTAssertEqual(patch.first?.diff, "@@\n--- old option\n+++ new option\n")
    }

    func testSourcePreviewResolvesRelativeWorkdirAndRejectsOversizedAndBinaryFiles() async throws {
        let root = System.temporary.appendingPathComponent(System.uuid().uuidString)
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("wrong directory".utf8).write(to: root.appendingPathComponent("file.swift"))
        let file = child.appendingPathComponent("file.swift")
        try Data("correct directory".utf8).write(to: file)
        let document = ToolDocument(path: "file.swift", diff: "", workingDirectory: "child")
        let source = try await document.source(in: root.path)
        XCTAssertEqual(source, "correct directory")
        try Data(repeating: 65, count: 2_000_001).write(to: file)
        let oversized = await Task { try await document.source(in: root.path) }.result
        XCTAssertThrowsError(try oversized.get())
        // Text with a NUL byte is not previewed as text (ported from SSHProtocolV2Tests' source preview).
        try Data("\0let value = 42\n".utf8).write(to: file)
        let binary = await Task { try await document.source(in: root.path) }.result
        XCTAssertThrowsError(try binary.get())
    }

    /// ⌃1…4 name layouts by physical digit key, so every keyboard layout reaches the same presets.
    func testLayoutShortcutsNameLayoutsByPhysicalKey() {
        XCTAssertEqual([18, 19, 20, 21].map { LayoutPreset.shortcut(keyCode: $0) }, [.single, .columns, .twoAbove, .grid])
        XCTAssertNil(LayoutPreset.shortcut(keyCode: 23), "⌃5 is not a layout")
        XCTAssertEqual([22, 28].map { LayoutPreset.shortcut(keyCode: $0) }, [.six, .eight], "⌃6 and ⌃8 name their pane counts")
        XCTAssertNil(LayoutPreset.shortcut(keyCode: 26), "⌃7 is not a layout")
        XCTAssertNil(LayoutPreset.shortcut(keyCode: 0))
    }

    /// Mission Control's enabled "Switch to Desktop N" shortcuts that are still ⌃digit take those spaces' keys.
    func testDesktopShortcutConflictsReadMissionControlHotKeys() {
        let control = 262_144, option = 524_288
        let hotKeys: [String: Any] = [
            "118": ["enabled": true],  // no value: the default ⌃1
            "119": ["enabled": true, "value": ["parameters": [50, 19, control], "type": "standard"]],
            "120": ["enabled": true, "value": ["parameters": [51, 20, control | option], "type": "standard"]],
            "121": ["enabled": false, "value": ["parameters": [52, 21, control], "type": "standard"]],
            "122": ["enabled": true, "value": ["parameters": [55, 26, control], "type": "standard"]],  // rebound to ⌃7
        ]
        XCTAssertEqual(ApplicationMenu.desktopShortcutConflicts(hotKeys), [1, 2, 7])
        XCTAssertEqual(ApplicationMenu.desktopShortcutConflicts(nil), [])
    }

    func testLayoutsRedistributeExistingTabsAndSingleMergesInSlotOrder() {
        let workspace = Workspace(); workspace.newSpace()
        for _ in 0..<4 { workspace.newTab() }
        let tabs = workspace.currentTabs.map(\.id)
        workspace.selectTab(tabs[0])
        workspace.onCloseTabs = { _ in XCTFail("A layout must never terminate a shell") }
        XCTAssertTrue(workspace.applyLayout(.grid))
        let space = workspace.current!
        XCTAssertEqual(space.panes.map { $0.tabs.map(\.id) }, [[tabs[0], tabs[1]], [tabs[2]], [tabs[3]], [tabs[4]]])
        XCTAssertEqual(space.activeTab?.id, tabs[0])
        XCTAssertEqual(workspace.allTabIDs, Set(tabs))
        XCTAssertTrue(workspace.applyLayout(.single))
        XCTAssertEqual(workspace.currentTabs.map(\.id), tabs)
        for preset in LayoutPreset.allCases where preset.count <= tabs.count {
            XCTAssertTrue(workspace.applyLayout(preset))
            XCTAssertEqual(workspace.current?.panes.count, preset.count)
            XCTAssertEqual(workspace.allTabIDs, Set(tabs))
        }
    }
    func testInsufficientTabsCannotCreateShellsAndEdgeDropKeepsIdentity() {
        let workspace = Workspace(); workspace.newSpace()
        let first = workspace.activeTab!.id; let pane = workspace.current!.focusedPane
        workspace.split(.columns)
        XCTAssertEqual(workspace.current?.panes.count, 1)
        XCTAssertFalse(workspace.applyLayout(.grid))
        XCTAssertFalse(workspace.splitTab(first, beside: pane, edge: .right))
        workspace.newTab(); let second = workspace.activeTab!.id
        XCTAssertFalse(workspace.canApplyLayout(.twoAbove))
        XCTAssertFalse(workspace.applyLayout(.twoAbove), "Three panes require three existing tabs")
        XCTAssertTrue(workspace.splitTab(second, beside: pane, edge: .left))
        XCTAssertEqual(workspace.current?.layout.paneIDs.last, pane)
        XCTAssertEqual(workspace.allTabIDs, Set([first, second]))
        XCTAssertEqual(workspace.activeTab?.id, second)
        workspace.moveTab(second, to: pane)
        XCTAssertEqual(workspace.current?.panes.count, 1)
        XCTAssertEqual(workspace.allTabIDs, Set([first, second]))
    }
    func testTwoAboveLayoutEncodingAndRetiredPresetCompatibility() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(LayoutPreset.self, from: encoder.encode(LayoutPreset.twoAbove)), .twoAbove)
        XCTAssertEqual(try decoder.decode(LayoutPreset.self, from: Data(#""main + side""#.utf8)), .columns)
        XCTAssertEqual(LayoutPreset.twoAbove.count, 3)
        XCTAssertEqual(LayoutPreset.allCases[3], .twoAbove, "Keep the layout picker ordering")
    }

    /// Six and eight panes split the window evenly (a third across for three), in reading order, each with its ⌘ digit;
    /// a smaller layout afterwards needs no saved ratios.
    func testSixAndEightPaneGridsShareTheWindowEvenly() throws {
        let workspace = Workspace(); workspace.newSpace()
        for _ in 0..<7 { workspace.newTab() }
        let tabs = workspace.currentTabs.map(\.id)
        workspace.onCloseTabs = { _ in XCTFail("A layout must never terminate a shell") }
        for (preset, columns) in [(LayoutPreset.six, 3), (.eight, 4)] {
            XCTAssertTrue(workspace.canApplyLayout(preset))
            XCTAssertTrue(workspace.applyLayout(preset))
            let space = try XCTUnwrap(workspace.current)
            XCTAssertEqual(space.panes.count, preset.count)
            XCTAssertEqual(space.preset, preset)
            XCTAssertEqual(workspace.allTabIDs, Set(tabs))
            let frames = space.layout.paneFrames(fractions: space.paneFractions)
            for frame in frames.map(\.frame) {
                XCTAssertEqual(frame.width, 1 / CGFloat(columns), accuracy: 0.0001)
                XCTAssertEqual(frame.height, 0.5, accuracy: 0.0001)
            }
            XCTAssertEqual(space.numberedPaneIDs, space.layout.paneIDs, "Tree order is reading order")
            XCTAssertEqual(space.numberedShortcutCount, preset.count)
            XCTAssertEqual(space.paneShortcutNumber(for: space.layout.paneIDs.last!), preset.count)
            workspace.selectPane(at: preset.count - 1)
            XCTAssertEqual(workspace.current?.focusedPane, space.layout.paneIDs.last)
            let cells = frames.map(\.frame)
            let places = cells.indices.map { SpaceTabsList.place(cells[$0], among: cells, index: $0) }
            XCTAssertEqual(places, columns == 3
                ? ["Top left", "Top middle", "Top right", "Bottom left", "Bottom middle", "Bottom right"]
                : (1...8).map { "Pane \($0)" }, "Four across has two middles: every heading numbers")
        }
        XCTAssertTrue(workspace.applyLayout(.grid))
        XCTAssertEqual(workspace.current?.splitRatios, [:])
        XCTAssertEqual(workspace.current?.panes.count, 4)
        XCTAssertEqual(workspace.allTabIDs, Set(tabs))
        XCTAssertEqual(try JSONDecoder().decode(LayoutPreset.self, from: JSONEncoder().encode(LayoutPreset.eight)), .eight)
    }

    /// Six and eight panes are offered only with room for them; a layout already applied stays when the room
    /// shrinks (a display disconnected), and up to four panes ignore the room.
    func testLargeLayoutsNeedRoomAndKeepWhenTheWindowShrinks() throws {
        let workspace = Workspace(); workspace.newSpace()
        for _ in 0..<7 { workspace.newTab() }
        let cell = CGSize(width: 8.4, height: 18)
        // A 5K display's points with the sidebar shown, then a 14-inch laptop's.
        let large = LayoutRoom(window: CGSize(width: 2300, height: 1380), screen: CGSize(width: 2300, height: 1380), cell: cell)
        let laptop = LayoutRoom(window: CGSize(width: 1250, height: 900), screen: CGSize(width: 1250, height: 900), cell: cell)
        workspace.layoutRoom = large
        XCTAssertTrue(workspace.canApplyLayout(.eight))
        XCTAssertEqual(LayoutOptions.shown(space: workspace.current, workspace: workspace), LayoutPreset.allCases)
        XCTAssertTrue(workspace.applyLayout(.eight))
        workspace.layoutRoom = laptop
        XCTAssertEqual(workspace.current?.preset, .eight, "Less room never rearranges the panes")
        XCTAssertEqual(workspace.current?.panes.count, 8)
        XCTAssertFalse(workspace.canApplyLayout(.six))
        XCTAssertFalse(workspace.applyLayout(.six))
        XCTAssertEqual(LayoutOptions.shown(space: workspace.current, workspace: workspace),
                       [.single, .columns, .rows, .twoAbove, .grid, .eight], "The space's own layout keeps its row")
        XCTAssertTrue(workspace.canApplyLayout(.grid))
        XCTAssertTrue(workspace.applyLayout(.grid))
        XCTAssertEqual(LayoutOptions.shown(space: workspace.current, workspace: workspace), [.single, .columns, .rows, .twoAbove, .grid])
        // A small window on a large screen: offered, but disabled until the window grows.
        workspace.layoutRoom = LayoutRoom(window: laptop.window, screen: large.screen, cell: cell)
        XCTAssertTrue(LayoutOptions.shown(space: workspace.current, workspace: workspace).contains(.eight))
        XCTAssertFalse(workspace.canApplyLayout(.eight))
        XCTAssertTrue(workspace.hasRoom(for: .eight, screen: true))
        // Sixty columns and 24 rows a pane, inside the terminal's padding (whole cells, for exact sums).
        let whole = CGSize(width: 8, height: 16)
        XCTAssertTrue(LayoutPreset.six.fits(CGSize(width: 3 * (60 * 8 + 20), height: 2 * (24 * 16 + 20)), cell: whole))
        XCTAssertFalse(LayoutPreset.six.fits(CGSize(width: 3 * (60 * 8 + 20) - 3, height: 2 * (24 * 16 + 20)), cell: whole))
        XCTAssertTrue(LayoutPreset.eight.fits(CGSize(width: 4 * (60 * 8 + 20), height: 2 * (24 * 16 + 20)), cell: whole))
        XCTAssertFalse(LayoutPreset.eight.fits(CGSize(width: 4 * (60 * 8 + 20), height: 2 * (24 * 16 + 20) - 2), cell: whole))
        XCTAssertTrue(LayoutPreset.grid.fits(.zero, cell: whole), "Up to four panes ignore the room")
        let measured = TerminalFontScale.cell(14, family: TerminalFontCatalog.defaultFamily)
        XCTAssertEqual(measured.width, 8.4, accuracy: 0.05, "Source Code Pro advances 0.6 em")
        XCTAssertGreaterThan(measured.height, 14)
    }
    func testMovingAcrossSpacesAndToNewSpaceKeepsEveryTab() {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab()
        let tab = workspace.activeTab!.id
        workspace.newSpace(); let target = workspace.current!.focusedPane
        let ids = workspace.allTabIDs
        workspace.onCloseTabs = { _ in XCTFail("Moving spaces must preserve shells") }
        XCTAssertTrue(workspace.moveTab(tab, to: target))
        XCTAssertEqual(workspace.currentTabs.count, 2)
        workspace.moveTabToNewSpace(tab)
        XCTAssertEqual(workspace.spaces.count, 3)
        XCTAssertEqual(workspace.currentTabs.map(\.id), [tab])
        XCTAssertEqual(workspace.allTabIDs, ids)
        workspace.newTab(); workspace.newTab(); workspace.newTab()
        workspace.applyLayout(.grid)
        workspace.onCloseTabs = { _ in }
        for _ in 0..<3 { workspace.closeTab(workspace.activeTab!.id) }
        XCTAssertEqual(workspace.current?.preset, .single)
        XCTAssertEqual(workspace.current?.panes.count, 1)
    }
    func testSplittingSelectedTabChoosesNearestSourceNeighbor() {
        let workspace = Workspace(); workspace.newSpace(); workspace.newTab()
        let neighbor = workspace.activeTab!.id
        let sourcePane = workspace.current!.focusedPane
        workspace.newTab(); let moved = workspace.activeTab!.id
        workspace.split(.columns)
        XCTAssertEqual(workspace.current?.panes.first { $0.id == sourcePane }?.selected, neighbor)
        XCTAssertEqual(workspace.activeTab?.id, moved)
    }
    func testChatAvailabilityFollowsAttachmentAndSetting() {
        let chat = ChatCoordinator(enabled: true); let session = chat.session(for: System.uuid())
        XCTAssertFalse(chat.canEnterChat(session))
        XCTAssertTrue(chat.chatAvailabilityHint(session).contains("Start"))
        chat.toggle(session.id); XCTAssertFalse(session.showChat)
        session.active = true
        XCTAssertTrue(chat.canEnterChat(session))
        chat.toggle(session.id); XCTAssertTrue(session.showChat)
        session.active = false; session.showChat = false
        chat.toggle(session.id); XCTAssertTrue(session.showChat, "Previously opened chat remains available after the agent exits")
        XCTAssertTrue(ChatCoordinator(enabled: false).chatAvailabilityHint(session).contains("Settings"))
    }
    func testToolPatchAndSourceUseRealLocalFile() async throws {
        let patch = "*** Begin Patch\n*** Update File: a.swift\n@@\n-old\n+new\n*** Add File: b.swift\n+hello\n*** End Patch"
        let input = String(decoding: try JSONSerialization.data(withJSONObject: ["patch": patch]), as: UTF8.self)
        let documents = ToolDocument.parse(ChatItem(id: "call", kind: .tool, text: input, title: "apply_patch"))
        XCTAssertEqual(documents.map(\.path), ["a.swift", "b.swift"])
        XCTAssertEqual(documents[0].diff, "@@\n-old\n+new\n")
        let deletion = ToolDocument.parse(ChatItem(id: "delete", kind: .tool, text: "--- a/old.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"))
        XCTAssertEqual(deletion.first?.path, "old.swift")
        XCTAssertTrue(deletion.first?.diff.contains("-old") == true)
        let shellPatch = ToolDocument.parse(ChatItem(id: "shell", kind: .tool, text: "apply_patch <<'PATCH'\n" + patch + "\nPATCH\nprintf unrelated"))
        XCTAssertFalse(shellPatch.last?.diff.contains("unrelated") == true)
        let directory = System.temporary.appendingPathComponent(System.uuid().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "new\n".write(to: directory.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let source = try await documents[0].source(in: directory.path)
        XCTAssertEqual(source, "new\n")
        let missing = await Task { try await documents[1].source(in: directory.path) }.result
        XCTAssertThrowsError(try missing.get())
        try Data([0, 1]).write(to: directory.appendingPathComponent("b.swift"))
        let binary = await Task { try await documents[1].source(in: directory.path) }.result
        XCTAssertThrowsError(try binary.get())
    }
    func testHostSampling() async throws {
        var sampler = HostSampler()
        let sample = try await sampler.sample()
        XCTAssertGreaterThan(sample.memoryTotal, 0)
        XCTAssertGreaterThan(sample.diskTotal, 0)
        XCTAssertFalse(sample.cores.isEmpty)
        XCTAssertFalse(sample.processes.isEmpty)
        XCTAssertTrue((0...100).contains(sample.memoryPercent))
        // Rows name the executable and count bytes: this test's own process is one of them.
        let own = try XCTUnwrap(sample.processes.first { $0.id == Int(System.pid) })
        XCTAssertEqual(own.name, ProcessInfo.processInfo.processName)
        XCTAssertGreaterThan(own.memory, 0)
    }
    func testAutomaticTabNamesFollowConversationProgramThenFolder() throws {
        XCTAssertTrue(Preferences().automaticTabNames)
        var preferences = Preferences(); preferences.automaticTabNames = false
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
        var tab = TerminalTab(directory: "/work/src/project")
        // Shell integration's prompt titles (zsh, zsh abbreviated, bash) versus command lines.
        for (title, conversation, automatic) in [
            ("~/work/src/project", nil, "project"), ("…/work/src/project", nil, "project"), ("/work/src/project", nil, "project"),
            ("vim notes.md", nil, "vim notes.md"), ("/usr/bin/python3 run.py", nil, "/usr/bin/python3 run.py"),
            ("~/work/src/project", " \n", "project"), ("✳ Claude Code", "Fix startup", "Fix startup"),
        ] as [(String, String?, String)] {
            tab.title = title
            XCTAssertEqual(tab.displayLabel(automatic: true, conversation: conversation), automatic, title)
            XCTAssertEqual(tab.displayLabel(automatic: false, conversation: conversation), title)
        }
        tab.customTitle = "Server"
        XCTAssertEqual(tab.displayLabel(automatic: true, conversation: "Fix startup"), "Server")

        // tmux windows follow the conversation over tmux's automatic name, but not over a hand-given one.
        var window = ContainerTab(id: System.uuid(), node: 1, name: "claude", arrangement: PaneArrangement(tab: tab))
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: "Fix startup"), "Fix startup")
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: nil), "claude")
        XCTAssertEqual(window.displayLabel(automatic: false, conversation: "Fix startup"), "claude")
        window.renamed = true
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: "Fix startup"), "claude")
    }

    func testBundledFontsAndPersistedSidebarMode() throws {
        AppFont.register()
        XCTAssertNotNil(NSFont(name: "SourceCodePro-Regular", size: 12))
        XCTAssertNotNil(NSFont(name: "0xProto-Regular", size: 12))
        for (name, ext, family) in [("DepartureMono-Regular", "otf", "Departure Mono"),
                                    ("IoskeleyMonoTerm-Regular", "ttf", "Ioskeley Mono Term"),
                                    ("Resources/JetBrainsMono-Variable", "ttf", "JetBrains Mono"),
                                    ("FiraCode-Regular", "ttf", "Fira Code"),
                                    ("FiraCode-Bold", "ttf", "Fira Code"),
                                    ("0xProto-Regular", "otf", "0xProto"),
                                    ("lmroman10-regular", "otf", "Latin Modern Roman"),
                                    ("lmmono10-regular", "otf", "Latin Modern Mono")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: System.resources.appendingPathComponent(name + "." + ext).path), name)
            let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)
            XCTAssertEqual(font?.familyName, family)
        }
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("Source Code Pro"))
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("0xProto"))
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("Fira Code"))
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("JetBrains Mono"))
        // The engine's variable JetBrains Mono has real bold and italic faces (no static files).
        let members = NSFontManager.shared.availableMembers(ofFontFamily: "JetBrains Mono")?.compactMap { $0[1] as? String } ?? []
        XCTAssertTrue(Set(["Regular", "Bold", "Italic", "Bold Italic"]).isSubset(of: members), "\(members)")
        // Latin Modern: Roman (a chat font) bolds itself; Mono (a terminal font, so chat's Same as code) bolds in Latin
        // Modern Mono Light, which Settings doesn't list.
        for name in ["LMRoman10-Regular", "LMRoman10-Bold", "LMRoman10-Italic", "LMRoman10-BoldItalic", "LMMono10-Regular",
                     "LMMono10-Italic", "LMMonoLt10-Bold", "LMMonoLt10-BoldOblique"] {
            XCTAssertNotNil(NSFont(name: name, size: 12), name)
        }
        XCTAssertEqual(ChatFont.boldPostScriptName("LMMono10-Italic"), "LMMonoLt10-BoldOblique")
        XCTAssertNil(ChatFont.boldPostScriptName("LMRoman10-Regular"))
        XCTAssertFalse(SettingsView.terminalFontFamilies.contains("Latin Modern Mono Light"))
        // Dispatch's own fonts (the more bundled ones too) by name, after the installed ones and a separator.
        let menu = SettingsView.fontMenuChoices
        let separator = try XCTUnwrap(menu.firstIndex(of: SettingsDropdown.separator))
        let own = Array(menu[(separator + 1)...]); XCTAssertEqual(own, own.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(menu[..<separator].contains("PT Mono"), "macOS's own fonts stay above the separator"); XCTAssertEqual(Set(own), Set(menu.dropFirst().filter(AppFont.bundledFamilies.contains)).union(SettingsView.moreBundledFontFamilies))
        XCTAssertTrue(Set(SettingsView.moreBundledFontFamilies).isDisjoint(with: SettingsView.monospacedFontFamilies))
        for family in SettingsView.moreBundledFontFamilies {
            XCTAssertNotNil(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12), family)
        }
        var mono = Preferences(); (mono.chatFont, mono.fontFamily) = (.sameAsCode, "Latin Modern Mono")
        let typography = ChatTypography(preferences: mono)
        XCTAssertEqual(typography.fontName, "LMMono10-Regular")
        XCTAssertEqual(typography.font(weight: .semibold), Font.custom("LMMonoLt10-Bold", fixedSize: typography.pointSize()))
        // Terminal fonts draw at Source Code Pro's lowercase height: the default exactly, others scaled to it.
        XCTAssertEqual(TerminalFontScale.size(12.5, family: "Source Code Pro"), 12.5)
        XCTAssertEqual(TerminalFontScale.factor("No Such Font \(System.uuid())"), 1)
        let reference = try XCTUnwrap(TerminalFontScale.lowercaseHeight("Source Code Pro"))
        for family in ["Inconsolata", "Victor Mono", "JetBrains Mono", "Latin Modern Mono", "Menlo"] {
            let height = try XCTUnwrap(TerminalFontScale.lowercaseHeight(family), family)
            XCTAssertEqual(height * TerminalFontScale.factor(family), reference, accuracy: reference * 0.002, family)
        }
        XCTAssertGreaterThan(TerminalFontScale.factor("Inconsolata"), 1.05)
        XCTAssertLessThan(TerminalFontScale.factor("Victor Mono"), 0.8)
        // Chat's faces and the interface's San Francisco draw at Source Code Pro's lowercase height too, at every size
        // (the system font changes optical size with it), measured the same way.
        let heightOf = { (font: NSFont) in try XCTUnwrap(TerminalFontScale.lowercaseHeight(font as CTFont)) }
        let interface = InterfaceFontStore.shared.current, codeFamily = InterfaceFontStore.shared.codeFamily
        defer { InterfaceFontStore.shared.current = interface; InterfaceFontStore.shared.codeFamily = codeFamily }
        for size in [10.0, 14, 18, 24] {
            let target = try heightOf(try XCTUnwrap(NSFont(name: "SourceCodePro-Regular", size: size)))
            for choice in ChatFont.allCases where choice != .sameAsCode {
                let scaled = size * choice.sizeScale
                let font = try XCTUnwrap(choice.systemFont(ofSize: scaled) ?? choice.postScriptName.flatMap { NSFont(name: $0, size: scaled) })
                XCTAssertEqual(try heightOf(font), target, accuracy: target * 0.005, "\(choice) at \(size)")
            }
            InterfaceFontStore.shared.current = .system
            XCTAssertEqual(try heightOf(AppFont.native(size: size)), target, accuracy: target * 0.005, "San Francisco at \(size)")
            // Same as code: the terminal font, at the size the terminal draws it.
            InterfaceFontStore.shared.current = .sameAsCode
            for family in ["Source Code Pro", "Inconsolata", "Victor Mono", "Latin Modern Mono"] {
                InterfaceFontStore.shared.codeFamily = family
                let font = AppFont.native(size: size)
                XCTAssertEqual(font.familyName, family)
                XCTAssertEqual(try heightOf(font), target, accuracy: target * 0.005, "Same as code in \(family) at \(size)")
            }
        }
        XCTAssertEqual(ChatFont.sameAsCode.sizeScale, 1)
        XCTAssertLessThan(ChatFont.system.sizeScale, 0.96, "SF Rounded's lowercase is taller than Source Code Pro's")
        // Chat's New York and San Francisco (drawn in SF Rounded): the system font's designs, never looked up by name.
        for (choice, design) in [(ChatFont.newYork, Font.Design.serif), (.system, .rounded)] {
            var chat = Preferences(); chat.chatFont = choice
            let typography = ChatTypography(preferences: chat)
            XCTAssertEqual(typography.font(), Font.system(size: typography.pointSize(), weight: .regular, design: design))
            XCTAssertNotEqual(choice.systemFont(ofSize: 12)?.familyName, NSFont.systemFont(ofSize: 12).familyName, "\(choice)")
        }
        var preferences = Preferences(); preferences.spaceOrder = .tree
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).spaceOrder, .tree)
    }

}

/// San Francisco draws in SF Rounded, which has no italic: chat's emphasis is San Francisco's italic at the same size
/// and weight, and fonts with italics of their own keep them.
extension PlanOneTests {
    func testChatEmphasisInRoundedDrawsSanFranciscoItalic() throws {
        let weightOf = { (font: CTFont) in (CTFontCopyTraits(font) as? [CFString: Any])?[kCTFontWeightTrait] as? CGFloat ?? -1 }
        for weight in [NSFont.Weight.regular, .semibold, .bold] {
            let upright = NSFont.systemFont(ofSize: 14, weight: weight)
            let rounded = try XCTUnwrap(upright.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 14) })
            let italic = try XCTUnwrap(ChatFont.italic(for: rounded), "\(weight)")
            XCTAssertTrue(CTFontGetSymbolicTraits(italic).contains(.traitItalic), "\(weight)")
            XCTAssertEqual(CTFontCopyFamilyName(italic) as String, upright.familyName)
            XCTAssertEqual(weightOf(italic), weightOf(upright), accuracy: 0.01, "\(weight)")
            XCTAssertEqual(CTFontGetSize(italic), 14)
        }
        XCTAssertNil(ChatFont.italic(for: NSFont.systemFont(ofSize: 14)), "San Francisco's own face")
        XCTAssertNil(ChatFont.italic(for: try XCTUnwrap(ChatFont.newYork.systemFont(ofSize: 14))), "New York has an italic")
        XCTAssertNil(ChatFont.italic(for: try XCTUnwrap(NSFont(name: "LMRoman10-Regular", size: 14))), "a font by name")
        XCTAssertFalse(ChatFont.allCases.map(\.rawValue).contains("SF Rounded"), "San Francisco is the rounded choice")
        let typography = ChatTypography(preferences: Preferences())
        XCTAssertEqual(typography.italic(), Font.system(size: typography.pointSize(), weight: .regular, design: .default).italic())
        XCTAssertEqual(typography.italic(offset: -2), Font.system(size: typography.pointSize(offset: -2), weight: .regular, design: .default).italic())
        var serif = Preferences(); serif.chatFont = .newYork
        let newYork = ChatTypography(preferences: serif)
        XCTAssertEqual(newYork.italic(), newYork.font().italic())
    }
}

/// A window the phone's launch named after its agent (`launch.names`: `new-window -n claude`) reads as renamed from
/// tmux, but follows its conversation as an unnamed one does; a name the user gave, or another agent's, stays.
extension PlanOneTests {
    func testALaunchNamedWindowFollowsItsConversation() {
        let tab = TerminalTab(directory: "/work/src/project")
        var window = ContainerTab(id: System.uuid(), node: 1, name: "claude", arrangement: PaneArrangement(tab: tab))
        window.renamed = true
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: "Fix startup", agent: "claude"), "Fix startup")
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: nil, agent: "claude"), "claude")
        XCTAssertEqual(window.displayLabel(automatic: false, conversation: "Fix startup", agent: "claude"), "claude")
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: "Fix startup", agent: "codex"), "claude")
        window.name = "Server"
        XCTAssertEqual(window.displayLabel(automatic: true, conversation: "Fix startup", agent: "claude"), "Server")
    }
}

/// Switching fonts changes the letters, not where lines fall: chat's prose and the interface's text are set on Source
/// Code Pro's line at their size whichever font draws them (`AppFont.lineHeight`), and text that changes in place
/// keeps its widest variant's width.
extension PlanOneTests {
    func testEveryFontSetsTextOnSourceCodeProsLines() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Line heights are set from macOS 26") }
        AppFont.register()
        let prose = String(repeating: "The queue drains once the link is back, and each retry waits for the reply. ", count: 4)
        for size in [14.0, 18] {
            let line = AppFont.lineHeight(size: size + 1)
            for choice in ChatFont.allCases {
                var preferences = Preferences(); preferences.fontSize = size; preferences.chatFont = choice
                var theme = ChatTheme.standard; theme.typography = ChatTypography(preferences: preferences)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close(); window.contentView = nil }
                window.contentView = NSHostingView(rootView: ChatMarkdown(text: prose).font(theme.typography.font(offset: 1))
                    .environment(\.chatTheme, theme).frame(width: 320))
                let root = try XCTUnwrap(window.contentView)
                try await TestSupport.eventually { PresentationTestSupport.views(of: NSTextView.self, in: root).first?.string.isEmpty == false }
                let view = try XCTUnwrap(PresentationTestSupport.views(of: NSTextView.self, in: root).first)
                let layout = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
                layout.ensureLayout(for: container)
                var origins: [CGFloat] = []
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, _, _ in origins.append(rect.minY) }
                XCTAssertGreaterThan(origins.count, 2, "\(choice) wraps")
                let pitches = Set(zip(origins.dropFirst(), origins).map { $0 - $1 })
                XCTAssertEqual(pitches, [line + theme.typography.lineSpacing], "\(choice) at \(size)")
            }
        }
        // The interface's roles: San Francisco's lines and every Same as code font's are Source Code Pro's, one line or
        // several, Latin Modern Mono's taller ones included.
        let interface = InterfaceFontStore.shared.current, codeFamily = InterfaceFontStore.shared.codeFamily
        defer { InterfaceFontStore.shared.current = interface; InterfaceFontStore.shared.codeFamily = codeFamily }
        let typography = AppTypography(contentSize: 14)
        let choices: [(InterfaceFont, String)] = [(.sameAsCode, "Source Code Pro"), (.system, "Source Code Pro"),
                                                  (.sameAsCode, "Victor Mono"), (.sameAsCode, "Latin Modern Mono")]
        for role in [AppTypography.Role.title, .content, .label, .body, .caption, .micro] {
            var heights: [String: [CGFloat]] = [:]
            for (font, family) in choices {
                InterfaceFontStore.shared.current = font
                InterfaceFontStore.shared.codeFamily = family
                heights["\(font) \(family)"] = ["Queue", "Queue\ndrains"].map {
                    NSHostingView(rootView: Text($0).font(typography, role).fixedSize()).fittingSize.height
                }
            }
            XCTAssertEqual(Set(heights.values).count, 1, "\(role): \(heights)")
            XCTAssertEqual(heights["system Source Code Pro"]?.first, AppFont.lineHeight(size: typography.size(role)), "\(role)")
        }
        let widths = ["Play", "Copying…"].map {
            NSHostingView(rootView: ReservedText(text: $0, variants: ["Play", "Copying…"]).fixedSize()).fittingSize.width
        }
        XCTAssertEqual(widths[0], widths[1])
    }
}
