import Foundation
import XCTest

/// Serial fixture phases, retained with VM results even when a scenario fails.
@MainActor
final class WalkthroughTimings {
    private let test: String
    private let agent: String
    private let transport: String
    private let started = ContinuousClock.now
    private var current: (name: String, started: ContinuousClock.Instant)?
    private var phases: [[String: Any]] = []

    init(test: String, agent: String, transport: String) {
        self.test = test; self.agent = agent; self.transport = transport
    }

    func begin(_ name: String) {
        finishPhase()
        current = (name, .now)
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let value = instant.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    private func finishPhase() {
        if let current { phases.append(["name": current.name, "seconds": seconds(since: current.started)]) }
        current = nil
    }

    func save(passed: Bool) {
        finishPhase()
        let directory = CodexTestSupport.root.appendingPathComponent("build/chat-walkthrough-validation")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let value: [String: Any] = ["test": test, "agent": agent, "transport": transport,
                                       "passed": passed, "seconds": seconds(since: started), "phases": phases]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch { XCTFail("Cannot preserve walkthrough phases: \(error)") }
    }
}
