import XCTest
@testable import DispatchMobile

final class TerminalSchemePolicyTests: XCTestCase {
    func testAmbiguousSchemesHaveAGroupOnEachSideAndKeepShortColors() {
        let scheme = TerminalSchemes.parse("background=\"#aaa\"\nforeground=#fff\npalette=1=#f00", file: "Example")
        XCTAssertNil(scheme.side)
        XCTAssertEqual(scheme.background, .init(170, 170, 170))
        XCTAssertEqual(scheme.accents, [.init(255, 0, 0)])
        XCTAssertTrue(SchemeGroup.dark.contains(scheme.group(light: false)))
        XCTAssertTrue(SchemeGroup.light.contains(scheme.group(light: true)))
        XCTAssertEqual(scheme.group(light: false), .neon)
        XCTAssertEqual(scheme.group(light: true), .offWhite)
    }
}
