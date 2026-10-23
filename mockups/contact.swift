// Contact sheet: contact <out.png> <label:shot.png>... Tiles the shots in a grid with labels.
// CONTACT_COLS (default 6) sets the columns, CONTACT_SCALE (default 0.25) the shot scale (1 for watch shots).
import AppKit
let args = CommandLine.arguments.dropFirst()
guard let out = args.first, args.count > 1 else { print("usage: contact <out.png> <label:shot.png>..."); exit(1) }
let items = args.dropFirst().map { $0.split(separator: ":", maxSplits: 1).map(String.init) }
let env = ProcessInfo.processInfo.environment
let scale = Double(env["CONTACT_SCALE"] ?? "") ?? 0.25, pad = 24.0, labelH = 28.0
let images = items.map { NSImage(contentsOfFile: $0[1])! }
let w = images[0].size.width * scale, h = images[0].size.height * scale
let cols = min(items.count, Int(env["CONTACT_COLS"] ?? "") ?? 6), rows = (items.count + cols - 1) / cols
let W = pad + Double(cols) * (w + pad), H = pad + Double(rows) * (h + labelH + pad)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
for (i, item) in items.enumerated() {
    let c = i % cols, r = i / cols
    let x = pad + Double(c) * (w + pad), y = H - pad - Double(r + 1) * (h + labelH + pad) + pad + labelH
    images[i].draw(in: NSRect(x: x, y: y, width: w, height: h))
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
    NSAttributedString(string: item[0], attributes: attrs).draw(at: NSPoint(x: x, y: y - labelH + 6))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
