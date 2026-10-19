import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The screens the app's demo launches do not reach on their own, in light and dark: the diff viewer (M5d), the code
/// composer (M5e) and the terminal (M6a), drawn in an iPhone 17 sized window and attached to the result bundle
/// (`<screen>-<scheme>`). The terminal keeps its own dark theme in light; its capsule follows the terminal.
@MainActor
final class AppearanceScreenshotTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func shoot(_ name: String, _ view: some View, settle: Duration = .milliseconds(600)) async throws {
        for (scheme, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let found = await TestSupport.windowScene()
            let scene = try XCTUnwrap(found)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView: view.background(Color.canvas))
            window.makeKeyAndVisible()
            self.window = window
            try await Task.sleep(for: settle)
            let format = UIGraphicsImageRendererFormat.preferred()
            format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name)-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    func testCodeScreens() async throws {
        try await shoot("M5d", NavigationStack { DiffView(model: CodeDemo.model()) })
        struct Composer: View {
            @State var text = CodeDemo.draft
            @FocusState var focused: Bool
            var body: some View {
                VStack { Spacer(); CodeComposer(text: $text, placeholder: "Message", working: false, focus: $focused, send: {}, stop: {}) }
            }
        }
        try await shoot("M5e", Composer())
    }

    func testTerminal() async throws {
        let output = Data(String(repeating: "\r\n", count: 60).utf8) + TerminalFixtures.viteDev
        try await shoot("M6a", TerminalSegmentView(feed: ScriptedTerminalFeed(output: output)), settle: .seconds(1))
    }
}
