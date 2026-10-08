// Kitty graphics state and execution (kitty/graphics_{exec,storage,image,animation,pixel}.zig):
// images and placements per screen, transmitting (chunked, from files or shared memory through the
// host), placing, deleting, animation frames and control, eviction at the byte limit, and
// placements following scrolls within margins. Replies are Ghostty's, word for word.

/// Platform services the core can't do itself (Ghostty's terminal/sys.zig + the medium reads):
/// nil = unsupported, with Ghostty's errors for that case.
public struct KittySystem {
    public struct Decoded { public var width: UInt32, height: UInt32, rgba: [UInt8]; public init(width: UInt32, height: UInt32, rgba: [UInt8]) { (self.width, self.height, self.rgba) = (width, height, rgba) } }
    /// PNG bytes -> straight RGBA8, nil when invalid.
    public var decodePNG: (([UInt8]) -> Decoded?)?
    /// zlib (RFC 1950) -> its bytes, at most `limit`; nil when invalid or larger.
    public var inflate: (([UInt8], Int) -> [UInt8]?)?
    public var media: KittyMedia?
    public init(decodePNG: (([UInt8]) -> Decoded?)? = nil, inflate: (([UInt8], Int) -> [UInt8]?)? = nil, media: KittyMedia? = nil) {
        (self.decodePNG, self.inflate, self.media) = (decodePNG, inflate, media)
    }
}

/// Reads a medium the way Ghostty does (graphics_image.zig readFile/readSharedMemory).
public protocol KittyMedia: AnyObject {
    /// A file's bytes (temporary: only inside the temp dirs, named for the protocol, then deleted).
    func file(_ path: [UInt8], temporary: Bool, offset: Int, size: Int, max: Int) throws(KittyError) -> [UInt8]
    /// A shared memory object's bytes in `range(size)`, then unlinked.
    func sharedMemory(_ name: [UInt8], _ range: (Int) throws(KittyError) -> Range<Int>) throws(KittyError) -> [UInt8]
}

public enum KittyError: Error {
    case insufficientData, invalidData, decompressionFailed, dimensionsRequired, dimensionsTooLarge, filePathTooLong
    case temporaryFileNotInTempDir, temporaryFileNotNamedCorrectly, unsupportedFormat, unsupportedMedium, unsupportedDepth, outOfMemory
    var message: String {
        switch self {
        case .outOfMemory: "ENOMEM: out of memory"
        case .insufficientData: "ENODATA: insufficient data"
        case .invalidData: "EINVAL: invalid data"
        case .decompressionFailed: "EINVAL: decompression failed"
        case .filePathTooLong: "EINVAL: file path too long"
        case .temporaryFileNotInTempDir: "EINVAL: temporary file not in temp dir"
        case .temporaryFileNotNamedCorrectly: "EINVAL: temporary file not named correctly"
        case .unsupportedFormat: "EINVAL: unsupported format"
        case .unsupportedMedium: "EINVAL: unsupported medium"
        case .unsupportedDepth: "EINVAL: unsupported pixel depth"
        case .dimensionsRequired: "EINVAL: dimensions required"
        case .dimensionsTooLarge: "EINVAL: dimensions too large"
        }
    }
    /// Per-command/source and decoded-pixel ceilings. The decoded limit is deliberately lower:
    /// RGB input otherwise briefly exists beside a larger RGBA copy and its GPU texture.
    public static let maxDimension: UInt32 = 4096
    public static let maxSize = 64 * 1024 * 1024
    public static let maxRGBABytes = 32 * 1024 * 1024
}

public struct KittyAnimation {
    public static let maxFrames = 1024
    public enum State: String { case stopped, loading, running }
    public struct Frame { public var data: [UInt8], gapMs: UInt32 }
    public var frames: [Frame] = [], rootGapMs: UInt32 = 0, currentIndex: UInt32 = 0, state = State.stopped
    public var maxLoops: UInt32 = 0, currentLoop: UInt32 = 0, frameShownAtMs: UInt64?
    static let defaultGapMs: UInt32 = 40
    var frameCount: UInt32 { UInt32(frames.count + 1) }
    func gap(_ i: UInt32) -> UInt32 { i == 0 ? rootGapMs : frames[Int(i) - 1].gapMs }
    mutating func setGap(_ i: UInt32, _ g: UInt32) { if i == 0 { rootGapMs = g } else { frames[Int(i) - 1].gapMs = g } }
    var durationMs: UInt64 { frames.reduce(UInt64(rootGapMs)) { $0 + UInt64($1.gapMs) } }
    var frameBytes: Int { frames.reduce(0) { $0 + $1.data.count } }
}

public struct KittyImage {
    public var id: UInt32 = 0, number: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0
    public var format = KittyFormat.rgb, zlib = false, data: [UInt8] = []
    public var transient = false, implicitID = false, placementCount: UInt32 = 0, generation: UInt64 = 0
    public var animation: KittyAnimation?
    var storageSize: Int { data.count + (animation?.frameBytes ?? 0) }
    /// Frame `n` (1: the image's own data).
    func frame(_ n: UInt32) -> [UInt8]? {
        if n == 1 { return data }
        guard n > 1, let a = animation, Int(n) - 2 < a.frames.count else { return nil }
        return a.frames[Int(n) - 2].data
    }
    /// The pixels to draw (the animation's current frame) as straight RGBA8: what the renderer
    /// uploads (Ghostty's renderData + Pending.convertCopy).
    public var rgba: [UInt8] { KittyPixels.rgba(format, animation.flatMap { $0.currentIndex > 0 ? $0.frames[Int($0.currentIndex) - 1].data : nil } ?? data) }
}

public struct KittyPlacementKey: Hashable {
    public var imageID: UInt32, external: Bool, id: UInt32
    func preferred(over o: KittyPlacementKey) -> Bool { external != o.external ? external : id < o.id }
}

public struct KittyPlacement {
    public enum Location { case pin(TrackedPin), virtual, relative(parent: KittyPlacementKey, horizontal: Int32, vertical: Int32) }
    public var location: Location
    public var xOffset: UInt32 = 0, yOffset: UInt32 = 0, sourceX: UInt32 = 0, sourceY: UInt32 = 0, sourceWidth: UInt32 = 0, sourceHeight: UInt32 = 0
    public var columns: UInt32 = 0, rows: UInt32 = 0, z: Int32 = 0

    var pin: TrackedPin? { if case .pin(let p) = location { p } else { nil } }

    public func sourceRect(_ img: KittyImage) -> (x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        let x = min(sourceX, img.width), y = min(sourceY, img.height)
        return (x, y, min(sourceWidth > 0 ? sourceWidth : img.width, img.width - x), min(sourceHeight > 0 ? sourceHeight : img.height, img.height - y))
    }

    static func cell(_ t: Terminal) -> (w: UInt32, h: UInt32) { (UInt32(t.widthPx / t.cols), UInt32(t.heightPx / t.rows)) }
    static func sat(_ a: UInt32, _ b: UInt32) -> UInt32 { let (m, o) = a.multipliedReportingOverflow(by: b); return o ? .max : m }
    static func scale(_ v: UInt32, _ num: UInt32, _ den: UInt32) -> UInt32 {
        den == 0 ? 0 : UInt32(clamping: (UInt64(v) * UInt64(num) + UInt64(den) / 2) / UInt64(den))
    }

    public func cellOffset(_ t: Terminal) -> (x: UInt32, y: UInt32) {
        let c = Self.cell(t)
        return (c.w > 0 ? min(xOffset, c.w - 1) : 0, c.h > 0 ? min(yOffset, c.h - 1) : 0)
    }

    public func pixelSize(_ img: KittyImage, _ t: Terminal) -> (width: UInt32, height: UInt32) {
        let src = sourceRect(img)
        if columns == 0, rows == 0 { return (src.width, src.height) }
        let c = Self.cell(t), off = cellOffset(t)
        if columns > 0, rows > 0 { return (subSat(Self.sat(c.w, columns), off.x), subSat(Self.sat(c.h, rows), off.y)) }
        if columns > 0 { let w = subSat(Self.sat(c.w, columns), off.x); return (w, Self.scale(w, src.height, src.width)) }
        let h = subSat(Self.sat(c.h, rows), off.y)
        return (Self.scale(h, src.width, src.height), h)
    }

    public func gridSize(_ img: KittyImage, _ t: Terminal) -> (cols: UInt32, rows: UInt32) {
        if columns > 0, rows > 0 { return (columns, rows) }
        let size = pixelSize(img, t), off = cellOffset(t), c = Self.cell(t)
        func ceil(_ a: UInt32, _ b: UInt32) -> UInt32 { b == 0 ? 0 : UInt32((UInt64(a) + UInt64(b) - 1) / UInt64(b)) }
        return (ceil(addSat(size.width, off.x), c.w), ceil(addSat(size.height, off.y), c.h))
    }

    mutating func clipTop(_ img: KittyImage, _ t: Terminal, _ count: UInt32, _ span: UInt32) -> Bool {
        let src = sourceRect(img)
        let crop = rows > 0 ? UInt32(UInt64(src.height) * UInt64(count) / UInt64(span)) : Self.sat(Self.cell(t).h, count)
        if crop >= src.height { return false }
        (sourceX, sourceY, sourceWidth, sourceHeight) = (src.x, src.y + crop, src.width, src.height - crop)
        if rows > 0 { rows -= count }
        return true
    }

    mutating func clipBottom(_ img: KittyImage, _ t: Terminal, _ count: UInt32, _ span: UInt32) -> Bool {
        let src = sourceRect(img)
        if src.height == 0 { return false }
        if rows > 0 {
            let crop = UInt32(UInt64(src.height) * UInt64(count) / UInt64(span))
            if crop >= src.height { return false }
            sourceHeight = src.height - crop
            rows -= count
        } else {
            let visible = Self.sat(Self.cell(t).h, span - count), off = cellOffset(t).y
            if visible <= off { return false }
            sourceHeight = min(src.height, visible - off)
        }
        (sourceX, sourceY, sourceWidth) = (src.x, src.y, src.width)
        return true
    }

    /// The cells it covers (pin placements only).
    func rect(_ img: KittyImage, _ t: Terminal) -> (topLeft: Pin, bottomRight: Pin)? {
        let g = gridSize(img, t)
        guard let tp = pin, !tp.pin.garbage, g.cols > 0, g.rows > 0 else { return nil }
        var br: Pin
        switch tp.pin.downOverflow(Int(g.rows) - 1) { case .offset(let p): br = p; case .overflow(let end, _): br = end }
        br.x = Int(min(addSat(UInt32(tp.pin.x), g.cols - 1), UInt32(t.cols) - 1))
        return (tp.pin, br)
    }
}

func addSat<T: FixedWidthInteger>(_ a: T, _ b: T) -> T { let (v, o) = a.addingReportingOverflow(b); return o ? (b < 0 ? .min : .max) : v }
func subSat<T: FixedWidthInteger & UnsignedInteger>(_ a: T, _ b: T) -> T { a > b ? a - b : 0 }

extension Pin {
    /// top <= self <= bottom, in screen order (PageList.Pin.isBetween).
    func isBetween(_ top: Pin, _ bottom: Pin) -> Bool {
        if page === top.page {
            if y < top.y { return false }
            if y > top.y { return page === bottom.page ? y <= bottom.y : true }
            if x < top.x { return false }
        }
        if page === bottom.page {
            if y > bottom.y { return false }
            if y < bottom.y { return true }
            return x <= bottom.x
        }
        if top.page === bottom.page { return false }
        var n = top.page.next
        while let p = n, p !== bottom.page { if p === page { return true }; n = p.next }
        return false
    }
}

/// An image being received (graphics_image.zig LoadingImage).
struct LoadingImage {
    var image: KittyImage, data: [UInt8] = [], display: KittyDisplay?, frame: (cmd: KittyFrameLoad, generation: UInt64)?, quiet: KittyQuiet, response: KittyResponse

    init(_ cmd: KittyCommand, _ sys: KittySystem) throws(KittyError) {
        let t = cmd.transmission!
        guard !t.formatUnknown else { throw .unsupportedFormat }
        image = KittyImage(id: t.imageID, number: t.imageNumber, width: t.width, height: t.height, format: t.format, zlib: t.zlib, transient: t.transient)
        display = if case .transmitAndDisplay(_, let d) = cmd.control { d } else { nil }
        (quiet, response) = (cmd.quiet, KittyResponse(id: t.imageID, number: t.imageNumber, placement: t.placementID))
        if t.medium == .direct { try addData(cmd.data); return }
        guard !(t.format == .png && sys.decodePNG == nil), let media = sys.media else { throw .unsupportedMedium }
        guard !cmd.data.contains(0) else { throw .invalidData }
        switch t.medium {
        case .file, .temporaryFile:
            data = try media.file(cmd.data, temporary: t.medium == .temporaryFile, offset: Int(t.offset), size: Int(t.size), max: KittyError.maxSize)
        default:
            let img = image
            data = try media.sharedMemory(cmd.data) { (stat: Int) throws(KittyError) -> Range<Int> in
                var expected: Int?
                if img.format != .png {
                    guard img.width <= KittyError.maxDimension, img.height <= KittyError.maxDimension else { throw .dimensionsTooLarge }
                    expected = Int(img.width) * Int(img.height) * img.format.bpp
                }
                let start = Int(t.offset)
                guard start <= stat else { throw .invalidData }
                let size = t.size > 0 ? Int(t.size) : !img.zlib && expected != nil ? expected! : stat - start
                guard size <= KittyError.maxSize, size <= stat - start else { throw .invalidData }
                return start..<start + size
            }
        }
    }

    mutating func addData(_ d: [UInt8]) throws(KittyError) {
        guard data.count + d.count <= KittyError.maxSize else { throw .invalidData }
        data += d
    }

    mutating func complete(_ sys: KittySystem) throws(KittyError) -> KittyImage {
        if image.zlib {
            guard let inflate = sys.inflate, let d = inflate(data, KittyError.maxSize) else { throw .decompressionFailed }
            (data, image.zlib) = (d, false)
        }
        if image.format == .png {
            guard let decode = sys.decodePNG else { throw .unsupportedFormat }
            guard let d = decode(data), d.rgba.count <= KittyError.maxRGBABytes else { throw .invalidData }
            (data, image.width, image.height, image.format) = (d.rgba, d.width, d.height, .rgba)
        }
        guard image.width > 0, image.height > 0 else { throw .dimensionsRequired }
        guard image.width <= KittyError.maxDimension, image.height <= KittyError.maxDimension else { throw .dimensionsTooLarge }
        guard KittyPixels.byteCount(image.width, image.height, 4, limit: KittyError.maxRGBABytes) != nil,
              let expected = KittyPixels.byteCount(image.width, image.height, image.format.bpp, limit: KittyError.maxSize) else {
            throw .dimensionsTooLarge
        }
        if frame != nil {
            guard data.count >= expected else { throw .insufficientData }
            data.removeLast(data.count - expected)
        } else if data.count != expected { throw .invalidData }
        var result = image
        (result.data, data, image) = (data, [], KittyImage())
        return result
    }
}

enum KittyPixels {
    static func byteCount(_ width: UInt32, _ height: UInt32, _ bpp: Int, limit: Int) -> Int? {
        let (pixels, pixelOverflow) = Int(width).multipliedReportingOverflow(by: Int(height))
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bpp)
        return pixelOverflow || byteOverflow || bytes > limit ? nil : bytes
    }

    static func rgba(_ f: KittyFormat, _ d: [UInt8]) -> [UInt8] {
        guard f != .rgba else { return d }
        let bpp = f.bpp
        var out: [UInt8] = []
        out.reserveCapacity(d.count / bpp * 4)
        for i in stride(from: 0, to: d.count - d.count % bpp, by: bpp) {
            switch f {
            case .rgb: out += [d[i], d[i + 1], d[i + 2], 255]
            case .gray: out += [d[i], d[i], d[i], 255]
            default: out += [d[i], d[i], d[i], d[i + 1]]
            }
        }
        return out
    }

    /// Y: 0 fills transparent black, otherwise R, G, B, A from 0xRRGGBBAA.
    static func fill(_ count: Int, _ bg: UInt32) -> [UInt8] {
        (0..<count / 4).flatMap { _ in [UInt8(bg >> 24 & 255), UInt8(bg >> 16 & 255), UInt8(bg >> 8 & 255), UInt8(bg & 255)] } + [UInt8](repeating: 0, count: count % 4)
    }

    /// One pixel over another, straight alpha (wuffs' nonpremul src-over, 16-bit math).
    static func over(_ d: inout [UInt8], _ di: Int, _ s: [UInt8], _ si: Int) {
        let da0 = 0x101 * UInt32(d[di + 3])
        if da0 == 0 { for k in 0..<4 { d[di + k] = s[si + k] }; return }
        var c = (0..<3).map { 0x101 * UInt32(d[di + $0]) * da0 / 0xFFFF }
        let sa = 0x101 * UInt32(s[si + 3]), ia = 0xFFFF - sa
        let da = sa + da0 * ia / 0xFFFF
        c = (0..<3).map { (0x101 * UInt32(s[si + $0]) * sa + c[$0] * ia) / 0xFFFF }
        if da != 0 { c = c.map { $0 * 0xFFFF / da } }
        for k in 0..<3 { d[di + k] = UInt8(truncatingIfNeeded: c[k] >> 8) }
        d[di + 3] = UInt8(truncatingIfNeeded: da >> 8)
    }

    static func row(_ d: inout [UInt8], _ di: Int, _ s: [UInt8], _ si: Int, _ width: Int, _ overwrite: Bool) {
        if overwrite { d.replaceSubrange(di..<di + width * 4, with: s[si..<si + width * 4]); return }
        for i in 0..<width { over(&d, di + i * 4, s, si + i * 4) }
    }

    /// `src` (srcW x srcH) onto `dst` (dstW x dstH) at x, y, clipped.
    static func compose(_ dst: inout [UInt8], _ dstW: UInt32, _ dstH: UInt32, _ src: [UInt8], _ srcW: UInt32, _ srcH: UInt32, _ x: UInt32, _ y: UInt32, _ overwrite: Bool) {
        guard x < dstW, y < dstH else { return }
        let w = Int(min(srcW, dstW - x)), h = Int(min(srcH, dstH - y))
        for r in 0..<h { row(&dst, ((Int(y) + r) * Int(dstW) + Int(x)) * 4, src, r * Int(srcW) * 4, w, overwrite) }
    }
}

/// One screen's images and placements (graphics_storage.zig ImageStorage).
public final class ImageStorage {
    /// A session can hold at most this much decoded image data, regardless of config input.
    public static let defaultTotalLimit = 64 * 1024 * 1024
    public static let maxImages = 1024, maxPlacements = 1024
    public internal(set) var images: [UInt32: KittyImage] = [:], placements: [KittyPlacementKey: KittyPlacement] = [:]
    var loading: LoadingImage?
    public internal(set) var totalBytes = 0
    var totalLimit = ImageStorage.defaultTotalLimit
    /// Bumped on every change (renderers key their caches off it).
    public internal(set) var generation: UInt64 = 0
    var nextImageID: UInt32 = 2147483647, nextInternalPlacement: UInt32 = 0

    public var isLoading: Bool { loading != nil }

    func reset(_ s: Screen) {
        for p in placements.values { if let t = p.pin { s.pages.untrack(t) } }
        (images, placements, loading, totalBytes, nextImageID, nextInternalPlacement) = ([:], [:], nil, 0, 2147483647, 0)
        markMutated()
    }

    func markMutated() { generation += 1 }
    func contentChanged(_ id: UInt32) { markMutated(); images[id]?.generation = generation }

    func nextID(implicit: Bool) -> UInt32 {
        var id: UInt32 = implicit ? nextImageID : 1
        for _ in 0..<images.count + 2 { if id != 0, images[id] == nil { break }; id &+= 1 }
        if id == 0 { id = 1 }
        if implicit { nextImageID = id &+ 1 }
        return id
    }

    func imageByNumber(_ n: UInt32) -> KittyImage? { images.values.filter { $0.number == n }.max { $0.generation < $1.generation } }
    func imageID(_ id: UInt32, _ number: UInt32) -> UInt32? { id != 0 ? (images[id] == nil ? nil : id) : imageByNumber(number)?.id }

    func addImage(_ s: Screen, _ img: KittyImage) throws(KittyError) {
        guard images[img.id] != nil || images.count < Self.maxImages else { throw .outOfMemory }
        let new = img.data.count
        guard new <= totalLimit else { throw .outOfMemory }
        let old = images[img.id]?.storageSize ?? 0
        let total = totalBytes - old + new
        if total > totalLimit, !evict(s, total - totalLimit, except: img.id) { throw .outOfMemory }
        if let prev = images[img.id] {
            removePlacements(s, image: img.id)
            removeOrphans(s, deleteUnused: false)
            totalBytes -= prev.storageSize
        }
        var stored = img
        stored.placementCount = 0
        totalBytes += new
        markMutated()
        stored.generation = generation
        images[img.id] = stored
    }

    func addPlacement(_ s: Screen, _ imageID: UInt32, _ placementID: UInt32, _ p: KittyPlacement) throws(KittyError) {
        let key: KittyPlacementKey
        if placementID == 0 { key = .init(imageID: imageID, external: false, id: nextInternalPlacement); nextInternalPlacement &+= 1 } else {
            key = .init(imageID: imageID, external: true, id: placementID)
        }
        if placements[key] == nil, placements.count >= Self.maxPlacements {
            reapGarbage(s)
            guard placements.count < Self.maxPlacements else { throw .outOfMemory }
        }
        if let old = placements[key] { if let t = old.pin { s.pages.untrack(t) } } else {
            images[imageID]!.placementCount += 1
        }
        placements[key] = p
        markMutated()
    }

    func removePlacement(_ s: Screen, _ key: KittyPlacementKey) {
        guard let p = placements.removeValue(forKey: key) else { return }
        if let t = p.pin { s.pages.untrack(t) }
        images[key.imageID]!.placementCount -= 1
    }

    func removePlacements(_ s: Screen, image: UInt32) { for k in placements.keys where k.imageID == image { removePlacement(s, k) } }

    func reapGarbage(_ s: Screen) {
        let dead = placements.filter { $0.value.pin?.pin.garbage == true }.keys
        guard !dead.isEmpty else { return }
        for k in dead { removePlacement(s, k) }
        removeOrphans(s, deleteUnused: false)
        markMutated()
    }

    /// Relative placements whose parent is gone go too, until none is left.
    @discardableResult func removeOrphans(_ s: Screen, deleteUnused: Bool) -> Bool {
        var any = false
        while true {
            let orphans = placements.filter { if case .relative(let parent, _, _) = $0.value.location { placements[parent] == nil } else { false } }.keys
            if orphans.isEmpty { return any }
            for k in orphans { removePlacement(s, k); any = true; if deleteUnused { deleteIfUnused(k.imageID) } }
        }
    }

    func deleteIfUnused(_ id: UInt32) {
        guard let img = images[id], img.placementCount == 0 else { return }
        totalBytes -= img.storageSize
        images[id] = nil
    }

    enum ParentError: Error { case imageNotFound, placementNotFound, selfParent, cycle, tooDeep, ancestorNotFound }
    static let chainLimit = 8

    func resolveParent(_ s: Screen, child: KittyPlacementKey?, _ image: UInt32, _ placement: UInt32) throws(ParentError) -> KittyPlacementKey {
        reapGarbage(s)
        guard images[image] != nil else { throw .imageNotFound }
        let parent: KittyPlacementKey
        if placement > 0 {
            parent = .init(imageID: image, external: true, id: placement)
            guard placements[parent] != nil else { throw .placementNotFound }
        } else {
            guard let best = placements.keys.filter({ $0.imageID == image }).min(by: { $0.preferred(over: $1) }) else { throw .placementNotFound }
            parent = best
        }
        if parent == child { throw .selfParent }
        var (depth, key) = (1, parent)
        while true {
            if key == child { throw .cycle }
            guard let p = placements[key] else { throw .ancestorNotFound }
            guard case .relative(let next, _, _) = p.location else { break }
            if depth >= Self.chainLimit { throw .tooDeep }
            (depth, key) = (depth + 1, next)
        }
        return parent
    }

    /// A relative placement's root (a pin or virtual placement) and the summed offsets.
    public func resolveChain(_ parent: KittyPlacementKey, _ h: Int32, _ v: Int32) -> (key: KittyPlacementKey, root: KittyPlacement, horizontal: Int32, vertical: Int32)? {
        var (h, v, key, depth) = (h, v, parent, 1)
        while true {
            guard let p = placements[key] else { return nil }
            guard case .relative(let next, let ph, let pv) = p.location else { return (key, p, h, v) }
            if depth >= Self.chainLimit { return nil }
            (depth, h, v, key) = (depth + 1, addSat(h, ph), addSat(v, pv), next)
        }
    }

    func evict(_ s: Screen, _ req: Int, except: UInt32?) -> Bool {
        let before = images.count
        defer { if images.count != before { removeOrphans(s, deleteUnused: false); markMutated() } }
        var evicted = 0
        while evicted < req {
            func rank(_ i: KittyImage) -> (Int, UInt64, UInt32) { ((i.transient ? 0 : 1) + (i.placementCount > 0 ? 2 : 0), i.generation, i.id) }
            guard let c = images.values.filter({ $0.id != except }).min(by: { rank($0) < rank($1) }) else { return false }
            removePlacements(s, image: c.id)
            evicted += c.storageSize
            totalBytes -= c.storageSize
            images[c.id] = nil
        }
        return true
    }

    func convertToRGBA(_ s: Screen, _ id: UInt32) throws(KittyError) {
        guard var img = images[id], img.format != .rgba else { return }
        let rgba = KittyPixels.rgba(img.format, img.data)
        guard rgba.count <= KittyError.maxRGBABytes else { throw .outOfMemory }
        try reserve(s, id, rgba.count - img.data.count)
        (img.data, img.format) = (rgba, .rgba)
        images[id] = img
        contentChanged(id)
    }

    func reserve(_ s: Screen, _ id: UInt32, _ bytes: Int) throws(KittyError) {
        guard bytes <= totalLimit else { throw .outOfMemory }
        let total = totalBytes + bytes
        if total > totalLimit {
            let req = total - totalLimit
            guard req <= totalLimit, evict(s, req, except: id) else { throw .outOfMemory }
        }
        totalBytes += bytes
    }

    /// Advances running animations to `now`; the delay until the next frame change.
    public func animationTick(_ now: UInt64) -> UInt64? {
        var minDelay: UInt64?
        for id in images.keys {
            guard var a = images[id]!.animation, a.state != .stopped, !a.frames.isEmpty, images[id]!.placementCount > 0, a.durationMs > 0,
                  a.maxLoops == 0 || a.currentLoop < a.maxLoops else { continue }
            let shown = min(a.frameShownAtMs ?? now, now)
            a.frameShownAtMs = shown
            var next = addSat(shown, UInt64(a.gap(a.currentIndex)))
            var changed = false
            if now >= next {
                var i = a.currentIndex
                advance: while true {
                    let n = (i + 1) % a.frameCount
                    if n == 0 {
                        if a.state == .loading { break advance }
                        a.currentLoop += 1
                        if a.maxLoops > 0, a.currentLoop >= a.maxLoops { break advance }
                    }
                    i = n
                    if a.gap(i) != 0 { (a.currentIndex, a.frameShownAtMs, changed) = (i, now, true); next = addSat(now, UInt64(a.gap(i))); break }
                }
            }
            images[id]!.animation = a
            if changed { contentChanged(id) }
            if next > now { minDelay = min(minDelay ?? .max, next - now) }
        }
        return minDelay
    }
}

extension ImageStorage {
    typealias Delete = KittyDelete

    /// ED 2/3 and scroll-clear: visible placements go, and images nothing shows any more.
    func clearScreen(_ t: Terminal) {
        let (p, i) = (placements.count, images.count)
        deleteVisible(t, deleteUnused: true)
        removeOrphans(t.active, deleteUnused: false)
        for id in images.keys { deleteIfUnused(id) }
        if placements.count != p || images.count != i { markMutated() }
    }

    func deleteVisible(_ t: Terminal, deleteUnused: Bool) {
        let s = t.active
        for (k, p) in placements {
            guard let tp = p.pin, !tp.pin.garbage else { continue }
            if s.pages.point(.active, tp.pin) == nil {
                guard let img = images[k.imageID], let r = p.rect(img, t), s.pages.point(.active, r.bottomRight) != nil else { continue }
            }
            removePlacement(s, k)
            if deleteUnused { deleteIfUnused(k.imageID) }
        }
    }

    func deleteByID(_ s: Screen, _ id: UInt32, _ placement: UInt32, _ images: Bool) {
        var matched = placement == 0
        if placement == 0 { removePlacements(s, image: id) } else if placements[.init(imageID: id, external: true, id: placement)] != nil {
            removePlacement(s, .init(imageID: id, external: true, id: placement))
            matched = true
        }
        if images, matched { deleteIfUnused(id) }
    }

    func deleteIntersecting(_ t: Terminal, x: Int, y: Int, _ deleteUnused: Bool, z: Int32? = nil) {
        guard let target = t.active.pages.pin(.active, x: x, y: y) else { return }
        for (k, p) in placements {
            guard let img = images[k.imageID], let r = p.rect(img, t), target.x >= r.topLeft.x, target.x <= r.bottomRight.x else { continue }
            var row = target
            row.x = r.topLeft.x
            guard row.isBetween(r.topLeft, r.bottomRight), z == nil || p.z == z else { continue }
            removePlacement(t.active, k)
            if deleteUnused { deleteIfUnused(img.id) }
        }
    }

    func delete(_ t: Terminal, _ d: Delete) {
        let s = t.active, (p0, i0) = (placements.count, images.count)
        defer { if placements.count != p0 || images.count != i0 { markMutated() } }
        let cell: (Int, Int)? = d.x > 0 && d.y > 0 && d.x - 1 < UInt32(UInt16.max) + 1 && d.y - 1 < UInt32(UInt16.max) + 1 ? (Int(d.x) - 1, Int(d.y) - 1) : nil
        switch d.what {
        case 0x61: deleteVisible(t, deleteUnused: d.images)
        case 0x69: deleteByID(s, d.imageID, d.placementID, d.images)
        case 0x6E: if let img = imageByNumber(d.imageNumber) { deleteByID(s, img.id, d.placementID, d.images) }
        case 0x63: deleteIntersecting(t, x: s.cursor.x, y: s.cursor.y, d.images)
        case 0x70: if let (x, y) = cell { deleteIntersecting(t, x: x, y: y, d.images) }
        case 0x71: if let (x, y) = cell { deleteIntersecting(t, x: x, y: y, d.images, z: d.z) }
        case 0x78:
            guard d.x > 0 else { break }
            let x = Int(d.x) - 1
            for (k, p) in placements {
                guard let img = images[k.imageID], let r = p.rect(img, t), r.topLeft.x <= x, r.bottomRight.x >= x else { continue }
                removePlacement(s, k)
                if d.images { deleteIfUnused(img.id) }
            }
        case 0x79:
            guard d.y > 0, d.y - 1 <= UInt32(UInt16.max), let target = s.pages.pin(.active, y: Int(d.y) - 1) else { break }
            for (k, p) in placements {
                guard let img = images[k.imageID], let r = p.rect(img, t) else { continue }
                var row = target
                row.x = r.topLeft.x
                guard row.isBetween(r.topLeft, r.bottomRight) else { continue }
                removePlacement(s, k)
                if d.images { deleteIfUnused(img.id) }
            }
        case 0x7A:
            for (k, p) in placements where p.z == d.z {
                if case .virtual = p.location { continue }
                removePlacement(s, k)
                if d.images { deleteIfUnused(k.imageID) }
            }
        case 0x72:
            let (first, last) = (d.x, d.y)
            guard last != 0, first <= last else { break }
            for k in placements.keys where k.imageID >= first && k.imageID <= last { removePlacement(s, k) }
            if d.images { for id in images.keys where id >= first && id <= last { deleteIfUnused(id) } }
        default: deleteFrame(s, d)
        }
        removeOrphans(s, deleteUnused: d.images)
    }

    func deleteFrame(_ s: Screen, _ d: Delete) {
        guard d.imageID != 0 || d.imageNumber != 0, let id = imageID(d.imageID, d.imageNumber), var img = images[id] else { return }
        guard var a = img.animation, !a.frames.isEmpty else {
            guard d.images else { return }
            removePlacements(s, image: id)
            totalBytes -= img.storageSize
            images[id] = nil
            return
        }
        var n = min(d.frame, a.frameCount)
        if n == 0 { n = 1 }
        if n == 1 {
            totalBytes -= img.data.count
            let f = a.frames.removeFirst()
            (img.data, a.rootGapMs) = (f.data, f.gapMs)
        } else {
            totalBytes -= a.frames.remove(at: Int(n) - 2).data.count
        }
        let removed: UInt32 = n == 1 ? 0 : n - 2, remaining = UInt32(a.frames.count)
        var changed = false
        if a.currentIndex > remaining { (a.currentIndex, a.frameShownAtMs, changed) = (remaining, nil, true) } else if removed == a.currentIndex {
            (a.frameShownAtMs, changed) = (nil, true)
        } else if removed < a.currentIndex { a.currentIndex -= 1 }
        img.animation = a
        images[id] = img
        if changed { contentChanged(id) } else { markMutated() }
    }

    /// Scrolls within margins move the placements they carry (clipping at the margins, dropping
    /// what leaves); `end` re-anchors them after the rows moved.
    func scrollMarginsBegin(_ t: Terminal, _ delta: Int, inPlace: Bool) -> [(TrackedPin, Int, Int)] {
        let s = t.active, region = t.scrollingRegion
        var (restores, mutated) = ([(TrackedPin, Int, Int)](), false)
        for (k, var p) in placements {
            guard let tp = p.pin, !tp.pin.garbage, let c = s.pages.point(.active, tp.pin) else { continue }
            let y = c.y
            if inPlace, y < region.top || y > region.bottom { continue }
            var finalY = y
            inside: if let img = images[k.imageID] {
                let g = p.gridSize(img, t)
                guard g.rows > 0, g.cols > 0, y >= region.top, y + Int(g.rows) - 1 <= region.bottom,
                      c.x >= region.left, min(c.x + Int(g.cols) - 1, t.cols - 1) <= region.right else { break inside }
                let newY = y + delta, rows = Int(g.rows)
                let topClip = max(0, region.top - newY), bottomClip = max(0, newY + rows - 1 - region.bottom)
                var visible = topClip < rows && bottomClip < rows
                if visible, topClip > 0 {
                    visible = p.clipTop(img, t, UInt32(topClip), g.rows)
                    if visible { (mutated, finalY) = (true, region.top); placements[k] = p }
                } else if visible {
                    if bottomClip > 0 {
                        visible = p.clipBottom(img, t, UInt32(bottomClip), g.rows)
                        if visible { mutated = true; placements[k] = p }
                    }
                    if visible { finalY = newY }
                }
                if !visible { removePlacement(s, k); mutated = true; continue }
            }
            restores.append((tp, tp.pin.x, finalY))
        }
        if mutated { removeOrphans(s, deleteUnused: false); markMutated() }
        return restores
    }

    static func scrollMarginsEnd(_ s: Screen, _ restores: [(TrackedPin, Int, Int)]) {
        for (tp, x, y) in restores { if let p = s.pages.pin(.active, x: x, y: y) { tp.pin = p } }
    }
}

extension Terminal {
    /// Runs a kitty graphics command (graphics_exec.zig execute); the reply, if any.
    func kittyGraphics(_ cmd: KittyCommand) -> KittyResponse? {
        let st = active.images
        guard st.totalLimit != 0 else { return nil }
        var quiet = cmd.quiet
        let ids = cmd.identifiers
        if ids.id > 0, ids.number > 0 {
            return quiet == .failures ? nil : KittyResponse(id: ids.id, number: ids.number, placement: ids.placement, message: "EINVAL: image ID and number are mutually exclusive")
        }
        let r: KittyResponse
        switch cmd.control {
        case .query(let t): r = kittyQuery(cmd, t)
        case .display(let d): r = kittyDisplay(d)
        case .delete(let d): st.loading = nil; st.delete(self, d); r = KittyResponse()
        case .transmit, .transmitAndDisplay, .frame:
            if st.loading != nil { if cmd.quiet == .no { quiet = st.loading!.quiet } else { st.loading!.quiet = cmd.quiet } }
            if case .frame = cmd.control { r = kittyFrame(cmd) } else { r = kittyTransmit(cmd) }
        case .control(let a): r = kittyControl(a)
        case .compose(let c): r = kittyCompose(c)
        }
        switch quiet {
        case .no: return r.empty ? nil : r
        case .ok: return r.ok ? nil : r
        case .failures: return nil
        }
    }

    private func kittyQuery(_ cmd: KittyCommand, _ t: KittyTransmission) -> KittyResponse {
        guard t.imageID != 0 else { return KittyResponse(message: "EINVAL: image ID required") }
        var r = KittyResponse(id: t.imageID, number: t.imageNumber, placement: t.placementID)
        do {
            var l = try LoadingImage(cmd, kittySystem)
            _ = try l.complete(kittySystem)
        } catch { r.message = error.message }
        return r
    }

    private func kittyTransmit(_ cmd: KittyCommand) -> KittyResponse {
        let t = cmd.transmission!, st = active.images
        var r: KittyResponse
        if let l = st.loading {
            if l.frame != nil { return kittyFrame(cmd) }
            r = l.response
        } else { r = KittyResponse(id: t.imageID, number: t.imageNumber, placement: t.placementID) }
        let img: KittyImage, display: KittyDisplay?
        do {
            var l: LoadingImage
            if var loading = st.loading {
                try loading.addData(cmd.data)
                st.loading = loading
                if t.moreChunks { return KittyResponse() }
                (l, st.loading) = (loading, nil)
            } else {
                if t.imageID > 0 { st.delete(self, KittyDelete(what: 0x69, images: true, imageID: t.imageID, imageNumber: 0, placementID: 0, x: 0, y: 0, z: 0, frame: 0)) }
                l = try LoadingImage(cmd, kittySystem)
            }
            if l.image.id == 0 {
                l.image.id = st.nextID(implicit: l.image.number == 0)
                l.image.implicitID = l.image.number == 0
            }
            if t.moreChunks { st.loading = l; return KittyResponse() }
            var completed = try l.complete(kittySystem)
            if completed.format != .rgba {
                completed.data = KittyPixels.rgba(completed.format, completed.data)
                completed.format = .rgba
            }
            img = completed
            try st.addImage(active, img)
            display = l.display
        } catch { r.message = error.message; return r }
        if var d = display { d.imageID = img.id; r = kittyDisplay(d) }
        if img.implicitID { return KittyResponse() }
        r.id = img.id
        return r
    }

    func kittyDisplay(_ d: KittyDisplay) -> KittyResponse {
        guard d.imageID != 0 || d.imageNumber != 0 else { return KittyResponse(message: "EINVAL: image ID or number required") }
        var r = KittyResponse(id: d.imageID, number: d.imageNumber, placement: d.placementID)
        if d.virtual, d.parentID > 0 { r.message = "EINVAL: virtual placement cannot refer to a parent"; return r }
        let s = active, st = s.images
        guard let img = d.imageID != 0 ? st.images[d.imageID] : st.imageByNumber(d.imageNumber) else { r.message = "ENOENT: image not found"; return r }
        r.id = img.id
        let location: KittyPlacement.Location
        if d.virtual { location = .virtual } else if d.parentID == 0 { location = .pin(s.pages.track(s.pin)) } else {
            let child = d.placementID > 0 ? KittyPlacementKey(imageID: img.id, external: true, id: d.placementID) : nil
            do {
                location = .relative(parent: try st.resolveParent(s, child: child, d.parentID, d.parentPlacementID), horizontal: d.horizontalOffset, vertical: d.verticalOffset)
            } catch {
                r.message = [.imageNotFound: "ENOPARENT: parent image not found", .placementNotFound: "ENOPARENT: parent placement not found",
                             .selfParent: "EINVAL: placement cannot be its own parent", .cycle: "ECYCLE: parent chain creates a cycle",
                             .tooDeep: "ETOODEEP: parent chain too deep", .ancestorNotFound: "ENOENT: parent chain ancestor not found"][error]!
                return r
            }
        }
        var p = KittyPlacement(location: location, xOffset: d.xOffset, yOffset: d.yOffset, sourceX: d.x, sourceY: d.y, sourceWidth: d.width, sourceHeight: d.height,
                               columns: d.columns, rows: d.rows, z: d.z)
        let off = p.cellOffset(self)
        if widthPx / cols > 0 { p.xOffset = off.x }
        if heightPx / rows > 0 { p.yOffset = off.y }
        do { try st.addPlacement(s, img.id, r.placement, p) } catch {
            if let t = p.pin { s.pages.untrack(t) }
            r.message = error.message
            return r
        }
        if let tp = p.pin, d.moveCursor {
            let g = p.gridSize(img, self), targetX = tp.pin.x + Int(g.cols)
            let wraps = targetX >= cols
            let requested = Int(subSat(g.rows, 1)) + (wraps ? 1 : 0)
            let region = scrollingRegion
            let before = cursor.y >= region.top && cursor.y <= region.bottom && cursor.x >= region.left && cursor.x <= region.right ? region.bottom - cursor.y : 0
            for _ in 0..<min(requested, before + rows) { index() }
            active.cursor.pendingWrap = false
            active.cursorHorizontalAbsolute(wraps ? 0 : targetX)
        }
        return r
    }

    private func kittyFrame(_ cmd: KittyCommand) -> KittyResponse {
        let st = active.images
        if var l = st.loading {
            if l.frame == nil { return kittyTransmit(cmd) }
            var r = l.response
            do { try l.addData(cmd.data) } catch { r.message = error.message; return r }
            st.loading = l
            if cmd.transmission!.moreChunks { return KittyResponse() }
            st.loading = nil
            return kittyCompleteFrame(&l)
        }
        guard case .frame(let f) = cmd.control else { return KittyResponse() }
        let t = f.transmission
        var r = KittyResponse(id: t.imageID, number: t.imageNumber, placement: t.placementID, frame: f.editFrame)
        guard t.imageID != 0 || t.imageNumber != 0 else { r.message = "EINVAL: image ID or number required"; return r }
        guard let id = st.imageID(t.imageID, t.imageNumber) else { r.message = "ENOENT: image not found"; return r }
        r.id = id
        var l: LoadingImage
        do { l = try LoadingImage(cmd, kittySystem) } catch { r.message = error.message; return r }
        l.frame = (f, st.images[id]!.generation)
        l.response.id = id
        if t.moreChunks { st.loading = l; return KittyResponse() }
        return kittyCompleteFrame(&l)
    }

    private func kittyCompleteFrame(_ l: inout LoadingImage) -> KittyResponse {
        let s = active, st = s.images
        var r = l.response
        let f = l.frame!.cmd
        guard let id = st.imageID(l.image.id, l.image.number), st.images[id]!.generation == l.frame!.generation else { r.message = "ENOENT: image not found"; return r }
        var frame: KittyImage
        do { frame = try l.complete(kittySystem) } catch { r.message = error.message; return r }
        let img0 = st.images[id]!
        guard frame.width <= img0.width, frame.height <= img0.height else { r.message = "EINVAL: frame dimensions exceed image"; return r }
        if frame.format != .rgba { frame.data = KittyPixels.rgba(frame.format, frame.data) }
        do { try st.convertToRGBA(s, id) } catch { r.message = "ENOSPC: image storage full"; return r }
        var img = st.images[id]!
        var a = img.animation ?? KittyAnimation()
        let count = a.frameCount
        let number = f.editFrame == 0 || f.editFrame > count + 1 ? count + 1 : f.editFrame
        r.frame = number
        if number == count + 1 {
            guard a.frames.count < KittyAnimation.maxFrames else { r.message = "ENOSPC: animation frame storage full"; return r }
            let gap: UInt32 = f.gap > 0 ? UInt32(f.gap) : f.gap < 0 ? 0 : KittyAnimation.defaultGapMs
            if f.createFrame > 0, img.frame(f.createFrame) == nil { st.images[id]!.animation = a; r.message = "EINVAL: base frame not found"; return r }
            let len = Int(img.width) * Int(img.height) * 4
            st.images[id]!.animation = a
            do { try st.reserve(s, id, len) } catch { r.message = "ENOSPC: animation frame storage full"; return r }
            img = st.images[id]!
            a = img.animation!
            var canvas = f.createFrame > 0 ? img.frame(f.createFrame)! : KittyPixels.fill(len, f.background)
            KittyPixels.compose(&canvas, img.width, img.height, frame.data, frame.width, frame.height, f.x, f.y, f.overwrite)
            a.frames.append(.init(data: canvas, gapMs: gap))
            st.images[id]!.animation = a
            st.markMutated()
        } else {
            if f.gap != 0 { a.setGap(number - 1, f.gap > 0 ? UInt32(f.gap) : 0) }
            var dst = img.frame(number)!
            KittyPixels.compose(&dst, img.width, img.height, frame.data, frame.width, frame.height, f.x, f.y, f.overwrite)
            if number == 1 { img.data = dst } else { a.frames[Int(number) - 2].data = dst }
            let current = number - 1 == a.currentIndex
            if current { a.frameShownAtMs = nil }
            img.animation = a
            st.images[id] = img
            if current { st.contentChanged(id) } else { st.markMutated() }
        }
        return r
    }

    private func kittyControl(_ c: KittyAnimationControl) -> KittyResponse {
        let st = active.images
        var r = KittyResponse(id: c.imageID, number: c.imageNumber, placement: c.placementID)
        guard c.imageID != 0 || c.imageNumber != 0 else { r.message = "EINVAL: image ID or number required"; return r }
        guard let id = st.imageID(c.imageID, c.imageNumber) else { r.message = "ENOENT: image not found"; return r }
        var a = st.images[id]!.animation ?? KittyAnimation()
        var (mutated, changed) = (false, false)
        if c.frame != 0, c.frame <= a.frameCount, c.gap != 0 { a.setGap(c.frame - 1, c.gap > 0 ? UInt32(c.gap) : 0); mutated = true }
        if c.currentFrame != 0, c.currentFrame <= a.frameCount, c.currentFrame - 1 != a.currentIndex {
            (a.currentIndex, a.frameShownAtMs, changed) = (c.currentFrame - 1, nil, true)
        }
        if c.action != .invalid {
            let old = a.state
            a.state = [.stop: .stopped, .runWait: .loading, .run: .running][c.action]!
            if old == .stopped, a.state != .stopped { a.frameShownAtMs = nil }
            a.currentLoop = 0
            mutated = true
        }
        if c.loops != 0 { a.maxLoops = c.loops - 1; mutated = true }
        st.images[id]!.animation = a
        // In Ghostty's order: the gap, the current frame, then the state and loops.
        if changed { st.contentChanged(id) }
        if mutated { st.markMutated() }
        return KittyResponse()
    }

    private func kittyCompose(_ c: KittyCompose) -> KittyResponse {
        let st = active.images
        var r = KittyResponse(id: c.imageID, number: c.imageNumber, placement: c.placementID)
        guard c.imageID != 0 || c.imageNumber != 0 else { r.message = "EINVAL: image ID or number required"; return r }
        guard let id = st.imageID(c.imageID, c.imageNumber) else { r.message = "ENOENT: image not found"; return r }
        r.id = id
        let img0 = st.images[id]!
        guard img0.frame(c.sourceFrame) != nil else { r.message = "ENOENT: source frame not found"; return r }
        guard img0.frame(c.destFrame) != nil else { r.message = "ENOENT: destination frame not found"; return r }
        let w = UInt64(c.width > 0 ? c.width : img0.width), h = UInt64(c.height > 0 ? c.height : img0.height)
        guard UInt64(c.x) + w <= img0.width, UInt64(c.y) + h <= img0.height else { r.message = "EINVAL: destination rectangle out of bounds"; return r }
        guard UInt64(c.leftEdge) + w <= img0.width, UInt64(c.topEdge) + h <= img0.height else { r.message = "EINVAL: source rectangle out of bounds"; return r }
        if c.sourceFrame == c.destFrame, UInt64(max(c.leftEdge, c.x)) < UInt64(min(c.leftEdge, c.x)) + w, UInt64(max(c.topEdge, c.y)) < UInt64(min(c.topEdge, c.y)) + h {
            r.message = "EINVAL: source and destination rectangles overlap"
            return r
        }
        do { try st.convertToRGBA(active, id) } catch { r.message = "ENOSPC: image storage full"; return r }
        var img = st.images[id]!
        let src = img.frame(c.sourceFrame)!
        var dst = img.frame(c.destFrame)!
        let cw = Int(img.width)
        for row in 0..<Int(h) {
            KittyPixels.row(&dst, ((Int(c.y) + row) * cw + Int(c.x)) * 4, src, ((Int(c.topEdge) + row) * cw + Int(c.leftEdge)) * 4, Int(w), c.overwrite)
        }
        if c.destFrame == 1 { img.data = dst } else { img.animation!.frames[Int(c.destFrame) - 2].data = dst }
        st.images[id] = img
        if c.destFrame - 1 == (img.animation?.currentIndex ?? 0) { st.contentChanged(id) } else { st.markMutated() }
        return r
    }
}
