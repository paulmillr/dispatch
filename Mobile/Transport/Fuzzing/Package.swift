// swift-tools-version: 6.2
import PackageDescription
import Foundation

let harnessSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  // libFuzzer supplies main().
  .unsafeFlags(["-parse-as-library"]),
]
let llvmRoot = ProcessInfo.processInfo.environment["FUZZER_LLVM_ROOT"] ?? "/opt/homebrew/opt/llvm@22"
let harnessLinkerSettings: [LinkerSetting] = [
  // Xcode's compiler has sanitizer coverage and ASan but its toolchain omits the libFuzzer runtime. The build
  // script locates Homebrew LLVM's arm64 runtime. Link it to macOS's libc++; statically mixing Homebrew's libc++
  // with the system copy gives libFuzzer two incompatible locale/allocator implementations under ASan.
  .unsafeFlags([ProcessInfo.processInfo.environment["FUZZER_RUNTIME"] ??
    "\(llvmRoot)/lib/clang/22/lib/darwin/libclang_rt.fuzzer_osx.a"]),
  .linkedLibrary("c++"),
]

let package = Package(
  name: "SSHEngineFuzzing",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "seed-corpus", targets: ["SeedCorpus"]),
    .executable(name: "fuzz-client-initial", targets: ["FuzzClientInitial"]),
    .executable(name: "fuzz-client-post-kex", targets: ["FuzzClientPostKex"]),
    .executable(name: "fuzz-messages", targets: ["FuzzMessages"]),
    .executable(name: "fuzz-key-blobs", targets: ["FuzzKeyBlobs"]),
    .executable(name: "fuzz-signatures", targets: ["FuzzSignatures"]),
    .executable(name: "fuzz-key-files", targets: ["FuzzKeyFiles"]),
  ],
  dependencies: [.package(path: "..")],
  targets: [
    .executableTarget(name: "SeedCorpus"),
    .executableTarget(name: "FuzzClientInitial", dependencies: [.product(name: "SSHEngine", package: "Transport")],
                      swiftSettings: harnessSwiftSettings, linkerSettings: harnessLinkerSettings),
    .executableTarget(name: "FuzzClientPostKex", dependencies: [.product(name: "SSHEngine", package: "Transport")],
                      swiftSettings: harnessSwiftSettings, linkerSettings: harnessLinkerSettings),
    .executableTarget(name: "FuzzMessages", dependencies: [.product(name: "SSHEngine", package: "Transport")],
                      swiftSettings: harnessSwiftSettings, linkerSettings: harnessLinkerSettings),
    .executableTarget(name: "FuzzKeyBlobs", dependencies: [.product(name: "SSHEngine", package: "Transport")],
                      swiftSettings: harnessSwiftSettings, linkerSettings: harnessLinkerSettings),
    .executableTarget(name: "FuzzSignatures", dependencies: [.product(name: "SSHEngine", package: "Transport")],
                      swiftSettings: harnessSwiftSettings, linkerSettings: harnessLinkerSettings),
    .executableTarget(name: "FuzzKeyFiles", dependencies: [.product(name: "SSHEngine", package: "Transport")],
                      swiftSettings: harnessSwiftSettings, linkerSettings: harnessLinkerSettings),
    .testTarget(name: "SSHEngineFuzzingTests", dependencies: [.product(name: "SSHEngine", package: "Transport")]),
  ]
)
