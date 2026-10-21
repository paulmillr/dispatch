import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The iPad visual pass (docs/ios.md, iPad windows): what read as an iPhone app stretched or as written for an
/// iPhone, fixed for an iPad while the phone's rendering stays as it was. Rendered cases run on an iPad and skip on
/// an iPhone; the rules run on both.
@MainActor
final class IPadPolishTests: XCTestCase {
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The text names the device it runs on: "this iPad" on an iPad, "this iPhone" on the phone, never the other.
    func testTheTextNamesTheDevice() {
        XCTAssertEqual(MobileDevice.name, pad ? "iPad" : "iPhone")
        let texts = [HostSessions.removalMessage, KeyCache.missing]
        for text in texts {
            XCTAssertTrue(text.contains("this \(MobileDevice.name)"), text)
            if pad { XCTAssertFalse(text.contains("iPhone"), text) }
        }
    }

    /// The Terminal / Chat control and the composer's key row keep a phone's width on an iPad, centred, rather than
    /// spreading two segments (or six keys) over a 1,000-point column; the phone's span their column.
    func testControlsKeepAPhonesWidthOnAnIPad() {
        XCTAssertEqual(TabSegmentControl.maxWidth(idiom: .phone), .infinity)
        XCTAssertEqual(TabSegmentControl.maxWidth(idiom: .pad), 400)
        XCTAssertEqual(CodeKeyRow.maxWidth(idiom: .phone), .infinity)
        XCTAssertEqual(CodeKeyRow.maxWidth(idiom: .pad), TerminalAdaptation.padCapsuleWidth)
    }

    /// Rendered across a 13-inch's column, the segmented control is 400 points wide in its middle on an iPad.
    func testTheSegmentedControlIsCentredInAWideColumn() throws {
        guard pad else { throw XCTSkip("The phone's control spans its column") }
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1045, height: 300)
        window.rootViewController = UIHostingController(rootView: TabSegmentControl(selection: .constant(.terminal)).padding(.horizontal, 16))
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        let control = try XCTUnwrap(views(window).first { $0 is UISegmentedControl })
        let frame = control.convert(control.bounds, to: window)
        XCTAssertEqual(frame.width, 400, accuracy: 1)
        XCTAssertEqual(frame.midX, 1045 / 2, accuracy: 1)
    }
}
