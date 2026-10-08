// Standard page blocks shared by every terminal in the process: a closed terminal's scrollback (or
// a left alternate screen) warms the next one instead of faulting fresh memory in. Holds at most
// one default scrollback; gives everything back to the system on memory pressure. Foundation only:
// the Term tool uses it on Linux too.
import Foundation
import Term

public final class SharedPageBlocks: PageBlocks, @unchecked Sendable {
    /// The process's blocks, for every terminal.
    public static let shared = SharedPageBlocks()

    /// The most it holds: one default scrollback's pages (a closed terminal can fully warm the next).
    let cap: Int
    /// One lock per block taken or given.
    let lock = NSLock()
    var blocks: [UnsafeMutableRawPointer] = []
    /// Blocks handed out, and asked for when none was held (under `lock`).
    @_spi(Test) public private(set) var taken = 0, missed = 0
    #if canImport(Darwin)
    let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
    #endif

    @_spi(Test) public init(cap: Int = pageBlocks(scrollbackBytes: TerminalOptions(cols: 1, rows: 1).maxScrollbackBytes ?? 0)) {
        self.cap = cap
        #if canImport(Darwin)
        pressure.setEventHandler { [weak self] in self?.trim() }
        pressure.resume()
        #endif
    }

    /// Blocks that end (a host's or a test's own) give back what they hold.
    deinit {
        #if canImport(Darwin)
        pressure.cancel()
        #endif
        trim()
    }

    public func take() -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        guard let block = blocks.popLast() else { missed += 1; return nil }
        taken += 1
        return block
    }

    public func give(_ block: UnsafeMutableRawPointer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard blocks.count < cap else { return false }
        blocks.append(block)
        return true
    }

    /// Gives every held block back to the system.
    public func trim() {
        lock.lock()
        let held = blocks
        blocks = []
        lock.unlock()
        for block in held { block.deallocate() }
    }

    @_spi(Test) public var held: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocks.count
    }
}
