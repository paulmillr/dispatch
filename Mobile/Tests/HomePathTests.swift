import XCTest
@testable import DispatchMobile

/// One "~" rule for Spaces, host detail, Terminal's subtitle and Chat's intro: the helper's homes, never a guess.
@MainActor
final class HomePathTests: XCTestCase {
    func testTheRule() {
        let homes = HomePath(account: "/Users/alex")
        XCTAssertEqual(homes.abbreviate("/Users/alex/src/app"), "~/src/app")
        XCTAssertEqual(homes.abbreviate("/Users/alex"), "~")
        XCTAssertEqual(homes.abbreviate("/Users/alex/"), "~")
        XCTAssertEqual(homes.abbreviate("/Users/alexandra/x"), "/Users/alexandra/x", "a whole folder name only")
        XCTAssertEqual(homes.abbreviate("/srv/app"), "/srv/app")
        XCTAssertEqual(HomePath(account: "/home/paul/").abbreviate("/home/paul/notes"), "~/notes", "a trailing slash on the home")
        XCTAssertEqual(HomePath(account: "/").abbreviate("/etc"), "/etc", "the root shortens nothing")
        XCTAssertEqual(HomePath(account: nil).abbreviate("/Users/alex/src"), "/Users/alex/src", "no home: no guessing")
        XCTAssertEqual(homes.expand("~/src"), "/Users/alex/src")
        XCTAssertEqual(homes.expand("~"), "/Users/alex")
        XCTAssertEqual(homes.expand("/tmp"), "/tmp")
    }

    /// The login environment's HOME, when the helper reports it, shortens too (the longer match wins) and is what a
    /// typed "~" means.
    func testTheLoginHome() {
        let homes = HomePath(account: "/Users/alex", login: "/tmp/dt/h")
        XCTAssertEqual(homes.abbreviate("/tmp/dt/h/src"), "~/src")
        XCTAssertEqual(homes.abbreviate("/Users/alex/src"), "~/src")
        XCTAssertEqual(homes.expand("~/x"), "/tmp/dt/h/x")
        let nested = HomePath(account: "/home/paul", login: "/home/paul/sandbox")
        XCTAssertEqual(nested.abbreviate("/home/paul/sandbox/app"), "~/app")
        XCTAssertEqual(homes.abbreviate("/private/tmp/dt/h/work"), "~/work", "macOS reports /tmp as /private/tmp")
        XCTAssertEqual(HomePath(account: "/private/var/u").abbreviate("/var/u/x"), "~/x")
        XCTAssertEqual(homes.abbreviate("/private/tmpx"), "/private/tmpx")
        let hello = ResilienceFixture.hello(home: "/Users/alex", loginHome: "/tmp/dt/h")
        XCTAssertEqual(HomePath(hello), homes, "read from hello.account")
        XCTAssertEqual(HomePath(ResilienceFixture.hello()).login, nil, "absent while the login HOME is the account's")
    }

    /// Spaces (TabsHost), host detail (HostSummary), Terminal's subtitle and Chat's intro say the same.
    func testEveryPlaceUsesTheSameRule() {
        let hello = ResilienceFixture.hello(home: "/Users/alex", loginHome: "/tmp/dt/h")
        let homes = HomePath(hello)
        let host = TabsHost(id: UUID(), name: "studio", tint: .blue, home: "/Users/alex", loginHome: "/tmp/dt/h")
        for path in ["/tmp/dt/h/src", "/Users/alex/notes", "/Users/alexandra", "/srv"] {
            let expected = homes.abbreviate(path)
            XCTAssertEqual(host.abbreviate(path), expected, path)
            XCTAssertEqual(TerminalSubtitle.text(directory: path, shell: nil, homes: homes), expected, path)
        }
        XCTAssertEqual(host.expand("~/new"), "/tmp/dt/h/new")
    }
}
