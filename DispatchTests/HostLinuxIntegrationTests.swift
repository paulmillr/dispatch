import XCTest
@testable import DispatchApp

@MainActor
final class HostLinuxIntegrationTests: XCTestCase {
    func testLinuxIdentityAndCreationInPlainSSH() async throws { try await walkthrough("plain") }
    func testLinuxIdentityAndCreationInRemoteTmux() async throws { try await walkthrough("tmux") }
    func testLinuxIdentityAndCreationInRemoteHerdr() async throws { try await walkthrough("herdr") }

    private func walkthrough(_ backend: String) async throws {
        let profileURL = SSHLinuxTestProfile.configurationURL(hostOnly: true)
        guard FileManager.default.fileExists(atPath: profileURL.path) else { throw XCTSkip("Run test/host-linux.py for the isolated Linux host tests") }
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf: profileURL))
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let sidebar = app.sidebarShown()
        let source = try XCTUnwrap(app.workspace.activeTab).id
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let view = app.runtime.views[source]!
        try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: .init(profile: .full))
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: view)
        try await TestSupport.eventually(timeout: .seconds(25), diagnostic: "Linux SSH helper greeting") {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        let session = try XCTUnwrap(app.runtime.ssh.links.values.first { $0.launch.tabID == source })
        let host = HostID.authenticated(session.greeting.host)
        let record = app.workspace.hosts.record(host)
        XCTAssertEqual(record.system?.os, "Linux")
        XCTAssertEqual(record.system?.distribution, profile.distribution ?? "ubuntu")
        XCTAssertTrue(record.system?.label.contains(profile.label ?? "Ubuntu 26.04") == true)
        XCTAssertEqual(record.name, profile.destination.split(separator: "@").last.map(String.init))
        XCTAssertNotNil(record.hostname)
        XCTAssertEqual(app.workspace.current?.hostID, host)
        let path = "/tmp/dispatch-host-" + UUID().uuidString.prefix(8)
        var herdr = false
        func cleanup() async {
            if backend == "tmux" {
                _ = try? await SSHTestCommand.run(master: session.launch.master, argv: ["tmux", "-S", path, "kill-server"])
            }
            if herdr {
                do { try await SSHTestCommand.stopHerdr(master: session.launch.master, socket: path) }
                catch { XCTFail("Cannot stop the Linux herdr fixture: " + error.localizedDescription) }
            }
            _ = try? await SSHTestCommand.run(master: session.launch.master, argv: ["/bin/rm", "-rf", "--", path + "-config"])
        }
        do {
        if backend == "tmux" {
            TerminalTestSupport.send("tmux -u -S \(path) -f /dev/null -CC new-session -s host-test /bin/bash", to: view)
            try await TestSupport.eventually(timeout: .seconds(10)) { app.workspace.current?.structured == true }
        } else if backend == "herdr" {
            TerminalTestSupport.send("export PATH=\(HerdrLaunch.quote(profile.path)); export HERDR_SOCKET_PATH=\(path); export XDG_CONFIG_HOME=\(path)-config; herdr", to: view)
            try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
            herdr = true
        }
        try await TestSupport.eventually { app.workspace.current?.hostID == host && app.workspace.activeTab?.isConnecting == false }
        if backend != "plain" {
            try await TestSupport.eventually { app.workspace.retiringLaunchers.isEmpty && app.workspace.current?.shows(backend) == true }
        }
        // A fresh window's one space stays one through the login and any multiplexer's handoff.
        XCTAssertEqual(app.workspace.spaces.count, 1)
        XCTAssertFalse(sidebar.withLock { $0 }, "The sidebar that one space hides must not show during the \(backend) login")
        XCTAssertFalse(app.workspace.followsDetectedSSH, "A backend already on this host retains contextual Shift-Command-N")
        let original = app.workspace.selectedSpace
        if backend == "plain" {
            // Contextual shells clear forwarding options. Their resolved
            // configuration requires its own explicit integration grant.
            try await SSHTestServer.authorize(arguments: session.launch.shell.arguments,
                executable: session.launch.shell.executable, grant: .init(profile: .full))
        }
        app.controller.newSpace()
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "backend=\(backend), selected=\(String(describing: app.workspace.selectedSpace)), host=\(String(describing: app.workspace.current?.hostID)), connecting=\(String(describing: app.workspace.activeTab?.isConnecting)), machine=\(app.workspace.currentMachine)") {
            app.workspace.selectedSpace != original && app.workspace.current?.hostID == host && app.workspace.activeTab?.isConnecting == false
        }
        if backend == "plain" {
            let created = try XCTUnwrap(app.workspace.activeTab).id
            XCTAssertNotEqual(app.workspace.hosts.terminals[created]?.generation, app.workspace.hosts.terminals[source]?.generation)
            try await TestSupport.eventually(timeout: .seconds(20)) { app.workspace.hosts.terminals[created]?.authenticated == true }
            XCTAssertEqual(app.workspace.liveHosts.filter { $0.id != .local }.count, 1)
        } else {
            XCTAssertEqual(app.workspace.current?.shows("tmux") == true, backend == "tmux")
            XCTAssertEqual(app.workspace.current?.shows("herdr") == true, backend == "herdr")
        }
        // The host menu creates a fresh plain SSH shell even from a tmux/herdr
        // space, so authorize its normalized configuration in every backend.
        try await SSHTestServer.authorize(arguments: session.launch.shell.arguments,
            executable: session.launch.shell.executable, grant: .init(profile: .full))
        try await PresentationTestSupport.chooseNewSpace(in: app.workspace, host: host)
        try await TestSupport.eventually { app.workspace.current?.hostID == host && app.workspace.currentMachine != .local }
        XCTAssertNotEqual(app.workspace.current?.shows("tmux"), true); XCTAssertNotEqual(app.workspace.current?.shows("herdr"), true)
        } catch { await cleanup(); throw error }
        await cleanup()
    }
}
