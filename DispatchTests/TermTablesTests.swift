import XCTest
@_spi(Test) import Term

/// The Swift terminal's tables: Tables.swift is exactly what Vendor/Term/tables/gen.py makes of the
/// vendored inputs (no Ghostty checkout needed), and the tables Term builds at first use equal
/// Ghostty's (the oracle's `x11` and `break` lines in those inputs).
@MainActor
final class TermTablesTests: XCTestCase {
    private let tables = CodexTestSupport.root.appendingPathComponent("Vendor/Term/tables")

    func testGeneratedTablesMatchTheirInputs() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        defer { try? FileManager.default.removeItem(at: output) }
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-B", tables.appendingPathComponent("gen.py").path, tables.appendingPathComponent("inputs").path, output.path]
        python.standardOutput = FileHandle.nullDevice
        try python.run()
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: CodexTestSupport.root.appendingPathComponent("Vendor/Term/Sources/Term/Tables.swift")))
    }

    func testTablesBuiltAtFirstUseMatchGhostty() throws {
        let lines = try String(contentsOf: tables.appendingPathComponent("inputs/oracle-tables.txt"), encoding: .utf8).split(separator: "\n")
        // X11 names: Ghostty matches them ignoring ASCII case.
        let x11 = Dictionary(uniqueKeysWithValues: lines.filter { $0.hasPrefix("x11 ") }.map { line in
            let f = line.split(separator: " ", maxSplits: 4)
            return (f[4].lowercased(), f[1...3].map { UInt8($0)! })
        })
        XCTAssertEqual(x11Colors.mapValues { [$0.0, $0.1, $0.2] }, x11)
        // Grapheme breaks for every (state, class, class), through a code point of each class.
        var classes: [UInt8: UInt32] = [:]
        for cp in UInt32(0)..<0x110000 where classes[Unicode.props(cp).graphemeBreak] == nil { classes[Unicode.props(cp).graphemeBreak] = cp }
        let breaks = lines.filter { $0.hasPrefix("break ") }.map { $0.split(separator: " ").dropFirst().map { UInt8($0)! } }
        XCTAssertEqual(breaks.count, 5 * 17 * 17)  // uucode 0.2.0: 5 break states, 17 classes without controls
        XCTAssertEqual(breaks.map { f in
            var state = f[0]
            let broken = Unicode.graphemeBreak(classes[f[1]]!, classes[f[2]]!, &state)
            return [f[0], f[1], f[2], broken ? 1 : 0, state]
        }, breaks)
    }
}
