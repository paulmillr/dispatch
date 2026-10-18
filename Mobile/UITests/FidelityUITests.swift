import UIKit
import XCTest

/// The design-fidelity check (docs/ios.md, Testing, Fidelity): every mockup screen the Debug demo hooks reach, in dark
/// and light, drawn beside the mockup's render and attached to the result bundle as `<screen>-<scheme>` (the pair) and
/// `<screen>-<scheme>-app` (the screenshot alone). Light screens sit beside L1a (Agents) and L2a (a thread) where the
/// mockup has them, else beside the dark render, for layout. The renders are `build/mockup-review/ios-<ID>.png`
/// (git-ignored; `TEST_RUNNER_DISPATCH_MOCKUP_DIR` names another folder); without them the test skips. The pairs are
/// looked at by eye: the test fails only when a screen cannot be reached.
/// `TEST_RUNNER_DISPATCH_FIDELITY_SCREENS=M5a,M7a` limits a run.
@MainActor
final class FidelityUITests: XCTestCase {
    typealias Screen = AppearanceUITests.Screen

    /// The mockup's 22 screens in its order.
    static let screens: [Screen] = {
        let appearance = Dictionary(uniqueKeysWithValues: AppearanceUITests.screens.map { ($0.id, $0) })
        let sample = AppearanceUITests.sample
        func demo(_ id: String) -> Screen { appearance[id] ?? Screen(id: id, environment: ["DISPATCH_MOBILE_CHAT_DEMO": id]) }
        return [
            appearance["M1d"]!,
            // Edit mode over the tree with ai collapsed, as drawn.
            Screen(id: "M1e", arguments: sample + ["-DispatchTabsTree", "YES", "-DispatchTabsCollapse", "ai", "-DispatchTabsShow", "edit"]),
            Screen(id: "M1f", environment: ["DISPATCH_MOBILE_SCRIPTED": "1"], then: { app in
                let edit = app.buttons["Edit"]
                if edit.waitForExistence(timeout: 5) { edit.tap() }
                let info = app.buttons["studio details"]
                if info.waitForExistence(timeout: 5) { info.tap() }
            }),
            appearance["M2a"]!,
            Screen(id: "M2b", arguments: sample + ["-DispatchTabsTree", "YES", "-DispatchTabsCollapse", "ai"]),
            appearance["M2c"]!,
            demo("M3a"), demo("M4a"), demo("M3b"), demo("M4b"), demo("M4c"),
            appearance["M4d"]!,
            demo("M5a"), demo("M5f"), demo("M5b"), demo("M5c"),
            // The mockup's patch (CodeDemo); AppearanceUITests reaches the viewer through M5b's fixture instead.
            Screen(id: "M5d", environment: ["DISPATCH_MOBILE_CHAT_DEMO": "M5d"]),
            demo("M5e"),
            // The sample's dev tab on its Terminal segment, showing the M6a fixture; a tap raises the keyboard and the
            // key capsule.
            Screen(id: "M6a", arguments: sample + ["-DispatchTabsShow", "tab:herdr:app:2"], then: { app in
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }),
            appearance["M7a"]!,
            appearance["M8a"]!,
            demo("M9a"),
        ]
    }()

    static var selected: [Screen] {
        let environment = ProcessInfo.processInfo.environment
        guard let list = environment["DISPATCH_FIDELITY_SCREENS"] else { return screens }
        let ids = Set(list.split(separator: ",").map(String.init))
        return screens.filter { ids.contains($0.id) }
    }

    static var mockups: URL {
        if let folder = ProcessInfo.processInfo.environment["DISPATCH_MOCKUP_DIR"] { return URL(fileURLWithPath: folder) }
        // Mobile/UITests/FidelityUITests.swift → the checkout's build/mockup-review (the simulator sees the Mac's disk).
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/mockup-review")
    }

    /// The render beside a screen: L1a and L2a for the light Agents list and thread.
    static func render(_ id: String, scheme: String) -> String {
        guard scheme == "light" else { return id }
        return ["M3a": "L1a", "M4a": "L2a"][id] ?? id
    }

    func testScreensBesideTheMockup() throws {
        guard FileManager.default.fileExists(atPath: Self.mockups.appendingPathComponent("ios-M2a.png").path) else {
            throw XCTSkip("No mockup renders in \(Self.mockups.path) (build/mockup-review, or TEST_RUNNER_DISPATCH_MOCKUP_DIR)")
        }
        for screen in Self.selected {
            for scheme in ["dark", "light"] {
                let app = XCUIApplication()
                app.launchEnvironment = screen.environment
                app.launchArguments = screen.arguments + ["-appearance", scheme]
                app.launch()
                // The demos load their fixtures and settle; the scripted hosts connect.
                Thread.sleep(forTimeInterval: 2.5)
                screen.then?(app)
                Thread.sleep(forTimeInterval: 1.5)
                let shot = XCUIScreen.main.screenshot().image
                attach(shot.pngData(), "\(screen.id)-\(scheme)-app")
                let id = Self.render(screen.id, scheme: scheme)
                if let mockup = UIImage(contentsOfFile: Self.mockups.appendingPathComponent("ios-\(id).png").path) {
                    attach(Self.pair(mockup: mockup, app: shot).pngData(), "\(screen.id)-\(scheme)")
                } else {
                    XCTFail("No render for \(id)")
                }
                app.terminate()
            }
        }
    }

    private func attach(_ data: Data?, _ name: String) {
        guard let data else { return XCTFail("No PNG for \(name)") }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The phone cut out of the render (868 px wide at 2x: the caption above, the 402 x 874 pt phone at the bottom with
    /// 32 px margins) and the app's screenshot, both at 2x, side by side, with a faint guide every 50 points
    /// (`scripts/fidelity-pairs.swift` does the same on the Mac).
    static func pair(mockup: UIImage, app: UIImage) -> UIImage {
        let phone = CGSize(width: 804, height: 1748), gap: CGFloat = 24
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: phone.width * 2 + gap, height: phone.height), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: phone.width * 2 + gap, height: phone.height))
            if let image = mockup.cgImage {
                let crop = CGRect(x: 32, y: CGFloat(image.height) - 32 - phone.height, width: phone.width, height: phone.height)
                if let cut = image.cropping(to: crop) {
                    UIImage(cgImage: cut).draw(in: CGRect(origin: .zero, size: phone))
                }
            }
            app.draw(in: CGRect(x: phone.width + gap, y: 0, width: phone.width, height: phone.height))
            UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.25).setFill()
            for y in stride(from: CGFloat(0), through: phone.height, by: 100) {
                context.fill(CGRect(x: 0, y: y, width: phone.width * 2 + gap, height: 1))
            }
        }
    }
}
