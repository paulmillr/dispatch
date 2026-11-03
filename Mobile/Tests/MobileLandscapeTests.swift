import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// A phone on its side (docs/ios.md, Landscape): which windows take the rail layout, which edge the rail stands on,
/// when the terminal's capsule shows and the rail folds, and that the rail fits the shortest phone.
@MainActor
final class MobileLandscapeTests: XCTestCase {
    /// Every iPhone on its side, and the Duo's cover screen; never upright, never a window that splits (the unfolded
    /// Duo), never an iPad (whose narrow windows keep the phone's stack upright).
    func testWhichWindowsAreOnTheirSide() {
        for size in [CGSize(width: 874, height: 402), CGSize(width: 956, height: 440), CGSize(width: 667, height: 375),
                     CGSize(width: 678, height: 466)] {
            XCTAssertTrue(MobileLandscape.applies(to: size, device: .phone), "\(size)")
        }
        for size in [CGSize(width: 402, height: 874), CGSize(width: 466, height: 678), CGSize(width: 951, height: 669),
                     CGSize(width: 669, height: 951), .zero] {
            XCTAssertFalse(MobileLandscape.applies(to: size, device: .phone), "\(size)")
        }
        XCTAssertFalse(MobileLandscape.applies(to: CGSize(width: 1210, height: 486), device: .pad), "an iPad's top half")
        XCTAssertFalse(MobileLandscape.applies(to: CGSize(width: 600, height: 400), device: .pad))
    }

    /// The rail stands on the Dynamic Island's edge: the phone's top, on the left when the interface is turned
    /// landscape right, on the right when turned landscape left.
    func testTheRailFollowsTheIsland() {
        XCTAssertEqual(MobileLandscape.railEdge(.landscapeRight), .leading)
        XCTAssertEqual(MobileLandscape.railEdge(.landscapeLeft), .trailing)
        XCTAssertEqual(MobileLandscape.railEdge(.unknown), .leading)
    }

    /// The terminal's capsule rides a docked keyboard only, where the rail folds to Back and the disc; at rest the
    /// rail's keyboard button stands for the capsule.
    func testTheKeyboardBringsTheCapsuleAndFoldsTheRail() {
        XCTAssertTrue(MobileLandscape.keyCapsule(keyboard: .docked))
        XCTAssertFalse(MobileLandscape.keyCapsule(keyboard: .hidden))
        XCTAssertFalse(MobileLandscape.keyCapsule(keyboard: .floating))
        XCTAssertTrue(MobileLandscape.compactRail(keyboard: .docked))
        XCTAssertFalse(MobileLandscape.compactRail(keyboard: .hidden))
    }

    /// The whole rail (Back, the disc, five modes, the action) fits the shortest phone on its side, 375 points; the
    /// switch stood on end is five 36-point slots.
    func testTheRailFitsTheShortestPhone() {
        XCTAssertEqual(PadModeSwitch.length(5), 5 * 40 + 4 * 2 + 6)
        XCTAssertEqual(PadModeSwitch.length(5, axis: .vertical), 5 * 36 + 4 * 2 + 6)
        XCTAssertLessThanOrEqual(MobileLandscape.railHeight, 375)
        XCTAssertGreaterThan(667 - MobileLandscape.railInset(island: MobileLandscape.defaultIsland) - MobileLandscape.railWidth
                             - MobileLandscape.contentInset - MobileLandscape.listWidth, 250, "a diff's pane beside the list")
    }
}

extension MobileLandscapeTests {
    /// The rail stands clear of each phone's island, inside the inset the safe area keeps for it: the island ends about
    /// 14 points inside that inset (the rail's glass measured in `PhoneLandscapeUITests` on the Air, 17e, 18 Pro Max). Insets measured on the simulators (portrait top, the landscape sides).
    func testTheRailStandsClearOfEachPhonesIsland() {
        // (phone, the safe area's inset, where its island or notch ends)
        let phones: [(String, CGFloat, CGFloat)] = [("iPhone 17, 18 Pro, 18 Pro Max", 62, 48), ("iPhone Air", 68, 54),
                                                    ("iPhone 17e's notch", 47, 33)]
        for (phone, inset, island) in phones {
            let rail = MobileLandscape.railInset(island: inset)
            // The rail's glass reaches 2 points past its padding.
            XCTAssertGreaterThanOrEqual(rail - 2, island + 2, "\(phone): clear of the island")
            XCTAssertLessThan(rail, inset, "\(phone): inside the inset it replaces")
        }
        XCTAssertEqual(MobileLandscape.railInset(island: 68), 58, "the Air: 6 points further in than the 17")
        XCTAssertEqual(MobileLandscape.railInset(island: 0), MobileLandscape.contentInset, "no island: the corners' margin")
        // Upright or on its side, the same depth.
        XCTAssertEqual(MobileLandscape.island(UIEdgeInsets(top: 68, left: 0, bottom: 34, right: 0)), 68)
        XCTAssertEqual(MobileLandscape.island(UIEdgeInsets(top: 0, left: 68, bottom: 21, right: 68)), 68)
    }
}
