import UIKit

/// What the app's text calls the device: "iPhone", or "iPad" on an iPad ("Removes … from this iPad"), so no iPad
/// screen says iPhone. Read from the idiom once at launch (`start`, the app delegate, before any screen), since
/// some of the text is made off the main actor (the SSH driver's key cache); "iPhone" until then.
enum MobileDevice {
    nonisolated(unsafe) private(set) static var name = "iPhone"

    @MainActor static func start() {
        name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}
