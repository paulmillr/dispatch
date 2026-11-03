import Foundation
import ImageIO

/// Header inspection and bounded image decoding. Callers keep separate memory policies: the Mac rejects canvases
/// past 64 MP and always draws a thumbnail; the phone downsamples past 40 MP and keeps smaller originals.
enum FilePreviewImage {
    /// The first frame's displayed size, including EXIF rotation. Inspecting a header never decodes its bitmap.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func isSafeSize(_ size: CGSize, dimensionLimit: Int, pixelLimit: Int? = nil) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= CGFloat(dimensionLimit), size.height <= CGFloat(dimensionLimit) else { return false }
        return pixelLimit.map { size.width * size.height <= CGFloat($0) } ?? true
    }

    /// The first frame rotated as it displays, with a hard long-side cap even if the requested size is larger.
    static func thumbnail(_ data: Data, maxPixels: Int?, dimensionLimit: Int) -> CGImage? {
        guard dimensionLimit > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let edge = min(dimensionLimit, max(1, maxPixels ?? dimensionLimit))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true,
                                      kCGImageSourceThumbnailMaxPixelSize: edge]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
