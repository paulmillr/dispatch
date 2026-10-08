import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class PlanOneTests: XCTestCase {
    func testSourcePreviewUsesBoundedTypedTextOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        XCTAssertEqual(space.panes.map { $0.tabs.map(\.id) }, [[tabs[0], tabs[4]], [tabs[1]], [tabs[2]], [tabs[3]]])
        XCTAssertEqual(space.activeTab?.id, tabs[0])
        XCTAssertEqual(workspace.allTabIDs, Set(tabs))
        XCTAssertTrue(workspace.applyLayout(.single))
        XCTAssertEqual(workspace.currentTabs.map(\.id), [tabs[0], tabs[4], tabs[1], tabs[2], tabs[3]])
        for preset in LayoutPreset.allCases {
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
        let chat = ChatCoordinator(enabled: true); let session = chat.session(for: UUID())
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let own = try XCTUnwrap(sample.processes.first { $0.id == Int(getpid()) })
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
        var window = ContainerTab(id: UUID(), node: 1, name: "claude", arrangement: PaneArrangement(tab: tab))
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
                                    ("JetBrainsMono-Regular", "ttf", "JetBrains Mono"),
                                    ("FiraCode-Regular", "ttf", "Fira Code"),
                                    ("FiraCode-Bold", "ttf", "Fira Code"),
                                    ("0xProto-Regular", "otf", "0xProto")] {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: ext), name)
            let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)
            XCTAssertEqual(font?.familyName, family)
        }
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("Source Code Pro"))
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("0xProto"))
        XCTAssertTrue(SettingsView.monospacedFontFamilies.contains("Fira Code"))
        var preferences = Preferences(); preferences.spaceOrder = .tree
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).spaceOrder, .tree)
    }

}
