import UIKit
import XCTest

/// The iPad mockups (I1–I8, `mockups/Sources/{PadStrip,IPad}.swift`) beside the app on an iPad on its side, in dark and
/// light (docs/ios.md, Testing, Fidelity). Each screenshot is attached as `<ID>-<scheme>-app` and, beside the mockup's
/// render when `mockups/shots` has it, as `<ID>-<scheme>`; `TEST_RUNNER_DISPATCH_FIDELITY_OUT=<folder>` also writes the
/// app's as `<ID>-<scheme>.png` there (the simulator sees the Mac's disk). `TEST_RUNNER_DISPATCH_FIDELITY_SCREENS=I1,I2`
/// limits a run. I6 and I6b are the left half of the window (Window Controls, Move & Resize), which is the phone's stack.
/// Skipped on an iPhone; the test fails only when a screen cannot be reached.
@MainActor
final class IPadFidelityUITests: XCTestCase {
    struct Screen {
        let id: String
        var environment: [String: String] = [:]
        var arguments: [String] = []
        /// The window's left half (I6, I6b) instead of the whole screen.
        var half = false
        var then: (@MainActor (XCUIApplication) -> Void)? = nil
    }

    /// The Spaces mockup sample (`TabsSample.spacesMockup`): the tabs, titles, hosts and offline group the iPad mockups
    /// draw.
    static let sample = ["-DispatchTabsSample", "YES", "-DispatchSpacesMockup", "P1", "-DispatchHardwareKeyboard", "YES"]
    static let touch = ["-DispatchTabsSample", "YES", "-DispatchSpacesMockup", "P1", "-DispatchHardwareKeyboard", "NO"]
    static let claude = ["-DispatchTabsShow", "tab:herdr:app:1"], dev = ["-DispatchTabsShow", "tab:herdr:app:2"]
    static let review = sample + claude + ["-DispatchTabsSegment", "files", "-DispatchTabsFilesMode", "review"]
    static let commits = sample + dev + ["-DispatchTabsSegment", "files", "-DispatchTabsFilesMode", "commits"]

    static let screens: [Screen] = [
        Screen(id: "I1", arguments: sample + dev + ["-DispatchTabsSegment", "files", "-DispatchFilesFolder", "src"]),
        Screen(id: "I2", arguments: review + ["-DispatchReviewDiff", "Sidebar.tsx"]),
        Screen(id: "I2b", arguments: review),
        Screen(id: "I3", arguments: commits + ["-DispatchTabsFilesRoute", "commits:c81a2f49e0b3d5a7c1f2e4b6d8a0c3e5f7a9b1d2"]),
        Screen(id: "I3b", arguments: commits),
        // A hardware keyboard: the composer takes the focus, and the system's keyboard bar shows under it (a touch
        // iPad's thread opened short of its end, as on the base build).
        Screen(id: "I4", arguments: sample + claude + ["-DispatchTabsSegment", "chat"]),
        // The demo's hosts are sessions with stats (`HostStatsDemo`): its web space open, then mba2's glyph in the
        // sidebar opens the popover; the demo's agents' banners off.
        Screen(id: "I5", environment: ["DISPATCH_MOBILE_DEMO": "1"],
               arguments: ["-DispatchHardwareKeyboard", "NO", "-notify.needsYou", "NO", "-notify.finished", "NO",
                           "-notify.failed", "NO"], then: { app in
            let web = app.buttons["web"].firstMatch
            if web.waitForExistence(timeout: 10) { web.tap() }
            // The demo's agents finish a turn as it starts: their banner goes first.
            Thread.sleep(forTimeInterval: 6)
            let glyph = app.buttons["mba2 stats"].firstMatch
            if glyph.waitForExistence(timeout: 10) { glyph.tap() }
        }),
        Screen(id: "I7", arguments: sample + dev + ["-DispatchTabsSegment", "terminal"]),
        Screen(id: "I8", arguments: touch + claude + ["-DispatchTabsSegment", "chat"], then: { app in
            let hide = app.buttons["Hide sidebar"].firstMatch
            if hide.waitForExistence(timeout: 5) { hide.tap() }
        }),
        Screen(id: "I6", arguments: sample + claude + ["-DispatchTabsSegment", "files", "-DispatchFilesFolder", "src"], half: true),
        Screen(id: "I6b", arguments: sample + ["-DispatchSpacesMockup", "P1"], half: true),
    ]

    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    static var selected: [Screen] {
        guard let list = ProcessInfo.processInfo.environment["DISPATCH_FIDELITY_SCREENS"] else { return screens }
        let ids = Set(list.split(separator: ",").map(String.init))
        return screens.filter { ids.contains($0.id) }
    }

    func testIPadScreensBesideTheMockup() throws {
        let out = ProcessInfo.processInfo.environment["DISPATCH_FIDELITY_OUT"].map { URL(fileURLWithPath: $0) }
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for screen in Self.selected {
            for scheme in ["dark", "light"] {
                XCUIDevice.shared.orientation = .landscapeLeft
                let app = XCUIApplication()
                app.launchEnvironment = screen.environment.merging(["DISPATCH_MOBILE_STORE": "memory"]) { a, _ in a }
                app.launchArguments = screen.arguments + ["-appearance", scheme]
                app.launch()
                arrange(app, screen.half ? "Left" : "Fill")
                Thread.sleep(forTimeInterval: 2.5)
                screen.then?(app)
                Thread.sleep(forTimeInterval: 1.5)
                let shot = Self.upright(XCUIScreen.main.screenshot().image)
                attach(shot.pngData(), "\(screen.id)-\(scheme)-app")
                if let out {
                    try? shot.pngData()?.write(to: out.appendingPathComponent("\(screen.id)-\(scheme).png"))
                }
                if let mockup = FidelityUITests.shot(screen.id, scheme: scheme) {
                    attach(Self.pair(mockup: mockup, app: shot).pngData(), "\(screen.id)-\(scheme)")
                }
                if screen.half { arrange(app, "Fill") }
                app.terminate()
            }
        }
    }

    /// The screen on its side as it is seen: the simulator's capture of a landscape screen is the panel's portrait
    /// bitmap, turned a quarter.
    static func upright(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage, cg.width < cg.height else { return image }
        let size = CGSize(width: cg.height, height: cg.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cg, scale: 1, orientation: .left).draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The mockup and the app side by side at the mockup's size.
    static func pair(mockup: UIImage, app: UIImage) -> UIImage {
        let size = mockup.size, gap: CGFloat = 24
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * 2 + gap, height: size.height), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width * 2 + gap, height: size.height))
            mockup.draw(in: CGRect(origin: .zero, size: size))
            app.draw(in: CGRect(x: size.width + gap, y: 0, width: size.width, height: size.height))
        }
    }

    private func attach(_ data: Data?, _ name: String) {
        guard let data else { return XCTFail("No PNG for \(name)") }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// iPadOS's window controls (as `IPadLayoutUITests` drives them): hold Zoom, then a Move & Resize entry.
    private func arrange(_ app: XCUIApplication, _ entry: String) {
        let window = app.windows.firstMatch.frame
        let screen = springboard.windows.firstMatch.frame.size
        let full = window.size == screen || window.size == CGSize(width: screen.height, height: screen.width)
        if entry == "Fill", full { return }
        if full {
            let corner = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -6, dy: -6))
            corner.press(forDuration: 0.5, thenDragTo: corner.withOffset(CGVector(dx: -150, dy: -150)))
            sleep(1)
        }
        let controls = springboard.descendants(matching: .any)["window-controls:yachts.dispatch.mobile"].firstMatch
        guard controls.waitForExistence(timeout: 5) else { return XCTFail("window controls") }
        controls.tap()
        let zoom = springboard.buttons["Zoom-button"].firstMatch
        guard zoom.waitForExistence(timeout: 5) else { return XCTFail("Zoom") }
        zoom.press(forDuration: 1.2)
        let item = springboard.buttons[entry].firstMatch
        guard item.waitForExistence(timeout: 5) else { return XCTFail(entry) }
        item.tap()
        sleep(2)
    }
}
