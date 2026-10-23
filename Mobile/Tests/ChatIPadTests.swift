import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Chat and Code on an iPad: the composer's hardware keys (the Mac composer's rules), focus when a tab opens in the
/// split's detail column, and the readable measure at wide widths. Pure rules, and the editor's handling of the key
/// commands in a key window; the keys themselves, sent as hardware events, are `ChatIPadUITests`.
@MainActor
final class ChatIPadTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private typealias Keys = ComposerHardwareKeys

    // MARK: Keys

    func testReturnSendsAndShiftReturnStartsALineAsOnTheMac() {
        XCTAssertEqual(Keys.action(.returnKey, modifiers: [], multiline: false, working: false), .send)
        XCTAssertEqual(Keys.action(.returnKey, modifiers: [], multiline: false, working: true), .send,
                       "while the agent works it queues, as the Mac's Return does (send routes it)")
        XCTAssertEqual(Keys.action(.returnKey, modifiers: .shift, multiline: false, working: false), .newline)
        XCTAssertEqual(Keys.action(.returnKey, modifiers: .shift, multiline: true, working: false), .newline)
    }

    func testInEditorModeReturnInsertsANewlineAndCommandReturnSends() {
        XCTAssertEqual(Keys.action(.returnKey, modifiers: [], multiline: true, working: false), .newline)
        for modifiers: UIKeyModifierFlags in [.command, .control] {
            XCTAssertEqual(Keys.action(.returnKey, modifiers: modifiers, multiline: true, working: false), .send)
            XCTAssertEqual(Keys.action(.returnKey, modifiers: modifiers, multiline: false, working: false), .send)
        }
        XCTAssertEqual(Keys.action(.returnKey, modifiers: .alternate, multiline: false, working: true), .steer)
        XCTAssertEqual(Keys.action(.returnKey, modifiers: .alternate, multiline: true, working: true), .steer)
        XCTAssertEqual(Keys.action(.returnKey, modifiers: [.command, .shift], multiline: false, working: false), .system)
    }

    func testEscapeLeavesEditorModeThenStopsThenLeavesTheField() {
        XCTAssertEqual(Keys.action(.escape, modifiers: [], multiline: true, working: true), .leaveEditor,
                       "editor mode first, as the Mac's Esc, so a running turn is not stopped by leaving it")
        XCTAssertEqual(Keys.action(.escape, modifiers: [], multiline: false, working: true), .stop)
        XCTAssertEqual(Keys.action(.escape, modifiers: [], multiline: false, working: false), .resign)
        XCTAssertEqual(Keys.action(.escape, modifiers: .command, multiline: false, working: true), .system)
    }

    func testCommandETogglesEditorMode() {
        XCTAssertEqual(Keys.action(.e, modifiers: .command, multiline: false, working: false), .toggleEditor)
        XCTAssertEqual(Keys.action(.e, modifiers: .command, multiline: true, working: true), .toggleEditor)
        XCTAssertEqual(Keys.action(.e, modifiers: [.command, .shift], multiline: false, working: false), .system)
    }

    func testAnOpenCompositionKeepsReturnAndEscape() {
        for key: Keys.Key in [.returnKey, .escape, .e] {
            for modifiers: UIKeyModifierFlags in [[], .shift, .command, .alternate] {
                XCTAssertEqual(Keys.action(key, modifiers: modifiers, multiline: false, working: true, composing: true), .system)
            }
        }
    }

    func testOnlyTheDiscoverableCommandsHaveTitles() {
        let commands = Keys.commands(action: #selector(CodeTextView.hardwareKey(_:)))
        let titled = commands.filter { !$0.title.isEmpty }.map { "\($0.title) \($0.modifierFlags.rawValue)" }
        XCTAssertEqual(titled, ["Send \(UIKeyModifierFlags.command.rawValue)",
                                "Send into Running Turn \(UIKeyModifierFlags.alternate.rawValue)",
                                "Editor Mode \(UIKeyModifierFlags.command.rawValue)"])
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior), "the text view's own Return never wins")
        XCTAssertTrue(commands.allSatisfy { Keys.key($0) != nil })
    }

    /// An editor 300 points wide in a key window, first responder, its key state and actions recorded.
    private func editor(_ text: String = "", multiline: Bool = false, working: Bool = false) -> (CodeTextView, Recorder) {
        let scene = TestSupport.windowScene()!
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        let view = CodeTextView()
        view.frame = CGRect(x: 0, y: 100, width: 300, height: 40)
        host.view.addSubview(view)
        view.setDraft(text)
        XCTAssertTrue(view.becomeFirstResponder())
        let recorder = Recorder(multiline: multiline, working: working)
        view.keyState = { (recorder.multiline, recorder.working) }
        view.keyAction = { recorder.actions.append($0) }
        return (view, recorder)
    }

    private final class Recorder {
        var multiline: Bool
        var working: Bool
        var actions: [ComposerKeyAction] = []
        init(multiline: Bool, working: Bool) { self.multiline = multiline; self.working = working }
    }

    private func command(_ input: String, _ modifiers: UIKeyModifierFlags, in view: CodeTextView) -> UIKeyCommand {
        view.keyCommands!.first { $0.input == input && $0.modifierFlags == modifiers }!
    }

    func testTheEditorCarriesOutTheKeys() {
        let (view, recorder) = editor("Hello")
        view.hardwareKey(command("\r", [], in: view))
        XCTAssertEqual(recorder.actions, [.send])
        XCTAssertEqual(view.textStorage.string, "Hello", "Return sent instead of starting a line")

        view.hardwareKey(command("\r", .shift, in: view))
        XCTAssertEqual(view.textStorage.string, "Hello\n", "Shift-Return starts a line in the field itself")
        recorder.multiline = true
        view.hardwareKey(command("\r", [], in: view))
        XCTAssertEqual(view.textStorage.string, "Hello\n\n", "in editor mode Return starts a line")
        view.hardwareKey(command("\r", .command, in: view))
        view.hardwareKey(command("e", .command, in: view))
        view.hardwareKey(command(UIKeyCommand.inputEscape, [], in: view))
        XCTAssertEqual(recorder.actions, [.send, .send, .toggleEditor, .leaveEditor])

        recorder.multiline = false
        recorder.working = true
        view.hardwareKey(command(UIKeyCommand.inputEscape, [], in: view))
        view.hardwareKey(command("\r", .alternate, in: view))
        XCTAssertEqual(recorder.actions.suffix(2), [.stop, .steer])
        XCTAssertTrue(view.isFirstResponder)

        recorder.working = false
        view.hardwareKey(command(UIKeyCommand.inputEscape, [], in: view))
        XCTAssertFalse(view.isFirstResponder, "Esc with nothing to leave or stop leaves the field")
        XCTAssertEqual(recorder.actions.count, 6, "and is the field's own")
    }

    func testANewlineFromTheKeysIsOneUndoableEditThatReachesTheDraft() {
        let (view, _) = editor("a")
        var drafts: [String] = []
        view.changed = { drafts.append($0) }
        view.perform(.newline)
        XCTAssertEqual(drafts.last, "a\n")
        view.undoManager?.undo()
        XCTAssertEqual(view.textStorage.string, "a")
    }

    func testTheEditorDeclinesKeysAnOpenCompositionOwns() {
        let (view, recorder) = editor("")
        let send = command("\r", [], in: view)
        XCTAssertTrue(view.canPerformAction(#selector(CodeTextView.hardwareKey(_:)), withSender: send))
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertFalse(view.canPerformAction(#selector(CodeTextView.hardwareKey(_:)), withSender: send),
                       "Return commits the input method's composition instead of sending")
        XCTAssertFalse(view.canPerformAction(#selector(CodeTextView.hardwareKey(_:)),
                                             withSender: command(UIKeyCommand.inputEscape, [], in: view)))
        view.hardwareKey(send)
        XCTAssertEqual(recorder.actions, [])
        view.unmarkText()
        XCTAssertTrue(view.canPerformAction(#selector(CodeTextView.hardwareKey(_:)), withSender: send))
    }

    func testWithoutAComposerTheEditorStillSendsOnReturn() {
        let (view, _) = editor("Hi")
        view.keyAction = nil
        var sent = 0
        view.submit = { sent += 1 }
        view.hardwareKey(command("\r", .command, in: view))
        XCTAssertEqual(sent, 1)
    }

    func testTheKeyRowAndEditorHintFollowTheKeyboard() {
        XCTAssertTrue(CodeComposer.showsKeyRow(editing: true, hardwareKeyboard: false))
        XCTAssertFalse(CodeComposer.showsKeyRow(editing: true, hardwareKeyboard: true), "the keyboard has its keys")
        XCTAssertFalse(CodeComposer.showsKeyRow(editing: false, hardwareKeyboard: false))
        XCTAssertTrue(CodeComposer.showsEditorHint(multiline: true, hardwareKeyboard: true))
        XCTAssertFalse(CodeComposer.showsEditorHint(multiline: true, hardwareKeyboard: false),
                       "a touch composer's Return always starts a line: nothing to say")
        XCTAssertFalse(CodeComposer.showsEditorHint(multiline: false, hardwareKeyboard: true))
    }

    /// The composer's Debug pin: `HardwareKeyboard(attached:)` is what tests and `-DispatchHardwareKeyboard` fix.
    func testAPinnedKeyboardStaysPinned() {
        XCTAssertTrue(HardwareKeyboard(attached: true).attached)
        XCTAssertFalse(HardwareKeyboard(attached: false).attached)
    }

    // MARK: Focus

    func testTheComposerTakesFocusInTheDetailColumnOnlyWithAHardwareKeyboard() {
        XCTAssertTrue(ChatThreadView.focusesOnAppear(requested: false, splitDetail: true, hardwareKeyboard: true))
        XCTAssertFalse(ChatThreadView.focusesOnAppear(requested: false, splitDetail: true, hardwareKeyboard: false),
                       "no software keyboard pops up unasked on a touch iPad")
        XCTAssertFalse(ChatThreadView.focusesOnAppear(requested: false, splitDetail: false, hardwareKeyboard: true),
                       "a stack (a phone, Slide Over) keeps the phone's behaviour")
        XCTAssertTrue(ChatThreadView.focusesOnAppear(requested: true, splitDetail: false, hardwareKeyboard: false),
                      "a new chat still asks")
    }

    // MARK: Measure

    func testTheMeasureIsTheMacsEightyCharacters() {
        let font = UIFont.preferredFont(forTextStyle: .callout,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(ChatMeasure.standard, (80 * zero + 28).rounded())
        XCTAssertTrue((700...900).contains(ChatMeasure.standard), "\(ChatMeasure.standard)")
    }

    func testPhoneColumnsKeepTheirShares() {
        let measure = ChatMeasure.standard
        // Every iPhone's column (the screen less 32), the Duo's 405-point tab column, an iPad mini's half.
        for column: CGFloat in [343, 370, 408, 373, 500] {
            XCTAssertEqual(ChatMeasure.bubble(user: true, column: column, measure: measure), column * 0.78)
            XCTAssertEqual(ChatMeasure.bubble(user: false, column: column, measure: measure), column * 0.86)
            XCTAssertEqual(ChatMeasure.queueCard(column: column, measure: measure), column * 0.92)
        }
    }

    func testWideColumnsStopAtTheMeasure() {
        let measure = ChatMeasure.standard
        // A 13-inch iPad's detail column in landscape, and a full-width thread.
        for column: CGFloat in [1000, 1344] {
            XCTAssertEqual(ChatMeasure.bubble(user: false, column: column, measure: measure), measure)
            XCTAssertEqual(ChatMeasure.queueCard(column: column, measure: measure), measure)
        }
        XCTAssertEqual(ChatMeasure.bubble(user: true, column: 1344, measure: measure), measure)
        XCTAssertEqual(ChatMeasure.bubble(user: true, column: 1000, measure: 780), 780, "the user's share until it reaches it")
        XCTAssertEqual(ChatMeasure.bubble(user: false, column: 1000, measure: 1200), 860, "a larger text size widens it")
    }

    /// A long agent message in a wide thread: the bubble stops at the measure, on the agent's side.
    func testAWideThreadsBubbleStopsAtTheMeasure() {
        let text = String(repeating: "Stripe retries the same event with a new attempt counter. ", count: 8)
        let size = UIHostingController(rootView: ChatBubble(side: .agent) { Text(text) }
            .environment(\.chatColumnWidth, 1000)
            .environment(\.chatMeasure, ChatMeasure.standard)
            .fixedSize(horizontal: true, vertical: false))
            .sizeThatFits(in: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertLessThanOrEqual(size.width, ChatMeasure.standard + 0.5)
        XCTAssertGreaterThan(size.width, ChatMeasure.standard - 30, "a long message fills the measure")
    }

    // MARK: Agents

    func testANarrowSidebarsAgentsRowKeepsTheNameWhole() {
        let wide = AgentsScreen.rowText(host: "mba2", muted: false, preview: "Fitted the easing", narrow: false)
        XCTAssertEqual(wide.detail, "mba2")
        XCTAssertEqual(wide.subtitle, "Fitted the easing")
        let narrow = AgentsScreen.rowText(host: "mba2", muted: false, preview: "Fitted the easing", narrow: true)
        XCTAssertNil(narrow.detail, "nothing beside the name at 263 points")
        XCTAssertEqual(narrow.subtitle, "mba2 · Fitted the easing")
        XCTAssertEqual(AgentsScreen.rowText(host: "mba2", muted: true, preview: nil, narrow: true).detail, "muted")
        XCTAssertEqual(AgentsScreen.rowText(host: "mba2", muted: true, preview: nil, narrow: true).subtitle, "mba2")
        XCTAssertEqual(AgentsScreen.rowText(host: "mba2", muted: true, preview: nil, narrow: false).detail, "mba2 · muted")
    }
}
