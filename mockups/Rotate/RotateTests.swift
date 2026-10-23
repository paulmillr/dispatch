import XCTest

/// Turns the simulator to landscape; the orientation stays after the test (simctl cannot rotate).
final class RotateTests: XCTestCase {
    @MainActor func testLandscape() {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeRight
        sleep(3)
        XCTAssertTrue(XCUIDevice.shared.orientation.isLandscape)
    }
}
