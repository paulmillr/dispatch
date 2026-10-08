import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class HostPerformanceTests: XCTestCase {
    func testHostSidebarPresentationAndScaling() async throws {
        try DesktopTestSupport.requireUnlocked()
        let controller = AppDelegate(), workspace = controller.workspace
        controller.settings.values.spaceOrder = .tree
        let names = ["homelab", "prod", "tinygrad", "builder", "legacy"]
        let systems = ["Linux", "Linux", "FreeBSD", "Darwin", ""]
        let distributions = ["ubuntu", "debian", "", "", ""]
        let groups = [["api-refactor", "ci-fix", "scratch"], ["nightly", "bench"], ["deploy", "canary"], ["train-7b"], ["release"], ["scratchpad"]]
        for (host, labels) in groups.enumerated() {
            for label in labels {
                var space = Space(name: label, directory: "/tmp")
                if host > 0 {
                    let terminal = space.tabs[0].id, generation = UUID(), name = names[host - 1]
                    workspace.hosts.begin(terminal, generation: generation, destination: "admin@" + name)
                    var greeting = SSHGreeting(version: 1, host: name, boot: "test", uid: 501, home: "/tmp", capabilities: [])
                    if !systems[host - 1].isEmpty { greeting.os = systems[host - 1]; greeting.distribution = distributions[host - 1] }
                    workspace.hosts.update(terminal, generation: generation, destination: "admin@" + name,
                                           greeting: greeting, state: host == 3 ? .disconnected : .connected)
                    space.hostID = .authenticated(name)
                }
                workspace.spaces.append(space)
            }
        }
        workspace.selectSpace(workspace.spaces[0].id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 264, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller))
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(350))
        _ = try await PresentationTestSupport.capture(window, named: "host-cards-six-hosts", in: "host-detection-validation")
        try PresentationTestSupport.click(window, at: NSPoint(x: 96, y: 50))
        var popoverText = ""
        try await TestSupport.eventually(diagnostic: "Host popover: \(popoverText)") {
            for candidate in NSApp.windows where candidate !== window && candidate.isVisible {
                let text = try await PresentationTestSupport.capture(candidate).text()
                popoverText = text
                if text.localizedCaseInsensitiveContains("ssh") && text.contains("admin@homelab") { return true }
            }
            return false
        }
        try PresentationTestSupport.click(window, at: NSPoint(x: 96, y: 50))
        XCTAssertEqual(workspace.selectedSpace, workspace.spaces[0].id, "Closing host information keeps the selected space")
        workspace.selectSpace(workspace.spaces[3].id)
        try await Task.sleep(for: .milliseconds(150))
        let field = try await PresentationTestSupport.openSpaceSearch(controller, in: view)
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
        editor.insertText("nightly", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await TestSupport.eventually {
            let filtered = try await PresentationTestSupport.capture(window, named: "host-filter", in: "host-detection-validation").text()
            return filtered.contains("nightly") && !filtered.contains("bench") && !filtered.contains("deploy") && !filtered.contains("scratchpad")
        }
        workspace.selectSpace(at: 0)
        XCTAssertEqual(field.stringValue, "nightly", "Space selection preserves the active filter")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await TestSupport.eventually { field.stringValue.isEmpty }
        controller.settings.values.spaceOrder = .flat
        try await Task.sleep(for: .milliseconds(200))
        _ = try await PresentationTestSupport.capture(window, named: "host-flat-labels", in: "host-detection-validation")
        controller.settings.values.spaceOrder = .tree
        for index in 0..<240 {
            var space = Space(name: "Work \(index)", directory: "/tmp")
            space.hostID = workspace.spaces[index % 10].hostID
            workspace.spaces.append(space)
        }
        let start = ContinuousClock.now
        workspace.spaceOrder = .tree
        for _ in 0..<200 { XCTAssertEqual(workspace.presentationSpaces.count, 250) }
        print("HOST PROFILE presentation 250 spaces x 200:", start.duration(to: .now))
        try await Task.sleep(for: .milliseconds(300))
        let rendering = ContinuousClock.now
        for index in 0..<6 {
            controller.settings.values.spaceOrder = index.isMultiple(of: 2) ? .flat : .tree
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        }
        print("HOST PROFILE sidebar 250 spaces / six order changes:", rendering.duration(to: .now))
    }

    func testBackgroundWatcherBatchCost() async {
        let watcher = HostProcessWatcher()
        let targets = (0..<16).map { _ in HostProcessTarget(terminal: UUID(), source: .terminal(UInt64(getpgrp()))) }
        let start = ContinuousClock.now
        for _ in 0..<100 { _ = await watcher.probe(targets) }
        print("HOST PROFILE 100 batches of 16 foreground groups:", start.duration(to: .now))
    }
}
