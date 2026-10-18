import XCTest
@testable import DispatchMobile

/// The desktop palette on the phone (M5d, M5e): which role each word of a sample gets.
final class CodeSyntaxTests: XCTestCase {
    /// The role of each listed word (its first occurrence at or after the previous word).
    private func roles(_ code: String, _ language: String, _ words: [String]) -> [String: CodeSyntax.Role] {
        let tokens = CodeSyntax.tokens(code, language: language)
        let source = code as NSString
        var result: [String: CodeSyntax.Role] = [:]
        var from = 0
        for word in words {
            let range = source.range(of: word, range: NSRange(location: from, length: source.length - from))
            XCTAssertNotEqual(range.location, NSNotFound, word)
            guard range.location != NSNotFound else { continue }
            from = NSMaxRange(range)
            let token = tokens.first { NSIntersectionRange($0.range, range).length > 0 }
            result[word] = token.map { NSEqualRanges(NSUnionRange($0.range, range), $0.range) ? $0.role : .plain } ?? .plain
        }
        return result
    }

    func testTypeScriptReadsAsTheMockup() {
        let code = """
            export async function seen(eventId: string) {
              const n = await redis.incr(`evt:${n}`);
              if (n === 1) await redis.expire(key, TTL);
              const ok = await redis.set(key, 1, { NX: true, EX: TTL });
              // Shared by billing and invoice routes
              return ok === 'OK' as Promise<T>;
            }
            """
        let found = roles(code, "ts", ["export", "async", "function", "seen", "eventId", "string", "const", "await", "redis", "incr",
                                       "`evt:${n}`", "1", "expire", "TTL", "set", "NX", "true", "// Shared by billing and invoice routes",
                                       "return", "'OK'", "Promise", "T"])
        XCTAssertEqual(found["export"], .keyword)
        XCTAssertEqual(found["async"], .keyword)
        XCTAssertEqual(found["function"], .keyword)
        XCTAssertEqual(found["seen"], .call, "Calls are blue")
        XCTAssertEqual(found["eventId"], .plain)
        XCTAssertEqual(found["string"], .type, "Types are purple")
        XCTAssertEqual(found["const"], .keyword, "Keywords are pink")
        XCTAssertEqual(found["redis"], .call, "The receiver of a call reads as the call")
        XCTAssertEqual(found["incr"], .call)
        XCTAssertEqual(found["`evt:${n}`"], .string, "A template literal is one string, keywords inside it stay green")
        XCTAssertEqual(found["1"], .number)
        XCTAssertEqual(found["TTL"], .number, "Constants are amber")
        XCTAssertEqual(found["NX"], .plain, "Object keys stay plain")
        XCTAssertEqual(found["true"], .number)
        XCTAssertEqual(found["// Shared by billing and invoice routes"], .comment)
        XCTAssertEqual(found["'OK'"], .string, "Strings are green")
        XCTAssertEqual(found["Promise"], .type)
        XCTAssertEqual(found["T"], .type)
        XCTAssertEqual(CodeSyntax.Role.keyword.uiColor, CodePalette.keyword)
    }

    func testSwiftKeywordsTypesAndLiterals() {
        let code = """
            /* block
               comment with let */
            func load(_ path: String) async throws -> [Int] {
                let mask = 0x1F
                guard let value = try await fetch("a \\"quoted\\" let") else { return nil }
                return Self.values(value, mask) // done
            }
            """
        let found = roles(code, "swift", ["/* block\n   comment with let */", "func", "load", "path", "String", "async", "throws", "Int",
                                          "let", "0x1F", "guard", "try", "fetch", "\"a \\\"quoted\\\" let\"", "nil", "Self", "values", "// done"])
        XCTAssertEqual(found["/* block\n   comment with let */"], .comment, "A block comment spans lines and hides its keywords")
        XCTAssertEqual(found["func"], .keyword)
        XCTAssertEqual(found["load"], .call)
        XCTAssertEqual(found["path"], .plain)
        XCTAssertEqual(found["String"], .type)
        XCTAssertEqual(found["async"], .keyword)
        XCTAssertEqual(found["throws"], .keyword)
        XCTAssertEqual(found["Int"], .type)
        XCTAssertEqual(found["0x1F"], .number)
        XCTAssertEqual(found["guard"], .keyword)
        XCTAssertEqual(found["try"], .keyword)
        XCTAssertEqual(found["fetch"], .call)
        XCTAssertEqual(found["\"a \\\"quoted\\\" let\""], .string, "Escaped quotes stay inside the string")
        XCTAssertEqual(found["nil"], .number)
        XCTAssertEqual(found["Self"], .keyword)
        XCTAssertEqual(found["values"], .call)
        XCTAssertEqual(found["// done"], .comment)
    }

    func testPythonHashCommentsAndConstants() {
        let code = """
            def greet(name: str) -> None:
                # say hello, def is not a keyword here
                if name is not None and len(name) > 2:
                    print(f"hi {name}", True)
                return '''doc
            string'''
            """
        let found = roles(code, "py", ["def", "greet", "str", "None", "# say hello, def is not a keyword here", "if", "is", "not",
                                       "and", "len", "2", "print", "\"hi {name}\"", "True", "return", "'''doc\nstring'''"])
        XCTAssertEqual(found["def"], .keyword)
        XCTAssertEqual(found["greet"], .call)
        XCTAssertEqual(found["str"], .type)
        XCTAssertEqual(found["None"], .number)
        XCTAssertEqual(found["# say hello, def is not a keyword here"], .comment)
        XCTAssertEqual(found["if"], .keyword)
        XCTAssertEqual(found["is"], .keyword)
        XCTAssertEqual(found["and"], .keyword)
        XCTAssertEqual(found["len"], .call)
        XCTAssertEqual(found["2"], .number)
        XCTAssertEqual(found["print"], .call)
        XCTAssertEqual(found["\"hi {name}\""], .string)
        XCTAssertEqual(found["True"], .number)
        XCTAssertEqual(found["'''doc\nstring'''"], .string, "Triple-quoted strings span lines")
    }

    func testLanguagesFollowTagsAndPathsAndLargeCodeStaysPlain() {
        XCTAssertEqual(CodeSyntax.language("ts"), "typescript")
        XCTAssertEqual(CodeSyntax.language("src/lib/idempotent.ts"), "typescript")
        XCTAssertEqual(CodeSyntax.language("Swift"), "swift")
        XCTAssertEqual(CodeSyntax.language("python title=x.py"), "python")
        XCTAssertEqual(CodeSyntax.language("Makefile"), "text")
        XCTAssertEqual(CodeSyntax.language(""), "text")
        XCTAssertTrue(CodeSyntax.tokens("let x = 1", language: "text").isEmpty)
        XCTAssertTrue(CodeSyntax.tokens(String(repeating: "let x = 1\n", count: 7_000), language: "swift").isEmpty,
                      "Beyond 64 KiB code is plain, as on the Mac")
        // Tokens never overlap and come in order.
        let tokens = CodeSyntax.tokens(CodeDemo.idempotentFile, language: "ts")
        for (a, b) in zip(tokens, tokens.dropFirst()) { XCTAssertLessThanOrEqual(NSMaxRange(a.range), b.range.location) }
    }

    func testLinesKeepAMultilineStringsColourOnEveryLine() {
        let lines = CodeSyntax.lines("let a = \"\"\"\nlet b\n\"\"\"\nlet c", language: "swift")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1].runs.first?.foregroundColor, CodeSyntax.Role.string.color, "Inside the string, `let` is not a keyword")
        XCTAssertEqual(lines[3].runs.first?.foregroundColor, CodeSyntax.Role.keyword.color)
    }
}
