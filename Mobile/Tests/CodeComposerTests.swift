import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import DispatchMobile

/// M5e: the composer's Markdown (chips, fences, language tags), its keys and "Paste as code", its growth, and the
/// styling that happens in place, in the same editing pass as each keystroke.
@MainActor
final class CodeComposerTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    /// An editor 300 points wide in a key window, first responder (undo and input traits need one).
    private func editor(_ text: String = "") -> CodeTextView {
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
        return view
    }

    private func type(_ text: String, into view: CodeTextView) {
        for character in text { view.insertText(String(character)) }
    }

    private func font(_ view: CodeTextView, at location: Int) -> UIFont? {
        view.textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont
    }

    private func color(_ view: CodeTextView, at location: Int) -> UIColor? {
        view.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor
    }

    func testInlineChipsFormOnClosedBackticksOutsideFences() {
        let text = "Use `redis.set` with ``a`b`` and `open\n```ts\nlet `x` = 1\n```\nthen `y`"
        let markdown = ComposerMarkdown(text)
        let source = text as NSString
        XCTAssertEqual(markdown.chips.map { source.substring(with: $0.code) }, ["redis.set", "a`b", "y"],
                       "Double backticks hold a single one; an unclosed backtick is literal; none inside a fence")
        XCTAssertEqual(markdown.chips.map(\.ticks), [1, 2, 1])
        XCTAssertEqual(source.substring(with: markdown.chips[0].range), "`redis.set`")
        XCTAssertTrue(ComposerMarkdown("``").chips.isEmpty, "An empty span is no chip")
        XCTAssertTrue(ComposerMarkdown("a `b\nc` d").chips.isEmpty, "Spans stay on their line")
    }

    func testFencesCarryTheirLanguageTagAndMayBeOpen() {
        let text = "Look:\n```ts\nconst a = 1\n```\nand\n~~~ python\nx = 1"
        let markdown = ComposerMarkdown(text)
        XCTAssertEqual(markdown.fences.map(\.language), ["ts", "python"])
        XCTAssertNotNil(markdown.fences[0].closing)
        XCTAssertNil(markdown.fences[1].closing, "An unclosed fence runs to the end, so it renders while typed")
        XCTAssertEqual(ComposerMarkdown("```\nx").fences.first?.language, "text")
        let source = text as NSString
        XCTAssertEqual(source.substring(with: markdown.fences[0].body), "const a = 1\n")
    }

    func testCodeContextsTurnAutocorrectionOff() {
        let text = "Use `redis.set` and `ope\n```ts\nlet a\n```\nprose"
        let markdown = ComposerMarkdown(text)
        let source = text as NSString
        XCTAssertFalse(markdown.isCode(at: 2, in: text), "Prose")
        XCTAssertTrue(markdown.isCode(at: source.range(of: "redis").location + 2, in: text), "Inside a chip")
        XCTAssertFalse(markdown.isCode(at: NSMaxRange(source.range(of: "redis.set`")), in: text), "After a chip")
        XCTAssertTrue(markdown.isCode(at: NSMaxRange(source.range(of: "`ope")), in: text), "After an open backtick")
        XCTAssertTrue(markdown.isCode(at: source.range(of: "let a").location, in: text), "In a fence")
        XCTAssertFalse(markdown.isCode(at: source.length, in: text), "After the fence")
    }

    func testKeysWrapTheSelectionAndPlaceTheCaret() {
        let edit = ComposerKey.backtick.edit("use redis.set now", selection: NSRange(location: 4, length: 9))
        XCTAssertEqual(edit.text, "`redis.set`")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 9))
        XCTAssertEqual(ComposerKey.backtick.edit("a", selection: NSRange(location: 1, length: 0)).text, "`")
        let braces = ComposerKey.braces.edit("f", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(braces.text, "{}")
        XCTAssertEqual(braces.selection, NSRange(location: 2, length: 0), "The caret between the pair")
        XCTAssertEqual(ComposerKey.parentheses.edit("", selection: NSRange(location: 0, length: 0)).text, "()")
        XCTAssertEqual(ComposerKey.arrow.edit("", selection: NSRange(location: 0, length: 0)).text, "=>")
        XCTAssertEqual(ComposerKey.tab.edit("", selection: NSRange(location: 0, length: 0)).text, "    ")
        // The fence opens on lines of its own with the caret on the empty body line.
        let fence = ComposerKey.fence.edit("Try this:", selection: NSRange(location: 9, length: 0))
        XCTAssertEqual(fence.text, "\n```\n\n```")
        XCTAssertEqual(fence.selection, NSRange(location: 9 + 5, length: 0))
        let around = ComposerKey.fence.edit("a\nlet x\nb", selection: NSRange(location: 2, length: 6))
        XCTAssertEqual(around.text, "```\nlet x\n```\n")
        XCTAssertEqual(around.selection, NSRange(location: 6, length: 5), "The selection stays selected inside the block")
        XCTAssertEqual(ComposerKey.allCases.map(\.label), ["`", "```", "{ }", "( )", "=>", "tab"], "The mockup's key row")
    }

    func testPasteAsCodeFencesThePasteOnItsOwnLines() {
        XCTAssertTrue(ComposerMarkdown.offersCode("let a = 1\nlet b = 2\n"))
        XCTAssertFalse(ComposerMarkdown.offersCode("one line\n"), "One line is pasted as it is")
        let text = "See let a = 1\nlet b = 2\n now"
        let range = NSRange(location: 4, length: 20)
        let edit = ComposerMarkdown.fenced("let a = 1\nlet b = 2\n", replacing: range, in: text)
        XCTAssertEqual(edit.text, "\n```\nlet a = 1\nlet b = 2\n```\n")
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        XCTAssertEqual(result, "See \n```\nlet a = 1\nlet b = 2\n```\n now")
        XCTAssertEqual(ComposerMarkdown(result).fences.count, 1)
        XCTAssertEqual(ComposerMarkdown(result).fences.first?.closing != nil, true)
    }

    /// Lets the run loop end the undo manager's group for the current event, as between two touches.
    private func nextEvent() async throws { try await Task.sleep(for: .milliseconds(50)) }

    func testPasteAsCodeIsOneUndoableStep() async throws {
        let view = editor("See ")
        view.selectedRange = NSRange(location: 4, length: 0)
        view.insertText("a()\nb()")
        try await nextEvent()
        let pasted = NSRange(location: 4, length: 7)
        view.fence(pasted)
        try await nextEvent()
        XCTAssertEqual(view.textStorage.string, "See \n```\na()\nb()\n```")
        XCTAssertEqual(view.markdown.fences.count, 1)
        let undo = try XCTUnwrap(view.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.textStorage.string, "See a()\nb()", "Undo restores the paste as it was")
        XCTAssertTrue(view.markdown.fences.isEmpty, "And its styling")
    }

    func testAChipFormsInTheSameEditAsItsClosingBacktick() {
        let view = editor()
        type("Use `redis.set", into: view)
        let open = view.styled
        XCTAssertTrue(view.markdown.chips.isEmpty)
        XCTAssertEqual(color(view, at: 4), UIColor.label, "An open backtick is visible text")
        XCTAssertTrue(view.inCode, "Typing after an open backtick is code: no autocorrection")
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.smartQuotesType, .no)
        view.insertText("`")
        // Nothing ran in between: the storage is styled when insertText returns.
        XCTAssertEqual(view.styled, open + 1, "One styling pass per keystroke")
        XCTAssertEqual(view.markdown.chips.count, 1)
        XCTAssertEqual(color(view, at: 4), UIColor.clear, "The backticks become the chip's padding")
        XCTAssertEqual(color(view, at: 14), UIColor.clear)
        XCTAssertEqual(font(view, at: 5)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), true)
        XCTAssertEqual(color(view, at: 5), CodePalette.call)
        XCTAssertEqual(view.selectedRange, NSRange(location: 15, length: 0), "The caret stays after the chip")
        XCTAssertFalse(view.inCode, "After the chip it is prose again")
        XCTAssertEqual(view.autocorrectionType, .default)
        type(" with", into: view)
        XCTAssertEqual(color(view, at: 16), UIColor.label)
        XCTAssertEqual(view.textStorage.string, "Use `redis.set` with", "The draft stays plain Markdown")
        let selection = view.selectedRange
        view.updateCaretContext()
        XCTAssertEqual(view.selectedRange, selection)
    }

    func testAFenceClosesInTheSameEditAsItsLastBacktick() {
        let view = editor()
        type("Fix:\n```ts\nconst ok = 1\n``", into: view)
        XCTAssertEqual(view.markdown.fences.count, 1)
        XCTAssertNil(view.markdown.fences[0].closing, "Two backticks are code in the open block")
        let source = view.textStorage.string as NSString
        let constant = source.range(of: "const").location
        XCTAssertEqual(color(view, at: constant), CodePalette.keyword, "Live colours while the block is open")
        XCTAssertEqual(font(view, at: constant)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), true)
        XCTAssertEqual(font(view, at: source.range(of: "ts").location)?.pointSize, CodeComposerStyle().tag.pointSize, "The tag in the header")
        XCTAssertEqual(color(view, at: source.range(of: "```").location), UIColor.clear, "The opening backticks take no room")
        XCTAssertTrue(view.inCode)
        let passes = view.styled
        view.insertText("`")
        XCTAssertEqual(view.styled, passes + 1)
        let fence = view.markdown.fences[0]
        XCTAssertNotNil(fence.closing, "Closed by the third backtick")
        let closing = fence.closing!.location
        XCTAssertEqual(color(view, at: closing), UIColor.clear, "The closing line is the panel's bottom padding at once")
        let style = view.textStorage.attribute(.paragraphStyle, at: closing, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.maximumLineHeight, CodeComposerStyle().padding)
        XCTAssertEqual(color(view, at: constant), CodePalette.keyword, "The body keeps its colours")
        view.insertText("\n")
        type("ok", into: view)
        XCTAssertFalse(view.inCode, "After the block, prose")
        XCTAssertEqual(color(view, at: view.textStorage.length - 1), UIColor.label)
    }

    func testRestylingKeepsSelectionAndUndo() async throws {
        let view = editor("Use ")
        view.selectedRange = NSRange(location: 4, length: 0)
        view.press(.fence)
        try await nextEvent()
        XCTAssertEqual(view.textStorage.string, "Use \n```\n\n```")
        XCTAssertEqual(view.selectedRange, NSRange(location: 9, length: 0), "On the empty body line")
        XCTAssertTrue(view.inCode)
        let typing = view.typingAttributes[.font] as? UIFont
        XCTAssertEqual(typing?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), true, "Typed code is mono at once")
        type("let x", into: view)
        try await nextEvent()
        XCTAssertEqual(view.selectedRange, NSRange(location: 14, length: 0))
        view.selectedRange = NSRange(location: 9, length: 3)
        view.restyleIfNeeded()
        view.updateCaretContext()
        XCTAssertEqual(view.selectedRange, NSRange(location: 9, length: 3), "Styling never moves the selection")
        let undo = try XCTUnwrap(view.undoManager)
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(view.textStorage.string, "Use ", "Undo walks back through the key and the typing")
        XCTAssertTrue(view.markdown.fences.isEmpty)
        undo.redo()
        XCTAssertEqual(view.textStorage.string, "Use \n```\n\n```")
        XCTAssertEqual(view.markdown.fences.count, 1)
    }

    func testTheFieldGrowsWithTheDraftUpToItsBound() {
        let view = editor()
        let one = view.fittingHeight(width: 300)
        XCTAssertEqual(one, 36, accuracy: 0.5, "One prose line: 22 pt and the insets, the stock composer's height")
        view.setDraft("one\ntwo\nthree")
        let three = view.fittingHeight(width: 300)
        XCTAssertEqual(three, 36 + 44, accuracy: 1)
        view.setDraft("Use `redis.set` with NX:\n```ts\nconst ok = await redis.set(key, 1, {\n  NX: true,\n});\nreturn ok;")
        let code = view.fittingHeight(width: 300)
        XCTAssertEqual(code, ceil(view.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height), accuracy: 1,
                       "The measure agrees with the text view's own at its width")
        XCTAssertGreaterThan(view.fittingHeight(width: 200), code, "and measures other widths without laying the view out")
        XCTAssertEqual(view.frame.width, 300)
        XCTAssertGreaterThan(code, three)
        XCTAssertLessThanOrEqual(code, CodeTextView.maximumHeight)
        view.setDraft(String(repeating: "line\n", count: 40))
        XCTAssertEqual(view.fittingHeight(width: 300), CodeTextView.maximumHeight, "Bounded: it scrolls beyond")
        view.frame.size.height = CodeTextView.maximumHeight
        view.layoutIfNeeded()
        XCTAssertTrue(view.isScrollEnabled)
        view.setDraft("")
        XCTAssertEqual(view.fittingHeight(width: 300), 36, accuracy: 0.5)
        view.frame.size.height = 36
        view.layoutIfNeeded()
        XCTAssertFalse(view.isScrollEnabled)
        XCTAssertFalse(view.placeholderLabel.isHidden, "The placeholder shows on an empty draft")
        view.insertText("a")
        XCTAssertTrue(view.placeholderLabel.isHidden, "and hides with the first character, in the same edit")
    }

    func testTheSlotMovesUnderTheTextOnlyWithAFence() {
        XCTAssertFalse(CodeComposer.stacked("one line"))
        XCTAssertFalse(CodeComposer.stacked("two\nlines with `code`"))
        XCTAssertTrue(CodeComposer.stacked("```ts\nlet a"))
    }

    /// A paste of images (a screenshot, a copied photo) attaches them and leaves the text alone; Paste is offered for
    /// them. Without a taker the composer offers nothing new.
    func testAPastedImageAttachesAndLeavesTheText() async throws {
        let view = editor("Look")
        let board = try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("composer-\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        view.pasteboard = board
        let png = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        board.setData(png, forPasteboardType: UTType.png.identifier)
        XCTAssertTrue(board.hasImages)
        var taken: [MobileAttachmentSource] = []
        view.pasteImages = { taken = $0 }
        XCTAssertTrue(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        view.paste(nil)
        XCTAssertEqual(taken.map(\.name), ["Pasted image.png"])
        XCTAssertEqual(taken.first?.kind, .image)
        // The pasteboard may hand back its own encoding of the image: the same picture.
        let data = try await XCTUnwrap(taken.first).load()
        XCTAssertEqual(UIImage(data: data)?.cgImage?.width, UIImage(data: png)?.cgImage?.width)
        XCTAssertEqual(view.textStorage.string, "Look", "The image attaches; the draft's text is untouched")
        XCTAssertTrue(MobileAttachmentSource.images(on: try XCTUnwrap(UIPasteboard(name: UIPasteboard.Name("empty-\(UUID().uuidString)"),
                                                                                  create: true))).isEmpty)
    }
}
