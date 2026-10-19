// Side-by-side images of the mockup's renders and the app's screenshots (docs/ios.md, Testing, Fidelity).
// usage: swiftc -O scripts/fidelity-pairs.swift -o build/fidelity-pairs
//        build/fidelity-pairs MOCKUP.png APP.png OUT.png [label]
// MOCKUP is a render from build/mockup-review (868 px wide at 2x: the caption above, the 402 x 874 pt phone at the
// bottom with 32 px margins); APP is a simulator screenshot of a 402 x 874 pt device at any scale. The phone is cut out
// of the render and both are drawn at 2x, mockup left, app right, with a 1 pt grid every 50 pt to read offsets.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(path)") }
    return image
}

let args = CommandLine.arguments
let mockup = load(args[1]), app = load(args[2])
let phone = CGSize(width: 804, height: 1748), gap = 24.0, header = 0.0
// The phone sits 32 px from the render's left and bottom edges.
let crop = CGRect(x: 32, y: mockup.height - 32 - Int(phone.height), width: Int(phone.width), height: Int(phone.height))
guard let cut = mockup.cropping(to: crop) else { fatalError("render too small") }
let width = Int(phone.width * 2 + gap), height = Int(phone.height + header)
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.interpolationQuality = .high
context.draw(cut, in: CGRect(x: 0, y: 0, width: phone.width, height: phone.height))
context.draw(app, in: CGRect(x: phone.width + gap, y: 0, width: phone.width, height: phone.height))
// Guides every 50 pt (100 px), faint, across both halves.
context.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.25))
context.setLineWidth(1)
for y in stride(from: 0.0, through: phone.height, by: 100) {
    context.move(to: CGPoint(x: 0, y: phone.height - y)); context.addLine(to: CGPoint(x: Double(width), y: phone.height - y))
}
context.strokePath()
let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(out, context.makeImage()!, nil)
guard CGImageDestinationFinalize(out) else { fatalError("cannot write \(args[3])") }
