import Foundation
import Metal

// The Metal kernel library and the plumbing around it: the MSL sources in `Kernels/` (upstream ggml-metal kernels,
// see `Kernels/PROVENANCE.md`) are concatenated and compiled at run time, pipelines are specialised with ggml's
// function constants and cached by name, and kernel arguments are packed byte for byte like the C `ggml_metal_kargs_*`
// structs the kernels declare. Nothing here knows about tensors; `MetalBackend` does the dispatching.

/// Compiles the kernel sources into an `MTLLibrary`.
enum MetalKernelLibrary {
  /// Compilation order: headers first (quoted `#include`s are stripped, so each header appears once, in dependency
  /// order), then the kernels.
  static let sourceFiles = [
    "ggml-metal-impl.h", "common.h", "ggml-common.h", "dequantize.h",
    "mul_mm.metal", "mul_mv.metal", "norm.metal", "binbcast.metal", "unary.metal", "softmax.metal",
    "fa_common.metal", "fa_f32.metal", "cpy_get_rows.metal", "whisper.metal",
  ]

  /// The package's resource bundle name, as SwiftPM generates it (`<package>_<target>`).
  static let resourceBundleName = "WhisperEngine_WhisperEngine"

  /// Where the `Kernels` directory may be, in the search order of SwiftPM's generated `Bundle.module` accessor
  /// (the `PACKAGE_RESOURCE_BUNDLE_PATH` override in debug builds; next to the app's resources; next to the
  /// resources of the bundle this code is linked into, which is how `swift test` finds it; next to a command-line
  /// tool), then, in debug builds, the source checkout. `Bundle.module` itself is not used: its accessor
  /// `fatalError`s when a target linking the package ships without the resource bundle, where this must throw.
  static func kernelDirectoryCandidates() -> [URL] {
    final class Finder {}
    var roots: [URL] = []
    #if DEBUG
      if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
        ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"]
      {
        roots.append(URL(fileURLWithPath: override))
      }
    #endif
    let bundleFile = resourceBundleName + ".bundle"
    for parent in [Bundle.main.resourceURL, Bundle(for: Finder.self).resourceURL, Bundle.main.bundleURL] {
      if let parent { roots.append(parent.appendingPathComponent(bundleFile)) }
    }
    var candidates: [URL] = []
    for root in roots {
      // `Bundle(url:)` resolves the platform layout (`Contents/Resources` on macOS, flat on iOS).
      if let bundle = Bundle(url: root), let url = bundle.url(forResource: "Kernels", withExtension: nil) {
        candidates.append(url)
      }
      candidates.append(root.appendingPathComponent("Kernels"))
    }
    #if DEBUG
      candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Kernels"))
    #endif
    return candidates
  }

  /// The `Kernels` directory, or `.kernelCompileFailed("kernel sources not found")`.
  static func kernelDirectory() throws -> URL {
    let probe = sourceFiles[0]
    for candidate in kernelDirectoryCandidates()
    where FileManager.default.fileExists(atPath: candidate.appendingPathComponent(probe).path) {
      return candidate
    }
    throw WhisperError.kernelCompileFailed("kernel sources not found (no \(resourceBundleName).bundle with a Kernels directory)")
  }

  /// The concatenated MSL source. Quoted includes and `#pragma once` are blanked (not removed) so compiler
  /// diagnostics keep each file's line numbers; `<metal_stdlib>` and the other system includes stay.
  static func source() throws -> String {
    let directory = try kernelDirectory()
    var source = ""
    for name in sourceFiles {
      let url = directory.appendingPathComponent(name)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        throw WhisperError.kernelCompileFailed("kernel source \(name) is missing from the bundle")
      }
      source += "// ---- \(name)\n#line 1 \"\(name)\"\n"
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#include \"") || trimmed.hasPrefix("#pragma once") {
          source += "\n"
        } else {
          source += line + "\n"
        }
      }
    }
    return source
  }

  /// ggml-metal-device.m's `MTLGPUFamilyMetal4_GGML` and `MTLLanguageVersion4_0_GGML`: the Metal 4 tensor API.
  static let metal4Family = MTLGPUFamily(rawValue: 5002)
  static let metal4Language = MTLLanguageVersion(rawValue: 4 << 16)

  /// Compiles the library. Options follow ggml-metal-device.m: a fresh `MTLCompileOptions` (fast math, the default),
  /// and with `tensorAPI` the `GGML_METAL_HAS_TENSOR` macro plus Metal language version 4.0, which selects the
  /// tensor-API `kernel_mul_mm` (ggml enables it on M5-class GPUs). The bf16 kernels are not included, so
  /// `GGML_METAL_HAS_BF16` is never defined.
  static func compile(on device: MTLDevice, tensorAPI: Bool, cacheBuster: String? = nil) throws
    -> (library: MTLLibrary, seconds: TimeInterval)
  {
    var source = try source()
    // Metal caches compiled sources on disk by their text; tests append a unique comment to measure a cold compile.
    if let cacheBuster { source += "\n// \(cacheBuster)\n" }
    let options = MTLCompileOptions()
    if #available(macOS 15.0, iOS 18.0, *) {
      options.mathMode = .fast
    } else {
      options.fastMathEnabled = true
    }
    if tensorAPI {
      options.preprocessorMacros = ["GGML_METAL_HAS_TENSOR": "1" as NSString]
      if let version = metal4Language { options.languageVersion = version }
    }
    let start = Date()
    do {
      let library = try device.makeLibrary(source: source, options: options)
      return (library, Date().timeIntervalSince(start))
    } catch {
      throw WhisperError.kernelCompileFailed(String(describing: error))
    }
  }
}

/// A function constant value at its index, in the types ggml's kernels use.
enum MetalFunctionConstant: Hashable {
  case bool(Int, Bool)
  case short(Int, Int16)
  case int(Int, Int32)
}

/// A kernel plus its specialisation; hashable so hot paths look pipelines up without building strings.
struct PipelineKey: Hashable {
  var name: String
  var constants: [MetalFunctionConstant]

  init(_ name: String, _ constants: [MetalFunctionConstant] = []) {
    self.name = name
    self.constants = constants
  }
}

/// Pipeline states by kernel name and function constants. `MetalBackend.init` builds the whole set the whisper
/// graph can ask for (`build`, concurrently); `pipeline` serves them and specialises anything else on first use.
/// `pipeline` is for one thread at a time (the graph thread); `build` may run before any graph. Unchecked
/// Sendable: the dictionary is behind `lock`, and Metal's own objects are thread-safe.
final class MetalPipelineCache: @unchecked Sendable {
  private let device: MTLDevice
  private let library: MTLLibrary
  private let lock = NSLock()
  private var pipelines: [PipelineKey: MTLComputePipelineState] = [:]

  init(device: MTLDevice, library: MTLLibrary) {
    self.device = device
    self.library = library
  }

  var count: Int { lock.withLock { pipelines.count } }

  /// Builds every key not yet cached, in parallel (`makeComputePipelineState` is thread-safe and mostly waits on
  /// the GPU compiler), throwing the first failure.
  func build(_ keys: [PipelineKey]) throws {
    let missing = lock.withLock { keys.filter { pipelines[$0] == nil } }
    guard !missing.isEmpty else { return }
    let results = Results(count: missing.count)
    DispatchQueue.concurrentPerform(iterations: missing.count) { index in
      results.set(index, Result { try self.make(missing[index]) })
    }
    for (key, result) in zip(missing, results.all) {
      let pipeline = try result.get()
      lock.withLock { pipelines[key] = pipeline }
    }
  }

  /// Slots written from `concurrentPerform`'s threads, each exactly once.
  private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Result<MTLComputePipelineState, Error>?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ result: Result<MTLComputePipelineState, Error>) { lock.withLock { slots[index] = result } }
    var all: [Result<MTLComputePipelineState, Error>] { lock.withLock { slots.map { $0! } } }
  }

  func pipeline(_ key: PipelineKey) throws -> MTLComputePipelineState {
    if let cached = lock.withLock({ pipelines[key] }) { return cached }
    let pipeline = try make(key)
    lock.withLock { pipelines[key] = pipeline }
    return pipeline
  }

  private func make(_ key: PipelineKey) throws -> MTLComputePipelineState {
    let function: MTLFunction
    do {
      if key.constants.isEmpty {
        guard let plain = library.makeFunction(name: key.name) else {
          throw WhisperError.kernelCompileFailed("kernel \(key.name) is not in the library")
        }
        function = plain
      } else {
        let values = MTLFunctionConstantValues()
        for constant in key.constants {
          switch constant {
          case .bool(let index, var value): values.setConstantValue(&value, type: .bool, index: index)
          case .short(let index, var value): values.setConstantValue(&value, type: .short, index: index)
          case .int(let index, var value): values.setConstantValue(&value, type: .int, index: index)
          }
        }
        function = try library.makeFunction(name: key.name, constantValues: values)
      }
    } catch let error as WhisperError {
      throw error
    } catch {
      throw WhisperError.kernelCompileFailed("specialising \(key): \(error)")
    }
    do {
      let descriptor = MTLComputePipelineDescriptor()
      descriptor.computeFunction = function
      descriptor.label = key.name
      return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
    } catch {
      throw WhisperError.kernelCompileFailed("pipeline \(key): \(error)")
    }
  }
}

/// Packs kernel arguments with C struct layout (natural alignment, fields in declaration order, trailing padding to
/// the struct's alignment), so a Swift call site can mirror a `ggml_metal_kargs_*` definition field by field.
struct KernelArguments {
  private(set) var bytes: [UInt8] = []
  private var maxAlignment = 1

  init() { bytes.reserveCapacity(256) }

  mutating func append<T>(_ value: T) {
    let alignment = MemoryLayout<T>.alignment
    maxAlignment = max(maxAlignment, alignment)
    while bytes.count % alignment != 0 { bytes.append(0) }
    withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
  }

  mutating func append(_ values: [Int]) { for value in values { append(Int32(value)) } }
  mutating func appendStrides(_ values: [Int]) { for value in values { append(UInt64(value)) } }

  /// The packed bytes, padded like `sizeof` would.
  var packed: [UInt8] {
    var result = bytes
    while result.count % maxAlignment != 0 { result.append(0) }
    return result
  }
}

/// IEEE half <-> float conversions, bit for bit the algorithms in ggml-impl.h (`ggml_compute_fp16_to_fp32`,
/// `ggml_compute_fp32_to_fp16`: round to nearest even), so CPU-side quantisation matches ggml's.
enum MetalHalf {
  static func toFloat(_ h: UInt16) -> Float {
    let w = UInt32(h) << 16
    let sign = w & 0x8000_0000
    let twoW = w &+ w
    let expOffset: UInt32 = 0xE0 << 23
    let expScale = Float(bitPattern: 0x0780_0000)  // 0x1.0p-112f
    let normalized = Float(bitPattern: (twoW >> 4) &+ expOffset) * expScale
    let magicMask: UInt32 = 126 << 23
    let magicBias: Float = 0.5
    let denormalized = Float(bitPattern: (twoW >> 17) | magicMask) - magicBias
    let denormalizedCutoff: UInt32 = 1 << 27
    let result = sign | (twoW < denormalizedCutoff ? denormalized.bitPattern : normalized.bitPattern)
    return Float(bitPattern: result)
  }

  static func fromFloat(_ f: Float) -> UInt16 {
    let scaleToInf = Float(bitPattern: 0x7780_0000)
    let scaleToZero = Float(bitPattern: 0x0880_0000)
    var base = (abs(f) * scaleToInf) * scaleToZero
    let w = f.bitPattern
    let shl1W = w &+ w
    let sign = w & 0x8000_0000
    var bias = shl1W & 0xFF00_0000
    if bias < 0x7100_0000 { bias = 0x7100_0000 }
    base = Float(bitPattern: (bias >> 1) &+ 0x0780_0000) + base
    let bits = base.bitPattern
    let expBits = (bits >> 13) & 0x0000_7C00
    let mantissaBits = bits & 0x0000_0FFF
    let nonsign = expBits &+ mantissaBits
    return UInt16(truncatingIfNeeded: (sign >> 16) | (shl1W > 0xFF00_0000 ? 0x7E00 : nonsign))
  }

  /// Decodes `count` elements of `type` at `pointer` into floats (q8_0: `count` is a multiple of 32).
  static func decode(_ pointer: UnsafeRawPointer, count: Int, type: WeightType) -> [Float] {
    switch type {
    case .f32:
      return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self), count: count))
    case .f16:
      let halves = UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt16.self), count: count)
      return halves.map(toFloat)
    case .q8_0:
      var result = [Float](repeating: 0, count: count)
      let bytes = pointer.assumingMemoryBound(to: UInt8.self)
      for block in 0..<(count / 32) {
        let base = block * 34
        let d = toFloat(UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8)
        for i in 0..<32 {
          result[block * 32 + i] = d * Float(Int8(bitPattern: bytes[base + 2 + i]))
        }
      }
      return result
    }
  }
}
