import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class NewSpacePresentationTests: XCTestCase {
    func testCaseBoundaryClearsLocalAndRemoteDiscovery() async {
        let hosts: [HostID] = [.local, .authenticated("case-remote")]
        var calls = 0
        var detected: Set<SpaceBackend> = [.native, .tmux]
        let cache = HostBackendCache(probe: { _ in calls += 1; return detected })
        for host in hosts { _ = await cache.installed(for: host, on: .local) }
        detected = [.native, .herdr]
        for host in hosts { _ = await cache.installed(for: host, on: .local) }
        XCTAssertEqual(hosts.map { cache.cached(for: $0) }, [[.native, .tmux], [.native, .tmux]])
        XCTAssertEqual(calls, 2)
        TestSupport.reset(cache)
        XCTAssertEqual(hosts.map { cache.cached(for: $0) }, [nil, nil])
        for host in hosts { _ = await cache.installed(for: host, on: .local) }
        XCTAssertEqual(hosts.map { cache.cached(for: $0) }, [[.native, .herdr], [.native, .herdr]])
        XCTAssertEqual(calls, 4)
    }

    func testResetOneHostRejectsLateProbeAndKeepsOtherHostCache() async throws {
        let host = HostID.authenticated("reset-one"), other = HostID.authenticated("keep-other")
        var finish: CheckedContinuation<Set<SpaceBackend>, Never>?
        let cache = HostBackendCache(probe: { machine in
            if machine == .local { return [.native, .tmux] }
            return await withCheckedContinuation { finish = $0 }
        })
        _ = await cache.installed(for: other, on: .local)
        let pending = Task { await cache.installed(for: host, on: .ssh(.init(destination: "fixture"))) }
        try await TestSupport.eventually { finish != nil }
        cache.reset(host)
        finish?.resume(returning: [.native, .herdr]); finish = nil
        _ = await pending.value
        XCTAssertNil(cache.cached(for: host))
        XCTAssertEqual(cache.cached(for: other), [.native, .tmux])
    }

    func testResetRemoteCacheRejectsLateProbeAndKeepsLocalDiscovery() async throws {
        var finish: CheckedContinuation<Set<SpaceBackend>, Never>?
        let cache = HostBackendCache(probe: { machine in
            if machine == .local { return [.native, .tmux] }
            return await withCheckedContinuation { finish = $0 }
        })
        _ = await cache.installed(for: .local, on: .local)
        let host = HostID.authenticated("reset-host")
        let pending = Task { await cache.installed(for: host, on: .ssh(.init(destination: "fixture"))) }
        try await TestSupport.eventually { finish != nil }
        cache.resetRemote()
        finish?.resume(returning: [.native, .herdr]); finish = nil
        _ = await pending.value
        XCTAssertNil(cache.cached(for: host))
        XCTAssertFalse(cache.probeFailed(for: host))
        XCTAssertEqual(cache.cached(for: .local), [.native, .tmux])
    }

    func testBackendCacheHasOneMinuteTTLAndUsesHostIdentityAcrossRoutes() async throws {
        var now = ContinuousClock.now
        var calls = 0
        var detected: Set<SpaceBackend> = [.native, .tmux]
        let cache = HostBackendCache(now: { now }, probe: { _ in calls += 1; return detected })
        let host = HostID.authenticated("cache-host"), other = HostID.authenticated("other-host")
        let first = await cache.installed(for: host, on: .ssh(SSHShell(destination: "alice@host")))
        XCTAssertEqual(first, [.native, .tmux])
        XCTAssertEqual(cache.refreshDelay(for: host), .seconds(60))
        now = now.advanced(by: .seconds(59))
        detected = [.native, .herdr]
        let alias = await cache.installed(for: host, on: .ssh(SSHShell(destination: "host-alias")))
        XCTAssertEqual(alias, first)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.refreshDelay(for: host), .seconds(1))
        XCTAssertNil(cache.cached(for: other))
        _ = await cache.installed(for: other, on: .ssh(SSHShell(destination: "other-host")))
        XCTAssertEqual(calls, 2)
        now = now.advanced(by: .seconds(1))
        XCTAssertNil(cache.cached(for: host))
        let refreshed = await cache.installed(for: host, on: .ssh(SSHShell(destination: "host-alias")))
        XCTAssertEqual(refreshed, [.native, .herdr])
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(cache.cached(for: other), [.native, .herdr])
    }

    func testBackendCacheSharesPendingProbeAndSurvivesClosingAView() async throws {
        var now = ContinuousClock.now
        var calls = 0
        var finish: CheckedContinuation<Set<SpaceBackend>, Never>?
        let cache = HostBackendCache(now: { now }, probe: { _ in
            calls += 1
            return await withCheckedContinuation { finish = $0 }
        })
        let host = HostID.authenticated("pending-host")
        let first = Task { await cache.installed(for: host, on: .ssh(SSHShell(destination: "host"))) }
        try await TestSupport.eventually { finish != nil }
        let second = Task { await cache.installed(for: host, on: .ssh(SSHShell(destination: "alias"))) }
        await Task.yield()
        first.cancel()
        XCTAssertEqual(calls, 1)
        now = now.advanced(by: .seconds(90))
        finish?.resume(returning: [.native, .tmux]); finish = nil
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [[.native, .tmux], [.native, .tmux]])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.cached(for: host), [.native, .tmux])
        XCTAssertEqual(cache.refreshDelay(for: host), .seconds(60), "TTL begins when the probe finishes")
    }

    func testBackendCacheAlsoCachesNoInstalledBackends() async throws {
        var now = ContinuousClock.now
        var calls = 0
        let cache = HostBackendCache(now: { now }, probe: { _ in calls += 1; return [.native] })
        let host = HostID.authenticated("plain-shell-host")
        _ = await cache.installed(for: host, on: .local)
        _ = await cache.installed(for: host, on: .local)
        XCTAssertEqual(cache.cached(for: host), [.native])
        XCTAssertEqual(calls, 1)
        now = now.advanced(by: .seconds(60))
        _ = await cache.installed(for: host, on: .local)
        XCTAssertEqual(calls, 2)
    }

    func testFailedBackendProbeStaysUnknownAndRetriesSoon() async {
        var now = ContinuousClock.now
        var calls = 0
        let host = HostID.authenticated("temporarily-unreachable")
        let cache = HostBackendCache(now: { now }, probe: { _ in
            calls += 1
            return calls == 1 ? nil : [.native, .tmux]
        })
        let initial = await cache.installed(for: host, on: .local)
        XCTAssertEqual(initial, [.native], "The menu can still offer a plain terminal")
        XCTAssertNil(cache.cached(for: host), "A failed SSH probe must not claim tmux is absent")
        XCTAssertTrue(cache.probeFailed(for: host))
        XCTAssertEqual(cache.refreshDelay(for: host), .seconds(5))
        _ = await cache.installed(for: host, on: .local)
        XCTAssertEqual(calls, 1, "Keep a short cooldown to avoid repeated connections")
        now = now.advanced(by: .seconds(5))
        let recovered = await cache.installed(for: host, on: .local)
        XCTAssertEqual(recovered, [.native, .tmux])
        XCTAssertFalse(cache.probeFailed(for: host))
        XCTAssertEqual(cache.cached(for: host), [.native, .tmux])
    }

    func testRemoteBackendProbeLoadsZshInteractiveLoginPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend probe '" + UUID().uuidString)
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["tmux", "herdr"] {
            let executable = bin.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try "test \"$DISPATCH_PROBE_LOGIN\" = yes || exit 1\nexport PATH=".appending(HerdrLaunch.quote(bin.path)).appending("\n")
            .write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "export DISPATCH_PROBE_LOGIN=yes\n".write(to: directory.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        // Exercise the complete SSH command quoting and remote shell startup,
        // without contacting a host or reading the user's shell configuration.
        let ssh = directory.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        for argument in "$@"; do remote_command=$argument; done
        export ZDOTDIR=\(HerdrLaunch.quote(directory.path))
        export SHELL=/bin/zsh
        export PATH=/usr/bin:/bin
        exec /bin/sh -c "$remote_command"
        """
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let found = await SpaceBackend.installed(on: .ssh(SSHShell(destination: "fixture", executable: ssh.path)))
        XCTAssertEqual(found, [.native, .tmux, .herdr])
    }

    private func addRemote(_ name: String, to workspace: Workspace) -> HostID {
        var space = Space(name: name, directory: "/tmp")
        let shell = SSHShell(destination: name, executable: "/usr/bin/false")
        space.panes[0].tabs[0].machine = .ssh(shell)
        let terminal = space.tabs[0].id, generation = UUID()
        workspace.hosts.begin(terminal, generation: generation, destination: name)
        workspace.hosts.update(terminal, generation: generation, destination: name,
            greeting: SSHGreeting(version: 1, host: name, boot: "test", uid: 501, home: "/tmp", capabilities: []), state: .connected)
        space.hostID = .authenticated(name)
        workspace.spaces.append(space)
        return space.hostID
    }

    /// The new space's tab runs that backend's command on its machine (a plain shell for native).
    private func runs(_ backend: SpaceBackend, in workspace: Workspace) -> Bool {
        guard let tab = workspace.activeTab else { return false }
        return tab.launchCommand == tab.machine.command(running: backend.command)
    }

    func testGlobalChoicesGroupInstalledBackendsByHostAndTargetEachMachine() async throws {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let first = addRemote("127.0.0.1", to: workspace)
        let second = addRemote("build", to: workspace)
        let probe: @Sendable (TerminalMachine) async -> Set<SpaceBackend> = { machine in
            switch machine {
            case .local: [.native, .tmux]
            case .ssh(let shell): shell.destination == "build" ? [.native, .herdr] : [.native, .tmux, .herdr]
            }
        }
        let choices = await NewSpaceMenu.choices(workspace: workspace, probe: probe)
        XCTAssertEqual(choices.map(\.title), ["New space", "New tmux space",
            "New space on 127.0.0.1", "New tmux space on 127.0.0.1", "New herdr space on 127.0.0.1",
            "New space on build", "New herdr space on build"])
        XCTAssertEqual(choices.map(\.host), [.local, .local, first, first, first, second, second])
        for choice in choices {
            workspace.newSpace(on: choice.host, backend: choice.backend)
            XCTAssertEqual(workspace.current?.hostID, choice.host)
            XCTAssertTrue(runs(choice.backend ?? .native, in: workspace))
            if case .ssh(let shell) = workspace.activeTab?.machine {
                XCTAssertEqual(shell.destination, workspace.hosts.record(choice.host).name)
            } else { XCTAssertEqual(choice.host, .local) }
        }
        let scoped = await NewSpaceMenu.choices(workspace: workspace, host: second, probe: probe)
        XCTAssertEqual(scoped.map(\.title), ["New space", "New herdr space"])
        XCTAssertTrue(scoped.allSatisfy { $0.host == second })
    }

    func testHostScopedMenuShowsOnlyDirectBackendChoices() async throws {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let remote = addRemote("homelab", to: workspace)
        _ = addRemote("other-host", to: workspace)
        for host in [HostID.local, remote] {
            let groups = await NewSpaceMenu.groups(workspace: workspace, host: host,
                probe: { _ in [.native, .tmux, .herdr] }, helperAvailable: { _ in false })
            XCTAssertEqual(groups.map(\.host.id), [host])
            XCTAssertTrue(groups.flatMap(\.options).allSatisfy { $0.choice.host == host })
            let button = NewSpaceNativeButton()
            button.host = host
            let menu = button.makeMenu(groups: groups)
            XCTAssertEqual(menu.items.map(\.title), host == .local
                ? ["New plain space", "New tmux space", "New herdr space"]
                : ["New plain space", "New tmux space", "New herdr space    no helper"])
            XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })
            XCTAssertEqual(menu.items.last?.isEnabled, host == .local)
            menu.performActionForItem(at: 1)
            XCTAssertEqual(workspace.current?.hostID, host)
            XCTAssertTrue(runs(.tmux, in: workspace))
        }
    }

    func testHostSubmenusPreserveContextAndDisableHerdrWithoutItsHelper() async throws {
        AppFont.register()
        let workspace = Workspace()
        workspace.newLocalSpace()
        let remote = addRemote("homelab", to: workspace)
        workspace.selectSpace(try XCTUnwrap(workspace.spaces.last).id)
        let probe: @Sendable (TerminalMachine) async -> Set<SpaceBackend> = { _ in [.native, .tmux, .herdr] }
        let groups = await NewSpaceMenu.groups(workspace: workspace, probe: probe, helperAvailable: { _ in false })
        let button = NewSpaceNativeButton()
        button.create = { workspace.newSpace(on: workspace.current?.hostID ?? .local) }
        let menu = button.makeMenu(groups: groups)
        XCTAssertEqual(menu.items.map(\.title), ["New space here", "", "On host", "local", "homelab"])
        XCTAssertEqual(menu.items[0].keyEquivalent, "n")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, .command)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        let localMenu = try XCTUnwrap(menu.items[3].submenu)
        let remoteMenu = try XCTUnwrap(menu.items[4].submenu)
        XCTAssertNotNil(menu.items[3].image)
        XCTAssertNotNil(menu.items[4].image)
        XCTAssertEqual(localMenu.items.map(\.title), ["New plain space", "New tmux space", "New herdr space"])
        XCTAssertEqual(remoteMenu.items.map(\.title), ["New plain space", "New tmux space", "New herdr space    no helper"])
        XCTAssertTrue(localMenu.items.allSatisfy(\.isEnabled))
        XCTAssertFalse(remoteMenu.items[2].isEnabled)
        XCTAssertTrue(remoteMenu.items[2].attributedTitle?.string.contains("no helper") == true)
        XCTAssertNil(groups.last?.options.last?.action)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(workspace.current?.hostID, remote)
        remoteMenu.performActionForItem(at: 1)
        XCTAssertEqual(workspace.current?.hostID, remote)
        XCTAssertTrue(runs(.tmux, in: workspace))
        localMenu.performActionForItem(at: 0)
        XCTAssertEqual(workspace.current?.hostID, .local)
        XCTAssertTrue(runs(.native, in: workspace))

        let authorized = await NewSpaceMenu.groups(workspace: workspace, probe: probe, helperAvailable: { _ in true })
        XCTAssertNotNil(authorized.last?.options.last?.action)
        XCTAssertNil(authorized.last?.options.last?.unavailableReason)
        let limited = await NewSpaceMenu.groups(workspace: workspace, probe: { _ in [.native] })
        XCTAssertTrue(limited.allSatisfy { $0.options.map(\.choice.backend) == [.native] })
    }

    func testInstalledBackendProbeHidesMissingCommandsAndHandlesFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ssh")
        let machine = TerminalMachine.ssh(SSHShell(destination: "fixture", executable: executable.path))
        for (output, status, expected): (String, Int, Set<SpaceBackend>?) in [
            ("dispatch-backend:tmux\\ndispatch-backend:complete", 0, [.native, .tmux]),
            ("dispatch-backend:herdr\\ndispatch-backend:complete", 0, [.native, .herdr]),
            ("dispatch-backend:tmux\\ndispatch-backend:herdr\\ndispatch-backend:complete", 0, [.native, .tmux, .herdr]),
            ("login banner\\ndispatch-backend:complete", 0, [.native]),
            ("login banner", 0, nil),
            ("dispatch-backend:tmux", 0, nil),
            ("dispatch-backend:tmux\\ndispatch-backend:complete", 1, nil)
        ] {
            try "#!/bin/sh\nprintf '\(output)\\n'\nexit \(status)\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let installed = await SpaceBackend.installed(on: machine)
            XCTAssertEqual(installed, expected)
        }
    }

    func testFlatHostGlyphsShareTheSpaceNameCentreLine() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let controller = AppDelegate(), workspace = controller.workspace
        controller.settings.values = Preferences()
        controller.settings.values.spaceOrder = .flat
        workspace.newLocalSpace()
        for (name, os, distribution) in [("mac-host", "Darwin", nil), ("ubuntu-host", "Linux", "ubuntu"), ("plain-host", nil, nil)] as [(String, String?, String?)] {
            var space = Space(name: name, directory: "/tmp")
            let shell = SSHShell(destination: "admin@" + name, options: [])
            space.panes[0].tabs[0].machine = .ssh(shell)
            let terminal = space.tabs[0].id, generation = UUID()
            workspace.hosts.begin(terminal, generation: generation, destination: shell.destination)
            var greeting = SSHGreeting(version: 1, host: name, boot: "test", uid: 501, home: "/tmp", capabilities: [])
            greeting.os = os; greeting.distribution = distribution
            workspace.hosts.update(terminal, generation: generation, destination: shell.destination, greeting: greeting, state: .connected)
            space.hostID = .authenticated(name)
            workspace.spaces.append(space)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        let text = try await PresentationTestSupport.capture(window, named: "flat-host-glyphs", in: "new-space-validation").text()
        for name in ["mac-host", "ubuntu-host", "plain-host"] {
            XCTAssertTrue(text.contains(name), {
                let root = window.contentView
                let rows = root.map { PresentationTestSupport.views(of: ReorderTrackingView.self, in: $0) } ?? []
                let scrolls = root.map { PresentationTestSupport.views(of: NSScrollView.self, in: $0) } ?? []
                return "\(text); rows=\(rows.map { "\($0.configuration.item) \($0.convert($0.bounds, to: root))" }); scrolls=\(scrolls.map { "viewport=\($0.contentView.bounds) document=\(String(describing: $0.documentView?.bounds))" })"
            }())
        }
    }

    func testEachHostOffersNewSpaceInItsHeaderWithLocalShortcutHint() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let previousPointer = CGEvent(source: nil)?.location
        defer { if let previousPointer { CGWarpMouseCursorPosition(previousPointer) } }
        let controller = AppDelegate(), workspace = controller.workspace
        controller.settings.values = Preferences()
        controller.settings.values.spaceOrder = .tree
        workspace.newLocalSpace()
        let local = try XCTUnwrap(workspace.selectedSpace)
        var remote = Space(name: "remote-work", directory: "/tmp")
        let shell = SSHShell(destination: "admin@fixture", options: ["-p", "2222"])
        remote.panes[0].tabs[0].machine = .ssh(shell)
        let terminal = remote.tabs[0].id, generation = UUID()
        workspace.hosts.begin(terminal, generation: generation, destination: shell.destination)
        let greeting = SSHGreeting(version: 1, host: "fixture", boot: "test", uid: 501, home: "/tmp", capabilities: [])
        workspace.hosts.update(terminal, generation: generation, destination: shell.destination, greeting: greeting, state: .connected)
        remote.hostID = .authenticated("fixture")
        workspace.spaces.append(remote)
        workspace.selectSpace(local)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SpaceSidebar(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); window.contentView = nil }
        func buttons() async throws -> [CGRect] {
            try await PresentationTestSupport.capture(try XCTUnwrap(window.contentView)).recognizedText()
                .filter { observation in
                    let text = (observation.topCandidates(1).first?.string ?? "").replacingOccurrences(of: " ", with: "")
                    return text.contains("+space") || text.contains("+local")
                }
                .map(\.boundingBox).sorted { $0.midY > $1.midY }
        }
        try await TestSupport.eventually { try await buttons().count == 2 }
        let treeText = try await PresentationTestSupport.capture(window).text()
        XCTAssertTrue(treeText.contains("local"), treeText)
        func clickButton(at index: Int) async throws {
            let root = try XCTUnwrap(window.contentView)
            let host = index == 0 ? HostID.local : remote.hostID
            let controls = PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root)
            let control = try XCTUnwrap(controls.first { $0.accessibilityIdentifier() == "host-new-space-\(host.rawValue)" },
                "host=\(host.rawValue), controls=\(controls.map { "\($0.accessibilityIdentifier() ?? "nil") \($0.convert($0.bounds, to: root))" }), scrolls=\(PresentationTestSupport.views(of: NSScrollView.self, in: root).map { "viewport=\($0.contentView.bounds) document=\(String(describing: $0.documentView?.bounds))" })")
            // Glass keeps a compact list and scrolls newly selected rows into view.
            // Reveal this host's header instead of treating the first visible label as local.
            control.scrollToVisible(control.bounds)
            var visible: CGRect?
            try await TestSupport.eventually {
                let frame = root.convert(control.bounds, from: control)
                visible = try await buttons().first { box in
                    frame.contains(NSPoint(x: box.midX * root.bounds.width,
                        y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height))
                }
                return visible != nil
            }
            let box = try XCTUnwrap(visible)
            let point = root.convert(NSPoint(x: box.midX * root.bounds.width,
                y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil)
            let screen = window.convertPoint(toScreen: point)
            let desktop = try XCTUnwrap(NSScreen.screens.first)
            let position = CGPoint(x: screen.x, y: desktop.frame.maxY - screen.y)
            XCTAssertEqual(CGWarpMouseCursorPosition(position), .success)
            let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: position, mouseButton: .left))
            move.postToPid(getpid())
            try await Task.sleep(for: .milliseconds(150))
            _ = try await PresentationTestSupport.capture(window, named: "new-space-hover-\(index)", in: "new-space-validation")
            try PresentationTestSupport.click(window, at: point)
        }
        let root = try XCTUnwrap(window.contentView)
        let rows = PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
        for (index, id) in [local, remote.id].enumerated() {
            let row = try XCTUnwrap(rows.first { $0.configuration.item == .space(id) })
            let frame = root.convert(row.bounds, from: row)
            let box = try await buttons()[index]
            let top = (root.isFlipped ? frame.minY : root.bounds.height - frame.maxY) / root.bounds.height
            XCTAssertLessThan(1 - box.midY, top, "Each new-space button sits in its host's header, above its spaces")
        }
        _ = try await PresentationTestSupport.capture(window, named: "per-host-before-remote", in: "new-space-validation")
        try await clickButton(at: 1)
        XCTAssertEqual(workspace.spaces.count, 3)
        XCTAssertEqual(workspace.currentMachine, .ssh(shell))
        XCTAssertEqual(workspace.current?.hostID, remote.hostID)
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.15))
        _ = try await PresentationTestSupport.capture(window, named: "per-host-before-local", in: "new-space-validation")
        try await clickButton(at: 0)
        XCTAssertEqual(workspace.spaces.count, 4)
        XCTAssertEqual(workspace.currentMachine, .local)
        XCTAssertEqual(workspace.current?.hostID, .local)
        controller.settings.values.spaceOrder = .flat
        try await TestSupport.eventually {
            let controls = PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root)
            return controls.count == 2 && Set(controls.compactMap { $0.accessibilityIdentifier() })
                == ["host-new-space-local", "sidebar-new-space"]
        }
        _ = try await PresentationTestSupport.capture(window, named: "shared-flat-two-line", in: "new-space-validation")
        let flatText = try await PresentationTestSupport.capture(root).text()
        XCTAssertTrue(flatText.contains("local"), flatText)
        let flatControls = PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root)
        let newHere = try XCTUnwrap(flatControls.first { $0.host == nil })
        let newLocal = try XCTUnwrap(flatControls.first { $0.host == .local })
        XCTAssertLessThan(newLocal.convert(newLocal.bounds, to: nil).midX,
                          newHere.convert(newHere.bounds, to: nil).midX, "New local comes first, beside new space")
        workspace.selectSpace(remote.id)
        newHere.performClick(nil)
        XCTAssertEqual(workspace.spaces.count, 5)
        XCTAssertEqual(workspace.current?.hostID, remote.hostID)
        newLocal.performClick(nil)
        XCTAssertEqual(workspace.spaces.count, 6)
        XCTAssertEqual(workspace.currentMachine, .local)
        XCTAssertEqual(workspace.current?.hostID, .local)
        workspace.spaces.removeAll { $0.hostID != .local }
        try await TestSupport.eventually {
            let controls = PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root)
            return controls.count == 1 && controls.first?.accessibilityIdentifier() == "sidebar-new-space"
        }
    }

    func testButtonCreatesImmediatelyAndOffersExplicitHostChoices() async throws {
        try DesktopTestSupport.requireUnlocked()
        let workspace = Workspace()
        workspace.newLocalSpace()
        let remote = addRemote("127.0.0.1", to: workspace)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: NewSpaceButton(workspace: workspace)
            .frame(width: 280, height: 60))
        window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually {
            !PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root).isEmpty
        }
        let button = try XCTUnwrap(PresentationTestSupport.views(of: NewSpaceNativeButton.self, in: root).first)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        try PresentationTestSupport.click(window, at: point)
        XCTAssertEqual(workspace.spaces.count, 3, "A normal click creates immediately")
        let options = await button.options().flatMap(\.options)
        XCTAssertEqual(options.first?.choice.title, "New space")
        XCTAssertEqual(options.last?.choice.title, "New space on 127.0.0.1")
        XCTAssertTrue(options.dropLast().allSatisfy { SpaceBackend.allCases.map(\.title).contains($0.choice.title) })
        try XCTUnwrap(try XCTUnwrap(options.first).action)()
        XCTAssertEqual(workspace.spaces.count, 4)
        XCTAssertNotEqual(workspace.current?.shows("tmux"), true); XCTAssertNotEqual(workspace.current?.shows("herdr"), true)
        try XCTUnwrap(try XCTUnwrap(options.last).action)()
        XCTAssertEqual(workspace.spaces.count, 5)
        XCTAssertEqual(workspace.current?.hostID, remote)
    }

    func testRightClickAndHoldRequestMenuWithoutCreatingSpace() async throws {
        try DesktopTestSupport.requireUnlocked()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 120, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NewSpaceNativeButton()
        window.contentView = button
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        var created = 0, menus = 0
        button.create = { created += 1 }
        button.options = { menus += 1; return [] }
        button.presentMenu = { menu, _, point in
            XCTAssertEqual(point, NSPoint(x: 30, y: 30))
            XCTAssertEqual(menu.items.first?.title, "New space here")
        }
        let point = NSPoint(x: 30, y: 30)
        button.rightMouseDown(with: try PresentationTestSupport.mouseEvent(.rightMouseDown, in: window, at: point))
        try await TestSupport.eventually { menus == 1 }
        XCTAssertEqual(created, 0)
        // No release is queued: the native control must recognize the hold.
        button.mouseDown(with: try PresentationTestSupport.mouseEvent(.leftMouseDown, in: window, at: point))
        button.mouseUp(with: try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: point))
        try await TestSupport.eventually { menus == 2 }
        XCTAssertEqual(created, 0, "Releasing a long press must not also create a space")
        try PresentationTestSupport.click(window, at: point)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(menus, 2)
    }

    func testRightClickPresentsCachedMenuWhileDiscoveryIsPending() async throws {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let button = NewSpaceNativeButton()
        button.host = .local
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = button
        defer { window.close(); window.contentView = nil }
        let choice = NewSpaceMenu.Choice(label: SpaceBackend.native.title, title: SpaceBackend.native.title, host: .local, backend: .native)
        let group = NewSpaceMenu.HostGroup(host: workspace.hosts.record(.local),
            options: [.init(choice: choice, unavailableReason: nil, action: {})])
        var finish: CheckedContinuation<[NewSpaceMenu.HostGroup], Never>?
        button.options = { await withCheckedContinuation { finish = $0 } }
        button.immediateOptions = { [group] }
        button.prefetchOptions()
        try await TestSupport.eventually { finish != nil }

        var menuTitles: [String]?
        button.presentMenu = { menu, _, _ in menuTitles = menu.items.map(\.title) }
        button.rightMouseDown(with: try PresentationTestSupport.mouseEvent(.rightMouseDown,
            in: window, at: .zero))
        XCTAssertEqual(menuTitles, ["New plain space"], "A pending backend probe must not delay the menu")
        finish?.resume(returning: []); finish = nil
    }
}
