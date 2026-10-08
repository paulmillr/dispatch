// Run with: xcrun swift test/contrast.swift
// Executes the production contrast shader code (Vendor/Term/Sources/TermApple/Shaders.swift),
// using independent Double-precision XYZ/Oklab calculations as the oracle (no CPU copy of the
// correction search).
import Foundation
import Metal
import simd

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
// The correction (dispatch_luminance through contrasted_color) and its cache (through the end of
// dispatch_cached_contrast), taken from the renderer's shader source.
let shaders = try String(contentsOf: root.appendingPathComponent("Vendor/Term/Sources/TermApple/Shaders.swift"), encoding: .utf8)
func section(from start: String, to end: String, in text: Substring) -> Substring {
    guard let lower = text.range(of: start)?.lowerBound, let upper = text[lower...].range(of: end)?.lowerBound else {
        fatalError("Shaders.swift no longer contains \(start)")
    }
    return text[lower..<upper]
}
let overlay = String(section(from: "float dispatch_luminance(", to: "constant uint DISPATCH_CONTRAST_CACHE_SIZE", in: shaders[...]))
let cacheStart = shaders.range(of: "constant uint DISPATCH_CONTRAST_CACHE_SIZE")!.lowerBound
let cacheFunction = shaders.range(of: "float4 dispatch_cached_contrast(")!.lowerBound
let cacheSource = String(shaders[cacheStart..<shaders[cacheFunction...].range(of: "\n}\n")!.upperBound])
// Count fallback calculations without changing cache lookup/publication logic.
let instrumentedCache = cacheSource.replacingOccurrences(of: "uint currentEpoch)",
    with: "uint currentEpoch, device atomic_uint& misses)")
let source = "#include <metal_stdlib>\nusing namespace metal;\n" + overlay + """

#define contrasted_color(m, f, b) (atomic_fetch_add_explicit(&misses, 1u, memory_order_relaxed), contrasted_color(m, f, b))

""" + instrumentedCache + """

#undef contrasted_color
static_assert(sizeof(DispatchContrastEntry) == 64, "Zig/Metal cache entry layout mismatch");
static_assert(sizeof(DispatchContrastCache) == 65536, "Zig/Metal cache buffer layout mismatch");
struct CacheVertexOut { float4 position [[position]]; float4 color; };
vertex CacheVertexOut check_cached_vertex(device const float4 *inputs [[buffer(0)]],
                                         device DispatchContrastCache& cache [[buffer(1)]],
                                         constant uint& epoch [[buffer(2)]],
                                         device atomic_uint& misses [[buffer(3)]], uint id [[vertex_id]]) {
    CacheVertexOut out;
    out.position = float4(2.0f * (float(id) + 0.5f) / 128.0f - 1.0f, 0, 0, 1);
    out.color = dispatch_cached_contrast(inputs[id * 3 + 2].x, inputs[id * 3], inputs[id * 3 + 1], cache, epoch, misses);
    return out;
}
fragment float4 check_cached_fragment(CacheVertexOut in [[stage_in]]) { return in.color; }
kernel void check_cached_contrast(device const float4 *inputs [[buffer(0)]],
                                 device float4 *outputs [[buffer(1)]],
                                 device DispatchContrastCache& cache [[buffer(2)]],
                                 constant uint& epoch [[buffer(3)]],
                                 device atomic_uint& misses [[buffer(4)]], uint id [[thread_position_in_grid]]) {
    outputs[id] = dispatch_cached_contrast(inputs[id * 3 + 2].x, inputs[id * 3], inputs[id * 3 + 1], cache, epoch, misses);
}

kernel void check_contrast(device const float4 *inputs [[buffer(0)]],
                           device float4 *outputs [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    outputs[id] = contrasted_color(inputs[id * 3 + 2].x, inputs[id * 3], inputs[id * 3 + 1]);
}
"""
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("A Metal device is required; this test cannot silently skip")
}
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check_contrast")!)
let backgrounds: [SIMD3<Double>] = [SIMD3(repeating: 0), SIMD3(repeating: 1), SIMD3(repeating: 0.18),
    SIMD3(repeating: 0.5), SIMD3(0.8, 0.05, 0.1), SIMD3(0.05, 0.5, 0.1), SIMD3(0.1, 0.05, 0.8)]
struct Sample {
    let fg: SIMD4<Float>
    let bg: SIMD3<Double>
    let target: Double
}
var samples: [Sample] = []
for r in 0...4 {
    for g in 0...4 {
        for b in 0...4 {
            for bg in backgrounds {
                for target in [1.0, 3, 4.5, 7, 21] {
                    for alpha: Float in [1, 0.5] {
                        samples.append(Sample(fg: SIMD4(Float(r) / 4 * alpha, Float(g) / 4 * alpha,
                            Float(b) / 4 * alpha, alpha), bg: bg, target: target))
                    }
                }
            }
        }
    }
}
samples.append(Sample(fg: .zero, bg: SIMD3(repeating: 1), target: 4.5))
// Both polarities can pass here. White has a smaller Oklab displacement even
// though black has a slightly higher contrast ratio; don't just pick black.
samples.append(Sample(fg: SIMD4(0.18, 0.18, 0.18, 1), bg: SIMD3(repeating: 0.18), target: 4.5))
var inputs = samples.flatMap { [$0.fg, SIMD4(Float($0.bg.x), Float($0.bg.y), Float($0.bg.z), 1),
    SIMD4(Float($0.target), 0, 0, 0)] }
let input = device.makeBuffer(bytes: &inputs, length: inputs.count * MemoryLayout<SIMD4<Float>>.stride)!
let output = device.makeBuffer(length: samples.count * MemoryLayout<SIMD4<Float>>.stride)!
let command = queue.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(input, offset: 0, index: 0)
encoder.setBuffer(output, offset: 0, index: 1)
encoder.dispatchThreads(MTLSize(width: samples.count, height: 1, depth: 1),
    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
precondition(command.status == .completed, "Metal execution failed: \(String(describing: command.error))")
let results = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: samples.count)

func xyz(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(simd_dot(rgb, SIMD3(608311.0 / 1250200, 189793.0 / 714400, 198249.0 / 1000160)),
          simd_dot(rgb, SIMD3(35783.0 / 156275, 247089.0 / 357200, 198249.0 / 2500400)),
          simd_dot(rgb, SIMD3(0, 32229.0 / 714400, 5220557.0 / 5000800)))
}
func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
    let value = xyz(rgb)
    let lms = SIMD3(cbrt(simd_dot(value, SIMD3(0.819022437996703, 0.3619062600528904, -0.1288737815209879))),
        cbrt(simd_dot(value, SIMD3(0.0329836539323885, 0.9292868615863434, 0.0361446663506424))),
        cbrt(simd_dot(value, SIMD3(0.0481771893596242, 0.2642395317527308, 0.6335478284694309))))
    return SIMD3(simd_dot(lms, SIMD3(0.210454268309314, 0.7936177747023054, -0.0040720430116193)),
        simd_dot(lms, SIMD3(1.9779985324311684, -2.4285922420485799, 0.450593709617411)),
        simd_dot(lms, SIMD3(0.0259040424655478, 0.7827717124575296, -0.8086757549230774)))
}
func contrast(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let first = xyz(a).y + 0.05, second = xyz(b).y + 0.05
    return max(first, second) / min(first, second)
}
var corrected = 0, worstHue = 0.0
for (index, sample) in samples.enumerated() {
    let result = results[index]
    let original = SIMD3(Double(sample.fg.x), Double(sample.fg.y), Double(sample.fg.z))
    let rgb = SIMD3(Double(result.x), Double(result.y), Double(result.z))
    let message = "sample \(index): \(sample), result \(result)"
    precondition((0..<4).allSatisfy { result[$0].isFinite && result[$0] >= 0 && result[$0] <= 1 }, message)
    let before = contrast(original + sample.bg * (1 - Double(sample.fg.w)), sample.bg)
    if sample.target == 1 || sample.fg.w == 0 || before >= sample.target + 0.00001 {
        precondition(result == sample.fg, "Readable/disabled/transparent text changed: " + message)
        continue
    }
    corrected += 1
    let maximum = max(contrast(.zero, sample.bg), contrast(SIMD3(repeating: 1), sample.bg))
    let after = contrast(rgb + sample.bg * (1 - Double(result.w)), sample.bg)
    precondition(after >= min(sample.target, maximum) - 0.0001, "Contrast \(after) fails: " + message)
    let beforeLab = lab(original / Double(sample.fg.w)), afterLab = lab(rgb / Double(result.w))
    let beforeChroma = hypot(beforeLab.y, beforeLab.z), afterChroma = hypot(afterLab.y, afterLab.z)
    precondition(afterChroma <= beforeChroma + 0.0001, "Chroma increased: " + message)
    if beforeChroma < 0.00001 {
        precondition(afterChroma < 0.00001, "Neutral text gained a hue: " + message)
    } else if afterChroma > 0.001 {
        let cosine = (beforeLab.y * afterLab.y + beforeLab.z * afterLab.z) / (beforeChroma * afterChroma)
        let difference = acos(min(1, max(-1, cosine))) * 180 / .pi
        worstHue = max(worstHue, difference)
        precondition(difference < 0.1, "Hue rotated \(difference) degrees: " + message)
    }
}
precondition(results[samples.count - 1].x > 0.9, "Must choose the closer passing Oklab candidate")
print("Passed \(samples.count) Metal color cases; \(corrected) corrected, worst hue drift \(worstHue)°")
print(String(format: "GPU evaluation: %.3f ms (informational, not a frame benchmark)",
    (command.gpuEndTime - command.gpuStartTime) * 1000))

let cachedPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check_cached_contrast")!)
let cache = device.makeBuffer(length: 1024 * 64, options: .storageModeShared)!
let misses = device.makeBuffer(length: 4, options: .storageModeShared)!
let cachedOutput = device.makeBuffer(length: output.length, options: .storageModeShared)!
memset(cache.contents(), 0, cache.length)
func cachedPass(epoch: UInt32, count: Int) -> UInt32 {
    var epoch = epoch
    memset(misses.contents(), 0, 4)
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(cachedPipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setBuffer(cachedOutput, offset: 0, index: 1)
    encoder.setBuffer(cache, offset: 0, index: 2)
    encoder.setBytes(&epoch, length: 4, index: 3)
    encoder.setBuffer(misses, offset: 0, index: 4)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: cachedPipeline.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed, "Cache execution failed")
    let colors = cachedOutput.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
    for index in 0..<count {
        precondition(simd_length(colors[index] - results[index]) < 0.00001,
            "Cached color differs at \(index), epoch \(epoch): \(colors[index]) vs \(results[index])")
    }
    return misses.contents().load(as: UInt32.self)
}
// Warm a typical small palette, proving that repeated pairs avoid the search.
for epoch in 1...4 { _ = cachedPass(epoch: UInt32(epoch), count: 128) }
let warmMisses = cachedPass(epoch: 5, count: 128)
precondition(warmMisses < 16, "Expected warmed palette hits; got \(warmMisses) misses")
// More pairs than capacity, including different backgrounds, alpha, and ratios.
_ = cachedPass(epoch: 6, count: samples.count)
_ = cachedPass(epoch: 7, count: samples.count)
// Simulate settings invalidation, then force a completely full collision table.
memset(cache.contents(), 0, cache.length)
_ = cachedPass(epoch: 1, count: samples.count)
memset(cache.contents(), 0xFF, cache.length)
precondition(cachedPass(epoch: 2, count: samples.count) == samples.count)
print("Cache passed: warm palette \(128 - Int(warmMisses))/128 hits; saturation, key changes, and reset preserve results")

// Metal warns about writes in a rasterizing vertex function because invocation
// counts are not guaranteed. This cache tolerates repeats/skips; verify that
// actual rendered draws populate and reuse entries, not only compute kernels.
let renderDescriptor = MTLRenderPipelineDescriptor()
renderDescriptor.vertexFunction = library.makeFunction(name: "check_cached_vertex")
renderDescriptor.fragmentFunction = library.makeFunction(name: "check_cached_fragment")
renderDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
let renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 1, mipmapped: false)
textureDescriptor.usage = .renderTarget
let texture = device.makeTexture(descriptor: textureDescriptor)!
memset(cache.contents(), 0, cache.length)
var vertexMisses: UInt32 = 0
for pass in 1...5 {
    var epoch = UInt32(pass)
    memset(misses.contents(), 0, 4)
    let command = queue.makeCommandBuffer()!
    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)!
    encoder.setRenderPipelineState(renderPipeline)
    encoder.setVertexBuffer(input, offset: 0, index: 0)
    encoder.setVertexBuffer(cache, offset: 0, index: 1)
    encoder.setVertexBytes(&epoch, length: 4, index: 2)
    encoder.setVertexBuffer(misses, offset: 0, index: 3)
    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 128)
    encoder.endEncoding()
    command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed, "Vertex cache draw failed")
    vertexMisses = misses.contents().load(as: UInt32.self)
    if pass == 1 { precondition(vertexMisses > 0, "The vertex shader must run on a cold cache") }
}
precondition(vertexMisses < 16, "Vertex draws must reuse the warmed cache")
print("Rendered vertex cache passed: warm palette \(128 - Int(vertexMisses))/128 hits")
