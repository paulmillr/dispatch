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

    /// The composer's key row keeps a phone's width on an iPad, centred, rather than spreading six keys over a
    /// 1,000-point column; the phone's spans its column.
    func testControlsKeepAPhonesWidthOnAnIPad() {
        XCTAssertEqual(CodeKeyRow.maxWidth(idiom: .phone), .infinity)
        XCTAssertEqual(CodeKeyRow.maxWidth(idiom: .pad), TerminalAdaptation.padCapsuleWidth)
    }
}
