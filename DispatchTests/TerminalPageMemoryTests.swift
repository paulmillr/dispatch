import Darwin
import XCTest
@_spi(Test) import Term

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

    func testClearedScrollbackLeavesTheFootprint() {
        let s = surface()
        feed(s, lines("Sam Example line", 60_000))
        let pages = s.terminal.view.primary.pageChain.count
        XCTAssertGreaterThan(pages, 50)
        let full = footprint()
        feed(s, "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        let cleared = footprint()
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
