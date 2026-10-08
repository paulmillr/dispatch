import Foundation
import XCTest
@testable import DispatchApp

final class SSHProtocolV2Tests: XCTestCase {
    /// The old operation codec is gone; its retained unknown-field refusal protects current routes.
    @MainActor
    func testHerdrOperationCodecRejectsGenericControlsAndUnknownFields() async throws {
        struct Route: Encodable { let mux: UInt64; let key: String; let socket: String }
        struct Echo: Codable, Equatable { let value: String }
        let connection = try await HelperApp.shared.connection()
        let client = HelperClient(connection)
        let backends = try await client.backends()
        let backend = try XCTUnwrap(backends.first { $0.key == "native" })
        do {
            let _: HelperClient.Ignored = try await connection.request("backends.open",
                params: Route(mux: backend.mux, key: backend.key, socket: "/tmp/other"))
            XCTFail("An unknown socket field supplied authority outside the advertised backend route")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, "invalid_input")
        }
        let barrier = Echo(value: "connection remains usable")
        let reply: Echo = try await connection.request("echo", params: barrier)
        XCTAssertEqual(reply, barrier)
    }

    /// A connection cannot mutate another connection's backend nodes.
    @MainActor
    func testBackendHandlesCannotCrossConnections() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("b" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try XCTUnwrap(HelperApp.executable)
        var sessions: [HelperSession] = []
        defer { for session in sessions { session.close() } }
        for index in 0..<2 {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--stdio"]
            var environment = ProcessInfo.processInfo.environment
            if let capture = environment["DISPATCH_CAPTURE"] {
                environment["DISPATCH_CAPTURE"] = capture + ".client-\(index)-%p.jsonl"
            }
            process.environment = environment
            process.standardError = FileHandle.nullDevice
            sessions.append(try await HelperSession(process: process))
        }
        XCTAssertFalse(sessions[0].connection === sessions[1].connection)
        let clients = sessions.map { HelperClient($0.connection) }
        let backends = try await clients[0].backends()
        let backend = try XCTUnwrap(backends.first { $0.key == "native" })
        let (updates, continuation) = AsyncThrowingStream<HelperClient.Update, any Error>.makeStream()
        _ = try await clients[0].open(backend.route) { result in
            switch result {
            case .success(let update): continuation.yield(update)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
        var parent: UInt64?
        for try await update in updates {
            if case .topology(let topology) = update { parent = topology.backend; break }
        }
        let node = try await clients[0].create(.init(parent: XCTUnwrap(parent), beside: nil,
                                                    cwd: root.path, launch: nil, command: "sleep 60"))
        defer { continuation.finish() }
        do {
            try await clients[1].rename(.init(node: node, name: "foreign mutation"))
            XCTFail("Foreign connection accepted another connection's backend node")
        } catch { }
        try await clients[0].rename(.init(node: node, name: "owner remains usable"))
        let closed = try await clients[0].close(.init(node: node, policy: .terminate))
        XCTAssertEqual(closed, .init(closed: true, confirmation: false))
    }

    /// An actual pathname replacement must not satisfy a read guarded by its old inode.
    @MainActor
    func testFileReadRejectsMetadataIdentityMismatch() async throws {
        struct Revision: Encodable { let inode: UInt64; let device: UInt64 }
        struct Read: Encodable { let path: String; let offset: UInt64; let length: UInt64; let revision: Revision }
        struct Metadata: Decodable { let size: UInt64; let inode: UInt64; let device: UInt64 }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent("r" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout")
        let bytes = Data(repeating: 0x61, count: 64)
        try bytes.write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let revision = Revision(inode: try XCTUnwrap(before[.systemFileNumber] as? NSNumber).uint64Value,
                                device: try XCTUnwrap(before[.systemNumber] as? NSNumber).uint64Value)
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.standardError = FileHandle.nullDevice
        let session = try await HelperSession(process: process)
        defer { session.close() }
        let original: (result: Metadata, bytes: Data) = try await session.connection.requestBinary(
            "files.read", params: Read(path: file.path, offset: 0, length: 64, revision: revision))
        XCTAssertEqual(original.bytes, bytes)
        XCTAssertEqual(original.result.inode, revision.inode)
        XCTAssertEqual(original.result.device, revision.device)
        try bytes.write(to: file, options: .atomic)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(try XCTUnwrap(after[.systemFileNumber] as? NSNumber).uint64Value, revision.inode)
        do {
            let _: (result: Metadata, bytes: Data) = try await session.connection.requestBinary(
                "files.read", params: Read(path: file.path, offset: 0, length: 64, revision: revision))
            XCTFail("Substituted file metadata was accepted")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure.code, "changed")
        }
    }
}
