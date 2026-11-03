import Darwin
@_spi(Test) import Term

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return Int(info.phys_footprint)
}

var options = TerminalOptions(cols: 120, rows: 30)
options.maxScrollbackBytes = 40_000_000
let surface = Surface(terminal: Terminal(options), options: HandlerOptions(),
    size: RenderSize(screen: (1200, 600), cell: (10, 20)), now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
func feed(_ text: String) { Array(text.utf8).withUnsafeBufferPointer { surface.feed($0) } }
feed((1...60_000).map { "Sam Example line \($0)\r\n" }.joined())
withExtendedLifetime(surface) {
    let pages = surface.terminal.view.primary.pageChain.count
    let full = footprint()
    feed("\u{1B}[H\u{1B}[2J\u{1B}[3J")
    let cleared = footprint()
    // The surface still holds the cleared blocks in its pool: this measures reusable memory, not deallocation.
    print("PAGE_MEMORY \(pages) \(full) \(cleared)")
}
