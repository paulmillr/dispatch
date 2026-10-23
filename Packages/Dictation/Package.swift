// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode: complete strict concurrency checking.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
  name: "Dictation",
  platforms: [.macOS(.v14), .iOS(.v26)],
  products: [.library(name: "Dictation", targets: ["Dictation"])],
  // WhisperEngine (Packages/WhisperEngine): whisper.cpp in Swift, the engine behind `WhisperTranscriber`.
  dependencies: [.package(path: "../WhisperEngine")],
  targets: [
    // The dictation engine: Whisper and Apple speech transcribers, audio capture, the model store.
    .target(
      name: "Dictation", dependencies: [.product(name: "WhisperEngine", package: "WhisperEngine")],
      path: "Sources/Dictation", swiftSettings: strict),
    .testTarget(
      name: "DictationTests", dependencies: ["Dictation", "WhisperEngine"], path: "Tests/DictationTests",
      swiftSettings: strict),
  ]
)
