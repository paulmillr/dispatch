// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode: complete strict concurrency checking.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]
// Accelerate's current CBLAS headers (the old ones are deprecated); a local package may use unsafe flags.
let accelerate: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])]

// WhisperEngine: OpenAI's Whisper in Swift, reading whisper.cpp's ggml model files, with a CPU (Accelerate) and a
// Metal backend. No C, C++ or Objective-C; the Metal kernels are MSL source compiled when the engine first runs
// (Xcode 27 ships no Metal toolchain), so they are plain resources here.
let package = Package(
  name: "WhisperEngine",
  platforms: [.macOS(.v14), .iOS(.v26)],
  products: [.library(name: "WhisperEngine", targets: ["WhisperEngine"])],
  targets: [
    .target(
      name: "WhisperEngine",
      path: "Sources/WhisperEngine",
      resources: [.copy("Kernels")],
      swiftSettings: strict + accelerate,
      linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("Metal")]
    ),
    .testTarget(
      name: "WhisperEngineTests", dependencies: ["WhisperEngine"], path: "Tests/WhisperEngineTests",
      swiftSettings: strict),
  ]
)
