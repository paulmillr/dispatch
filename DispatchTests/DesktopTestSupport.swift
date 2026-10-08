import CoreGraphics
import XCTest

/// A locked desktop cannot make AppKit test windows key. Keep this an explicit
/// environment skip; unlocked-desktop focus failures still fail the tests.
enum DesktopTestSupport {
    static func requireUnlocked() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
            throw XCTSkip("Requires an unlocked macOS desktop for keyboard focus and full-screen transitions.")
        }
    }
}
