// Draws Contents with Metal like Ghostty (renderer/generic.zig drawFrame on renderer/metal): its own
// shaders (Shaders.swift), the same uniform/cell/instance bytes and atlas textures, one pass:
// background color, kitty images below the backgrounds, cell backgrounds, images below the text,
// glyphs as instanced quads, images above the text. Background images and custom shaders are not
// drawn.
#if canImport(Metal)
import Dispatch
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
        let p = size.padding
        let (w, h) = (max(size.screen.width - p.left - p.right, 0), max(size.screen.height - p.top - p.bottom, 0))
        let (left, right, bottom, top) = (-Float(p.left), Float(w + p.right), Float(h + p.bottom), -Float(p.top))
        projection = [2 / (right - left), 0, 0, 0, 0, 2 / (top - bottom), 0, 0, 0, 0, -1, 0,
                      -(right + left) / (right - left), -(top + bottom) / (top - bottom), 0, 1]
        let blankRight = max(size.screen.width - (cols * cell.width + p.left + p.right), 0)
        let blankBottom = max(size.screen.height - (rows * cell.height + p.top + p.bottom), 0)
        (screen, self.cell, grid) = (SIMD2(Float(size.screen.width), Float(size.screen.height)), SIMD2(Float(cell.width), Float(cell.height)), SIMD2(UInt16(cols), UInt16(rows)))
        padding = SIMD4(Float(p.top), Float(blankRight + p.right), Float(blankBottom + p.bottom), Float(p.left))
        bgColor = SIMD4(background.r, background.g, background.b, UInt8((opacity * 255).rounded()))
        if let b = block { (cursorPos, cursorWide, cursorColor) = (SIMD2(UInt16(b.x), UInt16(b.y)), b.wide, SIMD4(b.text.r, b.text.g, b.text.b, 255)) }
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
    public var count: Int { lists.reduce(0) { $0 + $1.count } }

    /// The CellText records at `to` (32 bytes each: atlas position, size, bearings, grid position,
    /// color, atlas, flags).
    public func write(_ to: UnsafeMutableRawPointer) {
        var at = to
        for list in lists {
            for e in list {
                at.storeBytes(of: SIMD4<UInt32>(UInt32(e.glyph.x), UInt32(e.glyph.y), UInt32(e.glyph.width), UInt32(e.glyph.height)), as: SIMD4<UInt32>.self)
                at.storeBytes(of: Int16(e.bearings.x), toByteOffset: 16, as: Int16.self)
                at.storeBytes(of: Int16(e.bearings.y), toByteOffset: 18, as: Int16.self)
                at.storeBytes(of: UInt16(e.x), toByteOffset: 20, as: UInt16.self)
                at.storeBytes(of: UInt16(e.y), toByteOffset: 22, as: UInt16.self)
                at.storeBytes(of: SIMD8<UInt8>(e.color.r, e.color.g, e.color.b, e.alpha, e.glyph.color ? 1 : 0, (e.noMinContrast ? 1 : 0) | (e.cursor ? 2 : 0), 0, 0),
                              toByteOffset: 24, as: SIMD8<UInt8>.self)
                at += 32
            }
        }
    }

    /// The same bytes as an array (checks).
    public var instances: [UInt8] { [UInt8](unsafeUninitializedCapacity: count * 32) { b, n in if let p = b.baseAddress { write(p) }; n = count * 32 } }
}

public final class MetalRenderer {
    public enum Failure: Error { case commandQueueUnavailable }
    public let device: MTLDevice, pixelFormat: MTLPixelFormat
    let queue: MTLCommandQueue, bgColor: MTLRenderPipelineState, cellBg: MTLRenderPipelineState, cellText: MTLRenderPipelineState, image: MTLRenderPipelineState
    /// The kitty images of the next frame (set under the terminal lock, see Images.update).
    public let images = Images()

    /// Pipelines like metal/shaders.zig: premultiplied alpha blending (not for the background color).
    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        (self.device, self.pixelFormat) = (device, pixelFormat)
        guard let queue = device.makeCommandQueue() else { throw Failure.commandQueueUnavailable }
        self.queue = queue
        let library = try device.makeLibrary(source: ghosttyShaders, options: nil)
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
    public func invalidateContrast() { for i in frames.indices { frames[i].epoch = 0 } }

    /// New atlases replaced the old ones (fonts, size or scale changed; Ghostty's setFontGrid): their
    /// counters start again, so every frame uploads them on its next use instead of trusting a counter.
    public func invalidateTextures() {
        for i in frames.indices { frames[i].textures = frames[i].textures.mapValues { ($0.texture, -1) } }
    }

    func buffer(_ b: inout MTLBuffer?, _ length: Int) -> MTLBuffer? {
        if let b, b.length >= length { return b }
        b = device.makeBuffer(length: max(length, 2 * (b?.length ?? 0), 16), options: .storageModeShared)
        return b
    }

    /// The atlas as a texture (grayscale: r8, color: bgra8 sRGB), replaced when it grew, re-uploaded
    /// when it changed (syncAtlasTexture).
    func texture(_ a: Atlas, _ cache: inout [Atlas.Format: (texture: MTLTexture, modified: Int)]) -> MTLTexture? {
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
    @discardableResult
    public func draw(_ c: Contents, _ u: FrameUniforms, gray: Atlas, color: Atlas, into target: MTLTexture,
                     completed: (() -> Void)? = nil) -> MTLCommandBuffer? {
        guard inflight.wait(timeout: .now() + .milliseconds(250)) == .success else { return nil }
        var committed = false
        defer { if !committed { inflight.signal() } }
        let f = next
        next = (next + 1) % frames.count
        let n = c.count
        let (textBytes, overflow) = n.multipliedReportingOverflow(by: 32)
        guard !overflow, let uniforms = buffer(&frames[f].uniforms, FrameUniforms.size),
              let cells = buffer(&frames[f].cells, c.bg.count), let text = buffer(&frames[f].text, textBytes) else { return nil }
        u.write(uniforms.contents())
        c.bg.withUnsafeBytes { if let p = $0.baseAddress { cells.contents().copyMemory(from: p, byteCount: $0.count) } }
        c.write(text.contents())
        // This frame's previous GPU use has completed (the semaphore): its cache may be cleared.
        guard let contrast = buffer(&frames[f].contrast, 1024 * 64) else { return nil }
        frames[f].epoch &+= 1
        if frames[f].epoch <= 1 { memset(contrast.contents(), 0, contrast.length); frames[f].epoch = 1 }
        var epoch = frames[f].epoch
        let pass = MTLRenderPassDescriptor()
        (pass.colorAttachments[0].texture, pass.colorAttachments[0].loadAction, pass.colorAttachments[0].storeAction) = (target, .clear, .store)
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
        commands.addCompletedHandler { [inflight] _ in
            completed?()
            inflight.signal()
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
    var draws = ImageDraws(), textures: [UInt32: (generation: UInt64, texture: MTLTexture)] = [:]

    /// The terminal's draws now (under its lock: the images are shared copies, nothing converted).
    public func update(_ t: Terminal, cell: (width: Int, height: Int)) {
        t.imageDraws(&draws, cellWidth: UInt32(cell.width), cellHeight: UInt32(cell.height))
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
            guard let texture = textures[d.image]?.texture else { continue }
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
