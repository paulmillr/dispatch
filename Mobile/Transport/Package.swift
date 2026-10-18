// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode: complete strict concurrency checking (no unsafe flags, so the iOS app can
// depend on this package by path).
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
  name: "MobileTransport",
  platforms: [.macOS(.v14), .iOS(.v26)],
  products: [.library(name: "MobileTransport", targets: ["MobileTransport"])],
  targets: [
    // The SSH engine (russh, Core/), built by scripts/build-mobile-ssh.py into build/mobile-ssh;
    // Frameworks is a symlink to that directory.
    .binaryTarget(name: "DispatchMobileSSHCore", path: "Frameworks/DispatchMobileSSHCore.xcframework"),
    .target(name: "MobileTransport", dependencies: ["DispatchMobileSSHCore"], swiftSettings: strict),
    .testTarget(name: "MobileTransportTests", dependencies: ["MobileTransport"], swiftSettings: strict),
    // Dispatch/Helper's wire codec, connection and transport, compiled unmodified from symlinks in
    // Tests/HelperBridgeTests/Dispatch, prove the helper channel against the real helper.
    .testTarget(name: "HelperBridgeTests", dependencies: ["MobileTransport"], swiftSettings: strict),
  ]
)
