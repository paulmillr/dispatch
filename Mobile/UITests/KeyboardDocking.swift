import XCTest

/// The iPad software keyboard's docking, for the cases that float it or need it docked (`ChatIPadUITests`,
/// `TerminalKeyboardUITests`). iPadOS keeps a floating keyboard across launches, so a case that leaves it floating
/// decides the next runs' docked-keyboard cases (Chat's composer then sat under it). A pinch floats and docks it, but
/// a docking pinch on the small floating keyboard does not always take: dragging it by its handle to the window's
/// bottom edge docks it as well.
extension XCUIApplication {
    /// The shown software keyboard floats (narrower than the window).
    var keyboardFloats: Bool {
        let keyboard = keyboards.firstMatch
        return keyboard.exists && keyboard.frame.width < windows.firstMatch.frame.width - 1
    }

    /// Floats or docks the shown keyboard, as a user does; true when it ended as asked.
    @discardableResult func setKeyboardFloating(_ float: Bool) -> Bool {
        let keyboard = keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else { return false }
        Thread.sleep(forTimeInterval: 1)
        for attempt in 0..<4 where keyboardFloats != float {
            dismissKeyboardTip()
            if float || attempt % 2 == 0 {
                keyboard.pinch(withScale: float ? 0.4 : 2.5, velocity: float ? -2 : 2)
            } else {
                // The floating keyboard's handle (its "•••", between the emoji and dictation keys) is under the frame
                // XCUITest reports for it, which stops at the space bar's row; dropped at the window's bottom, it docks.
                let handle = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 28))
                let bottom = windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: 40))
                handle.press(forDuration: 0.2, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
            }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return keyboardFloats == float
    }

    /// The keyboard's one-time tip ("Speed up your typing by sliding your finger…", Continue) sits over a floating
    /// keyboard and takes the gestures meant for it.
    func dismissKeyboardTip() {
        for button in [keyboards.buttons["Continue"], buttons["Continue"]] where button.exists && button.isHittable {
            button.tap()
            Thread.sleep(forTimeInterval: 0.5)
            return
        }
    }
}
