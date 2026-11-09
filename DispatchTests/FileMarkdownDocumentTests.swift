import SwiftUI
import XCTest
@testable import DispatchApp

/// A Markdown file as Files' rendered preview reads it, without a window: how its source flows into blocks, what its
/// outline is, what a fold hides, and how the reading view is set.
@MainActor
final class FileMarkdownDocumentTests: XCTestCase {
    private func blocks(_ text: String) -> [ChatMarkdownBlock] { FileMarkdownDocument(text).blocks }
    private func block(_ kind: ChatMarkdownBlock.Kind, _ text: String = "") -> ChatMarkdownBlock { .init(kind: kind, text: text) }

    // MARK: Flow

    func testParagraphLinesFlowAndHardBreaksStay() {
        let text = """
        The billing service takes a charge request,
        checks its idempotency key
           and answers once.

        A first line ends in two spaces\u{20}\u{20}
        so the second starts a line. A backslash\\
        does too, and two \\\\
        do not.
        """
        XCTAssertEqual(blocks(text), [
            block(.paragraph, "The billing service takes a charge request, checks its idempotency key and answers once."),
            block(.paragraph, "A first line ends in two spaces\nso the second starts a line. A backslash\ndoes too, and two \\\\ do not."),
        ])
        // Chat keeps a message's lines as its author broke them: the document view alone flows them.
        XCTAssertEqual(ChatMarkdownBlock.parse("one\ntwo"), [block(.paragraph, "one\ntwo")])
    }

    func testIndentedLineContinuesItsListItem() {
        let text = """
        - **Replay first, record last.** After a change, replay the affected classes; the failures
          are exactly what changed.
        - A short item
          1. A nested step that
             wraps as well

        Not indented: a paragraph.
        """
        XCTAssertEqual(blocks(text), [
            block(.list("•", 0), "**Replay first, record last.** After a change, replay the affected classes; the failures are exactly what changed."),
            block(.list("•", 0), "A short item"),
            block(.list("1.", 1), "A nested step that wraps as well"),
            block(.paragraph, "Not indented: a paragraph."),
        ])
    }

    func testQuoteLinesAreOneQuoteWithItsParagraphsListsAndCalloutKept() {
        let text = """
        > A quote wrapped
        > over two lines.
        >
        > Its second paragraph:
        > - one
        > - two

        After it.

        > [!NOTE]
        > Useful context
        > worth noticing.
        """
        XCTAssertEqual(blocks(text), [
            block(.quote, "A quote wrapped over two lines.\n\nIts second paragraph:\n- one\n- two"),
            block(.paragraph, "After it."),
            block(.quote, "[!NOTE]\nUseful context worth noticing."),
        ])
    }

    func testFrontMatterIsAYAMLBlockAndALeadingRuleStaysARule() {
        let memory = """
        ---
        name: build-notes
        description: "What the build needs: a key"
        metadata:
          type: project
        ---

        # Build notes

        The body.
        """
        XCTAssertEqual(blocks(memory), [
            block(.code("yaml"), "name: build-notes\ndescription: \"What the build needs: a key\"\nmetadata:\n  type: project"),
            block(.heading(1), "Build notes"),
            block(.paragraph, "The body."),
        ])
        // A rule, prose, a rule: no key under the first, so nothing is taken for YAML.
        XCTAssertEqual(blocks("---\n\nAn opening line.\n\n---\n\nThe rest."), [
            block(.rule), block(.paragraph, "An opening line."), block(.rule), block(.paragraph, "The rest."),
        ])
        XCTAssertEqual(blocks("---\nname: never closed\n\nProse."), [
            block(.rule), block(.paragraph, "name: never closed"), block(.paragraph, "Prose."),
        ], "Front matter that never closes is not front matter")
    }

    func testIndentedLinesAreCodeAndAnUnderlinedParagraphIsAHeading() {
        let text = """
        Guide
        =====

        Run:

            make build
            make test

        ## Closed with marks ##
        """
        XCTAssertEqual(blocks(text), [
            block(.heading(1), "Guide"),
            block(.paragraph, "Run:"),
            block(.code("text"), "make build\nmake test"),
            block(.heading(2), "Closed with marks"),
        ])
    }

    func testFencesTablesAndRulesPassThrough() {
        let text = "```swift\nlet a = 1\n  let b = 2\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n---\n"
        XCTAssertEqual(blocks(text), [
            block(.code("swift"), "let a = 1\n  let b = 2"),
            block(.table([["A", "B"], ["1", "2"]])),
            block(.rule),
        ])
    }

    func testAFileLongerThanWhatRendersSaysSo() {
        let long = (0..<(TextRendering.richLineLimit + 50)).map { "Line \($0)\n" }.joined(separator: "\n")
        XCTAssertTrue(FileMarkdownDocument(long).truncated)
        XCTAssertFalse(FileMarkdownDocument("# Short\n").truncated)
    }

    // MARK: Outline and folds

    private let guide = """
    # Guide

    Opening.

    ## Install

    Steps.

    ### On a `host`

    Copy the helper.

    ## Use

    Run it.

    ## Install

    Again, for the other *platform*.
    """

    func testHeadingsNestByLevelAndNameTheirSections() throws {
        let document = FileMarkdownDocument(guide)
        XCTAssertEqual(document.headings.map(\.title), ["Guide", "Install", "On a host", "Use", "Install"],
                       "Titles without their markup")
        XCTAssertEqual(document.headings.map(\.depth), [0, 1, 2, 1, 1])
        XCTAssertEqual(document.headings.map(\.level), [1, 2, 3, 2, 2])
        XCTAssertEqual(document.headings.map(\.block), [0, 2, 4, 6, 8])
        XCTAssertEqual(document.headings.map(\.end), [10, 6, 6, 8, 10], "A section ends at the next heading of its level or above")
        XCTAssertEqual(document.headings.map(\.id), ["1 Guide", "2 Install", "3 On a host", "2 Use", "2 Install #2"],
                       "Headings alike are told apart by their order")
        // A level skipped still nests one deep, and a heading with nothing under it has nothing to fold.
        let skipped = FileMarkdownDocument("# Top\n\n### Deep\n\nText.\n\n## Last\n")
        XCTAssertEqual(skipped.headings.map(\.depth), [0, 1, 1])
        XCTAssertEqual(skipped.headings.map(\.foldable), [true, true, false])
    }

    func testAFoldHidesItsSectionAndKeepsItsHeading() throws {
        let document = FileMarkdownDocument(guide)
        let install = document.headings[1], host = document.headings[2]
        XCTAssertEqual(document.hidden(folded: []), IndexSet())
        XCTAssertEqual(document.hidden(folded: [install.id]), IndexSet(3...5), "Its text and the section under it")
        XCTAssertEqual(document.hidden(folded: [host.id]), IndexSet(integer: 5))
        XCTAssertEqual(document.hidden(folded: [install.id, host.id]), IndexSet(3...5))
        XCTAssertEqual(document.hidden(folded: ["2 Removed since"]), IndexSet(), "A heading the file no longer has folds nothing")
        XCTAssertEqual(document.shown(folded: [install.id], searching: false), [0, 1, 2, 6, 7, 8, 9])
        XCTAssertEqual(document.shown(folded: [install.id], searching: true), Array(0..<10),
                       "A search shows what it finds in a folded section")
        XCTAssertEqual(document.folds(in: [install.id, "2 Removed since"]), [install.id])
        // Going to a heading opens what is folded around it, and nothing else.
        XCTAssertEqual(document.ancestors(of: host).map(\.title), ["Guide", "Install"])
        XCTAssertEqual(document.revealing(host, in: ["1 Guide", install.id, host.id, "2 Use"]), [host.id, "2 Use"])
    }

    func testFoldAllKeepsALoneTitleOpen() {
        let document = FileMarkdownDocument(guide)
        XCTAssertEqual(document.allFolded, ["2 Install", "3 On a host", "2 Use", "2 Install #2"],
                       "The title over everything stays open: its sections show, folded")
        XCTAssertEqual(document.hidden(folded: document.allFolded), IndexSet([3, 4, 5, 7, 9]))
        let chapters = FileMarkdownDocument("# One\n\nText.\n\n# Two\n\n## Inside\n\nText.\n")
        XCTAssertEqual(chapters.allFolded, ["1 One", "1 Two", "2 Inside"], "Several at the top all fold")
        XCTAssertEqual(FileMarkdownDocument("Only prose.\n").allFolded, [])
    }

    func testAFoldStaysWithItsSectionWhileTheFileChangesElsewhere() {
        let before = FileMarkdownDocument(guide)
        let after = FileMarkdownDocument(guide.replacingOccurrences(of: "Opening.", with: "Opening.\n\nA paragraph an agent added.\n\n## New\n\nText."))
        let use = "2 Use"
        XCTAssertEqual(before.hidden(folded: [use]), IndexSet(integer: 7))
        XCTAssertEqual(after.hidden(folded: [use]), IndexSet(integer: 10), "The same section, three blocks further down")
    }

    func testSessionFoldsByFileAndRevealOpensTheSectionsAround() throws {
        let document = FileMarkdownDocument(guide)
        let session = FilesSession(id: System.uuid())
        let path = "/Users/ivan/src/api/GUIDE.md"
        session.toggleFold(document.headings[1], at: path)
        XCTAssertEqual(session.previewFolds, [path: ["2 Install"]])
        session.reveal(document.headings[2], of: document, at: path)
        XCTAssertEqual(session.previewFolds, [:], "No empty set is kept for a file with nothing folded")
        XCTAssertEqual(session.previewReveal?.heading, "3 On a host")
        XCTAssertEqual(session.previewReveal?.path, path)
        session.toggleFold(document.headings[3], at: path)
        session.toggleFold(document.headings[3], at: path)
        XCTAssertNil(session.previewFolds[path])
    }

    func testTheSameTextIsParsedOnce() {
        let text = "# Parsed once \(System.uuid().uuidString)\n\nText.\n"
        let before = FileMarkdownDocuments.parses
        XCTAssertEqual(FileMarkdownDocuments.document(text), FileMarkdownDocuments.document(text))
        XCTAssertEqual(FileMarkdownDocuments.parses, before + 1)
    }

    // MARK: Style

    func testProseIsLargerInAProportionalFaceAndTheColumnFollowsIt() {
        var preferences = Preferences()
        let chat = ChatTypography(preferences: preferences)
        let reading = FileMarkdownStyle.typography(preferences)
        XCTAssertEqual(reading.prose.size, chat.size + 3)
        XCTAssertEqual(reading.prose.pointSize(), chat.replySize + 2 * chat.sizeScale, accuracy: 0.001,
                       "Two points of Settings' size over chat's replies")
        XCTAssertEqual(reading.prose.lineSpacing, chat.lineSpacing, "On chat's line spacing")
        XCTAssertEqual(reading.code.codeDetailSize, chat.codeDetailSize + 1, "Code blocks a point over chat's")
        XCTAssertEqual(reading.code.codeFontName, chat.codeFontName, "Code keeps the code font")
        XCTAssertEqual(FileMarkdownStyle.measure(reading.prose), (reading.prose.pointSize() * 36).rounded())

        preferences.chatFont = .sameAsCode
        let code = ChatTypography(preferences: preferences)
        XCTAssertEqual(code.fontName, code.codeFontName)
        XCTAssertEqual(FileMarkdownStyle.typography(preferences), reading,
                       "A chat set in the code font still reads files in San Francisco")
        preferences.chatFont = .newYork
        var larger = preferences
        larger.fontSize += 3
        XCTAssertEqual(FileMarkdownStyle.typography(preferences).prose, ChatTypography(preferences: larger),
                       "Another chat font is the reading font too")

        preferences.fontSize = 18
        let large = FileMarkdownStyle.typography(preferences).prose
        XCTAssertEqual(large.size, 21)
        XCTAssertGreaterThan(FileMarkdownStyle.measure(large), FileMarkdownStyle.measure(reading.prose),
                             "A larger text keeps its characters a line: the column widens with it")
    }

    func testSixHeadingSizesAndMoreSpaceAboveAHeadingThanUnderIt() {
        let typography = FileMarkdownStyle.typography(Preferences()).prose
        // Of Settings' size, before the face's own scale: 17 for the prose.
        let sizes = (1...6).map { typography.size + FileMarkdownStyle.headingOffset($0, typography) }
        XCTAssertEqual(sizes, [30, 24.5, 20.5, 18.5, 17, 15.5])
        XCTAssertEqual(Set(sizes).count, 6, "No two levels alike")
        let size = typography.pointSize()
        for level in 1...6 {
            let above = FileMarkdownStyle.gap(before: .heading(level), after: .paragraph, size: size)
            let under = FileMarkdownStyle.gap(before: .paragraph, after: .heading(level), size: size)
            XCTAssertGreaterThan(above, under * 2, "Level \(level): a heading belongs to what follows it")
        }
        XCTAssertEqual(FileMarkdownStyle.gap(before: .heading(1), after: nil, size: size), 0, "Nothing above the first block")
        XCTAssertGreaterThan(FileMarkdownStyle.gap(before: .heading(2), after: .heading(2), afterFolded: true, size: size),
                             FileMarkdownStyle.gap(before: .heading(2), after: .heading(1), size: size),
                             "A heading under a folded one is the next section, not its subtitle")
        XCTAssertLessThan(FileMarkdownStyle.gap(before: .list("•", 0), after: .list("•", 0), size: size),
                          FileMarkdownStyle.gap(before: .paragraph, after: .paragraph, size: size), "A list's items sit together")
    }
}
