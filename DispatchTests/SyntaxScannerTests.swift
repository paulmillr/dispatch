import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

/// Foundation-only lexical contracts, shared with the phone's test target.
final class SyntaxScannerTests: XCTestCase {
    private func role(_ word: String, in code: String, language: String, profile: SyntaxScanner.Profile,
                      file: StaticString = #filePath, line: UInt = #line) -> SyntaxScanner.Role {
        let range = (code as NSString).range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound, word, file: file, line: line)
        return SyntaxScanner.tokens(code, language: language, profile: profile)
            .first { NSEqualRanges($0.range, range) }?.role ?? .plain
    }

    func testLanguageProfilesKeepTheirSupportedTagsAndPaths() {
        for profile in SyntaxScanner.Profile.allCases {
            for hint in ["ts", "src/lib/example.ts", "TypeScript title=x.ts"] {
                XCTAssertEqual(SyntaxScanner.language(hint, profile: profile), "typescript")
            }
            XCTAssertEqual(SyntaxScanner.language("Swift", profile: profile), "swift")
            XCTAssertEqual(SyntaxScanner.language("python title=x.py", profile: profile), "python")
            XCTAssertEqual(SyntaxScanner.language("Makefile", profile: profile), "text")
            XCTAssertEqual(SyntaxScanner.language("", profile: profile), "text")
            XCTAssertTrue(SyntaxScanner.tokens("let x = 1", language: "unknown", profile: profile).isEmpty)
        }
        for hint in ["mts", "src/example.cts"] {
            XCTAssertEqual(SyntaxScanner.language(hint, profile: .mobile), "typescript")
            XCTAssertEqual(SyntaxScanner.language(hint, profile: .desktop), "text")
        }
        for hint in ["example.m", "example.mm"] {
            XCTAssertEqual(SyntaxScanner.language(hint, profile: .mobile), "code")
            XCTAssertEqual(SyntaxScanner.language(hint, profile: .desktop), "text")
        }
        XCTAssertEqual(SyntaxScanner.language("src/swift", profile: .mobile), "swift")
        XCTAssertEqual(SyntaxScanner.language("src/swift", profile: .desktop), "text")
        XCTAssertEqual(SyntaxScanner.language("guide.mdx", profile: .desktop), "markdown")
        XCTAssertEqual(SyntaxScanner.language("guide.mdx", profile: .mobile), "text")
        // A language passed on is asked again (the file preview maps the name, then its text): each answer is itself.
        for profile in SyntaxScanner.Profile.allCases {
            for hint in ["a.sh", "a.js", "a.ts", "a.py", "a.swift", "a.json", "a.yml", "a.rs", "a.go", "a.c", "a.m", "a.css",
                         "a.html", "a.sql", "a.diff", "a.md", "a.txt"] {
                let language = SyntaxScanner.language(hint, profile: profile)
                XCTAssertEqual(SyntaxScanner.language(language, profile: profile), language, "\(hint) \(profile)")
            }
        }
    }

    func testProfilesRetainTheirKeywordTypeConstantAndReceiverRoles() {
        let code = "const item: String = true; client.run(TTL, { NX: 1_000 })"
        let expected: [(String, SyntaxScanner.Role, SyntaxScanner.Role)] = [
            ("const", .keyword, .keyword), ("String", .call, .type), ("true", .keyword, .number),
            ("client", .plain, .call), ("run", .call, .call), ("TTL", .call, .number),
            ("NX", .call, .plain), ("1_000", .plain, .number)
        ]
        for (word, desktop, mobile) in expected {
            XCTAssertEqual(role(word, in: code, language: "ts", profile: .desktop), desktop, word)
            XCTAssertEqual(role(word, in: code, language: "ts", profile: .mobile), mobile, word)
        }
        XCTAssertEqual(role("nonisolated", in: "nonisolated", language: "swift", profile: .mobile), .keyword)
        XCTAssertEqual(role("nonisolated", in: "nonisolated", language: "swift", profile: .desktop), .plain)
        XCTAssertEqual(role("def", in: "def", language: "swift", profile: .mobile), .plain)
        XCTAssertEqual(role("def", in: "def", language: "swift", profile: .desktop), .keyword)
        XCTAssertEqual(role("str", in: "str", language: "python", profile: .mobile), .type)
        XCTAssertEqual(role("true", in: "true", language: "json", profile: .mobile), .number)
        XCTAssertEqual(role("true", in: "true", language: "json", profile: .desktop), .keyword)
    }

    func testMultilineCommentsAndStringsConsumeTheirKeywords() {
        let spans: [(String, SyntaxScanner.Role)] = [
            ("/* let 42\nreturn */", .comment), ("\"\"\"let\nreturn 42\"\"\"", .string),
            ("'''let\nreturn 42'''", .string), ("`let\nreturn ${42}`", .string),
            ("\"a \\\"quoted\\\" return\"", .string), ("'a \\'quoted\\' return'", .string)
        ]
        for profile in SyntaxScanner.Profile.allCases {
            for (span, expected) in spans {
                let code = span + "\nlet next = 1"
                XCTAssertEqual(SyntaxScanner.tokens(code, language: "swift", profile: profile).first,
                               SyntaxScanner.Token(range: NSRange(location: 0, length: span.utf16.count), role: expected))
                XCTAssertEqual(role("next", in: code, language: "swift", profile: profile), .plain)
                XCTAssertEqual(role("1", in: code, language: "swift", profile: profile), .number)
            }
        }
    }

    func testCommentFamiliesAndShellVariablesStayShared() {
        let comments = [("shell", "# let 42"), ("python", "# let 42"), ("yaml", "# let 42"),
                        ("swift", "// let 42"), ("sql", "-- let 42"), ("html", "<!-- let\n42 -->")]
        for profile in SyntaxScanner.Profile.allCases {
            for (language, code) in comments {
                XCTAssertEqual(SyntaxScanner.tokens(code, language: language, profile: profile),
                               [.init(range: NSRange(location: 0, length: code.utf16.count), role: .comment)])
            }
            let code = "echo $value ${other} --flag -x"
            for word in ["$value", "${other}", "--flag", "-x"] {
                XCTAssertEqual(role(word, in: code, language: "shell", profile: profile), .call)
            }
            XCTAssertEqual(role("#fragment", in: "url#fragment", language: "shell", profile: profile), .plain)
            XCTAssertFalse(SyntaxScanner.tokens("// true", language: "json", profile: profile).contains { $0.role == .comment })
        }
    }

    func testIncompleteQuotesAndCommentsKeepTheirExistingBounds() {
        for profile in SyntaxScanner.Profile.allCases {
            for span in ["\"unfinished let", "'unfinished return", "\"\"\"unfinished\nlet", "'''unfinished\nlet", "`unfinished\nlet"] {
                XCTAssertEqual(SyntaxScanner.tokens(span, language: "swift", profile: profile),
                               [.init(range: NSRange(location: 0, length: span.utf16.count), role: .string)], span)
            }
            let comment = "/* unfinished\nlet value = 42"
            XCTAssertEqual(SyntaxScanner.tokens(comment, language: "swift", profile: profile),
                           [.init(range: NSRange(location: 0, length: comment.utf16.count), role: .comment)])
            for code in ["it's open\nlet value = 1", "'static\nlet value = 1", "\"unfinished\nlet value = 1"] {
                XCTAssertEqual(role("let", in: code, language: "swift", profile: profile), .keyword)
                XCTAssertFalse(SyntaxScanner.tokens(code, language: "swift", profile: profile).contains {
                    $0.role == .string && (code as NSString).substring(with: $0.range).contains("\n")
                })
            }
        }
    }

    func testDesktopMarkdownAndDiffRemainSeparateFromMobileCode() {
        let fence = "```swift\n# let **42**\n```"
        let markdown = "# Heading\n" + fence + "\n[label](https://example.invalid)\n**bold**\n- [x] done"
        XCTAssertEqual(role("# Heading", in: markdown, language: "md", profile: .desktop), .keyword)
        XCTAssertEqual(role(fence, in: markdown, language: "md", profile: .desktop), .string)
        XCTAssertEqual(role("[label](https://example.invalid)", in: markdown, language: "md", profile: .desktop), .call)
        XCTAssertEqual(role("**bold**", in: markdown, language: "md", profile: .desktop), .number)
        XCTAssertEqual(role("- [x]", in: markdown, language: "md", profile: .desktop), .number)
        XCTAssertTrue(SyntaxScanner.tokens(markdown, language: "md", profile: .mobile).isEmpty)

        let diff = "@@ -1 +1 @@\n-🦊 old\n+new\n context\n"
        let tokens = SyntaxScanner.tokens(diff, language: "patch", profile: .desktop)
        XCTAssertEqual(tokens.map(\.role), [.hunk, .removed, .added])
        XCTAssertEqual(tokens.map { (diff as NSString).substring(with: $0.range) }, ["@@ -1 +1 @@", "-🦊 old", "+new"])
        XCTAssertTrue(SyntaxScanner.tokens(diff, language: "patch", profile: .mobile).isEmpty)
    }

    func testUTF16RangesRemainOrderedAndNonoverlapping() {
        let code = "😀 let λ = \"🦊 e\u{301} return 5\"\n/* 👩🏽‍💻 let */\nreturn 42"
        for profile in SyntaxScanner.Profile.allCases {
            let tokens = SyntaxScanner.tokens(code, language: "swift", profile: profile)
            XCTAssertEqual(tokens.first, .init(range: NSRange(location: 3, length: 3), role: .keyword))
            XCTAssertEqual(role("\"🦊 e\u{301} return 5\"", in: code, language: "swift", profile: profile), .string)
            for token in tokens {
                XCTAssertGreaterThan(token.range.length, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(token.range), code.utf16.count)
                XCTAssertNotNil(Range(token.range, in: code))
            }
            for (a, b) in zip(tokens, tokens.dropFirst()) {
                XCTAssertLessThanOrEqual(NSMaxRange(a.range), b.range.location)
            }
        }
    }

    func testCutoffIncludes65536UTF16UnitsAndRejectsTheNextUnit() {
        let exact = "let" + String(repeating: " ", count: SyntaxScanner.limit - 5) + "😀"
        XCTAssertEqual(exact.utf16.count, 65_536)
        for profile in SyntaxScanner.Profile.allCases {
            XCTAssertEqual(SyntaxScanner.tokens(exact, language: "swift", profile: profile),
                           [.init(range: NSRange(location: 0, length: 3), role: .keyword)])
            XCTAssertTrue(SyntaxScanner.tokens(exact + " ", language: "swift", profile: profile).isEmpty)
            XCTAssertTrue(SyntaxScanner.tokens("let " + String(repeating: "😀", count: 32_767), language: "swift", profile: profile).isEmpty)
        }
        XCTAssertTrue(SyntaxScanner.tokens("+" + String(repeating: "x", count: 65_536), language: "diff", profile: .desktop).isEmpty)
    }
}
