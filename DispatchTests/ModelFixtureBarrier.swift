import Foundation
import XCTest
@testable import DispatchApp

/// A unique prompt marker controls exactly one request at the local endpoint.
struct ModelFixtureBarrier {
    let id = System.uuid().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let state: URL
    var prompt: String { "FIXTURE_BARRIER_" + id }
    private var directory: URL { state.appendingPathComponent("barriers/" + id) }

    @MainActor
    func accepted() async throws {
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Endpoint did not accept barrier " + id) {
            System.exists(directory.appendingPathComponent("accepted.json"))
        }
    }

    func release() throws { try System.write(Data(), to: directory.appendingPathComponent("release")) }
    func cancel() { try? System.write(Data(), to: directory.appendingPathComponent("cancel")) }

    @MainActor
    func completed() async throws {
        let path = directory.appendingPathComponent("completed.json")
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Endpoint did not complete barrier " + id) {
            System.exists(path)
        }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: System.read(path)) as? [String: Any])
        XCTAssertEqual(record["id"] as? String, id)
        XCTAssertEqual(record["outcome"] as? String, "delivered")
        XCTAssertEqual(record["released"] as? Bool, true)
    }
}
