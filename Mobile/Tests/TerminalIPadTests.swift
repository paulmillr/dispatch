import Foundation
import UIKit
import XCTest
@_spi(Test) import Term
@testable import DispatchMobile

/// The terminal's iPad rules (docs/ios.md, Terminal) on any simulator: the default font size per device class, the
/// key capsule's form with a hardware keyboard, where the software keyboard is, the shortcut bar, the Mac's Edit
/// actions and font sizes through the responder chain, extra hardware chords, the pointer (click and drag selection,
/// secondary click, wheel and trackpad scrolling), and wide grids.
@MainActor
final class TerminalIPadTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var controllers: [TerminalController] = []
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() async throws {
        for key in [TerminalController.fontSizeKey, TerminalController.keysShownKey] {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        for controller in controllers { controller.disappear() }
        controllers.removeAll()
        for (key, value) in savedDefaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func makeController(_ feed: ScriptedTerminalFeed, size: CGSize = CGSize(width: 820, height: 1000),
                                configuration: TerminalConfiguration = TerminalConfiguration()) async throws -> TerminalController {
        let controller = TerminalController(feed: feed, configuration: configuration)
        controllers.append(controller)
        windows.append(TerminalTestWindow.show(controller.hostView, size: size))
        controller.appear()
        try await TestSupport.eventually { !feed.record.attachments.isEmpty }
        return controller
    }

    private func sent(_ feed: ScriptedTerminalFeed, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic: "sent \(String(reflecting: String(decoding: feed.record.sent, as: UTF8.self)))") {
            String(decoding: feed.record.sent, as: UTF8.self) == expected
        }
    }

    // MARK: rules

    /// The phone keeps 12 points; an iPad starts at 13 (the Mac's 12.5 at a laptop's distance). A stored size, from
    /// a pinch or Settings, wins on either.
    func testDefaultFontSizeIsPerDeviceClass() {
        XCTAssertEqual(TerminalAdaptation.defaultFontSize(idiom: .phone), 12)
        XCTAssertEqual(TerminalAdaptation.defaultFontSize(idiom: .pad), 13)
        XCTAssertEqual(TerminalConfiguration().fontSize, 12, "the struct's own default stays the phone's")
        let device = TerminalAdaptation.defaultFontSize(idiom: UIDevice.current.userInterfaceIdiom)
        XCTAssertEqual(TerminalController.defaultFontSize, device)
        XCTAssertEqual(TerminalController.storedConfiguration().fontSize, device, "no stored size: the device's default")
        UserDefaults.standard.set(15.5, forKey: TerminalController.fontSizeKey)
        XCTAssertEqual(TerminalController.storedConfiguration().fontSize, 15.5, "a pinch's size is remembered")
        UserDefaults.standard.set(99, forKey: TerminalController.fontSizeKey)
        XCTAssertEqual(TerminalController.storedConfiguration().fontSize, device, "an out-of-range size is not used")
    }

    /// The capsule collapses only on an iPad with a hardware keyboard, and comes back when the user asks or the
    /// keyboard goes. The phone keeps its capsule.
    func testCapsuleFormRule() {
        XCTAssertEqual(TerminalAdaptation.capsuleForm(idiom: .pad, hardwareKeyboard: true, shown: false), .collapsed)
        XCTAssertEqual(TerminalAdaptation.capsuleForm(idiom: .pad, hardwareKeyboard: true, shown: true), .full)
        XCTAssertEqual(TerminalAdaptation.capsuleForm(idiom: .pad, hardwareKeyboard: false, shown: false), .full)
        XCTAssertEqual(TerminalAdaptation.capsuleForm(idiom: .phone, hardwareKeyboard: true, shown: false), .full)
        XCTAssertEqual(TerminalAdaptation.capsuleMaxWidth(idiom: .phone), .infinity)
        XCTAssertEqual(TerminalAdaptation.capsuleMaxWidth(idiom: .pad), 404)
    }

    /// Frames measured on an iPad Pro 11-inch simulator (portrait window 834 x 1210) and an iPhone 17.
    func testKeyboardPlacement() {
        let pad = CGRect(x: 0, y: 0, width: 834, height: 1210)
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 0, y: 870, width: 834, height: 340), window: pad), .docked)
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 257, y: 757.5, width: 320, height: 225.5), window: pad), .floating)
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 0, y: 1155, width: 834, height: 55), window: pad), .hidden,
                       "a hardware keyboard's shortcut bar has no keys")
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 220, y: 1130, width: 400, height: 60), window: pad), .hidden,
                       "nor does its floating minimised bar")
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 0, y: 1210, width: 834, height: 340), window: pad), .hidden, "off screen")
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: nil, window: pad), .hidden)
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: .zero, window: pad), .hidden)
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 0, y: 500, width: 834, height: 300), window: pad), .floating,
                       "a split keyboard: full width, lifted off the bottom")
        let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertEqual(TerminalAdaptation.keyboard(frame: CGRect(x: 0, y: 538, width: 402, height: 336), window: phone), .docked)
    }

    // MARK: the controller

    func testHardwareKeyboardCollapsesTheCapsuleOnAnIPad() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let controller = try await makeController(feed)
        controller.idiom = .pad
        controller.hardwareKeyboard = HardwareKeyboard(attached: true)
        XCTAssertEqual(controller.capsuleForm, .collapsed)
        XCTAssertTrue(controller.keysCanHide)
        // A latch made before the capsule collapsed modifies nothing while it is hidden.
        controller.hardwareKeyboard = HardwareKeyboard(attached: false)
        controller.tap(.ctrl)
        controller.hardwareKeyboard = HardwareKeyboard(attached: true)
        controller.hostView.insertText("c")
        try await sent(feed, "c")
        controller.showKeys()
        XCTAssertEqual(controller.capsuleForm, .full)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: TerminalController.keysShownKey), "remembered")
        controller.hideKeys()
        XCTAssertEqual(controller.capsuleForm, .collapsed)
        XCTAssertEqual(controller.capsule.ctrl, .off, "collapsing releases the latches")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: TerminalController.keysShownKey))
        controller.hardwareKeyboard = HardwareKeyboard(attached: false)
        XCTAssertEqual(controller.capsuleForm, .full, "the keyboard went: the capsule is back")
        XCTAssertFalse(controller.keysCanHide)
        controller.idiom = .phone
        controller.hardwareKeyboard = HardwareKeyboard(attached: true)
        XCTAssertEqual(controller.capsuleForm, .full, "the phone keeps its capsule")
    }

    /// The iPad keyboard's shortcut bar offers nothing (its Undo, Redo and Paste would cost the terminal rows).
    func testShortcutBarIsEmpty() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: Data()))
        XCTAssertTrue(controller.hostView.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(controller.hostView.inputAssistantItem.trailingBarButtonGroups.isEmpty)
    }

    // MARK: responder actions

    /// ⌘A then ⌘C copies the whole screen, as the Mac's Select All; Clear Screen empties it.
    func testSelectAllCopyAndClearScreen() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await makeController(feed).hostView
        try await TestSupport.eventually { view.visibleText().contains("invoices.ts") }
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.selectAll(_:)), withSender: nil))
        XCTAssertFalse(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        view.selectAll(nil)
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        view.copy(nil)
        let copied = try XCTUnwrap(UIPasteboard.general.string)
        XCTAssertTrue(copied.contains("pnpm dev") && copied.contains("invoices.ts"), copied)
        XCTAssertTrue(view.canPerformAction(#selector(TerminalHostView.clearScreen(_:)), withSender: nil))
        view.clearScreen(nil)
        try await TestSupport.eventually { !view.visibleText().contains("invoices.ts") }
        XCTAssertTrue(feed.record.sent.isEmpty, "Select All and Clear Screen send the program nothing")
    }

    /// ⌘+ and ⌘- step a point, within the zoom range, resize the grid and are remembered like a pinch; ⌘0 returns
    /// to the device's default.
    func testFontSizeActions() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let controller = try await makeController(feed)
        let view = controller.hostView
        let before = view.session.currentSize
        view.increaseSize(nil)
        XCTAssertEqual(view.configuration.fontSize, 13)
        XCTAssertEqual(UserDefaults.standard.double(forKey: TerminalController.fontSizeKey), 13)
        try await TestSupport.eventually { (feed.record.resizes.last?.columns ?? .max) < before.columns }
        view.decreaseSize(nil)
        view.decreaseSize(nil)
        XCTAssertEqual(view.configuration.fontSize, 11)
        view.setFontSize(28)
        XCTAssertFalse(view.canPerformAction(#selector(UIResponder.increaseSize(_:)), withSender: nil))
        view.increaseSize(nil)
        XCTAssertEqual(view.configuration.fontSize, 28, "the zoom range's top")
        view.resetFontSize(nil)
        XCTAssertEqual(view.configuration.fontSize, TerminalController.defaultFontSize)
    }

    // MARK: hardware keys

    /// Shift-Return and Ctrl-Alt-Shift arrows keep every modifier: Ghostty's encodings for a plain program (Shift-Return
    /// as `ESC [27;2;13~`, as the Mac's), CSI u for
    /// one that asked for the kitty keyboard protocol (an agent's TUI reading Shift-Return as a newline).
    func testShiftReturnAndThreeModifierArrows() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let view = try await makeController(feed).hostView
        let command = { (input: String, flags: UIKeyModifierFlags) in
            view.keyCommand(UIKeyCommand(input: input, modifierFlags: flags, action: #selector(TerminalHostView.keyCommand(_:))))
        }
        let commands = view.keyCommands ?? []
        XCTAssertTrue(commands.contains { $0.input == "\r" && $0.modifierFlags == .shift })
        XCTAssertTrue(commands.contains { $0.input == UIKeyCommand.inputUpArrow && $0.modifierFlags == [.shift, .control, .alternate] })
        XCTAssertTrue(commands.allSatisfy { $0.title.isEmpty && $0.discoverabilityTitle == nil },
                      "untitled: the ⌘-hold overlay lists none of the terminal's chords")
        XCTAssertFalse(commands.contains { $0.modifierFlags.contains(.command) }, "⌘ chords are the app's")
        command(UIKeyCommand.inputUpArrow, [.shift, .control, .alternate])
        command("\r", .shift)
        try await sent(feed, "\u{1B}[1;8A\u{1B}[27;2;13~")
        view.session.feed("\u{1B}[>1u")
        try await TestSupport.eventually { view.session.frameStats().bytesFed >= 5 }
        command("\r", .shift)
        try await sent(feed, "\u{1B}[1;8A\u{1B}[27;2;13~\u{1B}[13;2u")
    }

    /// Every hardware key has its command and the view lets UIKit fire it (`canPerformAction` refusing
    /// `keyCommand(_:)` once disabled them all): Esc, the navigation keys and F1 to F12 encode as the Mac's. These are
    /// the keys XCUITest's synthesizer cannot deliver on the simulator (`TerminalKeyboardUITests`).
    func testEveryHardwareKeyHasAnEnabledCommand() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let view = try await makeController(feed).hostView
        XCTAssertTrue(view.canPerformAction(#selector(TerminalHostView.keyCommand(_:)), withSender: nil))
        let commands = view.keyCommands ?? []
        let functions = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
                         UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12]
        let keys: [(String, String)] = [
            (UIKeyCommand.inputEscape, "\u{1B}"), (UIKeyCommand.inputHome, "\u{1B}[H"), (UIKeyCommand.inputEnd, "\u{1B}[F"),
            (UIKeyCommand.inputPageUp, "\u{1B}[5~"), (UIKeyCommand.inputPageDown, "\u{1B}[6~"), (UIKeyCommand.inputDelete, "\u{1B}[3~"),
        ] + zip(functions, ["\u{1B}OP", "\u{1B}OQ", "\u{1B}OR", "\u{1B}OS", "\u{1B}[15~", "\u{1B}[17~", "\u{1B}[18~", "\u{1B}[19~",
                            "\u{1B}[20~", "\u{1B}[21~", "\u{1B}[23~", "\u{1B}[24~"]).map { ($0, $1) }
        var expected = ""
        for (input, bytes) in keys {
            XCTAssertTrue(commands.contains { $0.input == input && $0.modifierFlags.isEmpty }, input)
            view.keyCommand(UIKeyCommand(input: input, modifierFlags: [], action: #selector(TerminalHostView.keyCommand(_:))))
            expected += bytes
        }
        try await sent(feed, expected)
    }

    /// Ctrl-Space never fires a key command (iPadOS switches input sources with it); its press is the terminal's.
    func testCtrlSpaceComesFromThePress() {
        XCTAssertEqual(TerminalHostView.reservedChord(.keyboardSpacebar, .control), TerminalInputKey.character(" ").with(.ctrl))
        XCTAssertEqual(TerminalHostView.reservedChord(.keyboardSpacebar, [.control, .shift])?.mods, [.ctrl, .shift])
        XCTAssertNil(TerminalHostView.reservedChord(.keyboardSpacebar, []), "a plain space is text")
        XCTAssertNil(TerminalHostView.reservedChord(.keyboardSpacebar, [.control, .command]), "⌘ chords are the app's")
        XCTAssertNil(TerminalHostView.reservedChord(.keyboardA, .control), "a key command takes it")
    }

    // MARK: pointer

    func testPointerRecognizers() async throws {
        let view = try await makeController(ScriptedTerminalFeed(output: Data())).hostView
        let recognizers = try XCTUnwrap(view.pointerRecognizers)
        XCTAssertEqual(recognizers.pan.allowedScrollTypesMask, .continuous, "a trackpad's two fingers scroll as a finger, with momentum")
        XCTAssertFalse(recognizers.pan.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)),
                       "a pointer drag selects instead of scrolling")
        XCTAssertEqual(recognizers.wheel.allowedScrollTypesMask, .discrete)
        XCTAssertTrue(recognizers.wheel.allowedTouchTypes.isEmpty, "the wheel recognizer takes scroll events only")
        XCTAssertEqual(recognizers.click.allowedTouchTypes, TerminalHostView.pointerTypes)
        XCTAssertEqual(recognizers.click.minimumPressDuration, 0)
        XCTAssertEqual(recognizers.secondary.buttonMaskRequired, .secondary)
        XCTAssertEqual(recognizers.secondary.allowedTouchTypes, TerminalHostView.pointerTypes)
        XCTAssertTrue(view.interactions.contains { $0 is UIPointerInteraction })
    }

    /// A pointer drag selects through the surface's mouse handling (no handles, nothing for the program); with
    /// mouse reporting on, the program gets the clicks instead.
    func testPointerDragSelectsAndReportsWhenAsked() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await makeController(feed).hostView
        try await TestSupport.eventually { view.visibleText().contains("localhost") }
        let from = view.rect(of: (x: 2, y: 2)), to = view.rect(of: (x: 30, y: 3))
        view.pointerPress(.began, at: CGPoint(x: from.midX, y: from.midY), mods: [])
        view.pointerPress(.changed, at: CGPoint(x: (from.midX + to.midX) / 2, y: to.midY), mods: [])
        view.pointerPress(.ended, at: CGPoint(x: to.midX, y: to.midY), mods: [])
        let selected = view.session.locked { view.session.surface.readSelection().map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(selected?.hasPrefix("vite v6.1.0"), true, selected ?? "no selection")
        XCTAssertTrue(view.startHandle.isHidden && view.endHandle.isHidden, "a pointer's selection has no handles")
        XCTAssertTrue(feed.record.sent.isEmpty)
        XCTAssertTrue(view.isFirstResponder)

        view.session.feed("\u{1B}[?1000h")
        try await TestSupport.eventually { view.session.locked { view.session.surface.touchMouseReporting } }
        view.pointerPress(.began, at: CGPoint(x: from.midX, y: from.midY), mods: [])
        view.pointerPress(.ended, at: CGPoint(x: from.midX, y: from.midY), mods: [])
        // X10 mouse reports: ESC [ M, the button + 32, column + 33, row + 33 (cell 2, 2).
        try await sent(feed, "\u{1B}[M ##\u{1B}[M###")
    }

    /// A secondary click selects the word under it (Ghostty's context-menu click) and offers Copy, Paste and
    /// Select All.
    func testSecondaryClickSelectsTheWordAndOffersTheEditMenu() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await makeController(feed).hostView
        try await TestSupport.eventually { view.visibleText().contains("localhost") }
        let cell = view.rect(of: (x: 4, y: 2))
        view.secondaryClick(at: CGPoint(x: cell.midX, y: cell.midY), mods: [])
        let selected = view.session.locked { view.session.surface.readSelection().map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(selected, "vite")
        let titles = view.pointerMenu().children.map(\.title)
        XCTAssertEqual(titles.first, "Copy")
        XCTAssertEqual(titles.last, "Select All")
        XCTAssertTrue(feed.record.sent.isEmpty)
    }

    // MARK: sizes

    /// A 13-inch iPad in landscape at a small font: a grid well past 200 columns, attached at that size.
    func testWideGrid() async throws {
        var configuration = TerminalConfiguration()
        configuration.fontSize = 7
        let feed = ScriptedTerminalFeed(output: Data((String(repeating: "x", count: 260) + "\r\nend").utf8))
        let controller = try await makeController(feed, size: CGSize(width: 1376, height: 1032), configuration: configuration)
        let size = try XCTUnwrap(feed.record.attachments.first)
        XCTAssertGreaterThanOrEqual(size.columns, 250)
        XCTAssertEqual(size, controller.hostView.session.currentSize)
        XCTAssertGreaterThan(size.rows, 80)
        try await TestSupport.eventually { controller.hostView.visibleText().contains("end") }
    }
}
