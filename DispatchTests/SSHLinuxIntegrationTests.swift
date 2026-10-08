import AppKit
import Term
import XCTest
@testable import DispatchApp

/// The macOS app talks to a separate Linux VM. Configure it with
/// `python3 test/vm.py linux`; no shared filesystem or model API is used.
@MainActor
final class SSHLinuxIntegrationTests: XCTestCase {
    func testLinuxDetachedTmuxRestorePreservesProcesses() async throws {
        try await checkDetachedTmuxRestore(grant: .init(profile: .full, hooks: true))
    }

    func testLinuxGranularTmuxGrantSurvivesDetachAndReconnect() async throws {
        try await checkDetachedTmuxRestore(grant: .init(helperEnabled: true, features: [.statistics, .tmux]))
    }

    private func checkDetachedTmuxRestore(grant: SSHIntegrationGrant) async throws {
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf:
            SSHLinuxTestProfile.configurationURL()))
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        @discardableResult
        func remote(_ arguments: [String]) async throws -> String {
            let result = try await SSHCommand.run(executable: "/usr/bin/ssh", arguments:
                profile.options + [profile.destination, arguments.map(HerdrLaunch.quote).joined(separator: " ")])
            guard result.status == 0 else { throw HerdrFailure(String(decoding: result.output, as: UTF8.self)) }
            return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let root = try await remote(["mktemp", "-d", "/tmp/dispatch-restore-XXXXXXXX"])
        let socket = root + "/tmux.sock", tmux = profile.supportedTmuxPath
        func cleanup() async {
            _ = try? await remote([tmux, "-S", socket, "kill-server"])
            _ = try? await remote(["rm", "-rf", "--", root])
        }
        do {
            let system = try await remote(["uname", "-s"])
            XCTAssertEqual(system, "Linux")
            let source = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let terminal = try XCTUnwrap(app.runtime.views[source])
            try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: grant)
            TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            try await TestSupport.eventually(timeout: .seconds(25)) {
                app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
            }
            XCTAssertEqual(app.runtime.ssh.links.values.first { $0.launch.tabID == source }?.grant, grant)
            TerminalTestSupport.send([tmux, "-u", "-S", socket, "-f", "/dev/null", "-CC", "new-session", "-s", "restore", "/bin/bash"].map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            try await TestSupport.eventually(timeout: .seconds(20)) { app.workspace.current?.structured == true }
            let processes = try await remote([tmux, "-S", socket, "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
            app.workspace.detachSpace(try XCTUnwrap(app.workspace.current).id)
            try await app.wait { !app.workspace.spaces.contains(where: \.structured) }
            let entry = try XCTUnwrap(app.workspace.detached.first)
            app.workspace.restoreDetached([entry.id])
            try await TestSupport.eventually(timeout: .seconds(25), diagnostic:
                "Restore: \(app.runtime.helpers[.local]?.error ?? "pending"); screens: \(app.runtime.views.mapValues { TerminalTestSupport.screen(terminal: $0) })") {
                app.workspace.spaces.contains { $0.structured && $0.tabs.allSatisfy { !$0.isConnecting } }
            }
            XCTAssertTrue(app.workspace.detached.isEmpty)
            XCTAssertEqual(Set(app.workspace.spaces.filter { $0.shows("tmux") }.compactMap(\.backend)).count, 1, "One tmux session")
            let restored = try XCTUnwrap(app.workspace.activeTab)
            let host = try XCTUnwrap(app.workspace.hosts.terminals[restored.id]).host
            let view = try XCTUnwrap(app.runtime.views[restored.id])
            for _ in 0..<2 {
                app.runtime.hosts.disconnect(host)
                try await app.wait { app.runtime.hosts.reconnect.state(for: restored.id) != nil }
                app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: restored.id)
                try await TestSupport.eventually(timeout: .seconds(30), diagnostic:
                    app.runtime.hosts.reconnect.state(for: restored.id)?.error ?? "Linux reconnect pending") {
                    app.runtime.hosts.reconnect.state(for: restored.id) == nil
                }
                XCTAssertTrue(app.runtime.views[restored.id] === view)
                XCTAssertEqual(app.workspace.spaces.filter { $0.structured }.count, 1)
                XCTAssertEqual(Set(app.workspace.spaces.filter { $0.shows("tmux") }.compactMap(\.backend)).count, 1, "One tmux session")
                XCTAssertTrue(app.workspace.detached.isEmpty)
            }
            let restoredProcesses = try await remote([tmux, "-S", socket, "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
            XCTAssertEqual(restoredProcesses, processes)
        } catch {
            await cleanup(); throw error
        }
        await cleanup()
    }

    func testLinuxExit255ReturnsToEditableLocalShell() async throws {
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf:
            SSHLinuxTestProfile.configurationURL()))
        let app = try TmuxWalkthrough(); defer { app.close() }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[source])
        try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: .init(profile: .statistics))
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " ")
            + "; printf 'LINUX_EXIT_%s\\n' \"$?\"", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        TerminalTestSupport.send("exit 255", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic:
            "Reconnect: \(String(describing: app.runtime.hosts.reconnect.state(for: source))); screen: " + TerminalTestSupport.screen(terminal: terminal)) {
            app.workspace.hosts.terminals[source] == nil && TerminalTestSupport.screen(terminal: terminal).contains("LINUX_EXIT_255")
        }
        XCTAssertNil(app.runtime.hosts.reconnect.state(for: source))
        XCTAssertTrue(app.runtime.views[source] === terminal)
        TerminalTestSupport.send("printf 'LOCAL_AFTER_LINUX_%s\\n' OK", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("LOCAL_AFTER_LINUX_OK") }
        // Reuse the same terminal, then deliberately disconnect the host.
        // A receipt from the preceding login must not turn this into an exit.
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        let host = try XCTUnwrap(app.workspace.hosts.terminals[source]).host
        app.runtime.hosts.disconnect(host)
        try await app.wait { app.runtime.hosts.reconnect.state(for: source) != nil }
        XCTAssertTrue(app.runtime.views[source] === terminal)
        XCTAssertNotNil(app.workspace.hosts.terminals[source])
        app.runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: source)
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic:
            app.runtime.hosts.reconnect.state(for: source)?.error ?? "Linux shell reconnect pending") {
            app.runtime.hosts.reconnect.state(for: source) == nil
        }
        XCTAssertTrue(app.runtime.views[source] === terminal)
        TerminalTestSupport.send("printf 'REMOTE_AFTER_RECONNECT_%s\\n' \"$(uname -s)\"", to: terminal)
        try await TestSupport.eventually(diagnostic:
            "Screen: " + TerminalTestSupport.screen(terminal: terminal) + "; shells: \(app.runtime.ssh.links.values.map { ($0.launch.tabID, $0.shellPID) })") {
            TerminalTestSupport.screen(terminal: terminal).contains("REMOTE_AFTER_RECONNECT_Linux")
        }
    }

    func testLinuxPlainChatAndRemoteFiles() async throws { try await walkthrough("plain") }
    func testLinuxTmuxChatCompatibilityAndRemoteFiles() async throws { try await walkthrough("tmux") }
    func testLinuxHerdrChatAndRemoteFiles() async throws { try await walkthrough("herdr") }
    func testLinuxSupportedTmuxCheckedChatAndRemoteFiles() async throws { try await walkthrough("tmux", supportedTmux: true) }
    func testLinuxPlainApprovalHooksAndCustomHomeTrust() async throws { try await walkthrough("plain", hooks: true) }
    func testLinuxTmuxApprovalHooksAndCustomHomeTrust() async throws { try await walkthrough("tmux", hooks: true, supportedTmux: true) }
    func testLinuxHerdrApprovalHooksAndCustomHomeTrust() async throws { try await walkthrough("herdr", hooks: true) }

    func testLinuxTwoTmuxCodexChatsShareDirectoryDuringToolCalls() async throws {
        try await walkthrough("tmux", supportedTmux: true, twoChats: true)
    }

    private func walkthrough(_ backend: String, hooks: Bool = false, supportedTmux: Bool = false, twoChats: Bool = false) async throws {
        let profileURL = SSHLinuxTestProfile.configurationURL()
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self, from: Data(contentsOf: profileURL))
        let runtime = TerminalRuntime.shared, previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previousChat }
        if hooks { try await TestSupport.integrations(["codex"], enabled: true, chat: runtime.chat) }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let origin = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let original = try XCTUnwrap(runtime.views[origin])
        try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: .init(profile: .full, hooks: hooks))
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
        try await TestSupport.eventually(timeout: .seconds(25), diagnostic: TerminalTestSupport.screen(terminal: original)) {
            runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
        }
        let ssh = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
        let greeting = ssh.greeting, master = ssh.launch.master
        let root = greeting.home + "/.cache/dispatch-tests/linux-" + UUID().uuidString
        let state = root + "/state", script = root + "/codex_fixture.py"
        let tmuxSocket = root + "/tmux.sock", herdrSocket = root + "/herdr.sock"
        let tmuxBinary = supportedTmux ? profile.supportedTmuxPath : "/usr/bin/tmux"
        var herdrStarted = false, fixture: SSHTestDaemon?

        @discardableResult
        func remote(_ arguments: [String], input: Data = Data()) async throws -> Data {
            let result = try await SSHTestCommand.run(master: master, argv: arguments, input: input)
            guard result.status == 0 else { throw HerdrFailure("Linux test command failed: " + String(decoding: result.output, as: UTF8.self)) }
            return result.output
        }
        func cleanup(remove: Bool) async {
            // Ending tmux control mode closes this SSH session: stop everything
            // else first, then kill tmux and remove the fixture in one command.
            await fixture?.stop()
            if herdrStarted {
                do { try await SSHTestCommand.stopHerdr(master: master, socket: herdrSocket) }
                catch { XCTFail("Cannot stop isolated Linux herdr fixture: " + error.localizedDescription) }
            }
            var commands: [String] = []
            if backend == "tmux" { commands.append(HerdrLaunch.quote(tmuxBinary) + " -S " + HerdrLaunch.quote(tmuxSocket) + " kill-server") }
            if remove { commands.append("rm -rf -- " + HerdrLaunch.quote(root)) }
            else { print("Linux fixture retained at " + root) }
            if !commands.isEmpty { _ = try? await remote(["/bin/sh", "-c", commands.joined(separator: "; ")]) }
        }
        do {
            let system = try await remote(["/usr/bin/uname", "-s"])
            XCTAssertEqual(String(decoding: system, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "Linux")
            if backend == "plain", !hooks {
                let store = HostStatisticsStore.shared
                let host = HostID.authenticated(greeting.host)
                let source = store.source(host: host, preferred: ssh.launch.connectionID)
                guard case .ssh(let key) = source else { throw HerdrFailure("Missing authorized Linux statistics provider") }
                let entry = try XCTUnwrap(store.remote.series[key])
                try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Authorized Linux statistics must sample in the background") {
                    entry.latest != nil
                }
                let subscription = try XCTUnwrap(store.subscribe(source, preferred: ssh.launch.connectionID))
                defer { store.unsubscribe(subscription) }
                try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "Linux counters did not reach the shared statistics store") {
                    let sample = store.snapshot(source)
                    return sample.memoryTotal != nil && sample.cpu != nil && sample.receivedPerSecond != nil && sample.volumes != nil && sample.processes != nil
                }
                let sample = store.snapshot(source)
                XCTAssertEqual(sample.account, ssh.scope.account)
                XCTAssertEqual(sample.state, .ready)
                XCTAssertEqual(sample.load?.count, 3)
                XCTAssertFalse(sample.cores?.isEmpty ?? true)
                XCTAssertFalse(sample.processes?.isEmpty ?? true)
                XCTAssertEqual(entry.providers.count, 1)
                XCTAssertEqual(runtime.ssh.links.count, 1, "Statistics reuses the live SSH connection")
                store.unsubscribe(subscription)
                try await TestSupport.eventually { entry.subscriptions.isEmpty }
            }
            try await remote(["/bin/mkdir", "-m", "700", "-p", root])
            for name in CodexTestSupport.scripts {
                try await remote(["/usr/bin/tee", root + "/" + name],
                    input: Data(contentsOf: CodexTestSupport.root.appendingPathComponent("scripts/" + name)))
            }
            let daemon = try SSHTestDaemon(master: master,
                argv: ["/usr/bin/python3", script, "serve", "--state", state, "--delay", "0.01", "--no-hooks"], pidFile: root + "/model.pid")
            fixture = daemon
            try await daemon.waitUntilReady()
            if !hooks && !twoChats {
                let catalog = root + "/transport-models.json"
                try await remote(["/usr/bin/tee", catalog], input: CodexTestSupport.transportModelCatalog())
                try await remote(["/usr/bin/python3", "-c",
                    "import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text('model_catalog_json = ' + json.dumps(sys.argv[2]) + '\\n' + p.read_text())",
                    state + "/codex-home/config.toml", catalog])
            }
            if twoChats {
                try await remote(["/usr/bin/python3", "-c", "import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text('approvals_reviewer = \"auto_review\"\\n' + p.read_text())", state + "/codex-home/config.toml"])
            }
            if backend == "tmux" {
                TerminalTestSupport.send(HerdrLaunch.quote(tmuxBinary) + " -u -S " + HerdrLaunch.quote(tmuxSocket) + " -f /dev/null -CC new-session -s linux /bin/bash", to: original)
                try await app.wait { app.workspace.current?.structured == true }
            } else if backend == "herdr" {
                TerminalTestSupport.send("export PATH=" + HerdrLaunch.quote(profile.path) + "; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(root) +
                    "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(herdrSocket) + "; herdr", to: original)
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: original)) { app.workspace.current?.shows("herdr") == true }
                herdrStarted = true
            }
            let surfaceID = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[surfaceID]?.surface != nil }
            let terminal = try XCTUnwrap(runtime.views[surfaceID])
            // The guardian case inspects the TUI's own FDs, as the original remote wrapper's
            // --no-daemon launch did. A private app-server owns those FDs in another process.
            let launch = "python3 " + HerdrLaunch.quote(script) + " launch --state " + HerdrLaunch.quote(state) + " --codex " + HerdrLaunch.quote(profile.codexPath) + (twoChats ? " --no-daemon" : "")
            let session = runtime.chat.session(for: surfaceID)
            try await SSHChatTestSupport.launch(launch, session: session, terminal: terminal)
            XCTAssertNil(session.process)
            XCTAssertEqual(session.remoteAgent?.host, greeting.hostID)
            XCTAssertNotNil(runtime.ssh.tint(for: try XCTUnwrap(app.workspace.activeTab)))
            if hooks {
                try await SSHChatTestSupport.trustHooks(state: URL(fileURLWithPath: state), command: launch,
                    session: session, terminal: terminal, read: { path in
                        try await ToolDocument(path: path, diff: "").source(in: "/", endpoint: .remote(ssh.launch.connectionID))
                    })
            }
            try await SSHChatTestSupport.waitForEditor(session: session, terminal: terminal)
            if backend == "tmux" {
                let mode = try await remote([tmuxBinary, "-S", tmuxSocket, "display-message", "-p", "#{bracket_paste_flag}"])
                let compatibility = String(decoding: mode, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // The tmux helper picks the paste path; both must deliver the prompts below unchanged.
                XCTAssertEqual(compatibility, !supportedTmux, "The supported and legacy tmux tests must exercise distinct capability paths")
            }
            runtime.chat.chooseChat(true, session: session)
            for prompt in ["Linux \(backend) chat\nsecond line · λ", "Another \(backend) message with 'quotes' and \\slashes"] {
                session.draft = prompt
                runtime.chat.sendFromComposer(session)
                try await TestSupport.eventually(timeout: .seconds(25), diagnostic: "\(session.status ?? "No Linux reply")\n\(TerminalTestSupport.screen(terminal: terminal))") {
                    session.draft.isEmpty && !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + prompt }
                }
                runtime.chat.chooseChat(true, session: session)
            }
            if !hooks && !twoChats {
                // Cover model/effort and queued delivery on the actual Linux
                // backend as well as its platform-specific file/exit checks.
                // Exercise the same Chat path on legacy and current tmux.
                try await TestSupport.eventually(timeout: .seconds(20)) { runtime.chat.canPickModel(session) }
                runtime.chat.openModelPicker(session, column: .model)
                let picker = try XCTUnwrap(session.modelPicker)
                try await TestSupport.eventually(timeout: .seconds(20)) { !picker.loading }
                XCTAssertNil(picker.error)
                let names = ["dispatch-fixture": "Dispatch fixture", "gpt-5.6-sol": "GPT-5.6 Sol"]
                let models = try Dictionary(uniqueKeysWithValues: names.map { slug, name in
                    (slug, try XCTUnwrap(picker.models.first { AgentModelMenu.containsModel($0.name, slug: slug, name: name) }).name)
                })
                XCTAssertEqual(Set(picker.models.map(\.name)), Set(models.values), "Focused transport must read the native fixture catalog")
                picker.selectModel(try XCTUnwrap(models["gpt-5.6-sol"]))
                try await TestSupport.eventually(timeout: .seconds(20)) { !picker.loading }
                XCTAssertNil(picker.error)
                XCTAssertEqual(Set(picker.efforts.compactMap(\.effort)), ["low", "medium"])
                picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
                try await TestSupport.eventually(timeout: .seconds(20)) { session.modelPicker == nil || picker.error != nil }
                XCTAssertNil(picker.error)
                XCTAssertEqual(session.model, "gpt-5.6-sol"); XCTAssertEqual(session.effort, "low")
                let messages = ["Linux transport queued first", "Linux transport queued second\nwith λ"]
                for message in messages { session.draft = message; runtime.chat.queue(session) }
                session.draft = "preserved Linux queue draft"
                try await TestSupport.eventually(timeout: .seconds(25), diagnostic: session.status ?? "Linux queue did not complete") {
                    !session.busy && session.queuedMessages.isEmpty && session.submissionID == nil
                        && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + messages[1] }
                }
                XCTAssertEqual(session.draft, "preserved Linux queue draft")
                XCTAssertNil(session.queuePaused)
                XCTAssertEqual(Array(session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text).suffix(2)), messages)
                let requests = try await remote(["/bin/cat", state + "/requests.jsonl"]).split(separator: 10).map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
                }.filter { ($0["body"] as? [String: Any])?["model"] as? String == "gpt-5.6-sol" }
                XCTAssertEqual(requests.count, 2)
                for request in requests {
                    let body = try XCTUnwrap(request["body"] as? [String: Any])
                    XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
                }
            }
            if twoChats {
                let firstID = try XCTUnwrap(session.sessionID)
                let firstProcess = try XCTUnwrap(session.remoteAgent)
                // A second tmux window of the same session.
                app.workspace.newTab()
                try await app.wait { app.workspace.activeSurfaceID != session.id && app.workspace.current?.shows("tmux") == true }
                let secondSurface = try XCTUnwrap(app.workspace.activeSurfaceID)
                try await app.wait { runtime.views[secondSurface]?.surface != nil }
                let secondTerminal = try XCTUnwrap(runtime.views[secondSurface])
                let second = runtime.chat.session(for: secondSurface)
                try await SSHChatTestSupport.launch(launch, session: second, terminal: secondTerminal)
                try await SSHChatTestSupport.waitForEditor(session: second, terminal: secondTerminal)
                runtime.chat.chooseChat(true, session: second)
                second.draft = "Second Linux conversation"
                runtime.chat.sendFromComposer(second)
                try await TestSupport.eventually(timeout: .seconds(25), diagnostic: second.status ?? "Second chat did not reply") {
                    !second.busy && second.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: Second Linux conversation" }
                }
                let secondID = try XCTUnwrap(second.sessionID)
                let secondProcess = try XCTUnwrap(second.remoteAgent)
                XCTAssertNotEqual(firstID, secondID)
                XCTAssertNotEqual(firstProcess.pid, secondProcess.pid)
                let directories = String(decoding: try await remote([tmuxBinary, "-S", tmuxSocket, "list-panes", "-a", "-F", "#{pane_current_path}"]), as: UTF8.self)
                    .split(separator: "\n").map(String.init)
                XCTAssertEqual(directories, [state + "/work", state + "/work"])
                for round in 0..<3 {
                    let firstPrompt = "DISPATCH_BACKGROUND_TOOL first \(round)"
                    let secondPrompt = "DISPATCH_BACKGROUND_TOOL second \(round)"
                    for (chat, prompt) in [(session, firstPrompt), (second, secondPrompt)] {
                        runtime.chat.chooseChat(true, session: chat)
                        chat.draft = prompt
                        runtime.chat.sendFromComposer(chat)
                        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: chat.status ?? "Tool turn was not submitted") {
                            chat.busy && chat.draft.isEmpty
                        }
                        chat.draft = "Retain draft for " + (chat.sessionID ?? "unknown")
                    }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                    while true {
                        for (chat, identity, conversation) in [(session, firstProcess, firstID), (second, secondProcess, secondID)] {
                            XCTAssertTrue(chat.showChat, chat.status ?? "Chat switched to Terminal")
                            XCTAssertFalse(chat.discoveryBlocked, chat.status ?? "Discovery blocked")
                            XCTAssertEqual(chat.sessionID, conversation)
                            XCTAssertEqual(chat.remoteAgent, identity)
                            XCTAssertEqual(chat.draft, "Retain draft for " + conversation)
                        }
                        let finished = [(session, firstPrompt), (second, secondPrompt)].allSatisfy { chat, prompt in
                            !chat.busy && chat.turns.flatMap(\.items).contains { $0.text.contains("Local fixture reply: " + prompt) }
                        }
                        if finished { break }
                        guard ContinuousClock.now < deadline else {
                            throw HerdrFailure("Two-chat tool turn timed out: \(session.status ?? "first ready") / \(second.status ?? "second ready")\n" + TerminalTestSupport.screen(terminal: terminal) + "\n" + TerminalTestSupport.screen(terminal: secondTerminal))
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text.contains("BACKGROUND_TOOL second") })
                XCTAssertFalse(second.turns.flatMap(\.items).contains { $0.kind == .user && $0.text.contains("BACKGROUND_TOOL first") })
                // Escalation opens a guardian rollout in each TUI process.
                // Keep both reviews in flight and inspect the kernel-owned FDs,
                // rather than inferring anything from the shared directory.
                for (chat, prompt) in [(session, "First Linux approval"), (second, "Second Linux approval")] {
                    chat.draft = prompt; runtime.chat.sendFromComposer(chat)
                    chat.draft = "Draft during review " + (chat.sessionID ?? "unknown")
                }
                let inspect = """
                import json, os, pathlib, sys
                result=[]
                for pid in sys.argv[1:]:
                    sessions={}
                    for fd in pathlib.Path('/proc/'+pid+'/fd').iterdir():
                        try:
                            path=os.readlink(fd)
                            if not path.endswith('.jsonl'): continue
                            with open(fd) as f: record=json.loads(f.readline())
                            if record.get('type') != 'session_meta': continue
                            meta=record['payload']
                            sessions[path]={'id':meta.get('id'), 'source':meta.get('source')}
                        except (OSError,ValueError): pass
                    result.append({'pid':pid,'executable':os.readlink('/proc/'+pid+'/exe'),'sessions':list(sessions.values())})
                print(json.dumps(result))
                """
                let reviewDeadline = ContinuousClock.now.advanced(by: .seconds(15))
                var captured = Data()
                while true {
                    captured = try await remote(["/usr/bin/python3", "-c", inspect, String(firstProcess.pid), String(secondProcess.pid)])
                    let processes = try XCTUnwrap(JSONSerialization.jsonObject(with: captured) as? [[String: Any]])
                    let reviewing = processes.count == 2 && processes.allSatisfy { process in
                        let rollouts = process["sessions"] as? [[String: Any]] ?? []
                        return rollouts.contains { row in
                            let source = row["source"] as? [String: Any]
                            return (source?["subagent"] as? [String: Any])?["other"] as? String == "guardian"
                        } && rollouts.contains { $0["source"] as? String == "cli" }
                    }
                    if reviewing { break }
                    guard ContinuousClock.now < reviewDeadline else { throw HerdrFailure("Guardian rollouts did not open: " + String(decoding: captured, as: UTF8.self)) }
                    try await Task.sleep(for: .milliseconds(100))
                }
                print("Concurrent Linux Codex rollout metadata: " + String(decoding: captured, as: UTF8.self))
                for _ in 0..<5 {
                    // Each terminal stays bound to its own main conversation while guardian rollouts open beside it.
                    for (chat, identity, conversation) in [(session, firstProcess, firstID), (second, secondProcess, secondID)] {
                        XCTAssertEqual(chat.remoteAgent?.key, identity.key)
                        XCTAssertEqual(chat.sessionID, conversation, "Guardian made the main conversation ambiguous")
                        XCTAssertTrue(chat.showChat, chat.status ?? "Chat switched to Terminal during review")
                        XCTAssertFalse(chat.discoveryBlocked, chat.status ?? "Review blocked discovery")
                        XCTAssertEqual(chat.draft, "Draft during review " + conversation)
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                _ = try await PresentationTestSupport.capture(app.window, named: "linux-two-chats-during-review", in: "ssh-linux-validation")
                await cleanup(remove: true)
                return
            }
            if hooks {
                for decision in [PendingApproval.Decision.allow, .deny] {
                    session.draft = "Linux \(backend) approval \(decision.rawValue)"
                    runtime.chat.sendFromComposer(session)
                    try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "\(session.status ?? "No Linux approval")\n\(TerminalTestSupport.screen(terminal: terminal))") {
                        session.approvals.contains(where: \.pending)
                    }
                    let approval = try XCTUnwrap(session.approvals.first(where: \.pending))
                    XCTAssertTrue(approval.operation.contains("DISPATCH_LOCAL_TOOL_OK"))
                    approval.resolve(decision)
                    try await TestSupport.eventually(timeout: .seconds(20), diagnostic: session.status ?? "Linux approval did not finish") { !session.busy }
                    XCTAssertEqual(approval.decision, decision)
                    let ran = session.turns.first { $0.id == approval.turnID }?.items.contains { $0.kind == .tool && $0.output.contains("DISPATCH_LOCAL_TOOL_OK") } == true
                    XCTAssertEqual(ran, decision == .allow, "Only an allowed remote command may produce tool output")
                }
            }
            let text = "File on the Linux host · 漢字"
            try await remote(["/usr/bin/tee", state + "/work/preview.txt"], input: Data(text.utf8))
            let preview = try await ToolDocument(path: "preview.txt", diff: "").source(in: state + "/work", endpoint: try XCTUnwrap(session.helper).endpoint)
            XCTAssertEqual(preview, text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: state + "/work/preview.txt"), "Remote source previews must not depend on a shared filesystem")
            _ = try await PresentationTestSupport.capture(app.window, named: "linux-" + backend + (hooks ? "-hooks" : supportedTmux ? "-checked" : ""), in: "ssh-linux-validation")
            session.draft = "Keep the Linux draft"
            runtime.chat.chooseChat(false, session: session)
            try await app.wait { terminal.isPresented }
            let surface = try XCTUnwrap(terminal.surface)
            surface.text("/quit")
            try await Task.sleep(for: .milliseconds(100)); TerminalTestSupport.key(36, "\r", terminal)
            try await TestSupport.eventually(timeout: .seconds(10)) { !session.active }
            XCTAssertEqual(session.draft, "Keep the Linux draft")
            XCTAssertFalse(session.turns.isEmpty)
            await cleanup(remove: true)
        } catch {
            await cleanup(remove: false)
            throw error
        }
    }
}
