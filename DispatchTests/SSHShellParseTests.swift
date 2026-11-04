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
