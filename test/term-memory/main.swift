// Headless memory and latency checks of the Swift terminal (no app, no window): Sessions drawing synchronously
// into their own IOSurface targets, as a hosted layer's display() does. Build and run with build.sh (see there).
//
// bench few <n>                        n terminals drawn
// bench hidden <n> [seconds] [pressure] n drawn, n-1 hidden; after `seconds`; HiddenResources.releaseHidden()
// bench history <n> <lines> [clear] [close]   n terminals with `lines` of output each; clear history; close all but one
// bench renderers <n>                  MetalRenderer setup cost
// bench steps                          one terminal step by step, frame times with new emoji
// Words: `ascii` (no CJK, emoji or box drawing), `pause=<s>` (sleep at the end, for footprint/vmmap).
import AppKit
import Darwin
import Metal
import Term
@_spi(Test) import TermApple

func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
let device = MTLCreateSystemDefaultDevice()!
func gpu() -> Double { Double(device.currentAllocatedSize) / 1_048_576 }
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
/// `footprint`'s view (what Activity Monitor's Memory column shows): total and the big categories, in MiB.
func categories() -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
    p.arguments = ["-f", "bytes", "\(getpid())"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    try! p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    var total = 0.0, parts: [String: Double] = [:]
    for line in text.split(separator: "\n") {
        if let r = line.range(of: "Footprint: ") { total = Double(line[r.upperBound...].split(separator: " ")[0])! / 1_048_576; continue }
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 8, f[1] == "B", let dirty = Double(f[0]) else { continue }
        let name = f[7...].joined(separator: " ")
        let key = name.hasPrefix("IOSurface") ? "iosurface" : name.contains("graphics") ? "graphics" : name.hasPrefix("Malloc") ? "malloc" : "other"
        parts[key, default: 0] += dirty / 1_048_576
    }
    return String(format: "footprint %7.1f MiB (malloc %6.1f, iosurface %6.1f, graphics %6.1f, other %5.1f)",
                  total, parts["malloc"] ?? 0, parts["iosurface"] ?? 0, parts["graphics"] ?? 0, parts["other"] ?? 0)
}
func report(_ label: String) {
    // Let Metal completion handlers and frees settle.
    for _ in 0..<10 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
    print(label.padding(toLength: 46, withPad: " ", startingAt: 0) + categories() + String(format: "  metal %6.1f MiB", gpu()))
}

let args = CommandLine.arguments
let scenario = args.count > 1 ? args[1] : "hidden"
let count = args.count > 2 ? Int(args[2])! : 20
let width = 2400, height = 1500, scale = 2.0
var config = Config()
config.load(Array("font-size = 13\n".utf8))
config.finalize(dark: true) { _, _ in nil }

/// Colored output with a varied repertoire (ASCII, box drawing, CJK, emoji), like a busy program.
func screenful(_ seed: Int, lines: Int) -> [UInt8] {
    var out = ""
    let words = args.contains("ascii") ? ["build", "test", "warning:", "error:", "ok", "0x7f3a", "done"]
        : ["build", "test", "warning:", "error:", "│", "─┼─", "日本語", "ok", "🚀", "λ", "→", "Σ", "0x7f3a", "done"]
    for i in 0..<lines {
        out += "\u{1B}[3\((i + seed) % 8)m\(i + seed) "
        for j in 0..<12 { out += words[(i * 7 + j * 3 + seed) % words.count] + " " }
        out += "\u{1B}[0m\r\n"
    }
    return Array(out.utf8)
}

func make(_ i: Int) -> Session {
    let s = try! Session(config: config, scale: scale, machine: .current)
    s.layer.bounds = CGRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale)
    s.setSize(width: width, height: height)
    s.locked { screenful(i, lines: 200).withUnsafeBufferPointer { s.surface.feed($0) } }
    return s
}
/// Three presents: every swap-chain target exists, as after a few frames on screen.
func draw(_ s: Session, frames: Int = 3) { for _ in 0..<frames { s.refresh(); s.layer.display() } }

func hold() {
    guard let pause = args.first(where: { $0.hasPrefix("pause=") }) else { return }
    print("pid", getpid()); fflush(stdout)
    Thread.sleep(forTimeInterval: Double(pause.dropFirst(6))!)
}
report("start")
switch scenario {
case "hidden":
    var sessions: [Session] = []
    var inits: [Double] = []
    for i in 0..<count {
        let t = now()
        let s = make(i)
        inits.append(now() - t)
        draw(s)
        sessions.append(s)
    }
    print(String(format: "session init: first %.1f ms, median of the rest %.1f ms", inits[0], inits.dropFirst().sorted()[inits.count / 2 - 1]))
    report("\(count) terminals drawn, all visible")
    for s in sessions.dropFirst() { s.setVisible(false) }
    report("\(count - 1) hidden, 1 visible (immediately)")
    let wait = args.count > 3 ? Double(args[3]) ?? 0 : 0
    if wait > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: wait)); report("\(count - 1) hidden, after \(wait) s") }
    #if RECLAIM
    if args.contains("pressure") { HiddenResources.releaseHidden(); report("after a memory-pressure reclaim") }
    #endif
    var shows: [Double] = []
    for s in sessions.dropFirst() {
        let t = now()
        s.setVisible(true)
        s.layer.display()
        shows.append(now() - t)
        s.setVisible(false)
    }
    shows.sort()
    print(String(format: "show again + first frame: median %.2f ms, max %.2f ms", shows[shows.count / 2], shows.last!))
    report("after showing each hidden terminal once")
    hold()
case "steps":
    let s = try! Session(config: config, scale: scale, machine: .current)
    report("session made")
    s.layer.bounds = CGRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale)
    s.setSize(width: width, height: height)
    report("sized")
    s.locked { screenful(0, lines: 200).withUnsafeBufferPointer { s.surface.feed($0) } }
    report("fed")
    var t0 = now()
    draw(s, frames: 1)
    print(String(format: "first frame: %.1f ms", now() - t0))
    report("1 frame")
    s.locked { Array("\u{1B}[2J\u{1B}[H😀😁😂🤣😃😄😅😆😉😊😋😎😍😘🥰😗".utf8).withUnsafeBufferPointer { s.surface.feed($0) } }
    t0 = now()
    draw(s, frames: 1)
    print(String(format: "frame with 16 new emoji: %.1f ms", now() - t0))
    draw(s, frames: 2)
    report("3 frames")
    let t = try! Session(config: config, scale: scale, machine: .current)
    report("second session made")
    hold()
    _ = t
case "renderers":
    var times: [Double] = [], renderers: [MetalRenderer] = []
    for _ in 0..<count { let t = now(); renderers.append(try! MetalRenderer(device: device)); times.append(now() - t) }
    print(String(format: "MetalRenderer init: first %.2f ms, then median %.3f ms, total %.1f ms", times[0], times.dropFirst().sorted()[(count - 1) / 2], times.reduce(0, +)))
    report("\(count) renderers")
case "few":
    var sessions: [Session] = []
    for i in 0..<count { let s = make(i); draw(s); sessions.append(s) }
    report("\(count) terminals drawn, visible")
    hold()
case "history":
    let lines = args.count > 3 ? Int(args[3]) ?? 100_000 : 100_000
    var sessions: [Session] = []
    for i in 0..<count {
        let s = make(i)
        let chunk = screenful(i, lines: 1000)
        for _ in 0..<(lines / 1000) { s.locked { chunk.withUnsafeBufferPointer { s.surface.feed($0) } } }
        draw(s)
        sessions.append(s)
        report("terminal \(i + 1): \(lines) lines of history")
    }
    let rows = sessions.map { s in s.locked { s.surface.terminal.scrollbar.total } }
    print("rows kept per terminal:", rows)
    hold()
    if args.contains("clear") {
        for s in sessions { s.locked { Array("\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8).withUnsafeBufferPointer { s.surface.feed($0) } } }
        report("history cleared (CSI 3 J) in every terminal")
    }
    if args.contains("close") {
        let closing = sessions.count - 1
        weak var closed = sessions[1]
        for s in sessions.dropFirst() { s.close() }
        sessions.removeLast(closing)
        for _ in 0..<20 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        print("closed session freed:", closed == nil)
        for _ in 0..<20 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        weak var probe = sessions.last
        print("shared pool holds", SharedPageBlocks.shared.held, "blocks; last session alive:", probe != nil)
        report("\(closing) of them closed")
        if args.contains("relief") {
            let t = now()
            let freed = malloc_zone_pressure_relief(nil, 0)
            print(String(format: "malloc_zone_pressure_relief: %d bytes in %.1f ms", freed, now() - t))
            report("after pressure relief")
        }
        let t = now()
        let s = make(99)
        let chunk = screenful(99, lines: 1000)
        for _ in 0..<(lines / 1000) { s.locked { chunk.withUnsafeBufferPointer { s.surface.feed($0) } } }
        print(String(format: "a new terminal filling its history: %.0f ms", now() - t))
        draw(s)
        sessions.append(s)
        report("a new terminal with \(lines) lines")
    }
default: fatalError("scenario: hidden | few | history")
}
