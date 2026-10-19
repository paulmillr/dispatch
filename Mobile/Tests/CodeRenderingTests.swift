import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// M5d and M5e drawn in a window the size of an iPhone 17: the palette and tints on screen, attached to the result
/// bundle (`xcrun xcresulttool export attachments`) for comparison with the mockups; and the composer's height in the
/// same update as a fence that opens or closes.
@MainActor
final class CodeRenderingTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func show<V: View>(_ view: V) -> UIWindow {
        let scene = TestSupport.windowScene()!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view.preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        self.window = window
        return window
    }

    private func snapshot(_ window: UIWindow, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    /// How many pixels (of every other row and column) are within `tolerance` of `color` (8-bit channels).
    private func count(_ color: UIColor, in image: UIImage, tolerance: Int = 6) -> Int {
        guard let cg = image.cgImage, cg.bitsPerPixel == 32, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            XCTFail("An 8-bit RGBA snapshot"); return 0
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // The palette is dynamic: these snapshots are dark.
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        // Translucent colours are compared over the black background.
        let target = [Int(r * a * 255), Int(g * a * 255), Int(b * a * 255)]
        let info = cg.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let bgra = info == CGBitmapInfo.byteOrder32Little.rawValue
        let (red, blue) = bgra ? (2, 0) : (0, 2)
        var found = 0
        for y in stride(from: 0, to: cg.height, by: 2) {
            for x in stride(from: 0, to: cg.width, by: 2) {
                let p = y * cg.bytesPerRow + x * 4
                if abs(Int(bytes[p + red]) - target[0]) <= tolerance, abs(Int(bytes[p + 1]) - target[1]) <= tolerance,
                   abs(Int(bytes[p + blue]) - target[2]) <= tolerance { found += 1 }
            }
        }
        return found
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    func testDiffDrawsTheMockupsPaletteAndTints() async throws {
        let window = show(NavigationStack { DiffView(model: CodeDemo.model()) })
        try await settle()
        let image = snapshot(window, name: "M5d")
        XCTAssertGreaterThan(count(CodePalette.addedRow, in: image, tolerance: 3), 500, "Added rows are tinted green")
        XCTAssertGreaterThan(count(CodePalette.removedRow, in: image, tolerance: 3), 250, "The removed row is tinted red")
        XCTAssertGreaterThan(count(CodePalette.hunkRow, in: image, tolerance: 3), 250, "The hunk header's band")
        for (name, color) in [("keywords", CodePalette.keyword), ("calls", CodePalette.call), ("strings", CodePalette.string),
                              ("types", CodePalette.type), ("numbers", CodePalette.number), ("comments", CodePalette.comment)] {
            XCTAssertGreaterThan(count(color, in: image, tolerance: 24), 5, "\(name) in their colour")
        }
    }

    func testTheWholeFileShowsTheFileWithTheHunksInIt() async throws {
        let model = CodeDemo.model(whole: true)
        let window = show(NavigationStack { DiffView(model: model) })
        try await TestSupport.eventually { if case .loaded? = model.states[model.changes.files[0].id] { true } else { false } }
        try await settle()
        let image = snapshot(window, name: "M5d whole file")
        XCTAssertGreaterThan(count(CodePalette.addedRow, in: image, tolerance: 3), 500)
        XCTAssertGreaterThan(count(CodePalette.comment, in: image, tolerance: 24), 5, "The file's own comments above the hunk")
    }

    func testComposerDrawsTheChipAndThePanel() async throws {
        struct Host: View {
            @State var text = CodeDemo.draft
            @FocusState var focused: Bool
            var body: some View {
                VStack { Spacer(); CodeComposer(text: $text, placeholder: "Message", working: false, focus: $focused, send: {}, stop: {}) }
                    .background(Color.black)
            }
        }
        let window = show(Host())
        try await settle()
        let image = snapshot(window, name: "M5e")
        XCTAssertGreaterThan(count(CodePalette.panel, in: image, tolerance: 1), 5_000, "The fenced block's mono panel")
        XCTAssertGreaterThan(count(CodePalette.call, in: image, tolerance: 24), 5, "The chip's code and the calls")
        XCTAssertGreaterThan(count(CodePalette.keyword, in: image, tolerance: 24), 5, "Keywords in the block")
        XCTAssertGreaterThan(count(CodePalette.number, in: image, tolerance: 24), 3, "Constants in the block")
        XCTAssertGreaterThan(count(UIColor(red: 0xe0 / 255, green: 0x7b / 255, blue: 0xe0 / 255, alpha: 1), in: image, tolerance: 3), 100,
                             "Send stays pink")
    }

    /// The field's height follows the text in the same update: when a fence opens or closes and the slot moves, the
    /// height is measured for the width the field is about to have, before anything is drawn.
    func testTheHeightIsMeasuredInTheSameUpdateAsTheText() {
        let scene = TestSupport.windowScene()!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        let view = CodeTextView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 36)
        window.rootViewController!.view.addSubview(view)
        let editor = CodeEditorModel()
        editor.view = view
        editor.pillWidth = 340
        var heights: [CGFloat] = []
        view.changed = { text in editor.measure(text: text); heights.append(editor.height) }
        XCTAssertTrue(view.becomeFirstResponder())
        for character in "Fix:\n``" { view.insertText(String(character)) }
        let prose = editor.height
        XCTAssertEqual(prose, view.fittingHeight(width: editor.fieldWidth(text: "Fix:\n``")), accuracy: 0.5)
        view.insertText("`")
        XCTAssertTrue(CodeComposer.stacked(view.textStorage.string))
        XCTAssertEqual(editor.height, view.fittingHeight(width: 340 - 20), accuracy: 0.5,
                       "Measured at the full width the stacked field gets, in the edit that opened the fence")
        XCTAssertEqual(heights.count, 8, "One measurement per keystroke, none deferred")
    }
}

/// Holds M5d or M5e full screen for `xcrun simctl io <device> screenshot` (TEST_RUNNER_DISPATCH_CODE_SHOT=M5d|M5d-file|M5e,
/// TEST_RUNNER_DISPATCH_CODE_SHOT_DIR for its ready and release files). Skipped otherwise.
@MainActor
final class CodeScreenshotTests: XCTestCase {
    func testShowForScreenshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let shot = environment["DISPATCH_CODE_SHOT"], let directory = environment["DISPATCH_CODE_SHOT_DIR"] else {
            throw XCTSkip("Screenshot harness: set TEST_RUNNER_DISPATCH_CODE_SHOT and TEST_RUNNER_DISPATCH_CODE_SHOT_DIR")
        }
        let scene = (await TestSupport.windowScene())!
        let window = UIWindow(windowScene: scene)
        var peer: ChatDemo.Peer?
        switch shot {
        case "M5e":
            let (conversations, demo) = ChatDemo.conversations(screen: "M4a")
            peer = demo
            let session = conversations.session(for: ChatConversationKey(host: ChatDemo.host, node: "tmux:s:$0:%0"))
            try await TestSupport.eventually { !session.transcript.isEmpty }
            session.drafts.edit(text: CodeDemo.draft)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                VStack(spacing: 0) {
                    ChatDemoHeader(session: session, needsYou: 1)
                    ChatThreadView(session: session, space: "app", directory: "/Users/paul/src/app", focusOnAppear: true)
                }
                .toolbar(.hidden, for: .navigationBar)
            }.preferredColorScheme(.dark))
        default:
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                DiffView(model: CodeDemo.model(whole: shot == "M5d-file"))
            }.preferredColorScheme(.dark))
        }
        window.makeKeyAndVisible()
        defer { window.isHidden = true; _ = peer }
        try await Task.sleep(for: .seconds(1))
        let ready = URL(fileURLWithPath: directory).appendingPathComponent("ready")
        let release = URL(fileURLWithPath: directory).appendingPathComponent("release")
        try? FileManager.default.removeItem(at: release)
        try Data(shot.utf8).write(to: ready)
        let deadline = Date().addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: release.path), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try? FileManager.default.removeItem(at: ready)
    }
}
