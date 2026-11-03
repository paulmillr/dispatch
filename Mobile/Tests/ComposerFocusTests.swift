import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The composer's field gives focus up for good: when UIKit ends its editing (the thread's interactive keyboard
/// dismissal, a drag onto the composer, `endEditing`), the field does not take it back while SwiftUI catches up with its
/// focus. Before, an update that still carried the old "focused" read as a new request and the keyboard came back up.
@MainActor
final class ComposerFocusTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    /// Asks the host for focus, as the slash list's row and a completed command do (`focused = true`).
    @Observable final class Request { var count = 0 }

    private struct Host: View {
        let request: Request
        @State var text = "Typed"
        @FocusState var focused: Bool
        var body: some View {
            VStack {
                Spacer()
                CodeComposer(text: $text, placeholder: "Message", working: false, focus: $focused, send: {}, steer: nil, stop: {})
            }
            .onChange(of: request.count) { _, _ in focused = true }
        }
    }

    private static func field(in view: UIView) -> CodeTextView? {
        if let field = view as? CodeTextView { return field }
        for child in view.subviews { if let field = field(in: child) { return field } }
        return nil
    }

    private func show(_ request: Request = Request()) async throws -> (UIWindow, CodeTextView) {
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(request: request))
        window.makeKeyAndVisible()
        self.window = window
        var field: CodeTextView?
        try await TestSupport.eventually { field = Self.field(in: window); return field != nil }
        return (window, try XCTUnwrap(field))
    }

    func testEndingEditingKeepsTheKeyboardDown() async throws {
        let (window, text) = try await show()
        for _ in 0..<3 {
            XCTAssertTrue(text.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(text.isFirstResponder)
            window.endEditing(true)
            // Long enough for SwiftUI's updates after the focus change and the field's deferred focus requests.
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertFalse(text.isFirstResponder, "the field took focus back")
            }
        }
    }
}

extension ComposerFocusTests {
    /// After the keyboard was dragged down, a request for focus (the slash list's row, a completed command) brings it up
    /// again, each time.
    func testARequestAfterADismissalFocusesTheField() async throws {
        let request = Request()
        let (window, text) = try await show(request)
        for _ in 0..<3 {
            XCTAssertTrue(text.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(300))
            window.endEditing(true)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertFalse(text.isFirstResponder)
            request.count += 1
            try await TestSupport.eventually(diagnostic: "the request focused the field") { text.isFirstResponder }
        }
    }
}

/// The drag that takes the keyboard down (`ChatKeyboardDragDismissal`): downward, past the thread's visible bottom edge.
final class ChatKeyboardDragDismissalTests: XCTestCase {
    func testOnlyADownwardDragPastTheThreadsBottomEdgeDismisses() {
        XCTAssertTrue(ChatKeyboardDragDismissal.crosses(location: CGPoint(x: 100, y: 510), translation: CGPoint(x: 0, y: 200), bottom: 509))
        XCTAssertFalse(ChatKeyboardDragDismissal.crosses(location: CGPoint(x: 100, y: 500), translation: CGPoint(x: 0, y: 200), bottom: 509),
                       "still over the thread")
        XCTAssertFalse(ChatKeyboardDragDismissal.crosses(location: CGPoint(x: 100, y: 520), translation: CGPoint(x: 0, y: -40), bottom: 509),
                       "a drag up from the composer reads on")
    }

    /// Only a software keyboard: an iPad's hardware keyboard (its shortcuts bar at most) keeps the field's focus.
    func testOnlyASoftwareKeyboardIsTakenDown() {
        XCTAssertTrue(ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: 336, hardwareKeyboard: false))
        XCTAssertTrue(ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: 336, hardwareKeyboard: true),
                      "shown on screen anyway")
        XCTAssertFalse(ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: 55, hardwareKeyboard: true), "the shortcuts bar")
        XCTAssertFalse(ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: 0, hardwareKeyboard: false), "none shows")
        XCTAssertFalse(ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: nil, hardwareKeyboard: true))
        XCTAssertTrue(ChatKeyboardDragDismissal.softwareKeyboard(visibleHeight: nil, hardwareKeyboard: false))
    }
}
