import XCTest
@testable import DispatchApp

/// Which typed `ssh` commands are logins Dispatch follows (host detection, reconnect, clones), read as OpenSSH reads
/// them: options, the destination, options again (unless `--` came first), then the remote command.
final class SSHShellParseTests: XCTestCase {
    private func parse(_ line: String) -> SSHShell? {
        SSHShell.parse(executable: "/usr/bin/ssh", arguments: line.split(separator: " ").map(String.init))
    }

    func testOptionsBeforeTheDestination() {
        XCTAssertEqual(parse("ssh -l alice nightly")?.options, ["-l", "alice"])
        XCTAssertEqual(parse("ssh -p 2222 -lalice nightly")?.options, ["-p", "2222", "-l", "alice"])
        XCTAssertEqual(parse("ssh nightly")?.destination, "nightly")
    }

    func testOptionsAfterTheDestination() {
        let shell = parse("ssh nightly -l alice")
        XCTAssertEqual(shell?.destination, "nightly")
        XCTAssertEqual(shell?.options, ["-l", "alice"])
        XCTAssertEqual(parse("ssh -4 nightly -p 2222 -luser -A")?.options, ["-4", "-p", "2222", "-l", "user", "-A"])
        XCTAssertEqual(parse("ssh nightly -L 8080:localhost:80")?.options, [], "Forwarding is not carried to clones")
        XCTAssertEqual(parse("ssh -t nightly -l alice top")?.options, ["-l", "alice"], "-t: a login running a command")
    }

    /// OpenSSH keeps the first user it reads; Dispatch's command puts the options first, so a later `-l` is dropped.
    func testAUserInTheDestinationWinsOverALaterDashL() {
        XCTAssertEqual(parse("ssh alice@nightly -l bob")?.options, [])
        XCTAssertEqual(parse("ssh -l bob alice@nightly")?.options, ["-l", "bob"], "Before it, -l wins and stays")
        XCTAssertEqual(parse("ssh alice@nightly -l bob -p 2222")?.options, ["-p", "2222"])
    }

    /// Found by comparing with `ssh -G`: a port in an `ssh://` destination and a user given as `-o User` behave as `-l`.
    func testADestinationsUserAndPortWinOverLaterOptions() {
        XCTAssertEqual(parse("ssh alice@nightly -o User=carol")?.options, [])
        XCTAssertEqual(parse("ssh alice@nightly -o user=carol -p 2222")?.options, ["-p", "2222"], "No port in the destination")
        XCTAssertEqual(parse("ssh ssh://nightly:2201 -p 2222 -l bob")?.options, ["-l", "bob"])
        XCTAssertEqual(parse("ssh ssh://alice@[fd00::5]:2201 -oPort=2300 -l bob -4")?.options, ["-4"])
        XCTAssertEqual(parse("ssh -p 2222 ssh://nightly:2201")?.options, ["-p", "2222"], "Before it, -p wins and stays")
    }

    func testTagTakesAValue() {
        XCTAssertEqual(parse("ssh -P work nightly")?.destination, "nightly")
        XCTAssertEqual(parse("ssh -P work nightly")?.options, ["-P", "work"])
    }

    /// `-t` asks for a terminal, `-T` refuses one, the last wins; `-o RequestTTY` counts only before either.
    func testTheTerminalRequestDecidesAsSSHDoes() {
        XCTAssertNil(parse("ssh -t nightly -T ls"))
        XCTAssertNotNil(parse("ssh -T -t nightly"))
        XCTAssertNotNil(parse("ssh -o RequestTTY=force nightly ls"))
        XCTAssertNil(parse("ssh -o RequestTTY=no nightly"))
        XCTAssertNotNil(parse("ssh -o RequestTTY=no -t nightly"))
        XCTAssertNotNil(parse("ssh -t -o RequestTTY=no nightly"), "-t came first: the option is ignored")
        XCTAssertNil(parse("ssh -o SessionType=none nightly"))
        XCTAssertNil(parse("ssh nightly -o ForkAfterAuthentication=yes"))
    }

    func testCommandsAndNonLoginsAreNotFollowed() {
        XCTAssertNil(parse("ssh nightly ls"))
        XCTAssertNil(parse("ssh nightly -l alice ls"))
        XCTAssertNil(parse("ssh nightly -- -l alice"), "After --, the rest is the remote command")
        XCTAssertNil(parse("ssh -- nightly -l alice"), "-- before the destination ends option parsing")
        XCTAssertNil(parse("ssh nightly -N"))
        XCTAssertNil(parse("ssh nightly -G"))
        XCTAssertNil(parse("ssh nightly -O exit"))
        XCTAssertNil(parse("ssh nightly -l"), "A missing value")
        XCTAssertNil(parse("ssh -T nightly"))
    }

    // MARK: The typed ssh Dispatch takes over (`SSHInvocation`, `--ssh-launch`)

    private func invocation(_ line: String) -> SSHInvocation? {
        SSHInvocation.parse(line.split(separator: " ").map(String.init), isTerminal: true)
    }

    func testTheLauncherReadsOptionsAfterTheHost() {
        XCTAssertEqual(invocation("nightly -l alice"),
                       SSHInvocation(options: ["-l", "alice"], destination: "nightly", command: nil, forcedTTY: false))
        XCTAssertEqual(invocation("-4 nightly -p 2222 -luser")?.options, ["-4", "-p", "2222", "-l", "user"])
        XCTAssertEqual(invocation("alice@nightly -l bob")?.options, [], "The destination's user wins, as in OpenSSH")
        XCTAssertEqual(invocation("-l bob alice@nightly")?.options, ["-l", "bob"])
        XCTAssertEqual(invocation("nightly -t -l alice top"),
                       SSHInvocation(options: ["-l", "alice"], destination: "nightly", command: "top", forcedTTY: true))
    }

    func testTheLauncherKeepsTheDestinationsUserAndPort() {
        XCTAssertEqual(invocation("alice@nightly -o User=carol -A")?.options, ["-A"])
        XCTAssertEqual(invocation("ssh://nightly:2201 -p 2222")?.options, [])
        XCTAssertEqual(invocation("-P work nightly -l bob")?.options, ["-P", "work", "-l", "bob"])
    }

    func testTheLauncherLeavesCommandsAndControlUsesToSSH() {
        XCTAssertNil(invocation("nightly -l alice ls"), "A command without -t")
        XCTAssertNil(invocation("nightly -- -l alice"))
        XCTAssertNil(invocation("-- nightly -l alice"))
        XCTAssertNil(invocation("nightly -N"))
        XCTAssertNil(invocation("nightly -O exit"))
        XCTAssertNil(invocation("nightly -o ControlMaster=yes"))
        XCTAssertNil(invocation("nightly -l"))
    }
}
