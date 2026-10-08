import Foundation
import XCTest

/// A unique prompt marker controls exactly one request at the local endpoint.
struct ModelFixtureBarrier {
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let state: URL
    var prompt: String { "FIXTURE_BARRIER_" + id }
    private var directory: URL { state.appendingPathComponent("barriers/" + id) }

    @MainActor
    func accepted() async throws {
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Endpoint did not accept barrier " + id) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("accepted.json").path)
        }
    }

    func release() throws { try Data().write(to: directory.appendingPathComponent("release"), options: .atomic) }
    func cancel() { try? Data().write(to: directory.appendingPathComponent("cancel"), options: .atomic) }

    @MainActor
    func completed() async throws {
        let path = directory.appendingPathComponent("completed.json")
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Endpoint did not complete barrier " + id) {
            FileManager.default.fileExists(atPath: path.path)
        }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(record["id"] as? String, id)
        XCTAssertEqual(record["outcome"] as? String, "delivered")
        XCTAssertEqual(record["released"] as? Bool, true)
    }
}
