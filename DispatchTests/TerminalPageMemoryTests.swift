import Darwin
import XCTest
@_spi(Test) import Term
#if os(macOS)
import Foundation
@testable import DispatchApp
#endif

/// History a terminal no longer holds stops counting in the process's footprint: page blocks waiting in a list's pool
/// (cleared scrollback, reflowed pages) are given back to the system until reused, and reused blocks show only what
/// is written to them.
final class TerminalPageMemoryTests: XCTestCase {
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private func surface(cols: Int = 120) -> Surface {
        var options = TerminalOptions(cols: cols, rows: 30)
        options.maxScrollbackBytes = 40_000_000
        return Surface(terminal: Terminal(options), options: HandlerOptions(), size: RenderSize(screen: (cols * 10, 600), cell: (10, 20)),
                       now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
    }

    private func feed(_ s: Surface, _ text: String) { Array(text.utf8).withUnsafeBufferPointer { s.feed($0) } }
    private func lines(_ prefix: String, _ count: Int) -> String { (1...count).map { "\(prefix) \($0)\r\n" }.joined() }

    func testClearedScrollbackLeavesTheFootprint() throws {
        #if os(macOS)
        // The suite's UI, renderer and helper callbacks allocate independently. Measure the same surface in a
        // fresh process so those allocations cannot offset its released pages in TASK_VM_INFO.
        let directory = System.temporary.appendingPathComponent("terminal-page-memory-" + System.uuid().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let products = System.bundle.deletingLastPathComponent()
        let binary = directory.appendingPathComponent("probe")
        var environment = System.inherited
        for name in environment.keys where name.hasPrefix("DYLD_") || name.hasPrefix("TEST_RUNNER_") || name.hasPrefix("XCTest") {
            environment.removeValue(forKey: name)
        }
        func run(_ executable: String, _ arguments: [String]) throws -> (Int32, Data) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments; process.environment = environment
            let result = try TestSupport.live(process, input: Data(), timeout: 60)
            XCTAssertFalse(result.timedOut)
            XCTAssertEqual(result.status, 0, String(decoding: result.errors, as: UTF8.self))
            return (result.status, result.output)
        }
        let source = System.checkout.appendingPathComponent("test/fixtures/terminal-page-memory.swift")
        let compiled = try run("/usr/bin/xcrun", ["swiftc", "-O", "-module-cache-path", directory.appendingPathComponent("modules").path,
            "-F", products.path, "-framework", "Term", "-Xlinker", "-rpath", "-Xlinker", products.path,
            source.path, "-o", binary.path])
        guard compiled.0 == 0 else { return }
        let measured = try run(binary.path, [])
        let line = try XCTUnwrap(String(decoding: measured.1, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("PAGE_MEMORY ") })
        let values = line.split(separator: " ").dropFirst().compactMap { Int($0) }
        XCTAssertEqual(values.count, 3)
        guard values.count == 3 else { return }
        let (pages, full, cleared) = (values[0], values[1], values[2])
        #else
        let s = surface()
        feed(s, lines("Sam Example line", 60_000))
        let pages = s.terminal.view.primary.pageChain.count
        let full = footprint()
        feed(s, "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        let cleared = footprint()
        #endif
        XCTAssertGreaterThan(pages, 50)
        // Each page block is about 400 KB; nearly all of them now wait in the list's pool.
        XCTAssertGreaterThan(full - cleared, (pages - 4) * 300_000, "\(pages) pages: \(full) -> \(cleared) bytes")
    }

    func testReusedBlocksShowOnlyWhatIsWrittenToThem() {
        let s = surface()
        feed(s, "\u{1B}[1;31m\u{1B}]8;;https://example.com\u{1B}\\" + lines("old", 30_000) + "\u{1B}]8;;\u{1B}\\\u{1B}[m")
        feed(s, "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        feed(s, lines("new", 20_000))
        let text = String(decoding: s.readPrimaryText(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(text.first, "new 1")
        XCTAssertEqual(text.count, 20_000)
        XCTAssertFalse(text.contains { $0.hasPrefix("old") })
        let screen = s.terminal.view.primary
        let p = screen.pin(.active, x: 0, y: 0)!
        XCTAssertFalse(p.page.style(p.page.cell(p.cell).styleID).flags.bold)
        XCTAssertNil(p.page.hyperlink(p.cell))
        // Reflowing moves every row through recycled blocks.
        s.terminal.resize(cols: 50, rows: 30)
        s.terminal.resize(cols: 140, rows: 30)
        let after = String(decoding: s.readPrimaryText(), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(after, text)
    }
}
