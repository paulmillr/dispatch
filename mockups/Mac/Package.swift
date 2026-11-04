// swift-tools-version: 6.2
// Mac design mockups (mockups/README.md, Mac): SwiftUI screens rendered to PNG offscreen. Not part of Dispatch.xcodeproj.
import PackageDescription

let package = Package(
    name: "MacMockups",
    platforms: [.macOS(.v26)],
    targets: [
        // App/ links a few of the app's own sources (palette, host colours) so the mockups draw with its values.
        // Everything is UI: main-actor isolated by default, so screens' static samples need no Sendable ceremony.
        .executableTarget(name: "MacMockups", path: "Sources/MacMockups",
                          swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
