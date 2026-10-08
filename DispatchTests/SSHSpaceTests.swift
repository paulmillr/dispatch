import AppKit
import Darwin
import XCTest
@testable import DispatchApp

@MainActor
final class SSHSpaceTests: XCTestCase {
    func testConnectingSpinnerPrecedesAuthenticationAndClearsOnFailure() async throws {
        for tmux in [false, true] {
            let app = try TmuxWalkthrough(autoClose: true)
            defer { app.close() }
            app.controller.settings.values.hideSingleSpace = false
            if tmux { try await app.attach(); try await app.ready() }
            let terminalID = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { app.runtime.views[terminalID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let terminal = try XCTUnwrap(app.runtime.views[terminalID])
            // TCP connects, but this listener never sends the SSH banner. No
            // privileged daemon, remote helper or credentials are needed.
            var listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { throw POSIXError(.EIO) }
            defer { if listener >= 0 { Darwin.close(listener) } }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let port = try withUnsafeMutablePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    guard Darwin.bind(listener, address, length) == 0, getsockname(listener, address, &length) == 0,
                          listen(listener, 1) == 0 else { throw POSIXError(.EIO) }
                    return UInt16(bigEndian: pointer.pointee.sin_port)
                }
            }
            let arguments = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-p", String(port), "127.0.0.1"]
            try await SSHTestServer.authorize(arguments: arguments, grant: .init(profile: .statistics))
            let command: String
            if tmux {
                // This externally created /bin/sh pane predates Dispatch's
                // shell integration. Inherit the gateway's normal capability;
                // progress must still be attributed to the actual pane PTY.
                let environment = app.runtime.herdrLaunch.environment(for: try XCTUnwrap(app.origin).id)
                command = (["env"] + environment.map { $0.key + "=" + $0.value }
                    + [try XCTUnwrap(Bundle.main.executablePath), "--ssh-launch"] + arguments)
                    .map(HerdrLaunch.quote).joined(separator: " ")
            } else { command = "ssh " + arguments.map(HerdrLaunch.quote).joined(separator: " ") }
            TerminalTestSupport.send(command + "; printf 'SSH_SPINNER_%s\\n' FINISHED", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                app.workspace.hostMoveMotion.connecting.contains(terminalID)
            }
            XCTAssertTrue(app.runtime.ssh.links.isEmpty)
            XCTAssertNil(app.runtime.ssh.machine(for: terminalID), "Progress must not start auxiliary helper channels before authentication")
            try await Task.sleep(for: .milliseconds(150))
            let first = try await PresentationTestSupport.capture(app.window, named: tmux ? "ssh-connecting-tmux" : "ssh-connecting-plain", in: "motion-validation")
            try await Task.sleep(for: .milliseconds(220))
            let second = try await PresentationTestSupport.capture(app.window)
            let before = amberPixels(first.bitmap), after = amberPixels(second.bitmap)
            XCTAssertGreaterThan(before.count, 20, "The amber connection arcs must be visible")
            XCTAssertNotEqual(before, after, "The connection arcs must visibly rotate")
            let sidebarEdge = Int(250 * app.window.backingScaleFactor)
            XCTAssertTrue(before.contains { $0 % first.bitmap.pixelsWide < sidebarEdge }, "Space row spinner")
            XCTAssertTrue(before.contains { $0 % first.bitmap.pixelsWide > sidebarEdge }, "Tab header spinner")
            Darwin.close(listener); listener = -1
            try await TestSupport.eventually(timeout: .seconds(5), diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                !app.workspace.hostMoveMotion.connecting.contains(terminalID)
                    && TerminalTestSupport.screen(terminal: terminal).contains("SSH_SPINNER_FINISHED")
            }
        }
    }

    private func amberPixels(_ bitmap: NSBitmapImageRep) -> Set<Int> {
        var result: Set<Int> = []
        // Chrome occupies the top of this fixture; exclude the terminal text.
        for y in 0..<min(bitmap.pixelsHigh, 250) {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.65, color.greenComponent > 0.5,
                   color.redComponent - color.greenComponent > 0.08,
                   color.greenComponent - color.blueComponent > 0.15 { result.insert(y * bitmap.pixelsWide + x) }
            }
        }
        return result
    }

    /// The SSH login running tmux -CC becomes the remote helper's hidden gateway while its own shell stays in this
    /// Mac's topology. A later local topology (a new local space) must not show that login again: neither while it
    /// carries tmux, nor after the last tmux space closes and the gateway ends.
    func testSSHTmuxHandoffLoginNeverReturnsAsASpace() async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        let login = try XCTUnwrap(app.workspace.activeTab?.id)
        let sidebar = app.sidebarShown()
        _ = try await app.login(server, surface: login)
        try await app.attach(); try await app.ready()
        try await app.wait { !app.workspace.allTabIDs.contains(login) }
        XCTAssertFalse(sidebar.withLock { $0 }, "One space throughout: the SSH login's handoff to tmux must not show the sidebar")
        let tmux = try XCTUnwrap(app.workspace.selectedSpace)
        func newLocalSpace() async throws -> UUID {
            app.workspace.newLocalSpace()
            let created = try XCTUnwrap(app.workspace.selectedSpace)
            // This Mac's helper adopts the space once its topology shows the new terminal.
            try await app.wait { app.workspace.spaces.first { $0.id == created }?.backend != nil }
            return created
        }
        let first = try await newLocalSpace()
        XCTAssertEqual(app.workspace.spaces.map(\.id), [tmux, first], "The hidden SSH login must not return as a space")
        app.controller.closeSpace(tmux)
        try await app.wait { app.runtime.views[login] == nil && !app.workspace.spaces.contains(where: \.structured) }
        let second = try await newLocalSpace()
        XCTAssertEqual(app.workspace.spaces.map(\.id), [first, second], "The ended gateway's SSH login must not return as a space")
    }

    func testRemoteTmuxPopupCreatesBackendAndLocalSpaces() async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let root = URL(fileURLWithPath: "/tmp/hs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key").path
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key]
        try generate.run(); generate.waitUntilExit()
        XCTAssertEqual(generate.terminationStatus, 0)
        let port = try availablePort()
        let config = root.appendingPathComponent("sshd_config")
        try """
        ListenAddress 127.0.0.1
        Port \(port)
        HostKey \(key)
        AuthorizedKeysFile \(key).pub
        PidFile \(root.path)/pid
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        LogLevel ERROR
        """.write(to: config, atomically: true, encoding: .utf8)
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        daemon.arguments = ["-D", "-e", "-f", config.path]
        daemon.standardOutput = FileHandle.nullDevice; daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer { if daemon.isRunning { daemon.terminate() }; daemon.waitUntilExit() }
        try await TestSupport.eventually(diagnostic: "Test SSH server did not start") { self.acceptingConnections(port) }
        let sourceID = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[sourceID].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let options = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                       "-o", "LogLevel=ERROR", "-o", "IdentitiesOnly=yes", "-i", key, "-p", String(port)]
        let host = NSUserName() + "@127.0.0.1"
        let command = ["/usr/bin/ssh"] + options + ["-tt", host, "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge"]
        try await app.attach(command: "TERM=xterm-256color " + command.map(HerdrLaunch.quote).joined(separator: " "))
        try await app.ready()
        try await app.wait { if case .ssh = app.workspace.currentMachine { return true }; return false }
        try await TestSupport.eventually(timeout: .seconds(10)) {
            app.workspace.current?.hostID != .local
        }
        let remoteSpace = try XCTUnwrap(app.workspace.selectedSpace), backend = try XCTUnwrap(app.workspace.current?.backend)
        try await PresentationTestSupport.chooseNewSpace("New tmux space", in: app.workspace, host: try XCTUnwrap(app.workspace.current?.hostID))
        try await app.wait { app.workspace.selectedSpace != remoteSpace && app.workspace.current?.structured == true }
        XCTAssertEqual(app.workspace.current?.backend, backend, "The new space belongs to the same tmux session")
        XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 2)
        guard case .ssh(let shell) = app.workspace.currentMachine else { return XCTFail("Expected the original SSH host") }
        XCTAssertEqual(shell.destination, host)
        XCTAssertTrue(app.attached)
        app.workspace.selectSpace(remoteSpace)
        try await app.ready()
        try await SSHTestServer.authorize(arguments: shell.arguments, executable: shell.executable,
            grant: .init(profile: .ordinary))
        try await PresentationTestSupport.chooseNewSpace(in: app.workspace, host: try XCTUnwrap(app.workspace.current?.hostID))
        try await app.wait { app.workspace.selectedSpace != remoteSpace && app.workspace.current?.shows("tmux") != true }
        let tab = try XCTUnwrap(app.workspace.activeTab)
        XCTAssertEqual(tab.machine, .ssh(shell))
        XCTAssertEqual(app.workspace.current?.structured, false)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Host=\(String(describing: app.workspace.hosts.terminals[tab.id])), sheet=\(app.window.attachedSheet != nil), foreground=\(String(describing: app.runtime.views[tab.id]?.foregroundPID)), viewMachine=\(String(describing: app.runtime.views[tab.id]?.machine))\n" + (app.runtime.views[tab.id].map { TerminalTestSupport.screen(terminal: $0) } ?? "missing shell")) {
            app.workspace.hosts.terminals[tab.id]?.state == .unverified
        }
        try await app.wait { app.runtime.views[tab.id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let plain = try XCTUnwrap(app.runtime.views[tab.id])
        TerminalTestSupport.send("printf 'LOCAL_PLAIN_%s_%s\\n' \"${TMUX-unset}\" \"${HERDR_ENV-unset}\"", to: plain)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: plain)) {
            TerminalTestSupport.screen(terminal: plain).contains("LOCAL_PLAIN_unset_unset")
        }
        XCTAssertTrue(app.attached, "The tmux session stays attached")
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    private func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                guard Darwin.bind(fd, address, length) == 0, getsockname(fd, address, &length) == 0 else { throw POSIXError(.EIO) }
                return UInt16(bigEndian: pointer.pointee.sin_port)
            }
        }
    }

    private func acceptingConnections(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
