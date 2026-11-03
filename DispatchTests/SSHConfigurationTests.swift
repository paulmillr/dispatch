import Foundation
import XCTest
@testable import DispatchApp

/// ssh_config features the connection Dispatch opens must keep: rules that depend on the command or session type,
/// relative paths, SendEnv and agent forwarding. Everything here resolves with `ssh -G` (nothing connects) against
/// fictional hosts; the loopback cases are in `SSHConfigurationIntegrationTests`.
@MainActor
final class SSHConfigurationTests: XCTestCase {
    /// Configuration files in a fresh folder (replay answers the recorded folder; its `ssh -G` answers are recorded too).
    private func folder(_ files: [String: String]) throws -> URL {
        let path = try TestSupport.fixture("ssh.configuration.folder", input: files.keys.sorted()) { () -> String in
            let directory = System.temporary.appendingPathComponent("ssh-config-" + System.uuid().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, text) in files { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }
            return directory.path
        }
        let directory = URL(fileURLWithPath: path)
        addTeardownBlock { if !AppReplay.replaying { try? FileManager.default.removeItem(at: directory) } }
        return directory
    }

    private static let sessionType = """
    Match sessiontype shell
      HostName shell.example.invalid
      User shelluser
    Match sessiontype exec
      HostName exec.example.invalid
      User execuser
    Match sessiontype none
      HostName transport.example.invalid
      User transportuser

    """
    private static let command = """
    Match command ""
      HostName shell.example.invalid
      User shelluser
    Match command "exec*"
      HostName exec.example.invalid
      User execuser

    """
    /// Only a master without a session (a reconnect's `-N`) goes elsewhere.
    private static let transportOnly = """
    Match sessiontype none
      HostName transport.example.invalid
      User transportuser
    Host fixture
      HostName fixture.example.invalid
      User sam

    """
    /// Options only the generated login master gets (an exec session): a master that forks after authentication would
    /// leave the launcher with no ssh to wait for and its control socket in a folder it removes.
    private static let forking = """
    Match sessiontype exec
      ForkAfterAuthentication yes
      StdinNull yes
      SessionType none
    Host fixture
      HostName fixture.example.invalid
      User sam

    """
    private static let plain = """
    Host fixture
      HostName fixture.example.invalid
      User sam
      IdentityFile ~/.ssh/id_fixture
      SendEnv LANG LC_*

    """

    /// The login: consent resolves the typed invocation, then the master Dispatch generates (its command, `-tt`) is
    /// resolved again; another host or account keeps the helper off. The reconnect: its `-f -N` master, silent or not.
    func testCommandDependentMatchRulesAreCheckedOnTheGeneratedLoginAndReconnect() async throws {
        let directory = try folder(["session-type": Self.sessionType, "command": Self.command,
                                    "transport-only": Self.transportOnly, "plain": Self.plain, "forking": Self.forking])
        let session = String(repeating: "c", count: 24)
        func login(_ name: String, command: String? = nil) throws -> (refusal: String?, approved: String) {
            let invocation = try XCTUnwrap(SSHInvocation.parse(["-F", directory.appendingPathComponent(name).path, "-t", "fixture"]
                + (command.map { [$0] } ?? []), isTerminal: true))
            let approved = try XCTUnwrap(SSHLauncherCommand.resolvedConfiguration(invocation, executable: "/usr/bin/ssh"), name)
            let remote = SSHLauncherCommand.remoteCommand(sessionID: session, grant: .init(profile: .statistics), command: invocation.command)
            let arguments = invocation.masterArguments(controlPath: directory.appendingPathComponent("master").path,
                                                       remoteCommand: remote, configuration: approved)
            return (SSHLauncherCommand.loginRefusal(approved: approved, arguments: arguments, executable: "/usr/bin/ssh"), approved)
        }
        func reconnect(_ name: String, automatic: Bool) async throws -> String? {
            let shell = SSHShell(destination: "fixture", options: ["-F", directory.appendingPathComponent(name).path])
            let invocation = SSHInvocation(options: shell.options, destination: shell.destination, command: nil, forcedTTY: false)
            let approved = try XCTUnwrap(SSHLauncherCommand.resolvedConfiguration(invocation, executable: shell.executable))
            let scope = SSHIntegrationScope(executable: shell.executable, destination: shell.destination, configuration: approved)
            do { _ = try await SSHCoordinator.verifyReconnect(shell, scope: scope, automatic: automatic); return nil }
            catch { return error.localizedDescription }
        }

        let typed = try login("session-type")
        XCTAssertTrue(typed.approved.contains("hostname shell.example.invalid\n"), "Consent covers the typed shell session")
        let refusal = try XCTUnwrap(typed.refusal, "Dispatch's command makes the master an exec session: another host and account")
        XCTAssertTrue(refusal.contains("hostname, user"), refusal)
        XCTAssertNotNil(try login("command").refusal, "Match command \"exec*\" matches Dispatch's own command")
        XCTAssertNotNil(try login("command", command: "uptime").refusal, "The typed command and Dispatch's differ as well")
        XCTAssertNil(try login("transport-only").refusal, "A login master has a session: the rule for none does not apply")
        XCTAssertNil(try login("plain").refusal, "Without command-dependent rules the generated master is the approved connection")
        let forked = try XCTUnwrap(try login("forking").refusal, "Only a reconnect's master sets these itself; for the login they come from Match")
        XCTAssertTrue(forked.contains("forkafterauthentication") && forked.contains("sessiontype") && forked.contains("stdinnull"), forked)

        for automatic in [false, true] {
            let refused = try await reconnect("session-type", automatic: automatic)
            XCTAssertTrue(refused?.contains("cannot reconnect") == true && refused?.contains("hostname, user") == true, refused ?? "accepted")
            let transport = try await reconnect("transport-only", automatic: automatic)
            XCTAssertNotNil(transport, "The -N master would log in to transport.example.invalid")
            let command = try await reconnect("command", automatic: automatic)
            XCTAssertNil(command, "Without a command -N resolves as the typed shell")
            let plain = try await reconnect("plain", automatic: automatic)
            XCTAssertNil(plain)
        }
        // A changed configuration is still a changed configuration.
        let shell = SSHShell(destination: "fixture", options: ["-F", directory.appendingPathComponent("plain").path])
        let other = try XCTUnwrap(SSHIntegrationScope(executable: shell.executable, destination: "fixture", configuration: "hostname a\nuser b\n"))
        do { _ = try await SSHCoordinator.verifyReconnect(shell, scope: other, automatic: false); XCTFail("A different scope must not reconnect") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed"), error.localizedDescription) }

        // Only Dispatch's own options may differ; anything else counts, repeated options as ordered lists.
        XCTAssertEqual(SSHResolvedConnection.differences(approved: "user sam\ncontrolmaster false\nrequesttty auto\nsendenv LANG\n",
                                                         actual: "user sam\ncontrolmaster true\nrequesttty force\nsendenv LANG\ncontrolpath /tmp/x\n",
                                                         ignoring: SSHResolvedConnection.login), [])
        XCTAssertEqual(SSHResolvedConnection.differences(approved: "user sam\nidentityfile a\nidentityfile b\n",
                                                         actual: "user sam\nidentityfile b\nidentityfile a\nproxyjump j\n",
                                                         ignoring: SSHResolvedConnection.login), ["identityfile", "proxyjump"])
        // Each invocation ignores only what it sets: -f -N's options count for the login, BatchMode for the login sheet.
        let approved = "user sam\nsessiontype default\nforkafterauthentication no\nbatchmode no\n"
        let detached = "user sam\nsessiontype none\nforkafterauthentication yes\nbatchmode yes\n"
        XCTAssertEqual(SSHResolvedConnection.differences(approved: approved, actual: detached, ignoring: SSHResolvedConnection.login),
                       ["batchmode", "forkafterauthentication", "sessiontype"])
        XCTAssertEqual(SSHResolvedConnection.differences(approved: approved, actual: detached, ignoring: SSHResolvedConnection.reconnect), ["batchmode"])
        XCTAssertEqual(SSHResolvedConnection.differences(approved: approved, actual: detached, ignoring: SSHResolvedConnection.silentReconnect), [])
    }

    /// `ssh -F ./config host` typed in a folder: the reconnect's configuration check and login run from that folder, as
    /// does a clone; a connection without one keeps the old behaviour and so fails the check.
    func testRelativeConfigurationPathsResolveFromTheFolderSSHWasTypedIn() async throws {
        let directory = try folder(["config": "Host fixture\n  HostName fixture.example.invalid\n  User sam\n  IdentityFile ../key\n"])
        let shell = SSHShell(destination: "fixture", options: ["-F", "./config"], directory: directory.path)
        let invocation = SSHInvocation(options: shell.options, destination: shell.destination, command: nil, forcedTTY: false)
        let approved = try XCTUnwrap(SSHLauncherCommand.resolvedConfiguration(invocation, executable: shell.executable, directory: directory.path))
        XCTAssertTrue(approved.contains("hostname fixture.example.invalid\n"))
        let scope = SSHIntegrationScope(executable: shell.executable, destination: shell.destination, configuration: approved)
        for automatic in [false, true] {
            let verified = try await SSHCoordinator.verifyReconnect(shell, scope: scope, automatic: automatic)
            XCTAssertEqual(verified.configuration, approved)
        }
        let homeless = SSHShell(destination: "fixture", options: ["-F", "./config"])
        do { _ = try await SSHCoordinator.verifyReconnect(homeless, scope: scope, automatic: false); XCTFail("./config is not in the app's folder") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed"), error.localizedDescription) }

        XCTAssertNil(SSHShell(destination: "fixture", directory: "relative/folder").directory, "Only an absolute folder is kept")
        XCTAssertEqual(TerminalMachine.ssh(shell).sshDirectory, directory.path)
        XCTAssertTrue(shell.command().contains(HerdrLaunch.quote("DISPATCH_SSH_DIRECTORY=" + directory.path)), shell.command())
        XCTAssertFalse(homeless.command().contains("DISPATCH_SSH_DIRECTORY"), "A clone without a folder runs as before")
        // Saved connections from before the folder decode; new ones keep it.
        let old = try JSONDecoder().decode(SSHShell.self, from: Data(#"{"executable":"/usr/bin/ssh","options":["-p","2222"],"destination":"sam@fixture"}"#.utf8))
        XCTAssertEqual(old, SSHShell(destination: "sam@fixture", options: ["-p", "2222"]))
        XCTAssertNil(old.directory)
        XCTAssertEqual(try JSONDecoder().decode(SSHShell.self, from: JSONEncoder().encode(shell)), shell)
    }

    /// Helper channels carry what the login's SendEnv sent (exact names, values from the terminal it was typed in); the
    /// resumed shell asks for agent forwarding only when the connection does. Without either, the arguments are as before.
    func testChannelsCarryTheSessionEnvironmentAndTheResumedShellItsAgentForwarding() {
        let configuration = "user sam\nsendenv LANG\nsendenv LC_*\nsendenv SAMPLE_?ENT\nsendenv DISPATCH_*\nforwardagent no\n"
        let environment = ["LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "SAMPLE_SENT": "a value", "SAMPLE_SENTX": "no",
                           "DISPATCH_HERDR_TOKEN": "private", "LCX": "no", "PATH": "/usr/bin", "BAD-NAME": "no"]
        let values = SSHSessionEnvironment.values(configuration: configuration, environment: environment)
        XCTAssertEqual(values, ["LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "SAMPLE_SENT": "a value"])
        XCTAssertEqual(SSHSessionEnvironment.values(configuration: "user sam\n", environment: environment), [:])
        // One too large for the limit is left out; the smaller ones after it still go.
        let large = ["A_LARGE": String(repeating: "x", count: SSHSessionEnvironment.maximumBytes), "B_SMALL": "fits"]
        XCTAssertEqual(SSHSessionEnvironment.values(configuration: "sendenv *\n", environment: large), ["B_SMALL": "fits"])
        XCTAssertTrue(SSHSessionEnvironment.matches("LC_ALL", "LC_*"))
        XCTAssertTrue(SSHSessionEnvironment.matches("ABC", "A?C"))
        XCTAssertTrue(SSHSessionEnvironment.matches("ANY", "*"))
        XCTAssertFalse(SSHSessionEnvironment.matches("lang", "LANG"))
        XCTAssertFalse(SSHSessionEnvironment.matches("LANGUAGE", "LANG"))

        let plain = SSHMaster(executable: "/usr/bin/ssh", controlPath: "/tmp/fixture/master", destination: "fixture")
        XCTAssertEqual(plain.arguments(command: "true"), [
            "-F", "/dev/null", "-S", "/tmp/fixture/master", "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false",
            "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=3",
            "-T", "--", "fixture", "exec /bin/sh -c 'true'"], "A connection without SendEnv opens the same helper channels as before")
        XCTAssertNil(plain.processEnvironment)
        var session = plain
        session.environment = values
        let helper = session.arguments(command: "true")
        XCTAssertEqual(Array(helper.drop { $0 != "ConnectTimeout=3" }.dropFirst().prefix(7)),
                       ["-o", "SendEnv=LANG", "-o", "SendEnv=LC_CTYPE", "-o", "SendEnv=SAMPLE_SENT", "-T"])
        XCTAssertFalse(helper.contains("ForwardAgent=yes"), "Helper channels never ask for agent forwarding")
        XCTAssertEqual(session.processEnvironment?["SAMPLE_SENT"], "a value")
        XCTAssertNotNil(session.processEnvironment?["PATH"], "The rest of the child's environment stays the app's")

        let resumed = session.shellArguments(command: "true", forwardAgent: true)
        XCTAssertEqual(Array(resumed.suffix(6)), ["-o", "ForwardAgent=yes", "-tt", "--", "fixture", "exec /bin/sh -c 'true'"])
        XCTAssertTrue(resumed.contains("SendEnv=SAMPLE_SENT"))
        XCTAssertEqual(plain.shellArguments(command: "true", forwardAgent: false),
                       plain.arguments(command: "true").map { $0 == "-T" ? "-tt" : $0 }, "Not requested: no forwarding, as before")
        XCTAssertTrue(SSHMaster.forwardsAgent("user sam\nforwardagent yes\n"))
        XCTAssertTrue(SSHMaster.forwardsAgent("forwardagent /tmp/agent.sock\n"))
        XCTAssertTrue(SSHMaster.forwardsAgent("forwardagent $SSH_AUTH_SOCK\n"))
        XCTAssertFalse(SSHMaster.forwardsAgent("user sam\nforwardagent no\n"))
        XCTAssertFalse(SSHMaster.forwardsAgent("user sam\n"))

        // Capture journals keep the names and lengths only.
        XCTAssertEqual(session.recorded.environment, ["LANG": "***********", "LC_CTYPE": "*****", "SAMPLE_SENT": "*******"])
        XCTAssertEqual(session.recorded.recorded.environment, session.recorded.environment, "Masking is stable, as replay masks again")
        XCTAssertNil(plain.recorded.environment)
        let request = SSHLaunchRequest(tabID: System.uuid(), token: "token", connectionID: SSHConnectionID(), credential: "credential",
                                       master: session, shell: SSHShell(destination: "fixture"))
        let bytes = try? JSONEncoder().encode(request)
        let journal = bytes.map(SSHLaunchRequest.recorded) ?? Data()
        XCTAssertFalse(String(decoding: journal, as: UTF8.self).contains("a value"), "The journal never holds a value")
        XCTAssertEqual(try? JSONDecoder().decode(SSHLaunchRequest.self, from: journal).master.environment?["SAMPLE_SENT"], "*******")
        let ordinary = try? JSONEncoder().encode(SSHLaunchRequest(tabID: System.uuid(), token: "token", connectionID: SSHConnectionID(),
                                                                  credential: "credential", master: plain, shell: SSHShell(destination: "fixture")))
        XCTAssertEqual(ordinary.map(SSHLaunchRequest.recorded), ordinary, "A request without session variables is recorded as it is")

        // The launch request carries the values to the app; older requests decode without them.
        let old = try? JSONDecoder().decode(SSHMaster.self, from: Data(#"{"executable":"/usr/bin/ssh","controlPath":"/tmp/m","destination":"fixture"}"#.utf8))
        XCTAssertNotNil(old)
        XCTAssertNil(old?.environment)
    }
}
