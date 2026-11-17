// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode: complete strict concurrency checking (no unsafe flags, so the iOS app can
// depend on this package by path).
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

// The SSH engine is the Swift one (Sources/SSHEngine). `DISPATCH_RUSSH=1` in the environment also builds in the older
// Rust russh engine (Core/, behind a C ABI; docs/ios.md, Transport): the binary target below, its glue
// (`#if DISPATCH_RUSSH`, RusshEngine.swift) and the tests that compare the two. Its XCFramework comes from
// scripts/build-mobile-ssh.py (build/mobile-ssh; Frameworks is a symlink there) and must exist before SwiftPM or Xcode
// resolves the package. Without the variable nothing here names it, so no Rust is needed.
let russh = Context.environment["DISPATCH_RUSSH"] == "1"
// MobileTransport and the tests: the compilation condition of the same name.
let transport = strict + (russh ? [.define("DISPATCH_RUSSH")] : [])

var transportDependencies: [Target.Dependency] = ["SSHEngine"]
var russhTargets: [Target] = []
if russh {
  transportDependencies.append("DispatchMobileSSHCore")
  russhTargets.append(.binaryTarget(name: "DispatchMobileSSHCore", path: "Frameworks/DispatchMobileSSHCore.xcframework"))
}

let package = Package(
  name: "MobileTransport",
  // macOS only runs `swift test` on the Mac; 26 for CryptoKit's ML-KEM (SSHEngine's mlkem768x25519-sha256).
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "MobileTransport", targets: ["MobileTransport"]),
    // Used by the separate Fuzzing/ package. That package is not part of this manifest, so neither `swift build`
    // nor `swift test` builds a fuzz harness unless it is invoked explicitly from Fuzzing/.
    .library(name: "SSHEngine", targets: ["SSHEngine"]),
  ],
  targets: russhTargets + [
    .target(name: "MobileTransport", dependencies: transportDependencies, swiftSettings: transport),
    // The Swift SSH client engine (Sources/SSHEngine/README.md): Apple's frameworks only, no package dependency.
    // MobileTransport runs on it (`SSHTransportEngine.swift`, the default).
    .target(name: "SSHEngine", exclude: ["README.md"], swiftSettings: strict),
    // MobileTransport too: the parity tests drive the engines through its public API against the scripted server.
    // Primitives/Vectors: third-party test vectors, copied unchanged (its README gives their origins and licences).
    .testTarget(name: "SSHEngineTests", dependencies: ["SSHEngine", "MobileTransport"],
                resources: [.copy("Primitives/Vectors")], swiftSettings: transport),
    .testTarget(name: "MobileTransportTests", dependencies: ["MobileTransport"], swiftSettings: transport),
    // Dispatch/Helper's wire codec, connection and transport, compiled unmodified from symlinks in
    // Tests/HelperBridgeTests/Dispatch, prove the helper channel against the real helper.
    .testTarget(name: "HelperBridgeTests", dependencies: ["MobileTransport"], swiftSettings: transport),
  ]
)
