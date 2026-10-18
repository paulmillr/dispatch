// Per-frame check of a simulator recording of pushes and pops (docs/ios.md, Testing): is the tab bar where it
// should be? usage:
//   xcrun simctl launch <device> yachts.dispatch.mobile -DispatchTabsSample YES -DispatchTabsScript "tab:herdr:app:2,pop"
//   xcrun simctl io <device> recordVideo --codec h264 spaces.mov   (Ctrl-C after the script)
//   swiftc -O scripts/tab-bar-frames.swift -o build/tab-bar-frames
//   START=<s> build/tab-bar-frames spaces.mov ROOT_TIME PUSHED_TIME [x0 y0 x1 y1: the bar's rectangle, fractions]
// ROOT_TIME is a moment the section's root is at rest with its tab bar (its large title and the bar's glyphs become
// the references). Frames are judged only at rest (the same picture five frames running): a root (its large title
// there) must show the bar's glyphs, any other screen must not. Frames in motion are counted, not judged: the bar
// slides with the root, as UIKit pushes it. TRACE=a-b prints every frame in that window; DUMP=t writes a frame.
import AVFoundation
import CoreImage
import Foundation

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let rootTime = Double(args[2])!, pushedTime = Double(args[3])!
let bar = args.count > 7 ? (Double(args[4])!, Double(args[5])!, Double(args[6])!, Double(args[7])!) : (0.03, 0.90, 0.50, 0.975)

struct Frame { let time: Double; let pixels: [UInt8]; let width: Int; let height: Int }

func frames() throws -> [Frame] {
    let asset = AVURLAsset(url: url)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var track: AVAssetTrack?
    Task { track = try? await asset.loadTracks(withMediaType: .video).first; semaphore.signal() }
    semaphore.wait()
    guard let track else { fatalError("no video track") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    var result: [Frame] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        // Downsample to a 1/6 grid of luminance.
        let step = 6
        var pixels: [UInt8] = []
        pixels.reserveCapacity((width / step) * (height / step))
        for y in stride(from: 0, to: height - step + 1, by: step) {
            for x in stride(from: 0, to: width - step + 1, by: step) {
                // The block's mean luminance: robust to compression noise and sub-pixel shifts.
                var sum = 0
                for dy in 0..<step { for dx in 0..<step {
                    let p = base + (y + dy) * row + (x + dx) * 4
                    sum += Int(p[0]) + Int(p[1]) * 2 + Int(p[2])
                } }
                pixels.append(UInt8(sum / (4 * step * step)))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        result.append(Frame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds, pixels: pixels, width: width / step, height: height / step))
    }
    return result
}

let all = try frames()
guard let first = all.first else { fatalError("no frames") }
let w = first.width, h = first.height
func inBar(_ x: Int, _ y: Int) -> Bool {
    let fx = Double(x) / Double(w), fy = Double(y) / Double(h)
    return fx >= bar.0 && fx <= bar.2 && fy >= bar.1 && fy <= bar.3
}
func distance(_ a: Frame, _ b: Frame, bar wanted: Bool) -> Double {
    var sum = 0, count = 0
    for y in 0..<h { for x in 0..<w where inBar(x, y) == wanted {
        sum += abs(Int(a.pixels[y * w + x]) - Int(b.pixels[y * w + x])); count += 1
    } }
    return Double(sum) / Double(max(count, 1))
}
func frame(at time: Double) -> Frame {
    var found = first
    for candidate in all where candidate.time <= time { found = candidate }
    return found
}
if let dump = ProcessInfo.processInfo.environment["DUMP"].flatMap(Double.init) {
    let f = all.last { $0.time <= dump } ?? first
    var data = Data("P5\n\(w) \(h)\n255\n".utf8)
    data.append(contentsOf: f.pixels)
    try data.write(to: URL(fileURLWithPath: "dump.pgm"))
}
let root = frame(at: rootTime), pushed = frame(at: pushedTime)
/// The root's large title and toolbar: the bright pixels of its header band.
let titleMask: [Int] = ((h * 13 / 100)..<(h * 18 / 100)).flatMap { y in (0..<(w * 6 / 10)).compactMap { x in root.pixels[y * w + x] > 120 ? y * w + x : nil } }
func titled(_ f: Frame) -> Double {
    Double(titleMask.filter { f.pixels[$0] > 80 }.count) / Double(max(titleMask.count, 1))
}
/// The bar's glyphs and labels: the bright pixels of the root's bar area (white over glass).
let mask: [Int] = (0..<h).flatMap { y in (0..<w).compactMap { x in inBar(x, y) && root.pixels[y * w + x] > 120 ? y * w + x : nil } }
/// The share of the bar's glyph pixels that are bright in `f`: near 1 while the bar is there.
/// Tolerates the bar being a few points off its resting place horizontally (the last frames of a slide: the bar
/// moves with the root, that is not a missing bar).
func glyphs(_ f: Frame) -> Double {
    (-10...10).map { dx in
        Double(mask.filter { index in
            let x = index % w + dx
            return x >= 0 && x < w && f.pixels[index + dx] > 80
        }.count) / Double(max(mask.count, 1))
    }.max() ?? 0
}
let barGap = distance(root, pushed, bar: true)
print(String(format: "frames %d, %.2f s; bar glyph pixels %d (root %.2f, pushed %.2f)", all.count, all.last!.time - first.time, mask.count, glyphs(root), glyphs(pushed)))
// A frame is at rest when it and the four before it are the same picture (a static run of five frames, ~80 ms).
var wrong = 0, rootFrames = 0, pushedFrames = 0, moving = 0, run = 0
var rootMax = 0.0, pushedMin = 100.0
var previous: Frame?
let start = ProcessInfo.processInfo.environment["START"].flatMap(Double.init) ?? 0
for f in all where f.time >= start {
    let same = previous.map { distance(f, $0, bar: false) + distance(f, $0, bar: true) < 0.4 } ?? false
    run = same ? run + 1 : 0
    previous = f
    let likeRoot = 100 * (1 - titled(f)), shown = glyphs(f)
    if let range = ProcessInfo.processInfo.environment["TRACE"]?.split(separator: "-").compactMap({ Double($0) }), range.count == 2,
       f.time >= range[0], f.time <= range[1] {
        print(String(format: "%.3f header %.2f glyphs %.2f run %d", f.time, likeRoot, shown, run))
    }
    guard run >= 4 else { moving += 1; continue }
    if likeRoot < 10 {
        rootFrames += 1
        rootMax = max(rootMax, likeRoot)
        if shown < 0.8 { wrong += 1; print(String(format: "WRONG %.3f root at rest without its tab bar (glyphs %.2f)", f.time, shown)) }
    } else {
        pushedFrames += 1
        pushedMin = min(pushedMin, likeRoot)
        if shown > 0.5 { wrong += 1; print(String(format: "WRONG %.3f pushed screen at rest with the tab bar (glyphs %.2f)", f.time, shown)) }
    }
}
print("at rest: root \(rootFrames), pushed \(pushedFrames); moving \(moving); wrong \(wrong)")
print(String(format: "root title pixels missing: at rest on the root up to %.2f%%, on pushed screens from %.2f%% (threshold 10%%)", rootMax, pushedMin))
