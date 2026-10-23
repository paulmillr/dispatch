import XCTest

/// The phone installs and talks to its watch app only when the two agree on identity: the watch app's bundle id
/// extends the phone's, and its companion key names the phone's (with the same signing suffix).
final class WatchScaffoldTests: XCTestCase {
    func testTheWatchAppNamesThePhoneAppAsItsCompanion() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertTrue(identifier.hasPrefix("yachts.dispatch.mobile"), identifier)
        XCTAssertTrue(identifier.hasSuffix(".watchkitapp"), identifier)
        XCTAssertEqual(info["WKCompanionAppBundleIdentifier"] as? String,
                       String(identifier.dropLast(".watchkitapp".count)))
        XCTAssertEqual(info["WKApplication"] as? Bool, true)
        XCTAssertEqual(info["WKRunsIndependentlyOfCompanionApp"] as? Bool, false)
    }
}
