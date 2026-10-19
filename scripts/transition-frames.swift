// Per-frame review of a simulator recording of transitions (docs/ios.md, Testing, Frame checks): the extension of
// scripts/tab-bar-frames.swift for screens whose wrong states cannot be told by one fixed region (sheets, the segment
// switch, the thinking row, the queue card, the banner, edit mode, the tree, a filter).
// usage:
//   xcrun simctl io <device> recordVideo --codec h264 run.mov   (while a TransitionUITests case or a
//                                                                 -DispatchTabsScript launch runs; Ctrl-C after)
//   swiftc -O scripts/transition-frames.swift -o build/transition-frames
//   build/transition-frames run.mov OUTDIR [START END]
// The picture of every frame is compared with the one before (mean luminance difference on a 1/6 grid). A picture
// that stays the same for 80 ms or more is at rest; the frames between two rests are one motion. Written to OUTDIR:
//   rest.png        the first frame of every rest, in order, labelled with its time and how long it stayed (and its
//                   last frame when a small change ran through it): every picture the user could see still, to judge
//                   one by one (no blank content, stale bar, half row);
//   motion-NN.png   every frame of motion NN (up to 72, evenly sampled beyond), to judge only for content that should
//                   never appear (an empty placeholder, a wrong title);
// and printed: the frame count, each rest (time, duration) and each motion (time, frames).
import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: transition-frames VIDEO OUTDIR [START END]") }
let url = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let window = args.count >= 5 ? (Double(args[3])!, Double(args[4])!) : (0, Double.greatestFiniteMagnitude)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Frame { let time: Double; let grid: [UInt8]; let thumb: CGImage }

let thumbScale = 8
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
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time >= window.0, time <= window.1, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let step = 6
        var grid: [UInt8] = []
        grid.reserveCapacity((width / step) * (height / step))
        for y in stride(from: 0, to: height - step + 1, by: step) {
            for x in stride(from: 0, to: width - step + 1, by: step) {
                var sum = 0
                for dy in 0..<step { for dx in 0..<step {
                    let p = base + (y + dy) * row + (x + dx) * 4
                    sum += Int(p[0]) + Int(p[1]) * 2 + Int(p[2])
                } }
                grid.append(UInt8(sum / (4 * step * step)))
            }
        }
        let full = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: row, space: space,
                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let image = full.makeImage()!
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let small = CGContext(data: nil, width: width / thumbScale, height: height / thumbScale, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width / thumbScale, height: height / thumbScale))
        result.append(Frame(time: time, grid: grid, thumb: small.makeImage()!))
    }
    return result
}

func distance(_ a: Frame, _ b: Frame) -> Double {
    var sum = 0
    for index in a.grid.indices { sum += abs(Int(a.grid[index]) - Int(b.grid[index])) }
    return Double(sum) / Double(max(a.grid.count, 1))
}

/// Grid cells (6 x 6 pixels) whose luminance differs by more than 8.
func changed(_ a: Frame, _ b: Frame) -> Int {
    a.grid.indices.filter { abs(Int(a.grid[$0]) - Int(b.grid[$0])) > 8 }.count
}

/// Thumbnails in rows of `columns`, each with a label under it.
func sheet(_ items: [(CGImage, String)], to file: URL, columns: Int = 12) {
    guard let first = items.first?.0 else { return }
    let w = first.width, h = first.height, label = 16, gap = 4
    let rows = (items.count + columns - 1) / columns
    let width = columns * (w + gap) + gap, height = rows * (h + label + gap) + gap
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
    for (index, item) in items.enumerated() {
        let x = gap + (index % columns) * (w + gap)
        let top = gap + (index / columns) * (h + label + gap)
        let y = height - top - h
        context.draw(item.0, in: CGRect(x: x, y: y, width: w, height: h))
        let text = NSAttributedString(string: item.1, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
        context.textPosition = CGPoint(x: x + 2, y: y - 13)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let all = try frames()
guard all.count > 1 else { fatalError("no frames") }
// Runs of the same picture: [start index, end index] with the time until the next picture.
var runs: [(start: Int, end: Int)] = []
for index in all.indices {
    if index > 0, distance(all[index], all[index - 1]) < 0.4, var last = runs.popLast() {
        last.end = index
        runs.append(last)
    } else {
        runs.append((index, index))
    }
}
/// How long a picture stayed; the last one stays until the recording ends (the recorder writes no frame while the
/// screen does not change), so it always counts as at rest.
func duration(_ run: (start: Int, end: Int)) -> Double {
    let next = run.end + 1 < all.count ? all[run.end + 1].time : all[run.end].time + 1
    return next - all[run.start].time
}
let restLimit = 0.08
var rests: [(CGImage, String)] = []
var motions: [[Frame]] = [], current: [Frame] = []
for run in runs {
    if duration(run) >= restLimit {
        if !current.isEmpty { motions.append(current); current = [] }
        rests.append((all[run.start].thumb, String(format: "%.2f %.2fs", all[run.start].time, duration(run))))
        // A slow change the mean misses (a segmented control's lens sliding, a counter ticking) shows as drift: the
        // run's last frame is drawn too, so the picture that actually stays is judged.
        let drift = changed(all[run.start], all[run.end])
        if drift > 24 { rests.append((all[run.end].thumb, String(format: "%.2f end", all[run.end].time))) }
        print(String(format: "rest   %7.3f  %5.2f s%@", all[run.start].time, duration(run), drift > 24 ? " (drift \(drift) cells)" : ""))
    } else {
        current += all[run.start...run.end]
    }
}
if !current.isEmpty { motions.append(current) }
sheet(rests, to: out.appendingPathComponent("rest.png"), columns: 8)
for (number, motion) in motions.enumerated() {
    let picked = motion.count <= 72 ? motion : (0..<72).map { motion[$0 * motion.count / 72] }
    sheet(picked.map { ($0.thumb, String(format: "%.3f", $0.time)) }, to: out.appendingPathComponent(String(format: "motion-%02d.png", number)))
    print(String(format: "motion %02d %7.3f-%7.3f  %3d frames", number, motion.first!.time, motion.last!.time, motion.count))
}
print("frames \(all.count), rests \(rests.count), motions \(motions.count), motion frames \(motions.map(\.count).reduce(0, +))")
