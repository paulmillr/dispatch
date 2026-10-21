import Foundation
import Metal

// Device tensors on Metal: a shared-storage `MTLBuffer` (unified memory on Apple Silicon, so uploads and reads are
// plain memcpys once the GPU is done), a byte offset (row views share their parent's storage) and the storage type:
// `.f32` for activations, the model file's `.f16` or `.q8_0` for weights that the matmul kernels consume directly.
// Activation buffers come from a pool and go back to it when the last tensor using them is released.

/// Recycles activation buffers by size class. A buffer released while a command buffer is open may still be read by
/// dispatches already encoded into it; it can be handed to a *later* dispatch (one queue runs command buffers in
/// commit order, and the serial encoder orders dispatches inside one) but not to the CPU, so such buffers wait in
/// `pending`, tagged with the generation of the command buffer open at the time, and move to `free` once that
/// command buffer (and therefore every earlier one) has completed. With several command buffers in flight (the
/// iOS split in `MetalBackend`) a buffer tagged `g` is only ever read by command buffers up to `g`, so completion
/// of `g` frees it.
///
/// Thread safety: every method takes `lock`. `give` runs from `MetalStorage.deinit` on whatever thread drops the
/// last tensor sharing a buffer (a session released from a background thread while a graph runs elsewhere),
/// `completed` from Metal's completion handlers, `take` and `opened` from the graph thread. Unchecked Sendable for
/// that reason: every piece of state is behind the lock.
final class MetalBufferPool: @unchecked Sendable {
  private let device: MTLDevice
  private let lock = NSLock()
  private var free: [Int: [MTLBuffer]] = [:]
  private var pending: [Int: [(generation: Int, buffer: MTLBuffer)]] = [:]
  /// The command buffer open now (the newest one that can still receive a dispatch reading a released buffer).
  private var openGeneration = 0
  /// The newest command buffer known to have completed; every earlier one has too.
  private var completedGeneration = 0
  private var allocationCount = 0
  private var allocatedByteCount = 0
  private var reuseCount = 0
  private var outstandingCount = 0

  init(device: MTLDevice) { self.device = device }

  /// Buffers are rounded up to 64 KiB classes (one page of waste at most for the activations that matter).
  static func sizeClass(_ bytes: Int) -> Int { (max(bytes, 1) + 0xFFFF) & ~0xFFFF }

  /// Buffers ever allocated by the pool.
  var allocations: Int { lock.withLock { allocationCount } }
  var allocatedBytes: Int { lock.withLock { allocatedByteCount } }
  /// `take` calls served from `free` or `pending`.
  var reuses: Int { lock.withLock { reuseCount } }
  /// Buffers handed out and not yet given back (live tensors' storage).
  var outstanding: Int { lock.withLock { outstandingCount } }
  var freeCount: Int { lock.withLock { free.values.reduce(0) { $0 + $1.count } } }
  var pendingCount: Int { lock.withLock { pending.values.reduce(0) { $0 + $1.count } } }

  /// A buffer of at least `bytes`, nil when Metal cannot allocate one (memory pressure). `forCPUWrite` restricts the
  /// choice to buffers no pending GPU work can read.
  func take(bytes: Int, forCPUWrite: Bool) -> MTLBuffer? {
    let size = MetalBufferPool.sizeClass(bytes)
    return lock.withLock {
      if let buffer = free[size]?.popLast() {
        reuseCount += 1
        outstandingCount += 1
        return buffer
      }
      if !forCPUWrite, let entry = pending[size]?.popLast() {
        reuseCount += 1
        outstandingCount += 1
        return entry.buffer
      }
      guard let buffer = device.makeBuffer(length: size, options: .storageModeShared) else { return nil }
      allocationCount += 1
      allocatedByteCount += size
      outstandingCount += 1
      return buffer
    }
  }

  /// Returns a buffer from `take` once no tensor uses it.
  func give(_ buffer: MTLBuffer) {
    lock.withLock {
      outstandingCount -= 1
      if completedGeneration >= openGeneration {
        free[buffer.length, default: []].append(buffer)  // nothing that could read it is open or in flight
      } else {
        pending[buffer.length, default: []].append((openGeneration, buffer))
      }
    }
  }

  /// The backend opened command buffer `generation` (generations increase; buffers released from now on may be
  /// read by it).
  func opened(generation: Int) {
    lock.withLock { openGeneration = max(openGeneration, generation) }
  }

  /// Command buffer `generation` has completed, and with it every earlier one: their pending buffers become free.
  /// Idempotent, and tolerant of handlers arriving out of order.
  func completed(generation: Int) {
    lock.withLock {
      guard generation > completedGeneration else { return }
      completedGeneration = generation
      for (size, entries) in pending where !entries.isEmpty {
        var kept: [(generation: Int, buffer: MTLBuffer)] = []
        for entry in entries {
          if entry.generation <= generation {
            free[size, default: []].append(entry.buffer)
          } else {
            kept.append(entry)
          }
        }
        pending[size] = kept
      }
    }
  }
}

/// The owner of a buffer: pooled activations return to the pool when the last tensor sharing them goes away;
/// weights and other unpooled buffers are simply released.
final class MetalStorage {
  let buffer: MTLBuffer
  private let pool: MetalBufferPool?

  init(buffer: MTLBuffer, pool: MetalBufferPool?) {
    self.buffer = buffer
    self.pool = pool
  }

  deinit { pool?.give(buffer) }
}

/// A tensor on the Metal device. Row-major in `shape`; the last dimension is contiguous.
public final class MetalTensor: DeviceTensor {
  public let shape: [Int]
  let type: WeightType
  let storage: MetalStorage
  /// Byte offset of the first element inside `buffer`.
  let offset: Int

  init(storage: MetalStorage, offset: Int, shape: [Int], type: WeightType) {
    self.storage = storage
    self.offset = offset
    self.shape = shape
    self.type = type
  }

  var buffer: MTLBuffer { storage.buffer }
  var elementCount: Int { shape.reduce(1, *) }
  var byteCount: Int { type.byteCount(elements: elementCount) }
  /// The contiguous dimension.
  var columns: Int { shape.last ?? 1 }
  /// Everything but the contiguous dimension, flattened.
  var rows: Int { shape.dropLast().reduce(1, *) }
  var rowBytes: Int { type.byteCount(elements: columns) }
  /// False for the placeholder a failed allocation produced (`MetalBackend`): its buffer is too small for the
  /// shape, so nothing may read or write through it.
  var holdsData: Bool { offset + byteCount <= buffer.length }

  /// The tensor as ggml sees a matrix: `ne = [columns, rows, 1, 1]`, byte strides in `nb`.
  var matrix: MetalView { MetalView(self, ne: [columns, rows, 1, 1]) }
}

/// A ggml-style description of (part of) a buffer: `ne` are element counts per dimension, innermost first (the
/// reverse of a Swift shape), `nb` byte strides. This is the vocabulary of the upstream kernels and their host
/// code, so dispatch logic ported from ggml-metal-ops.cpp reads the same here.
struct MetalView {
  var buffer: MTLBuffer
  var offset: Int
  var type: WeightType
  var ne: [Int]
  var nb: [Int]

  /// A contiguous view of `tensor` with the given `ne` (whose product must be the tensor's element count).
  init(_ tensor: MetalTensor, ne: [Int]) {
    precondition(ne.count == 4 && ne.reduce(1, *) == tensor.elementCount, "view does not cover the tensor")
    self.init(buffer: tensor.buffer, offset: tensor.offset, type: tensor.type, ne: ne, nb: MetalView.contiguousStrides(ne, type: tensor.type))
  }

  init(buffer: MTLBuffer, offset: Int, type: WeightType, ne: [Int], nb: [Int]) {
    precondition(ne.count == 4 && nb.count == 4)
    self.buffer = buffer
    self.offset = offset
    self.type = type
    self.ne = ne
    self.nb = nb
  }

  /// ggml's strides for a contiguous tensor: `nb[0]` is the type size (34 for a q8_0 block), `nb[1]` a row.
  static func contiguousStrides(_ ne: [Int], type: WeightType) -> [Int] {
    let row = type.byteCount(elements: ne[0])
    return [type == .q8_0 ? 34 : type.byteCount(elements: 1), row, row * ne[1], row * ne[1] * ne[2]]
  }

  var isContiguous: Bool { nb == MetalView.contiguousStrides(ne, type: type) }
  var elementCount: Int { ne.reduce(1, *) }
  var rowCount: Int { ne[1] * ne[2] * ne[3] }
  var typeName: String {
    switch type {
    case .f32: "f32"
    case .f16: "f16"
    case .q8_0: "q8_0"
    }
  }
}
