import Accelerate
import Foundation
import Metal

// The Metal implementation of `WhisperBackend`. Each op maps onto the kernels ggml-metal would run for the same
// ggml graph node (`ggml_metal_op_*` in ggml-metal-ops.cpp decides the kernel variant, the function constants, the
// threadgroup shape and the threadgroup memory; those decisions are reproduced here, with the same `ne`/`nb`
// vocabulary, so a reader can check them against upstream line by line). Weights stay in the model file's type:
// `kernel_mul_mv_*` and `kernel_mul_mm_*` read f16 and q8_0 directly. Two ops have kernels of our own (whisper.metal):
// the decoder's few-query attention (one dispatch instead of five) and im2col.
//
// Submission: ops are encoded into one open command buffer with a single serial compute encoder (every dispatch sees
// the previous one's writes), committed and waited for only in `read` or `flush`. On macOS an encoder pass or a
// decoder step is therefore one GPU submission. On iOS, where the GPU watchdog kills a command buffer that runs too
// long, the open command buffer is committed (without waiting) every `commandBufferSplit` dispatches and a new one
// opened; one queue runs them in commit order, so the dependencies between them hold, and `flush` waits for the
// last. Activation buffers come from `MetalBufferPool` and return to it when the last tensor sharing them is
// released, so a pass reuses a few dozen buffers instead of allocating hundreds.
//
// Failures. `init` throws (`.metalUnavailable`, `.kernelCompileFailed`): it compiles the library, builds every
// pipeline the whisper graph can use and runs a smoke test, so a backend that exists can run the graph. After that
// nothing traps on the device's account: a `makeBuffer`, `makeCommandBuffer` or `makeComputeCommandEncoder` that
// returns nil, a pipeline outside the prebuilt set that fails to specialise, or a command buffer that completes with
// an error is recorded as `lastError` (a `MetalBackendFailure` or the `WhisperError`), and from then until
// `takeFailure` clears it every dispatch is skipped: ops still return tensors of the right shape (a failed
// allocation yields a placeholder whose buffer holds no data; `read` returns zeros for it) so the graph reaches its
// next `read`, after which `takeFailure` hands the error to the caller. The contents of tensors produced while a
// failure is recorded are undefined. Shape and type mismatches remain programming errors (preconditions).

/// A device failure `MetalBackend` records instead of trapping; `takeFailure` hands it to the graph.
public enum MetalBackendFailure: Error, Equatable, CustomStringConvertible {
  /// `makeBuffer`, `makeCommandBuffer` or `makeComputeCommandEncoder` returned nil (memory pressure).
  case allocationFailed(String)
  /// A command buffer completed with an error (a GPU fault, a timeout, the iOS watchdog).
  case commandBufferFailed(String)
  /// A tensor produced by a failed allocation was bound to a dispatch after the failure had been taken.
  case placeholderInUse
  /// Set by tests through `recordFailure`.
  case injected(String)

  public var description: String {
    switch self {
    case .allocationFailed(let what): "Metal allocation failed: \(what)"
    case .commandBufferFailed(let what): "Metal command buffer failed: \(what)"
    case .placeholderInUse: "a tensor from a failed Metal allocation is still in use"
    case .injected(let what): "injected failure: \(what)"
    }
  }
}

public final class MetalBackend: WhisperBackend, @unchecked Sendable {
  // Unchecked: the protocol promises one graph at a time from one thread; Metal objects are thread-safe themselves,
  // and the pool (reached from other threads by tensor deinits and completion handlers) locks.
  public typealias Tensor = MetalTensor

  let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipelines: MetalPipelineCache
  let pool: MetalBufferPool
  /// The storage of tensors whose allocation failed: 16 bytes, never bound to a dispatch (`dispatch` checks).
  private let placeholder: MetalStorage
  /// Whether the Metal 4 tensor-API matmul kernels are in use (ggml's choice on M5-class GPUs).
  public let usesTensorAPI: Bool
  /// How long `makeLibrary(source:)` took in this init (Metal caches compiled sources per process/device, so a
  /// second init is usually fast).
  public let compileSeconds: TimeInterval
  /// How long building the graph's pipelines took in this init, and how many there are.
  public let pipelineSeconds: TimeInterval
  public let pipelineCount: Int
  /// How long the init smoke test took.
  public private(set) var smokeTestSeconds: TimeInterval = 0

  private var commandBuffer: MTLCommandBuffer?
  private var encoder: MTLComputeCommandEncoder?
  /// Committed command buffers not yet waited for, oldest first (several only with `commandBufferSplit`).
  private var inFlight: [(buffer: MTLCommandBuffer, generation: Int)] = []
  /// Ids of command buffers opened so far; the pool tags released buffers with the open one.
  private var generation = 0
  private var dispatchesInCommandBuffer = 0
  /// Dispatches per command buffer before it is committed and a new one opened; nil keeps one command buffer per
  /// pass. iOS kills command buffers that run for seconds (the GPU watchdog), so it splits about every two
  /// encoder layers, like ggml's `n_cb` concurrent command buffers; macOS has no such limit.
  #if os(iOS)
    var commandBufferSplit: Int? = 64
  #else
    var commandBufferSplit: Int? = nil
  #endif
  /// The first failure since the last `takeFailure` (see the header). While set, dispatches are skipped.
  public private(set) var lastError: Error?

  /// Counters since the last `resetStatistics()`: how the work was submitted and where the time went.
  public struct Statistics: Sendable {
    public var dispatches = 0
    public var commandBuffers = 0
    public var encoders = 0
    public var buffersAllocated = 0
    public var bytesAllocated = 0
    public var buffersReused = 0
    /// GPU execution time of completed command buffers.
    public var gpuSeconds: TimeInterval = 0
    /// Time spent blocked in `waitUntilCompleted`.
    public var waitSeconds: TimeInterval = 0
  }
  public private(set) var statistics = Statistics()
  public func resetStatistics() {
    statistics = Statistics()
    poolBaseline = (pool.allocations, pool.allocatedBytes, pool.reuses)
  }
  private var poolBaseline = (0, 0, 0)

  /// Profiling: when set, every dispatch is submitted and waited for on its own and its GPU time is attributed to
  /// the kernel name in `profile`. Slow; for benchmarks only.
  public var profiling = false
  public private(set) var profile: [String: (count: Int, seconds: TimeInterval)] = [:]
  public func resetProfile() { profile = [:] }

  /// Throws `.metalUnavailable` without a GPU and `.kernelCompileFailed` with the compiler log when the MSL sources
  /// do not build, when a pipeline the graph uses cannot be created on this device, or when the smoke test (a few
  /// ops read back and compared with the CPU) fails. `tensorAPI` forces the Metal 4 tensor-API matmul on or off;
  /// nil follows ggml (on when the device supports the Metal 4 family, falling back to the simdgroup kernels if
  /// that compile fails).
  public init(tensorAPI: Bool? = nil) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let placeholderBuffer = device.makeBuffer(length: 16, options: .storageModeShared)
    else {
      throw WhisperError.metalUnavailable
    }
    self.device = device
    self.queue = queue
    self.pool = MetalBufferPool(device: device)
    self.placeholder = MetalStorage(buffer: placeholderBuffer, pool: nil)

    let supportsMetal4 = MetalKernelLibrary.metal4Family.map { device.supportsFamily($0) } ?? false
    var compiled: (library: MTLLibrary, seconds: TimeInterval)
    var tensor = tensorAPI ?? supportsMetal4
    if tensor {
      do {
        compiled = try MetalKernelLibrary.compile(on: device, tensorAPI: true)
      } catch {
        if tensorAPI == true { throw error }
        tensor = false
        compiled = try MetalKernelLibrary.compile(on: device, tensorAPI: false)
      }
    } else {
      compiled = try MetalKernelLibrary.compile(on: device, tensorAPI: false)
    }
    self.usesTensorAPI = tensor
    self.compileSeconds = compiled.seconds
    let pipelines = MetalPipelineCache(device: device, library: compiled.library)
    self.pipelines = pipelines

    // Every pipeline the graph can ask for, so a device that rejects one (an unsupported specialisation, a
    // threadgroup or register limit) fails here and the caller falls back to the CPU, instead of trapping
    // mid-dictation.
    let pipelineStart = Date()
    let keys = MetalBackend.graphPipelineKeys()
    try pipelines.build(keys)
    self.pipelineSeconds = Date().timeIntervalSince(pipelineStart)
    self.pipelineCount = keys.count

    let smokeStart = Date()
    try smokeTest()
    self.smokeTestSeconds = Date().timeIntervalSince(smokeStart)
    resetStatistics()  // the counters describe the caller's work, not the smoke test
  }

  deinit {
    encoder?.endEncoding()
    commandBuffer?.commit()
  }

  // MARK: - Buffers and submission

  /// Records `error` as `lastError` unless one is pending (the first failure is the informative one).
  func recordFailure(_ error: Error) {
    if lastError == nil { lastError = error }
  }

  /// A pooled activation tensor. `forCPUWrite` when the CPU fills it (uploads, cache zeroing). A placeholder (see
  /// the header) when the allocation fails.
  private func allocate(shape: [Int], type: WeightType, forCPUWrite: Bool = false) -> MetalTensor {
    let bytes = type.byteCount(elements: shape.reduce(1, *))
    guard let buffer = pool.take(bytes: bytes, forCPUWrite: forCPUWrite) else {
      recordFailure(MetalBackendFailure.allocationFailed("\(bytes) bytes for a \(shape) \(type) tensor"))
      return placeholderTensor(shape: shape, type: type)
    }
    return MetalTensor(storage: MetalStorage(buffer: buffer, pool: pool), offset: 0, shape: shape, type: type)
  }

  /// What a failed allocation returns: the right shape over the 16-byte placeholder storage (`holdsData` is
  /// false). Exposed for tests of the failure contract.
  func placeholderTensor(shape: [Int], type: WeightType) -> MetalTensor {
    MetalTensor(storage: placeholder, offset: 0, shape: shape, type: type)
  }

  private func openCommandBuffer() -> MTLCommandBuffer? {
    if let commandBuffer { return commandBuffer }
    guard let buffer = queue.makeCommandBuffer() else {
      recordFailure(MetalBackendFailure.allocationFailed("command buffer"))
      return nil
    }
    generation += 1
    pool.opened(generation: generation)
    commandBuffer = buffer
    dispatchesInCommandBuffer = 0
    statistics.commandBuffers += 1
    return buffer
  }

  private func computeEncoder() -> MTLComputeCommandEncoder? {
    if let encoder { return encoder }
    guard let buffer = openCommandBuffer() else { return nil }
    guard let encoder = buffer.makeComputeCommandEncoder() else {  // serial dispatch: in-order, writes visible to the next
      recordFailure(MetalBackendFailure.allocationFailed("compute command encoder"))
      return nil
    }
    statistics.encoders += 1
    self.encoder = encoder
    return encoder
  }

  /// Commits the open command buffer without waiting; its completion frees the pool buffers released while it was
  /// open (the pool orders generations, so a handler arriving late or early is harmless).
  private func submit() {
    encoder?.endEncoding()
    encoder = nil
    guard let buffer = commandBuffer else { return }
    let generation = generation
    let pool = pool
    buffer.addCompletedHandler { _ in pool.completed(generation: generation) }
    buffer.commit()
    inFlight.append((buffer, generation))
    commandBuffer = nil
    dispatchesInCommandBuffer = 0
  }

  /// Submits everything encoded so far and waits for it.
  public func flush() {
    submit()
    guard let last = inFlight.last else { return }
    let start = Date()
    last.buffer.waitUntilCompleted()  // the queue runs them in order: the earlier ones have completed too
    statistics.waitSeconds += Date().timeIntervalSince(start)
    for entry in inFlight {
      statistics.gpuSeconds += entry.buffer.gpuEndTime - entry.buffer.gpuStartTime
      // Kept until `takeFailure`: the contents of a failed command buffer are garbage and the graph must not
      // return them as logits.
      if let error = entry.buffer.error {
        recordFailure(MetalBackendFailure.commandBufferFailed(String(describing: error)))
      }
    }
    inFlight.removeAll(keepingCapacity: true)
    pool.completed(generation: last.generation)  // not left to the handler: the pool must be settled on return
    statistics.buffersAllocated = pool.allocations - poolBaseline.0
    statistics.bytesAllocated = pool.allocatedBytes - poolBaseline.1
    statistics.buffersReused = pool.reuses - poolBaseline.2
  }

  /// The pipeline for `key`, nil (with the failure recorded) when it is outside the prebuilt set and cannot be
  /// specialised on this device.
  private func pipeline(_ key: PipelineKey) -> MTLComputePipelineState? {
    do {
      return try pipelines.pipeline(key)
    } catch {
      recordFailure(error)
      return nil
    }
  }

  private func dispatch(
    _ pipeline: MTLComputePipelineState, _ args: KernelArguments, buffers: [(MTLBuffer, Int)],
    threadgroupMemory: Int = 0, threadgroups: MTLSize, threadsPerThreadgroup: MTLSize, threads: Bool = false
  ) {
    for binding in buffers where binding.0 === placeholder.buffer {
      recordFailure(MetalBackendFailure.placeholderInUse)
    }
    guard lastError == nil, let encoder = computeEncoder() else { return }
    encoder.setComputePipelineState(pipeline)
    let packed = args.packed
    packed.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
    for (index, binding) in buffers.enumerated() {
      encoder.setBuffer(binding.0, offset: binding.1, index: index + 1)
    }
    if threadgroupMemory > 0 { encoder.setThreadgroupMemoryLength(threadgroupMemory, index: 0) }
    if threads {
      encoder.dispatchThreads(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    } else {
      encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }
    statistics.dispatches += 1
    dispatchesInCommandBuffer += 1
    if profiling {
      let before = statistics.gpuSeconds
      flush()
      var name = pipeline.label ?? "?"
      if name.hasPrefix("kernel_cpy") { name += " tg=\(threadgroups.width)x\(threadgroups.height)x\(threadgroups.depth) nth=\(threadsPerThreadgroup.width)x\(threadsPerThreadgroup.height)" }
      let entry = profile[name] ?? (0, 0)
      profile[name] = (entry.count + 1, entry.seconds + statistics.gpuSeconds - before)
    } else if let split = commandBufferSplit, dispatchesInCommandBuffer >= split {
      submit()
    }
  }

  // MARK: - Uploads and reads

  public func weight(_ tensor: WeightTensor) throws -> MetalTensor {
    let count = tensor.elementCount
    if tensor.type == .q8_0 && count % 32 != 0 {
      throw WhisperError.shapeMismatch("\(tensor.name): q8_0 needs a multiple of 32 elements, has \(count)")
    }
    guard tensor.data.count == tensor.type.byteCount(elements: count) else {
      throw WhisperError.truncated("\(tensor.name): \(tensor.data.count) bytes for \(count) \(tensor.type) elements")
    }
    // Vectors (biases, layer norm parameters) feed elementwise kernels that take f32; store them as such.
    if tensor.shape.count == 1 && tensor.type != .f32 {
      let floats = tensor.data.withUnsafeBytes { MetalHalf.decode($0.baseAddress!, count: count, type: tensor.type) }
      let result = self.tensor(floats, shape: tensor.shape)
      guard result.holdsData else {
        _ = takeFailure()  // the throw reports it; the backend stays usable for the next model
        throw MetalBackendFailure.allocationFailed("\(tensor.name): \(count) floats")
      }
      return result
    }
    // Weights live for the model's lifetime: their own buffers, outside the pool.
    guard let buffer = device.makeBuffer(length: max(tensor.data.count, 16), options: .storageModeShared) else {
      throw MetalBackendFailure.allocationFailed("\(tensor.name): \(tensor.data.count) bytes")
    }
    tensor.data.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    return MetalTensor(storage: MetalStorage(buffer: buffer, pool: nil), offset: 0, shape: tensor.shape, type: tensor.type)
  }

  public func tensor(_ values: [Float], shape: [Int]) -> MetalTensor {
    precondition(values.count == shape.reduce(1, *), "values do not fill shape \(shape)")
    let result = allocate(shape: shape, type: .f32, forCPUWrite: true)
    guard result.holdsData, !values.isEmpty else { return result }
    values.withUnsafeBytes { result.buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    return result
  }

  public func read(_ tensor: MetalTensor) -> [Float] {
    flush()
    guard tensor.holdsData else { return [Float](repeating: 0, count: tensor.elementCount) }  // a failed allocation
    return MetalHalf.decode(tensor.buffer.contents() + tensor.offset, count: tensor.elementCount, type: tensor.type)
  }

  public func takeFailure() -> Error? {
    defer { lastError = nil }
    return lastError
  }

  // MARK: - Ops

  public func conv1d(_ x: MetalTensor, weight: MetalTensor, bias: MetalTensor, stride: Int, padding: Int)
    -> MetalTensor
  {
    precondition(x.shape.count == 2 && weight.shape.count == 3 && x.type == .f32, "conv1d: x [cin, len], weight [cout, cin, k]")
    let (cin, len) = (x.shape[0], x.shape[1])
    let (cout, kernel) = (weight.shape[0], weight.shape[2])
    precondition(weight.shape[1] == cin && bias.shape == [cout] && weight.type != .q8_0, "conv1d: shapes")
    let outLen = (len + 2 * padding - kernel) / stride + 1

    // ggml_conv_1d: im2col to f16 [OL, IC * K], then mul_mat(im2col, weight [OC, IC * K]) -> [OC, OL].
    let columns = allocate(shape: [outLen, cin * kernel], type: .f16)
    let result = allocate(shape: [cout, outLen], type: .f32)
    var args = KernelArguments()
    args.append([len, cin, kernel, outLen, stride, padding])
    guard let im2col = pipeline(PipelineKey("whisper_im2col_f16")) else { return result }
    dispatch(
      im2col, args, buffers: [(x.buffer, x.offset), (columns.buffer, columns.offset)],
      threadgroups: MTLSize(width: outLen * cin * kernel, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1), threads: true)

    let weightMatrix = MetalView(weight, ne: [cin * kernel, cout, 1, 1])
    matmul(src0: columns.matrix, src1: weightMatrix, dst: result)

    // Bias per output channel: ggml adds b [1, OC] (ne = [1, OC]), broadcast along the row.
    let biasColumn = MetalView(buffer: bias.buffer, offset: bias.offset, type: .f32, ne: [1, cout, 1, 1], nb: [4, 4, 4 * cout, 4 * cout])
    binaryAdd(src0: result.matrix, src1: biasColumn, dst: result.matrix)
    return result
  }

  public func linear(_ x: MetalTensor, weight: MetalTensor, bias: MetalTensor?) -> MetalTensor {
    precondition(weight.shape.count == 2 && weight.shape[1] == x.columns && x.type == .f32, "linear: x [n, in], weight [out, in]")
    let out = weight.shape[0]
    let result = allocate(shape: Array(x.shape.dropLast()) + [out], type: .f32)
    matmul(src0: weight.matrix, src1: x.matrix, dst: result)
    if let bias {
      precondition(bias.shape == [out], "linear: bias [out]")
      binaryAdd(src0: result.matrix, src1: float32(bias).matrix, dst: result.matrix)  // in place
    }
    return result
  }

  public func layerNorm(_ x: MetalTensor, weight: MetalTensor, bias: MetalTensor, epsilon: Float) -> MetalTensor {
    let (n, d) = (x.rows, x.columns)
    precondition(x.type == .f32 && weight.shape == [d] && bias.shape == [d], "layerNorm: weight and bias [d]")
    let w = float32(weight)
    let b = float32(bias)
    let result = allocate(shape: x.shape, type: .f32)

    // ggml_metal_op_norm with the NORM + MUL + ADD fusion: kernel_norm_mul_add_f32[_4].
    let ne00t = d % 4 == 0 ? d / 4 : d
    var args = KernelArguments()
    args.append(Int32(d))
    args.append(Int32(ne00t))
    args.appendStrides([d * 4, n * d * 4, n * d * 4])  // nb1, nb2, nb3 of dst
    args.append(epsilon)
    args.append([n, 1, 1])  // nef1: rows of x, w, b
    args.append([1, 1, 1])  // nef2
    args.append([1, 1, 1])  // nef3
    args.appendStrides([d * 4, d * 4, d * 4])  // nbf1
    args.appendStrides([n * d * 4, d * 4, d * 4])  // nbf2
    args.appendStrides([n * d * 4, d * 4, d * 4])  // nbf3
    args.append(Float(1))  // scale (unused without FC_norm_use_scale)

    guard let pipeline = pipeline(PipelineKey(d % 4 == 0 ? "kernel_norm_mul_add_f32_4" : "kernel_norm_mul_add_f32", [.bool(1700, false)])) else {
      return result
    }
    let maxThreads = pipeline.maxTotalThreadsPerThreadgroup
    var nth = 32
    while nth < ne00t && nth < maxThreads { nth *= 2 }
    nth = min(nth, maxThreads, (ne00t + 31) / 32 * 32)
    dispatch(
      pipeline, args,
      buffers: [(x.buffer, x.offset), (w.buffer, w.offset), (b.buffer, b.offset), (result.buffer, result.offset)],
      threadgroupMemory: 32 * 4, threadgroups: MTLSize(width: n, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: nth, height: 1, depth: 1))
    return result
  }

  public func add(_ a: MetalTensor, _ b: MetalTensor) -> MetalTensor {
    precondition(a.type == .f32 && Array(a.shape.suffix(b.shape.count)) == b.shape, "add: b's shape must be a suffix of a's")
    let b32 = float32(b)
    let result = allocate(shape: a.shape, type: .f32)
    // b has a's trailing dims: as a matrix its rows repeat with period b.rows over a's rows (ggml's i11 = i01 % ne11).
    let bView = b.shape.isEmpty ? MetalView(b32, ne: [1, 1, 1, 1]) : MetalView(b32, ne: [a.columns, b32.rows, 1, 1])
    binaryAdd(src0: a.matrix, src1: bView, dst: result.matrix)
    return result
  }

  public func gelu(_ x: MetalTensor) -> MetalTensor {
    precondition(x.type == .f32)
    let (n, d) = (x.rows, x.columns)
    let result = allocate(shape: x.shape, type: .f32)

    // ggml_metal_op_unary, OP_UNARY_NUM_GELU: kernel_unary_f32_f32[_4] over a contiguous [n, d].
    let c4 = d % 4 == 0
    let contiguousSmall = n * d < 32768
    let ne00 = c4 ? d / 4 : d
    var args = KernelArguments()
    args.append([ne00, n, 1, 1])
    args.appendStrides([4, d * 4, n * d * 4, n * d * 4])
    args.append([ne00, n, 1, 1])
    args.appendStrides([4, d * 4, n * d * 4, n * d * 4])
    for _ in 0..<6 { args.append(Float(0)) }  // slope, scale, bias, val, min, max

    guard let pipeline = pipeline(PipelineKey(c4 ? "kernel_unary_f32_f32_4" : "kernel_unary_f32_f32", [.short(1200, 103), .bool(1201, contiguousSmall)])) else {
      return result
    }
    if contiguousSmall {
      dispatch(
        pipeline, args, buffers: [(x.buffer, x.offset), (result.buffer, result.offset)],
        threadgroups: MTLSize(width: ne00 * n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    } else {
      let nth = min(ne00, min(256, pipeline.maxTotalThreadsPerThreadgroup))
      let nk0 = (ne00 + nth - 1) / nth
      dispatch(
        pipeline, args, buffers: [(x.buffer, x.offset), (result.buffer, result.offset)],
        threadgroups: MTLSize(width: nk0 * n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: nth, height: 1, depth: 1))
    }
    return result
  }

  public func transpose(_ x: MetalTensor) -> MetalTensor {
    precondition(x.shape.count == 2 && x.type == .f32, "transpose: a [r, c] f32 matrix")
    let (r, c) = (x.shape[0], x.shape[1])
    let result = allocate(shape: [c, r], type: .f32)
    // ggml_transpose is a view with swapped ne/nb; ggml_cont copies it into a contiguous tensor.
    let view = MetalView(buffer: x.buffer, offset: x.offset, type: .f32, ne: [r, c, 1, 1], nb: [c * 4, 4, r * c * 4, r * c * 4])
    copy(src: view, dst: result.matrix)
    return result
  }

  public func attention(query: MetalTensor, key: MetalTensor, value: MetalTensor, heads: Int, scale: Float, causal: Bool)
    -> MetalTensor
  {
    let (nq, d) = (query.rows, query.columns)
    let nk = key.rows
    precondition(d % heads == 0 && key.columns == d && value.columns == d && value.rows == nk, "attention: shapes")
    precondition(query.type == .f32 && key.type == .f32 && value.type == .f32)
    let hd = d / heads
    let result = allocate(shape: [nq, d], type: .f32)

    // Keys padded to the flash-attention chunk and no mask (the encoder and the cross-attention, whose keys
    // `WhisperModel` pads to a multiple of 256 like whisper.cpp): ggml_metal_op_flash_attn_ext's simdgroup kernel,
    // one dispatch, output already [nq, heads * hd]. Fewer queries go to the split-K kernel below.
    if !causal && nq > 8 && hd == 64 && nk % 64 == 0 {
      let nqptg = 8, ncpsg = 64, nsg = 4
      let nHeadLog2 = 1 << Int(floor(log2(Float(heads))))
      var args = KernelArguments()
      args.append([nq, heads, 1])  // ne01, ne02, ne03
      args.appendStrides([d * 4, hd * 4, nq * d * 4])  // nb01, nb02, nb03
      args.append([nk, heads, 1, d])  // ne11, ne_12_2, ne_12_3, ns10
      args.appendStrides([d * 4, hd * 4, nk * d * 4])  // nb11, nb12, nb13
      args.append(Int32(d))  // ns20
      args.appendStrides([d * 4, hd * 4, nk * d * 4])  // nb21, nb22, nb23
      args.append([nq, 1, 1])  // ne31, ne32, ne33 (no mask; only used in pointer arithmetic)
      args.appendStrides([0, 0, 0])  // nb31, nb32, nb33
      args.append([heads, nq, 1])  // ne1, ne2, ne3 of dst [nq, heads, hd]
      args.append(scale)
      args.append(Float(0))  // max_bias
      args.append(Float(1))  // m0
      args.append(Float(1))  // m1
      args.append(Int32(nHeadLog2))
      args.append(Float(0))  // logit_softcap
      guard let pipeline = pipeline(MetalBackend.flashAttentionKey(d: d, nsg: nsg)) else { return result }
      let smem = (nqptg * (hd + 2 * hd + 4 * ncpsg) * 2 + 15) / 16 * 16  // fa_smem: dv padded to 64
      let q = (query.buffer, query.offset)
      dispatch(
        pipeline, args,
        buffers: [q, (key.buffer, key.offset), (value.buffer, value.offset), q, q, q, q, (result.buffer, result.offset)],
        threadgroupMemory: smem, threadgroups: MTLSize(width: (nq + nqptg - 1) / nqptg, height: heads, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 32, height: nsg, depth: 1))
      return result
    }

    // The decoder's few queries: our split-K kernel (whisper.metal), one dispatch per key partition plus a reduce.
    if nq <= 8 && hd % 64 == 0 && hd <= 256 {
      let nparts = nk >= 256 ? min(16, nk / 128) : 1
      let chunk = (nk + nparts - 1) / nparts
      var args = KernelArguments()
      args.append([nq, nk, hd, d, d, d, d])
      args.append(scale)
      args.append([causal ? 1 : 0, chunk, nparts])
      let partial = nparts > 1 ? allocate(shape: [nq * heads * nparts, hd + 2], type: .f32) : result
      guard let decode = pipeline(PipelineKey("whisper_attn_decode_f32")) else { return result }
      dispatch(
        decode, args,
        buffers: [(query.buffer, query.offset), (key.buffer, key.offset), (value.buffer, value.offset), (result.buffer, result.offset), (partial.buffer, partial.offset)],
        threadgroupMemory: (hd + chunk + 32 + 256) * 4, threadgroups: MTLSize(width: nq, height: heads, depth: nparts),
        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
      if nparts > 1 {
        guard let reduce = pipeline(PipelineKey("whisper_attn_decode_reduce_f32")) else { return result }
        dispatch(
          reduce, args,
          buffers: [(partial.buffer, partial.offset), (result.buffer, result.offset)],
          threadgroups: MTLSize(width: nq, height: heads, depth: 1), threadsPerThreadgroup: MTLSize(width: hd, height: 1, depth: 1))
      }
      return result
    }

    // whisper.cpp's non-flash path: KQ = mul_mat(K, Q) per head, soft_max_ext(KQ, mask, scale), KQV = mul_mat(V^T, KQ),
    // then permute back to [nq, d]. Heads are the batch dimension (ne2) of strided views into the [n, d] tensors.
    let kView = MetalView(buffer: key.buffer, offset: key.offset, type: .f32, ne: [hd, nk, heads, 1], nb: [4, d * 4, hd * 4, nk * d * 4])
    let qView = MetalView(buffer: query.buffer, offset: query.offset, type: .f32, ne: [hd, nq, heads, 1], nb: [4, d * 4, hd * 4, nq * d * 4])
    let kq = allocate(shape: [heads, nq, nk], type: .f32)
    matmul(src0: kView, src1: qView, dst: kq)

    var mask: MetalTensor?
    if causal && nq > 1 {
      let m = allocate(shape: [nq, nk], type: .f32)
      var args = KernelArguments()
      args.append([nq, nk])
      guard let causalMask = pipeline(PipelineKey("whisper_causal_mask_f32")) else { return result }
      dispatch(
        causalMask, args, buffers: [(m.buffer, m.offset)],
        threadgroups: MTLSize(width: nk, height: nq, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1), threads: true)
      mask = m
    }
    softmax(kq, mask: mask, scale: scale)

    // V^T per head, contiguous [heads, hd, nk] (whisper.cpp: ggml_cpy of the permuted V).
    let vt = allocate(shape: [heads, hd, nk], type: .f32)
    let vView = MetalView(buffer: value.buffer, offset: value.offset, type: .f32, ne: [nk, hd, heads, 1], nb: [d * 4, 4, hd * 4, nk * d * 4])
    copy(src: vView, dst: MetalView(vt, ne: [nk, hd, heads, 1]))

    let kqv = allocate(shape: [heads, nq, hd], type: .f32)
    matmul(src0: MetalView(vt, ne: [nk, hd, heads, 1]), src1: MetalView(kq, ne: [nk, nq, heads, 1]), dst: kqv)

    // [heads, nq, hd] -> [nq, heads * hd].
    let kqvView = MetalView(buffer: kqv.buffer, offset: kqv.offset, type: .f32, ne: [hd, heads, nq, 1], nb: [4, hd * nq * 4, hd * 4, d * nq * 4])
    copy(src: kqvView, dst: MetalView(result, ne: [hd, heads, nq, 1]))
    return result
  }

  public func embedding(_ table: MetalTensor, ids: [Int32]) -> MetalTensor {
    precondition(table.shape.count == 2, "embedding: table [vocab, d]")
    let d = table.columns
    let result = allocate(shape: [ids.count, d], type: .f32)
    guard !ids.isEmpty else { return result }
    let idsTensor = allocate(shape: [ids.count], type: .f32, forCPUWrite: true)  // Int32 ids, same byte size
    guard idsTensor.holdsData else { return result }
    ids.withUnsafeBytes { idsTensor.buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

    // ggml_metal_op_get_rows: kernel_get_rows_{f32,f16,q8_0}; quantized rows are copied 16 values at a time.
    let ne00t = table.type == .q8_0 ? d / 16 : d
    var args = KernelArguments()
    args.append(Int32(ne00t))
    args.append(Int32(d))
    args.appendStrides([table.rowBytes, table.rowBytes * table.rows, table.rowBytes * table.rows])
    args.append(Int32(ids.count))
    args.appendStrides([4, 4 * ids.count, 4 * ids.count])
    args.appendStrides([d * 4, d * 4 * ids.count, d * 4 * ids.count])

    guard let pipeline = pipeline(PipelineKey("kernel_get_rows_" + table.matrix.typeName)) else { return result }
    let nth = min(ne00t, pipeline.maxTotalThreadsPerThreadgroup)
    let nw0 = (ne00t + nth - 1) / nth
    dispatch(
      pipeline, args, buffers: [(table.buffer, table.offset), (idsTensor.buffer, idsTensor.offset), (result.buffer, result.offset)],
      threadgroups: MTLSize(width: nw0 * ids.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: nth, height: 1, depth: 1))
    return result
  }

  public func rows(_ x: MetalTensor, _ range: Range<Int>) -> MetalTensor {
    precondition(x.shape.count >= 1 && range.lowerBound >= 0 && range.upperBound <= x.shape[0], "rows: range out of bounds")
    let rowElements = x.shape.dropFirst().reduce(1, *)
    let rowBytes = x.type.byteCount(elements: rowElements)
    return MetalTensor(storage: x.storage, offset: x.offset + range.lowerBound * rowBytes, shape: [range.count] + x.shape.dropFirst(), type: x.type)
  }

  public func cache(capacity: Int, width: Int) -> MetalTensor {
    let result = allocate(shape: [capacity, width], type: .f32)
    guard result.elementCount > 0 else { return result }
    var args = KernelArguments()
    args.append(Int32(result.elementCount))
    guard let pipeline = pipeline(PipelineKey("whisper_fill_zero_f32")) else { return result }
    dispatch(
      pipeline, args, buffers: [(result.buffer, result.offset)],
      threadgroups: MTLSize(width: result.elementCount, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1), threads: true)
    return result
  }

  public func write(_ values: MetalTensor, into cache: MetalTensor, at offset: Int) {
    precondition(values.type == .f32 && cache.type == .f32 && values.columns == cache.columns, "write: [k, width] into [capacity, width]")
    precondition(offset >= 0 && offset + values.rows <= cache.rows, "write: rows out of range")
    guard values.rows > 0 else { return }
    // A copy kernel in the open encoder (a blit would end it): ordered after the dispatches that produced `values`.
    let dst = MetalView(buffer: cache.buffer, offset: cache.offset + offset * cache.rowBytes, type: .f32, ne: values.matrix.ne, nb: values.matrix.nb)
    copy(src: values.matrix, dst: dst)
  }

  // MARK: - Kernel dispatch (ported from ggml-metal-ops.cpp / ggml-metal-device.cpp)

  /// `x` when it is f32, else a converted copy (f16 parameters that an elementwise kernel reads).
  private func float32(_ x: MetalTensor) -> MetalTensor {
    if x.type == .f32 { return x }
    precondition(x.type == .f16, "only f16 converts to f32 on the device")
    let result = allocate(shape: x.shape, type: .f32)
    copy(src: x.matrix, dst: result.matrix)
    return result
  }

  /// ggml_mul_mat: `dst[ne1 = src1 rows, ne0 = src0 rows] = src1 . src0^T`, batched over ne2/ne3 with src0
  /// broadcast (`r2 = ne12 / ne02`). Matrix-vector kernels for up to 8 src1 rows, matrix kernels beyond
  /// (ggml_metal_op_mul_mat_use_mm: ne00 >= 64 && ne11 > 8): the tensor-API `kernel_mul_mm` when the library has it,
  /// else the simdgroup one. Upstream also has `mul_mv_ext` for 2 ... 8 rows and an MMA few-row kernel; both are
  /// optimisations left for later, the classic mat-vec kernel covers those sizes.
  private func matmul(src0: MetalView, src1: MetalView, dst: MetalTensor) {
    let ne00 = src0.ne[0], ne01 = src0.ne[1], ne02 = src0.ne[2], ne03 = src0.ne[3]
    let ne10 = src1.ne[0], ne11 = src1.ne[1], ne12 = src1.ne[2], ne13 = src1.ne[3]
    precondition(ne00 == ne10 && ne12 % ne02 == 0 && ne13 % ne03 == 0, "matmul: inner dimensions")
    precondition(dst.elementCount == ne01 * ne11 * ne12 * ne13 && dst.type == .f32, "matmul: dst")
    precondition(src1.type == .f32 || src1.type == .f16, "matmul: src1 must be f32 or f16")
    let ne0 = ne01, ne1 = ne11
    let r2 = ne12 / ne02, r3 = ne13 / ne03
    let dstBinding = (dst.buffer, dst.offset)

    if ne00 >= 64 && ne11 > 8 {
      // ggml_metal_library_get_pipeline_mul_mm: 64 x 32 output tiles (64 x 128 with the tensor API), 4 simdgroups.
      let nr0 = 64
      let nr1 = usesTensorAPI ? 128 : 32
      let bcInp = ne00 % 32 != 0
      let bcOut = ne0 % nr0 != 0 || ne1 % nr1 != 0
      guard let pipeline = pipeline(MetalBackend.matrixKey(
        src0: src0.typeName, src1: src1.typeName, bcInp: bcInp, bcOut: bcOut, ne12: ne12, ne13: ne13, r2: r2, r3: r3))
      else { return }
      var args = KernelArguments()
      args.append(Int32(ne00))
      args.append(Int32(ne02))
      args.appendStrides([src0.nb[1], src0.nb[2], src0.nb[3]])
      args.append(Int32(ne12))
      args.appendStrides([src1.nb[0], src1.nb[1], src1.nb[2], src1.nb[3]])
      args.append(Int32(ne0))
      args.append(Int32(ne1))
      args.append(Int16(r2))
      args.append(Int16(r3))
      dispatch(
        pipeline, args, buffers: [(src0.buffer, src0.offset), (src1.buffer, src1.offset), dstBinding],
        threadgroupMemory: usesTensorAPI ? 64 * 32 * 2 : (bcOut ? 8192 : 4096 + 2048),
        threadgroups: MTLSize(width: (ne11 + nr1 - 1) / nr1, height: (ne01 + nr0 - 1) / nr0, depth: ne12 * ne13),
        threadsPerThreadgroup: MTLSize(width: 32, height: 4, depth: 1))
      return
    }

    // ggml_metal_library_get_pipeline_mul_mv + ggml_metal_op_mul_mat_mv.
    var nsg = 0, nr0 = 0, smem = 0
    var suffix = ""
    switch src0.type {
    case .f32, .f16:
      if ne00 < 32 {
        nsg = 1
        nr0 = 32
        suffix = "_short"
      } else {
        nsg = min(4, (ne00 + 127) / 128)
        nr0 = 2
        smem = 32 * 4 * nr0
        suffix = ne00 % 4 == 0 ? "_4" : ""
      }
    case .q8_0:
      nsg = 4  // N_SG_Q8_0
      nr0 = 2  // N_R0_Q8_0
      smem = 32 * 4 * nr0
    }
    guard let pipeline = pipeline(MetalBackend.vectorKey(
      src0: src0.typeName, src1: src1.typeName, suffix: suffix, nsg: nsg, ne12: ne12, r2: r2, r3: r3))
    else { return }
    var args = KernelArguments()
    args.append([ne00, ne01, ne02])
    args.appendStrides([src0.nb[0], src0.nb[1], src0.nb[2], src0.nb[3]])
    args.append([ne10, ne11, ne12])
    args.appendStrides([src1.nb[0], src1.nb[1], src1.nb[2], src1.nb[3]])
    args.append([ne0, ne1, nr0])
    args.append(Int16(r2))
    args.append(Int16(r3))
    dispatch(
      pipeline, args, buffers: [(src0.buffer, src0.offset), (src1.buffer, src1.offset), dstBinding],
      threadgroupMemory: smem,
      threadgroups: MTLSize(width: (ne01 + nr0 - 1) / nr0, height: ne11, depth: ne12 * ne13),
      threadsPerThreadgroup: MTLSize(width: 32, height: nsg, depth: 1))
  }

  /// ggml_add of two f32 views, src1 broadcast over src0 (`i1x = i0x % ne1x`, and along the row when ne10 != ne00).
  /// `dst` may be `src0` (in place).
  private func binaryAdd(src0: MetalView, src1: MetalView, dst: MetalView) {
    precondition(src0.type == .f32 && src1.type == .f32 && dst.ne == src0.ne, "add: f32, dst shaped like src0")
    let ne00 = src0.ne[0], ne10 = src1.ne[0]
    let c4 = ne00 % 4 == 0 && ne10 % 4 == 0
    let cb = ne00 != ne10
    let rb = src0.isContiguous && src1.isContiguous && src1.rowCount == 1 && src0.elementCount < 65536

    var args = KernelArguments()
    args.append([c4 ? ne00 / 4 : ne00, src0.ne[1], src0.ne[2], src0.ne[3]])
    args.appendStrides(src0.nb)
    args.append([c4 ? ne10 / 4 : ne10, src1.ne[1], src1.ne[2], src1.ne[3]])
    args.appendStrides(src1.nb)
    args.append([c4 ? ne00 / 4 : ne00, dst.ne[1], dst.ne[2], dst.ne[3]])
    args.appendStrides(dst.nb)
    args.append(UInt64(0))  // offs
    for _ in 0..<8 { args.append(UInt64(0)) }  // o1: src1 is bound with its own offset

    guard let pipeline = pipeline(MetalBackend.addKey(vector4: c4, rb: rb, cb: cb)) else { return }
    let buffers = [(src0.buffer, src0.offset), (src1.buffer, src1.offset), (dst.buffer, dst.offset)]
    if rb {
      dispatch(
        pipeline, args, buffers: buffers,
        threadgroups: MTLSize(width: c4 ? ne00 / 4 : ne00, height: src0.rowCount, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    } else {
      let ne0 = c4 ? ne00 / 4 : ne00
      let nthMax = min(256, pipeline.maxTotalThreadsPerThreadgroup)
      var nth = 1
      while 2 * nth < ne0 && nth < nthMax { nth *= 2 }
      dispatch(
        pipeline, args, buffers: buffers,
        threadgroups: MTLSize(width: src0.ne[1], height: src0.ne[2], depth: src0.ne[3]),
        threadsPerThreadgroup: MTLSize(width: nth, height: 1, depth: 1))
    }
  }

  /// ggml_soft_max_ext in place over the rows of `x` [ne2, ne1, ne0]: `softmax(scale * x + mask)`, the f32 mask
  /// [ne1, ne0] shared by every ne2 slice.
  private func softmax(_ x: MetalTensor, mask: MetalTensor?, scale: Float) {
    precondition(x.shape.count == 3)
    let ne00 = x.shape[2], ne01 = x.shape[1], ne02 = x.shape[0]
    var args = KernelArguments()
    args.append([ne00, ne01, ne02])
    args.appendStrides([ne00 * 4, ne00 * ne01 * 4, ne00 * ne01 * ne02 * 4])
    args.append([mask == nil ? 1 : ne01, 1, 1])  // ne11, ne12, ne13
    args.appendStrides([ne00 * 4, ne00 * ne01 * 4, ne00 * ne01 * 4])  // nb11, nb12, nb13
    args.appendStrides([ne00 * 4, ne00 * ne01 * 4, ne00 * ne01 * ne02 * 4])  // nb1, nb2, nb3
    args.append(scale)
    args.append(Float(0))  // max_bias
    let nHeadLog2 = 1 << Int(floor(log2(Float(ne02))))
    args.append(Float(1))  // m0 = 2^(-0 / n_head_log2)
    args.append(Float(1))  // m1
    args.append(Int32(nHeadLog2))

    guard let pipeline = pipeline(PipelineKey(ne00 % 4 == 0 ? "kernel_soft_max_f32_4" : "kernel_soft_max_f32")) else { return }
    var nth = 32
    if ne00 % 4 == 0 {
      while nth < ne00 / 4 && nth * ne01 * ne02 < 256 { nth *= 2 }
    } else {
      while nth < ne00 && nth * ne01 * ne02 < 256 { nth *= 2 }
    }
    let source = (x.buffer, x.offset)
    let maskBinding = mask.map { ($0.buffer, $0.offset) } ?? source  // src1 == src0 means "no mask"
    dispatch(
      pipeline, args, buffers: [source, maskBinding, source, source], threadgroupMemory: 32 * 4,
      threadgroups: MTLSize(width: ne01, height: ne02, depth: 1), threadsPerThreadgroup: MTLSize(width: nth, height: 1, depth: 1))
  }

  /// ggml_cpy: element-wise copy (with conversion) from a possibly strided `src` to `dst` of the same `ne`, whose
  /// innermost dimension is contiguous.
  private func copy(src: MetalView, dst: MetalView) {
    precondition(src.ne == dst.ne && src.type != .q8_0 && dst.type != .q8_0, "copy: same shape, no quantized data")
    if src.type == .f32 && dst.type == .f32 && src.isContiguous && dst.isContiguous && src.elementCount % 4 == 0
      && src.offset % 16 == 0 && dst.offset % 16 == 0
    {
      var args = KernelArguments()
      args.append(Int32(src.elementCount / 4))
      guard let pipeline = pipeline(PipelineKey("whisper_copy_f32x4")) else { return }
      dispatch(
        pipeline, args, buffers: [(src.buffer, src.offset), (dst.buffer, dst.offset)],
        threadgroups: MTLSize(width: src.elementCount / 4, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1), threads: true)
      return
    }
    let nk0 = src.ne[0]
    var nth = min(nk0 * src.ne[1], 256)
    var nrptg = 1
    if nth > nk0 {
      nrptg = (nth + nk0 - 1) / nk0
      nth = nk0
      if nrptg * nth > 256 { nrptg -= 1 }
    }
    nth = min(nth, nk0)

    var args = KernelArguments()
    args.append(Int64(nk0))
    for n in src.ne { args.append(Int64(n)) }
    args.appendStrides(src.nb)
    for n in dst.ne { args.append(Int64(n)) }
    args.appendStrides(dst.nb)

    let nw0 = nrptg == 1 ? (nk0 + nth - 1) / nth : 1
    guard let pipeline = pipeline(PipelineKey("kernel_cpy_" + src.typeName + "_" + dst.typeName)) else { return }
    dispatch(
      pipeline, args,
      buffers: [(src.buffer, src.offset), (dst.buffer, dst.offset)],
      threadgroups: MTLSize(width: nw0 * (src.ne[1] + nrptg - 1) / nrptg, height: src.ne[2], depth: src.ne[3]),
      threadsPerThreadgroup: MTLSize(width: nth, height: nrptg, depth: 1))
  }

  // MARK: - Pipeline keys

  /// The function-constant specialisations the ops above ask for, in one place so `graphPipelineKeys` enumerates
  /// exactly what the dispatch code can request.
  static func matrixKey(src0: String, src1: String, bcInp: Bool, bcOut: Bool, ne12: Int, ne13: Int, r2: Int, r3: Int) -> PipelineKey {
    PipelineKey(
      "kernel_mul_mm_" + src0 + "_" + src1,
      [.bool(700, bcInp), .bool(701, bcOut), .short(702, Int16(ne12)), .short(703, Int16(ne13)), .short(704, Int16(r2)), .short(705, Int16(r3))])
  }

  static func vectorKey(src0: String, src1: String, suffix: String, nsg: Int, ne12: Int, r2: Int, r3: Int) -> PipelineKey {
    PipelineKey(
      "kernel_mul_mv_" + src0 + "_" + src1 + suffix,
      [.short(600, Int16(nsg)), .short(602, Int16(ne12)), .short(603, Int16(r2)), .short(604, Int16(r3)), .bool(605, false)])
  }

  static func addKey(vector4: Bool, rb: Bool, cb: Bool) -> PipelineKey {
    PipelineKey(vector4 ? "kernel_bin_fuse_f32_f32_f32_4" : "kernel_bin_fuse_f32_f32_f32", [.short(1300, 0), .short(1301, 1), .bool(1302, rb), .bool(1303, cb)])
  }

  static func flashAttentionKey(d: Int, nsg: Int) -> PipelineKey {
    PipelineKey(
      "kernel_flash_attn_ext_f32_dk64_dv64",
      [.bool(300, false), .bool(301, false), .bool(302, false), .bool(303, false), .bool(304, false), .bool(310, false),
       .int(320, Int32(d)), .int(321, Int32(d)), .int(322, Int32(nsg))])
  }

  /// Whisper's model families: (state width, heads). Head size is 64 throughout, which the attention paths rely on.
  static let modelFamilies = [(state: 384, heads: 6), (state: 512, heads: 8), (state: 768, heads: 12), (state: 1024, heads: 16), (state: 1280, heads: 20)]

  /// Every pipeline the whisper graph (`WhisperModel` over this backend) can request for any model family, so
  /// `init` can build them up front. Specialisations that depend on shapes are enumerated over their whole range:
  /// `mul_mm`'s input/output boundary flags, `mul_mv`'s simdgroup count (1...4 by inner dimension), the head count
  /// as the batch dimension of the composed attention path, the state width of the flash-attention kernel.
  static func graphPipelineKeys() -> [PipelineKey] {
    var keys: [PipelineKey] = []
    for name in [
      "whisper_im2col_f16", "whisper_attn_decode_f32", "whisper_attn_decode_reduce_f32", "whisper_causal_mask_f32",
      "whisper_copy_f32x4", "whisper_fill_zero_f32", "kernel_soft_max_f32", "kernel_soft_max_f32_4",
      "kernel_cpy_f32_f32", "kernel_cpy_f16_f32", "kernel_get_rows_f32", "kernel_get_rows_f16", "kernel_get_rows_q8_0",
    ] {
      keys.append(PipelineKey(name))
    }
    for name in ["kernel_norm_mul_add_f32", "kernel_norm_mul_add_f32_4"] { keys.append(PipelineKey(name, [.bool(1700, false)])) }
    for name in ["kernel_unary_f32_f32", "kernel_unary_f32_f32_4"] {
      for contiguousSmall in [false, true] { keys.append(PipelineKey(name, [.short(1200, 103), .bool(1201, contiguousSmall)])) }
    }
    for vector4 in [false, true] {
      for rb in [false, true] { for cb in [false, true] { keys.append(addKey(vector4: vector4, rb: rb, cb: cb)) } }
    }
    // Matrix products: weights (f32, f16, q8_0) against f32 activations, im2col columns (f16) against conv weights
    // (f16 or f32), and the composed attention's f32 views batched over the heads.
    func matrixKeys(src0: String, src1: String, ne12: Int) -> [PipelineKey] {
      var result: [PipelineKey] = []
      for bcInp in [false, true] {
        for bcOut in [false, true] {
          result.append(matrixKey(src0: src0, src1: src1, bcInp: bcInp, bcOut: bcOut, ne12: ne12, ne13: 1, r2: 1, r3: 1))
        }
      }
      return result
    }
    for (src0, src1) in [("f32", "f32"), ("f16", "f32"), ("q8_0", "f32"), ("f16", "f16")] {
      keys += matrixKeys(src0: src0, src1: src1, ne12: 1)
    }
    for family in modelFamilies { keys += matrixKeys(src0: "f32", src1: "f32", ne12: family.heads) }
    // Matrix-vector products (up to 8 activation rows): the simdgroup count follows the inner dimension.
    for src0 in ["f32", "f16"] {
      for suffix in ["", "_4"] {
        for nsg in 1...4 { keys.append(vectorKey(src0: src0, src1: "f32", suffix: suffix, nsg: nsg, ne12: 1, r2: 1, r3: 1)) }
      }
      keys.append(vectorKey(src0: src0, src1: "f32", suffix: "_short", nsg: 1, ne12: 1, r2: 1, r3: 1))
    }
    keys.append(vectorKey(src0: "q8_0", src1: "f32", suffix: "", nsg: 4, ne12: 1, r2: 1, r3: 1))
    for family in modelFamilies {
      for suffix in ["", "_4", "_short"] {
        keys.append(vectorKey(src0: "f32", src1: "f32", suffix: suffix, nsg: 1, ne12: family.heads, r2: 1, r3: 1))
      }
    }
    for family in modelFamilies { keys.append(flashAttentionKey(d: family.state, nsg: 4)) }
    var seen = Set<PipelineKey>()
    return keys.filter { seen.insert($0).inserted }
  }

  // MARK: - Smoke test

  /// A few ops at the shapes that exercise the main kernels, read back and compared with CPU arithmetic: a device
  /// whose pipelines build but compute wrongly (or fault) is rejected by `init`.
  private func smokeTest() throws {
    var seed: UInt32 = 0x1234_5678
    func random(_ count: Int, scale: Float = 1) -> [Float] {
      (0..<count).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223  // Numerical Recipes' LCG, plenty for test inputs
        return (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * scale
      }
    }
    func check(_ label: String, _ got: [Float], _ want: [Float], tolerance: Float) throws {
      guard got.count == want.count else {
        throw WhisperError.kernelCompileFailed("smoke test: \(label) returned \(got.count) values, expected \(want.count)")
      }
      for i in 0..<got.count {
        let error = abs(got[i] - want[i]) / max(abs(want[i]), 1)
        if !(error <= tolerance) {
          throw WhisperError.kernelCompileFailed("smoke test: \(label) differs from the CPU at \(i): \(got[i]) vs \(want[i])")
        }
      }
    }

    /// C [m, n] = A [m, k] . B^T (B [n, k]) or A . B (B [k, n]); Accelerate, since a debug build's loops would
    /// make init noticeably slower.
    func product(_ a: [Float], _ b: [Float], m: Int, n: Int, k: Int, transposed: Bool) -> [Float] {
      var c = [Float](repeating: 0, count: m * n)
      cblas_sgemm(
        CblasRowMajor, CblasNoTrans, transposed ? CblasTrans : CblasNoTrans, Int32(m), Int32(n), Int32(k), 1, a, Int32(k),
        b, Int32(transposed ? k : n), 0, &c, Int32(n))
      return c
    }

    // linear: x [n, 64] against w [48, 64], f32 (mul_mv for n = 1, mul_mm for n = 16) and q8_0.
    let (inDim, out) = (64, 48)
    let w = random(out * inDim, scale: 0.5)
    let bias = random(out)
    let (q8Data, q8Values) = MetalBackend.quantizeQ8(w)
    let f32Weight = try weight(WeightTensor(name: "smoke.w32", shape: [out, inDim], type: .f32, data: w.withUnsafeBytes { Data($0) }))
    let q8Weight = try weight(WeightTensor(name: "smoke.w8", shape: [out, inDim], type: .q8_0, data: q8Data))
    let biasTensor = tensor(bias, shape: [out])
    for n in [1, 16] {
      let x = random(n * inDim)
      for (label, weightTensor, values) in [("f32", f32Weight, w), ("q8_0", q8Weight, q8Values)] {
        var want = product(x, values, m: n, n: out, k: inDim, transposed: true)
        for i in 0..<want.count { want[i] += bias[i % out] }
        let got = read(linear(tensor(x, shape: [n, inDim]), weight: weightTensor, bias: biasTensor))
        try check("linear \(label) n=\(n)", got, want, tolerance: 2e-2)
      }
    }

    // Attention: the flash kernel (nq = 64, nk = 256, one head of 64) and the split-K decode kernel (nq = 1, two
    // partitions plus the reduce).
    for (nq, nk, causal) in [(64, 256, false), (1, 256, true)] {
      let d = 64
      let q = random(nq * d), k = random(nk * d), v = random(nk * d)
      let scale: Float = 0.125
      var scores = product(q, k, m: nq, n: nk, k: d, transposed: true)
      for i in 0..<nq {
        var m = -Float.infinity
        for j in 0..<nk {
          scores[i * nk + j] = causal && j > i + nk - nq ? -.infinity : scores[i * nk + j] * scale
          m = max(m, scores[i * nk + j])
        }
        var sum: Float = 0
        for j in 0..<nk {
          let e = scores[i * nk + j] == -.infinity ? 0 : exp(scores[i * nk + j] - m)
          scores[i * nk + j] = e
          sum += e
        }
        for j in 0..<nk { scores[i * nk + j] /= sum }
      }
      let want = product(scores, v, m: nq, n: d, k: nk, transposed: false)
      let got = read(attention(query: tensor(q, shape: [nq, d]), key: tensor(k, shape: [nk, d]), value: tensor(v, shape: [nk, d]), heads: 1, scale: scale, causal: causal))
      try check("attention nq=\(nq) nk=\(nk)", got, want, tolerance: 2e-2)
    }

    if let failure = takeFailure() { throw WhisperError.kernelCompileFailed("smoke test: \(failure)") }
  }

  /// ggml's `quantize_row_q8_0_ref`: per block of 32, d = amax / 127 (stored as f16), q = round(x / d).
  static func quantizeQ8(_ values: [Float]) -> (data: Data, dequantized: [Float]) {
    precondition(values.count % 32 == 0)
    var data = Data(capacity: values.count / 32 * 34)
    var dequantized = [Float](repeating: 0, count: values.count)
    for block in 0..<(values.count / 32) {
      let slice = values[block * 32..<(block + 1) * 32]
      var amax: Float = 0
      for v in slice { amax = max(amax, abs(v)) }
      let d = amax / 127
      let id: Float = d != 0 ? 1 / d : 0
      let dBits = MetalHalf.fromFloat(d)
      let dStored = MetalHalf.toFloat(dBits)
      data.append(UInt8(dBits & 0xFF))
      data.append(UInt8(dBits >> 8))
      for (i, v) in slice.enumerated() {
        let q = Int8((v * id).rounded(.toNearestOrAwayFromZero))
        data.append(UInt8(bitPattern: q))
        dequantized[block * 32 + i] = dStored * Float(q)
      }
    }
    return (data, dequantized)
  }
}
