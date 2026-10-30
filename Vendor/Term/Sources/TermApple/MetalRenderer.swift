// Draws Contents with Metal like Ghostty (renderer/generic.zig drawFrame on renderer/metal): its own
// shaders (Shaders.swift), the same uniform/cell/instance bytes and atlas textures, one pass:
// background color, kitty images below the backgrounds, cell backgrounds, images below the text,
// glyphs as instanced quads, images above the text. Background images and custom shaders are not
// drawn; Dispatch's own Glow (GlowShaders.swift) is a second pass over the frame.
#if canImport(Metal)
import Dispatch
import Foundation
import Metal
import Term

/// The shaders' Uniforms struct (shaders.metal) with Ghostty's values for a frame (plain values:
/// making one per frame allocates nothing).
public struct FrameUniforms {
    public var projection: SIMD16<Float>, screen: SIMD2<Float>, cell: SIMD2<Float>, grid: SIMD2<UInt16>, padding: SIMD4<Float>
    public var paddingExtend: UInt8 = 0, minContrast: Float = 1, cursorPos = SIMD2<UInt16>(.max, .max), cursorColor = SIMD4<UInt8>(0, 0, 0, 0)
    public var bgColor: SIMD4<UInt8>, cursorWide = false, displayP3 = false, linearBlending = false, linearCorrection = false

    /// updateScreenSizeUniforms + updateFontGridUniforms + the frame's background and block cursor:
    /// the projection maps the padded terminal area, the grid padding adds the blank space the grid
    /// leaves at the right and bottom. `cell`: the font grid's cell (the renderer's own metrics).
    public init(size: RenderSize, cell: (width: Int, height: Int), cols: Int, rows: Int, background: RGB, opacity: Double = 1,
                block: (x: Int, y: Int, wide: Bool, text: RGB)? = nil) {
        // Keep malformed embedding inputs finite. The normal path is unchanged, but a zero-sized
        // target, an excessive padding value, or an out-of-range cursor can no longer create an
        // infinity or trap while narrowing values for the shader ABI.
        let p = (top: Float(max(size.padding.top, 0)), bottom: Float(max(size.padding.bottom, 0)),
                 right: Float(max(size.padding.right, 0)), left: Float(max(size.padding.left, 0)))
        let (sw, sh) = (Float(max(size.screen.width, 0)), Float(max(size.screen.height, 0)))
        let (cw, ch) = (Float(max(cell.width, 1)), Float(max(cell.height, 1)))
        let (w, h) = (max(sw - p.left - p.right, 0), max(sh - p.top - p.bottom, 0))
        let (left, right, bottom, top) = (-p.left, w + p.right, h + p.bottom, -p.top)
        let (spanX, spanY) = (max(right - left, 1), min(top - bottom, -1))
        projection = [2 / spanX, 0, 0, 0, 0, 2 / spanY, 0, 0, 0, 0, -1, 0,
                      -(right + left) / spanX, -(top + bottom) / spanY, 0, 1]
        let blankRight = max(sw - (Float(max(cols, 0)) * cw + p.left + p.right), 0)
        let blankBottom = max(sh - (Float(max(rows, 0)) * ch + p.top + p.bottom), 0)
        (screen, self.cell, grid) = (SIMD2(sw, sh), SIMD2(cw, ch), SIMD2(UInt16(clamping: cols), UInt16(clamping: rows)))
        padding = SIMD4(p.top, blankRight + p.right, blankBottom + p.bottom, p.left)
        let alpha = opacity.isFinite ? min(max(opacity, 0), 1) : 1
        bgColor = SIMD4(background.r, background.g, background.b, UInt8((alpha * 255).rounded()))
        if let b = block, let x = UInt16(exactly: b.x), let y = UInt16(exactly: b.y) {
            (cursorPos, cursorWide, cursorColor) = (SIMD2(x, y), b.wide, SIMD4(b.text.r, b.text.g, b.text.b, 255))
        }
    }

    /// MSL layout: each field at its alignment, the whole padded to 16.
    public static let size = 144

    /// The MSL bytes at `to` (size bytes).
    public func write(_ to: UnsafeMutableRawPointer) {
        var at = 0
        func put<T>(_ v: T, align: Int) {
            at += (align - at % align) % align
            withUnsafeBytes(of: v) { (to + at).copyMemory(from: $0.baseAddress!, byteCount: $0.count); at += $0.count }
        }
        put(projection, align: 16)
        put(screen, align: 8)
        put(cell, align: 8)
        put(grid, align: 4)
        put(padding, align: 16)
        put(paddingExtend, align: 1)
        put(minContrast, align: 4)
        put(cursorPos, align: 4)
        put(cursorColor, align: 4)
        put(bgColor, align: 4)
        put(SIMD4<UInt8>(cursorWide ? 1 : 0, displayP3 ? 1 : 0, linearBlending ? 1 : 0, linearCorrection ? 1 : 0), align: 1)
        (to + at).initializeMemory(as: UInt8.self, repeating: 0, count: FrameUniforms.size - at)
    }

    /// The same bytes as an array (checks).
    public var bytes: [UInt8] { [UInt8](unsafeUninitializedCapacity: FrameUniforms.size) { b, n in write(b.baseAddress!); n = FrameUniforms.size } }
}

extension Contents {
    /// Text instances in draw order.
    public var count: Int {
        lists.reduce(0) { total, list in
            guard total != .max else { return .max }
            let (next, overflow) = total.addingReportingOverflow(list.count)
            return overflow ? .max : next
        }
    }

    /// The CellText records at `to` (32 bytes each: atlas position, size, bearings, grid position,
    /// color, atlas, flags).
    public func write(_ to: UnsafeMutableRawPointer, wide: WideColors? = nil) {
        var at = to
        for list in lists {
            for e in list {
                let color = wide?.map(e.color) ?? e.color
                at.storeBytes(of: SIMD4<UInt32>(UInt32(clamping: e.glyph.x), UInt32(clamping: e.glyph.y),
                                                UInt32(clamping: e.glyph.width), UInt32(clamping: e.glyph.height)), as: SIMD4<UInt32>.self)
                at.storeBytes(of: Int16(clamping: e.bearings.x), toByteOffset: 16, as: Int16.self)
                at.storeBytes(of: Int16(clamping: e.bearings.y), toByteOffset: 18, as: Int16.self)
                at.storeBytes(of: UInt16(clamping: e.x), toByteOffset: 20, as: UInt16.self)
                at.storeBytes(of: UInt16(clamping: e.y), toByteOffset: 22, as: UInt16.self)
                at.storeBytes(of: SIMD8<UInt8>(color.r, color.g, color.b, e.alpha, e.glyph.color ? 1 : 0, (e.noMinContrast ? 1 : 0) | (e.cursor ? 2 : 0), 0, 0),
                              toByteOffset: 24, as: SIMD8<UInt8>.self)
                at += 32
            }
        }
    }

    /// The same bytes as an array (checks).
    public var instances: [UInt8] {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: 32)
        guard !overflow else { return [] }
        return [UInt8](unsafeUninitializedCapacity: bytes) { b, n in if let p = b.baseAddress { write(p) }; n = bytes }
    }
}

/// Dispatch's phosphor look: a halo around what is brighter than the background, and scanlines (0: none, 1: black
/// between them).
public struct Glow: Equatable, Sendable {
    public var strength: Float, scanlines: Float
    public init(strength: Float = 2.5, scanlines: Float = 0.3) { (self.strength, self.scanlines) = (strength, scanlines) }
}

public final class MetalRenderer {
    public enum Failure: Error { case commandQueueUnavailable }
    public let device: MTLDevice, pixelFormat: MTLPixelFormat
    let queue: MTLCommandQueue, bgColor: MTLRenderPipelineState, cellBg: MTLRenderPipelineState, cellText: MTLRenderPipelineState, image: MTLRenderPipelineState
    let glow: MTLRenderPipelineState
    /// The frame a Glow draws from, with its mipmaps (the halo's blur), at the target's size. The frames in flight
    /// share it: the queue runs their command buffers in order and Metal tracks the texture between them.
    var glowFrame: MTLTexture?
    /// Serializes the public renderer boundary. Sessions already have a draw lock, but keeping the
    /// swap-chain index, caches, and image snapshot safe here prevents another embedder from racing
    /// `draw`, invalidation, and `Images.update` into the same shared Metal resources.
    let stateLock = NSLock()
    /// The kitty images of the next frame (set under the terminal lock, see Images.update).
    public let images: Images

    /// Pipelines like metal/shaders.zig: premultiplied alpha blending (not for the background color).
    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        (self.device, self.pixelFormat) = (device, pixelFormat)
        images = Images(lock: stateLock)
        guard let queue = device.makeCommandQueue() else { throw Failure.commandQueueUnavailable }
        self.queue = queue
        let library = try device.makeLibrary(source: ghosttyShaders + glowShaders, options: nil)
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool, instances: MTLVertexDescriptor? = nil) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            (d.vertexFunction, d.fragmentFunction, d.vertexDescriptor) = (library.makeFunction(name: vertex), library.makeFunction(name: fragment), instances)
            let a = d.colorAttachments[0]!
            (a.pixelFormat, a.isBlendingEnabled) = (pixelFormat, blend)
            (a.rgbBlendOperation, a.alphaBlendOperation, a.sourceRGBBlendFactor, a.sourceAlphaBlendFactor) = (.add, .add, .one, .one)
            (a.destinationRGBBlendFactor, a.destinationAlphaBlendFactor) = (.oneMinusSourceAlpha, .oneMinusSourceAlpha)
            return try device.makeRenderPipelineState(descriptor: d)
        }
        // CellText's fields as vertex attributes, one set per instance.
        let text = MTLVertexDescriptor()
        for (i, (format, offset)) in [(MTLVertexFormat.uint2, 0), (.uint2, 8), (.short2, 16), (.ushort2, 20), (.uchar4, 24), (.uchar, 28), (.uchar, 29)].enumerated() {
            (text.attributes[i].format, text.attributes[i].offset, text.attributes[i].bufferIndex) = (format, offset, 0)
        }
        (text.layouts[0].stride, text.layouts[0].stepFunction) = (32, .perInstance)
        bgColor = try pipeline("full_screen_vertex", "bg_color_fragment", blend: false)
        cellBg = try pipeline("full_screen_vertex", "cell_bg_fragment", blend: true)
        cellText = try pipeline("cell_text_vertex", "cell_text_fragment", blend: true, instances: text)
        // ImageVertexIn (metal/shaders.zig Image): grid position, cell offset, source rect, size.
        let quad = MTLVertexDescriptor()
        for (i, (format, offset)) in [(MTLVertexFormat.float2, 0), (.float2, 8), (.float4, 16), (.float2, 32)].enumerated() {
            (quad.attributes[i].format, quad.attributes[i].offset, quad.attributes[i].bufferIndex) = (format, offset, 0)
        }
        (quad.layouts[0].stride, quad.layouts[0].stepFunction) = (40, .perInstance)
        image = try pipeline("image_vertex", "image_fragment", blend: true, instances: quad)
        glow = try pipeline("full_screen_vertex", "glow_fragment", blend: false)
    }

    /// The offscreen frame for a Glow at the target's size, made again when that changes.
    func glowTexture(like target: MTLTexture) -> MTLTexture? {
        if let t = glowFrame, t.width == target.width, t.height == target.height { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: target.width, height: target.height, mipmapped: true)
        (d.usage, d.storageMode) = ([.renderTarget, .shaderRead], .private)
        glowFrame = device.makeTexture(descriptor: d)
        return glowFrame
    }

    /// Per in-flight frame (Ghostty's SwapChain: 3): the uniform, cell and instance buffers and the
    /// atlas textures, each grown to the largest size seen, never shrunk; Dispatch's contrast cache
    /// (1,024 color pairs of 64 bytes) and its epoch (0: to be cleared before the next use).
    struct Frame {
        var uniforms: MTLBuffer?, cells: MTLBuffer?, text: MTLBuffer?, textures: [Atlas.Format: (texture: MTLTexture, modified: Int)] = [:]
        var contrast: MTLBuffer?, epoch: UInt32 = 0
    }
    var frames = [Frame](repeating: Frame(), count: 3), next = 0
    let inflight = DispatchSemaphore(value: 3)

    /// Colors or the minimum contrast changed: every frame's contrast cache is cleared when it is
    /// next used (a frame the GPU may still read is never touched here).
    public func invalidateContrast() {
        stateLock.lock()
        defer { stateLock.unlock() }
        for i in frames.indices { frames[i].epoch = 0 }
    }

    /// New atlases replaced the old ones (fonts, size or scale changed; Ghostty's setFontGrid): their
    /// counters start again, so every frame uploads them on its next use instead of trusting a counter.
    public func invalidateTextures() {
        stateLock.lock()
        defer { stateLock.unlock() }
        for i in frames.indices { frames[i].textures = frames[i].textures.mapValues { ($0.texture, -1) } }
    }

    func buffer(_ b: inout MTLBuffer?, _ length: Int) -> MTLBuffer? {
        guard length >= 0 else { return nil }
        if let b, b.length >= length { return b }
        let doubled = (b?.length ?? 0).multipliedReportingOverflow(by: 2)
        let capacity = min(max(length, doubled.overflow ? length : doubled.partialValue, 16), device.maxBufferLength)
        guard capacity >= length else { return nil }
        b = device.makeBuffer(length: capacity, options: .storageModeShared)
        return b
    }

    /// Checks every value that becomes a GPU address or a narrowed ABI field. Metal buffer pointers
    /// do not carry a shader-visible length, so rejecting an inconsistent frame here is what keeps a
    /// bad cell coordinate or background size from becoming an out-of-bounds device read.
    func validatedCount(_ c: Contents, _ u: FrameUniforms, gray: Atlas, color: Atlas, target: MTLTexture) -> Int? {
        guard c.cols > 0, c.rows > 0, c.cols <= Int(UInt16.max), c.rows <= Int(UInt16.max),
              u.grid == SIMD2(UInt16(c.cols), UInt16(c.rows)),
              target.pixelFormat == pixelFormat, target.textureType == .type2D, target.sampleCount == 1,
              target.usage.contains(.renderTarget),
              target.width > 0, target.height > 0, target.device.registryID == device.registryID else { return nil }

        let shaderIntMax = Float(Int32.max)
        let floatsAreFinite = (0..<16).allSatisfy { u.projection[$0].isFinite }
            && (0..<2).allSatisfy { u.screen[$0].isFinite && u.screen[$0] >= 0 && u.screen[$0] <= shaderIntMax
                && u.cell[$0].isFinite && u.cell[$0] > 0 && u.cell[$0] <= shaderIntMax }
            && (0..<4).allSatisfy { u.padding[$0].isFinite && u.padding[$0] >= 0 && u.padding[$0] <= shaderIntMax }
            && u.minContrast.isFinite
        guard floatsAreFinite else { return nil }
        let cursorHidden = u.cursorPos == SIMD2<UInt16>(repeating: .max)
        guard cursorHidden || Int(u.cursorPos.x) < c.cols && Int(u.cursorPos.y) < c.rows
                && (!u.cursorWide || Int(u.cursorPos.x) + 1 < c.cols) else { return nil }

        func valid(_ a: Atlas, _ format: Atlas.Format) -> Bool {
            guard a.format == format, a.size >= 2, a.size <= Atlas.maxSize else { return false }
            let pixels = a.size.multipliedReportingOverflow(by: a.size)
            guard !pixels.overflow else { return false }
            let bytes = pixels.partialValue.multipliedReportingOverflow(by: a.format.depth)
            return !bytes.overflow && a.data.count == bytes.partialValue
        }
        guard valid(gray, .grayscale), valid(color, .bgra) else { return nil }

        let cells = c.cols.multipliedReportingOverflow(by: c.rows)
        guard !cells.overflow else { return nil }
        let cellBytes = cells.partialValue.multipliedReportingOverflow(by: 4)
        guard !cellBytes.overflow, cellBytes.partialValue <= device.maxBufferLength, c.bg.count == cellBytes.partialValue else { return nil }

        var count = 0
        for list in c.lists {
            let next = count.addingReportingOverflow(list.count)
            guard !next.overflow else { return nil }
            count = next.partialValue
            for e in list {
                guard e.x >= 0, e.x < c.cols, e.y >= 0, e.y < c.rows,
                      UInt16(exactly: e.x) != nil, UInt16(exactly: e.y) != nil,
                      Int16(exactly: e.bearings.x) != nil, Int16(exactly: e.bearings.y) != nil,
                      e.glyph.x >= 0, e.glyph.y >= 0, e.glyph.width > 0, e.glyph.height > 0,
                      UInt32(exactly: e.glyph.x) != nil, UInt32(exactly: e.glyph.y) != nil,
                      UInt32(exactly: e.glyph.width) != nil, UInt32(exactly: e.glyph.height) != nil else { return nil }
                let right = e.glyph.x.addingReportingOverflow(e.glyph.width)
                let bottom = e.glyph.y.addingReportingOverflow(e.glyph.height)
                let atlas = e.glyph.color ? color : gray
                guard !right.overflow, !bottom.overflow, right.partialValue <= atlas.size, bottom.partialValue <= atlas.size else { return nil }
            }
        }
        let textBytes = count.multipliedReportingOverflow(by: 32)
        guard !textBytes.overflow, textBytes.partialValue <= device.maxBufferLength else { return nil }
        return count
    }

    /// The atlas as a texture (grayscale: r8, color: bgra8 sRGB), replaced when it grew, re-uploaded
    /// when it changed (syncAtlasTexture).
    func texture(_ a: Atlas, _ cache: inout [Atlas.Format: (texture: MTLTexture, modified: Int)]) -> MTLTexture? {
        // Metal has no three-channel 8-bit texture format. Treating BGR as BGRA would make
        // `replace` read a fourth byte per source pixel past each row (and eventually the array).
        guard a.format == .grayscale || a.format == .bgra else { return nil }
        if let t = cache[a.format], t.modified == a.modified { return t.texture }
        var t = cache[a.format]?.texture
        if t == nil || a.size > t!.width {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: a.format == .grayscale ? .r8Unorm : .bgra8Unorm_srgb, width: a.size, height: a.size, mipmapped: false)
            t = device.makeTexture(descriptor: d)
        }
        guard let t else { return nil }
        a.data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { t.replace(region: MTLRegionMake2D(0, 0, a.size, a.size), mipmapLevel: 0, withBytes: base, bytesPerRow: a.size * a.format.depth) }
        }
        cache[a.format] = (t, a.modified)
        return t
    }

    /// Encodes one frame into `target` (cleared to transparent) and commits it; returns the command
    /// buffer; `completed` runs when the GPU is done with it. Waits while 3 frames are in flight.
    /// With a `glow` the frame is drawn offscreen and the glow pass draws it into `target`.
    @discardableResult
    /// `wide`: a theme with Display P3 colors (every color goes to the shader as P3).
    public func draw(_ c: Contents, _ u: FrameUniforms, gray: Atlas, color: Atlas, into target: MTLTexture,
                     glow: Glow? = nil, wide: WideColors? = nil, completed: (() -> Void)? = nil) -> MTLCommandBuffer? {
        guard let n = validatedCount(c, u, gray: gray, color: color, target: target) else { return nil }
        guard inflight.wait(timeout: .now() + .milliseconds(250)) == .success else { return nil }
        var committed = false
        stateLock.lock()
        defer {
            stateLock.unlock()
            if !committed { inflight.signal() }
        }
        let f = next
        next = (next + 1) % frames.count
        let (textBytes, overflow) = n.multipliedReportingOverflow(by: 32)
        guard !overflow, let uniforms = buffer(&frames[f].uniforms, FrameUniforms.size),
              let cells = buffer(&frames[f].cells, c.bg.count), let text = buffer(&frames[f].text, textBytes) else { return nil }
        if let wide {
            var u = u
            u.displayP3 = true
            for keyPath in [\FrameUniforms.bgColor, \FrameUniforms.cursorColor] {
                let v = u[keyPath: keyPath], p3 = wide.map(RGB(r: v[0], g: v[1], b: v[2]))
                u[keyPath: keyPath] = SIMD4(p3.r, p3.g, p3.b, v[3])
            }
            u.write(uniforms.contents())
        } else {
            u.write(uniforms.contents())
        }
        c.bg.withUnsafeBytes { if let p = $0.baseAddress { cells.contents().copyMemory(from: p, byteCount: $0.count) } }
        if let wide {
            // rgba per cell: the colors mapped in place, alpha kept.
            let p = cells.contents().bindMemory(to: UInt8.self, capacity: c.bg.count)
            for i in stride(from: 0, to: c.bg.count - 3, by: 4) {
                let p3 = wide.map(RGB(r: p[i], g: p[i + 1], b: p[i + 2]))
                (p[i], p[i + 1], p[i + 2]) = (p3.r, p3.g, p3.b)
            }
        }
        c.write(text.contents(), wide: wide)
        // This frame's previous GPU use has completed (the semaphore): its cache may be cleared.
        guard let contrast = buffer(&frames[f].contrast, 1024 * 64) else { return nil }
        frames[f].epoch &+= 1
        if frames[f].epoch <= 1 { memset(contrast.contents(), 0, contrast.length); frames[f].epoch = 1 }
        var epoch = frames[f].epoch
        let offscreen = glow == nil ? nil : glowTexture(like: target)
        if glow != nil, offscreen == nil { return nil }
        let pass = MTLRenderPassDescriptor()
        (pass.colorAttachments[0].texture, pass.colorAttachments[0].loadAction, pass.colorAttachments[0].storeAction) = (offscreen ?? target, .clear, .store)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        images.upload(device)
        var atlasTextures: [MTLTexture] = []
        if n > 0 {
            for atlas in [gray, color] {
                guard let texture = texture(atlas, &frames[f].textures) else { return nil }
                atlasTextures.append(texture)
            }
        }
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        for (state, layer) in [(bgColor, Images.Layer.belowBackground), (cellBg, .belowText)] {
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBuffer(uniforms, offset: 0, index: 1)
            encoder.setFragmentBuffer(cells, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            images.draw(layer, encoder, image, uniforms)
        }
        if n > 0 {
            encoder.setRenderPipelineState(cellText)
            for (b, index) in [(text, 0), (uniforms, 1), (cells, 2)] {
                encoder.setVertexBuffer(b, offset: 0, index: index)
                encoder.setFragmentBuffer(b, offset: 0, index: index)
            }
            encoder.setVertexBuffer(contrast, offset: 0, index: 3)
            encoder.setVertexBytes(&epoch, length: 4, index: 4)
            for (i, t) in atlasTextures.enumerated() {
                encoder.setVertexTexture(t, index: i)
                encoder.setFragmentTexture(t, index: i)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
        images.draw(.aboveText, encoder, image, uniforms)
        encoder.endEncoding()
        if let glow, let offscreen {
            guard let blit = commands.makeBlitCommandEncoder() else { return nil }
            blit.generateMipmaps(for: offscreen)
            blit.endEncoding()
            let post = MTLRenderPassDescriptor()
            (post.colorAttachments[0].texture, post.colorAttachments[0].loadAction, post.colorAttachments[0].storeAction) = (target, .dontCare, .store)
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: post) else { return nil }
            var params = SIMD2<Float>(glow.strength, glow.scanlines)
            encoder.setRenderPipelineState(self.glow)
            encoder.setFragmentBuffer(uniforms, offset: 0, index: 1)
            encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            encoder.setFragmentTexture(offscreen, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commands.addCompletedHandler { [inflight] _ in
            inflight.signal()
            completed?()
        }
        committed = true
        commands.commit()
        return commands
    }
}

/// Kitty images on the GPU (renderer/image.zig State): a texture per image id, uploaded when the
/// image is drawn and its generation changed, dropped when the image is gone or changed; each
/// placement one quad (image_vertex/image_fragment) in its layer. Used under the renderer's draw lock.
public final class Images {
    public enum Layer { case belowBackground, belowText, aboveText }
    let lock: NSLock
    var draws = ImageDraws(), textures: [UInt32: (generation: UInt64, texture: MTLTexture)] = [:]

    init(lock: NSLock) { self.lock = lock }

    /// The terminal's draws now (under its lock: the images are shared copies, nothing converted).
    public func update(_ t: Terminal, cell: (width: Int, height: Int)) {
        lock.lock()
        defer { lock.unlock() }
        guard let width = UInt32(exactly: cell.width), let height = UInt32(exactly: cell.height), width > 0, height > 0 else {
            draws.draws.removeAll(keepingCapacity: true)
            draws.images.removeAll(keepingCapacity: true)
            (draws.belowBackground, draws.belowText, draws.virtual) = (0, 0, false)
            return
        }
        t.imageDraws(&draws, cellWidth: width, cellHeight: height)
    }

    /// RGBA8 sRGB textures (imageTextureOptions(.rgba, srgb: true)) for the drawn images that lack
    /// one; frames still in flight keep the textures they encoded (Metal retains them).
    func upload(_ device: MTLDevice) {
        for (id, t) in textures where draws.images[id]?.generation != t.generation { textures[id] = nil }
        for d in draws.draws where textures[d.image] == nil {
            guard let img = draws.images[d.image], img.width > 0, img.height > 0 else { continue }
            let (w, h, rgba) = (Int(img.width), Int(img.height), img.rgba)
            let (pixels, pixelOverflow) = w.multipliedReportingOverflow(by: h)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            guard !pixelOverflow, !byteOverflow, bytes <= KittyError.maxRGBABytes else { continue }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
            (desc.usage, desc.storageMode, desc.cpuCacheMode) = (.shaderRead, .shared, .writeCombined)
            guard rgba.count >= bytes, let texture = device.makeTexture(descriptor: desc) else { continue }
            rgba.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
            textures[d.image] = (img.generation, texture)
        }
    }

    /// The layer's placements (those without a texture are skipped, like Ghostty's "not ready").
    func draw(_ layer: Layer, _ encoder: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState, _ uniforms: MTLBuffer) {
        let range = switch layer {
        case .belowBackground: 0..<draws.belowBackground
        case .belowText: draws.belowBackground..<draws.belowText
        case .aboveText: draws.belowText..<draws.draws.count
        }
        guard !range.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(uniforms, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniforms, offset: 0, index: 1)
        for d in draws.draws[range] {
            guard let texture = textures[d.image]?.texture,
                  d.sourceWidth > 0, d.sourceHeight > 0,
                  UInt64(d.sourceX) < UInt64(texture.width), UInt64(d.sourceY) < UInt64(texture.height),
                  UInt64(d.sourceX) + UInt64(d.sourceWidth) <= UInt64(texture.width),
                  UInt64(d.sourceY) + UInt64(d.sourceHeight) <= UInt64(texture.height) else { continue }
            var quad = SIMD16<Float>(Float(d.x), Float(d.y), Float(d.cellOffsetX), Float(d.cellOffsetY), Float(d.sourceX), Float(d.sourceY),
                                     Float(d.sourceWidth), Float(d.sourceHeight), Float(d.width), Float(d.height), 0, 0, 0, 0, 0, 0)
            encoder.setVertexBytes(&quad, length: 40, index: 0)
            encoder.setVertexTexture(texture, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }
    }
}
#endif
