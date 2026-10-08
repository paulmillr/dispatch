// Kitty graphics media and decoders for the core (Ghostty's graphics_image.zig reads and
// terminal/sys.zig decode_png): files, temporary files and shared memory with Ghostty's rules
// (POSIX, builds on Linux too for the Term tool); PNG through ImageIO and zlib through Compression
// on Apple platforms, giving the same bytes as Ghostty's wuffs/zlib (straight RGBA8, no color
// management).
import Foundation
import Term
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class KittyFiles: KittyMedia {
    /// The temp dir Ghostty allows temporary files in (os/file.zig allocTmpDir: TMPDIR, TMP, /tmp).
    let temp: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var t = environment["TMPDIR"] ?? environment["TMP"] ?? "/tmp"
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        temp = t
    }

    static func inDir(_ dir: String, _ path: String) -> Bool {
        guard !dir.isEmpty, path.hasPrefix(dir) else { return false }
        return path.count == dir.count || dir.hasSuffix("/") || path.dropFirst(dir.count).first == "/"
    }

    public func file(_ path: [UInt8], temporary: Bool, offset: Int, size: Int, max: Int) throws(KittyError) -> [UInt8] {
        let fd = open(String(decoding: path, as: UTF8.self), O_RDONLY)
        guard fd >= 0 else { throw .invalidData }
        defer { close(fd) }
        guard let real = realPath(fd) else { throw .invalidData }
        if real.hasPrefix("/proc/") || real.hasPrefix("/sys/") || real.hasPrefix("/dev/") && !real.hasPrefix("/dev/shm/") { throw .invalidData }
        if temporary {
            let realTemp = temp.withCString { p in realpath(p, nil).map { r in defer { free(r) }; return String(cString: r) } }
            guard ["/tmp", "/dev/shm", temp, realTemp ?? ""].contains(where: { KittyFiles.inDir($0, real) }) else { throw .temporaryFileNotInTempDir }
            guard real.contains("tty-graphics-protocol") else { throw .temporaryFileNotNamedCorrectly }
        }
        defer { if temporary { unlink(real) } }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw .invalidData }
        if offset > 0, lseek(fd, off_t(offset), SEEK_SET) < 0 { throw .invalidData }
        guard size <= max else { throw .invalidData }
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
        while size == 0 || out.count < size {
            let n = read(fd, &buf, size == 0 ? buf.count : Swift.min(buf.count, size - out.count))
            guard n >= 0 else { throw .invalidData }
            if n == 0 { break }
            out += buf[..<n]
            guard out.count <= max else { throw .invalidData }
        }
        guard size == 0 || out.count == size else { throw .invalidData }
        return out
    }

    /// The opened file's own path (symlinks resolved), like Zig's File.realPath.
    func realPath(_ fd: Int32) -> String? {
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return fcntl(fd, F_GETPATH, &buf) == 0 ? String(cString: buf) : nil
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")
        #endif
    }

    public func sharedMemory(_ name: [UInt8], _ range: (Int) throws(KittyError) -> Range<Int>) throws(KittyError) -> [UInt8] {
        guard name.count >= 2, name.count <= 255, name[0] == 0x2F, !name.dropFirst().contains(where: { $0 == 0x2F || $0 == 0 }) else { throw .invalidData }
        let path = String(decoding: name, as: UTF8.self)
        let fd = path.withCString { KittyFiles.shmOpen($0, O_RDONLY) }
        guard fd >= 0 else { throw .invalidData }
        defer { close(fd); shm_unlink(path) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { throw .invalidData }
        let size = Int(st.st_size), r = try range(size)
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { throw .invalidData }
        defer { munmap(map, size) }
        return Array(UnsafeRawBufferPointer(start: map + r.lowerBound, count: r.count))
    }

    #if canImport(Darwin)
    /// Darwin's shm_open is variadic (not importable); without O_CREAT it never reads the mode.
    static let shmOpen: @convention(c) (UnsafePointer<CChar>, Int32) -> Int32 = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open"), to: (@convention(c) (UnsafePointer<CChar>, Int32) -> Int32).self)
    #else
    static func shmOpen(_ name: UnsafePointer<CChar>, _ flags: Int32) -> Int32 { shm_open(name, flags, 0) }
    #endif
}

#if canImport(ImageIO) && canImport(Compression)
import Compression
import CoreGraphics
import ImageIO

extension KittySystem {
    /// What the app gives its terminals: files, ImageIO PNG, Compression zlib.
    public static let apple = KittySystem(decodePNG: decodePNG, inflate: inflate, media: KittyFiles())
    /// Image decoders without transports that refer to resources on the host machine. Remote
    /// sessions use this while retaining direct inline Kitty graphics.
    public static let appleInline = KittySystem(decodePNG: decodePNG, inflate: inflate)

    /// PNG -> straight RGBA8 from the decoded samples as stored (no color matching, no
    /// premultiplying): gray, gray+alpha, RGB(X), RGBA, 16-bit (high byte) and indexed.
    @_spi(Test) public static func decodePNG(_ png: [UInt8]) -> Decoded? {
        // ImageIO can allocate the decoded bitmap while producing a CGImage. Read the fixed PNG
        // header first so attacker-controlled dimensions are bounded before entering ImageIO.
        guard let header = pngDimensions(png),
              let src = CGImageSourceCreateWithData(Data(png) as CFData, nil), CGImageSourceGetType(src) as String? == "public.png",
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let (w, h, bpc, bpp, stride) = (img.width, img.height, img.bitsPerComponent, img.bitsPerPixel, img.bytesPerRow)
        guard (w, h) == header, let outputBytes = rgbaBytes(width: w, height: h), bpc == 8 || bpc == 16,
              bpp % bpc == 0 else { return nil }
        let channels = bpp / bpc, alpha = img.alphaInfo, little = img.bitmapInfo.contains(.byteOrder16Little) || img.bitmapInfo.contains(.byteOrder32Little)
        let (rowSamples, rowOverflow) = w.multipliedReportingOverflow(by: channels)
        let (rowBytes, byteOverflow) = rowSamples.multipliedReportingOverflow(by: bpc / 8)
        let (dataBytes, dataOverflow) = stride.multipliedReportingOverflow(by: h)
        guard (1...4).contains(channels), !rowOverflow, !byteOverflow, !dataOverflow, stride >= rowBytes,
              let data = img.dataProvider?.data as Data?, data.count >= dataBytes, let space = img.colorSpace else { return nil }
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        // An indexed image's palette: RGB triplets.
        let table = space.model == .indexed ? space.colorTable ?? [] : []
        // wuffs compares a gray/RGB color key at the PNG's depth (low depths scaled to 8 bits).
        let key = colorKey(png).flatMap { k in (k.depth == 16) != (bpc == 16) ? nil : k.values.map { v in
            k.depth == 16 ? v : k.depth == 8 ? v & 255 : (v & ((1 << k.depth) - 1)) * (255 / ((1 << k.depth) - 1))
        } }
        var out = [UInt8](repeating: 0, count: outputBytes)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    func sample(_ c: Int) -> UInt8 { UInt8(truncatingIfNeeded: full(c) >> (bpc - 8)) }
                    func full(_ c: Int) -> Int {
                        let i = y * stride + (x * channels + c) * bpc / 8
                        return bpc == 8 ? Int(raw[i]) : little ? Int(raw[i + 1]) << 8 | Int(raw[i]) : Int(raw[i]) << 8 | Int(raw[i + 1])
                    }
                    var px: [UInt8]
                    switch channels {
                    case 1 where space.model == .indexed:
                        let k = Int(sample(0)) * 3
                        px = k + 2 < table.count ? [table[k], table[k + 1], table[k + 2], 255] : [0, 0, 0, 255]
                    case 1: let g = sample(0); px = [g, g, g, 255]
                    case 2: let g = sample(alphaFirst ? 1 : 0); px = [g, g, g, hasAlpha ? sample(alphaFirst ? 0 : 1) : 255]
                    default:
                        let o = alphaFirst ? 1 : 0
                        px = [sample(o), sample(o + 1), sample(o + 2), hasAlpha && channels == 4 ? sample(alphaFirst ? 0 : 3) : 255]
                    }
                    if let key, key == (key.count == 1 ? [alphaFirst ? 1 : 0] : [0, 1, 2].map { $0 + (alphaFirst ? 1 : 0) }).map(full) { px = [0, 0, 0, 0] }
                    for k in 0..<4 { out[(y * w + x) * 4 + k] = px[k] }
                }
            }
        }
        return Decoded(width: UInt32(w), height: UInt32(h), rgba: out)
    }

    /// A PNG starts with its signature and one 13-byte IHDR chunk. Keep both dimensions and the
    /// eventual RGBA allocation within the core's protocol limits before asking ImageIO to decode.
    @_spi(Test) public static func pngDimensions(_ png: [UInt8]) -> (width: Int, height: Int)? {
        guard png.count >= 24, Array(png[..<8]) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(png[8..<12]) == [0, 0, 0, 13], Array(png[12..<16]) == Array("IHDR".utf8) else { return nil }
        func u32(_ at: Int) -> UInt32 {
            png[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let (width, height) = (Int(u32(16)), Int(u32(20)))
        return rgbaBytes(width: width, height: height) == nil ? nil : (width, height)
    }

    private static func rgbaBytes(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0, width <= Int(KittyError.maxDimension), height <= Int(KittyError.maxDimension) else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelOverflow || byteOverflow || bytes > KittyError.maxRGBABytes ? nil : bytes
    }

    /// A gray or RGB PNG's tRNS color key (values at the PNG's bit depth): wuffs makes those pixels
    /// transparent black; ImageIO's samples don't always carry it.
    static func colorKey(_ png: [UInt8]) -> (depth: Int, values: [Int])? {
        var at = 8, depth = 0, type = -1
        func u32(_ i: Int) -> Int { Int(png[i]) << 24 | Int(png[i + 1]) << 16 | Int(png[i + 2]) << 8 | Int(png[i + 3]) }
        while at + 8 <= png.count {
            let (length, kind, body) = (u32(at), Array(png[at + 4 ..< at + 8]), at + 8)
            guard length <= png.count - body else { return nil }
            switch kind {
            case Array("IHDR".utf8) where length >= 10: (depth, type) = (Int(png[body + 8]), Int(png[body + 9]))
            case Array("tRNS".utf8) where (type == 0 && length == 2) || (type == 2 && length == 6):
                return (depth, stride(from: body, to: body + length, by: 2).map { Int(png[$0]) << 8 | Int(png[$0 + 1]) })
            case Array("IDAT".utf8): return nil   // a tRNS chunk comes before the image data
            default: break
            }
            at = body + length + 4
        }
        return nil
    }

    /// zlib (RFC 1950): the header, then raw DEFLATE through Compression; nil when invalid or
    /// over `limit`.
    static func inflate(_ z: [UInt8], _ limit: Int) -> [UInt8]? {
        guard z.count >= 6, z[0] & 0x0F == 8, z[1] & 0x20 == 0, (UInt16(z[0]) << 8 | UInt16(z[1])) % 31 == 0 else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 1 << 16)
        let body = Array(z.dropFirst(2))
        let ok: Bool = body.withUnsafeBufferPointer { input in
            stream.pointee.src_ptr = input.baseAddress!
            stream.pointee.src_size = input.count
            while true {
                let status = buf.withUnsafeMutableBufferPointer { b -> compression_status in
                    stream.pointee.dst_ptr = b.baseAddress!
                    stream.pointee.dst_size = b.count
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                out += buf[..<(buf.count - stream.pointee.dst_size)]
                if out.count > limit { return false }
                if status == COMPRESSION_STATUS_END { return true }
                if status != COMPRESSION_STATUS_OK { return false }
            }
        }
        // Like Ghostty's reader: what follows the stream (the Adler-32, anything else) isn't checked.
        return ok ? out : nil
    }
}
#endif
