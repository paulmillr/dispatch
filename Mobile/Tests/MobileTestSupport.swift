import Foundation
import UIKit
import XCTest
@testable import DispatchMobile

/// What the shared Mac test files ask of `System` and `TestSupport` (DispatchTests/TestSupport.swift, AppKit only),
/// answered for the simulator.
extension System {
    /// The checkout the tests were built from: the simulator reads the Mac's file system, so fixtures load in place.
    static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

@MainActor
enum TestSupport {
    /// Polls `condition` until it holds or `timeout` passes (the Mac's TestSupport.eventually without its diagnostics).
    static func eventually(timeout: Duration = .seconds(5), interval: Duration = .milliseconds(25),
                           file: StaticString = #filePath, line: UInt = #line,
                           diagnostic: @autoclosure () -> String = "Condition timed out",
                           _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: interval)
        }
        if try await condition() { return }
        XCTFail(diagnostic(), file: file, line: line)
    }

    /// The test host's window scene. Right after a fresh install the host may not have connected its scene when the
    /// first test runs, so this waits for it (up to 10 s) instead of failing that test.
    static func windowScene() -> UIWindowScene? {
        let deadline = Date().addingTimeInterval(10)
        while true {
            if let scene = connectedScene { return scene }
            guard Date() < deadline else { return nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    static func windowScene() async -> UIWindowScene? {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if let scene = connectedScene { return scene }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static var connectedScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}
