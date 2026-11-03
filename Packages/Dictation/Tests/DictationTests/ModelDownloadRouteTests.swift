import CryptoKit
import Foundation
import Network
import XCTest
@testable import Dictation

/// Model downloads against a loopback HTTP server: the redirects the route allows and refuses, the status and declared
/// length checks, bytes counted as they stream, truncation, a cancel, and a pinned model that installs. The server is
/// `http`, so the tests' route accepts `http` where the origin is `http`; the production route is checked directly.
@MainActor
final class ModelDownloadRouteTests: XCTestCase {
    private var server: LoopbackServer!
    private var directory: URL!
    /// The model the catalog publishes in these tests.
    private nonisolated static let body = Data((0..<(256 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    private var body: Data { Self.body }

    override func setUp() async throws {
        server = try await LoopbackServer.start()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: parakeetDirectory)
    }

    private var parakeetDirectory: URL { directory.appendingPathExtension("parakeet") }
    private var origin: URL { URL(string: "http://127.0.0.1:\(server.port)")! }
    /// The tests' stand-in for Hugging Face's CDN: another host name for the same server.
    private var cdn: URL { URL(string: "http://localhost:\(server.port)")! }

    /// A store whose Whisper Small is `body` at `path` on the origin (or whatever `bytes` and `digest` say).
    private func store(_ path: String, bytes: Int64? = nil, digest: String? = nil) -> DictationModelStore {
        let file = ModelFile(path: "", bytes: bytes ?? Int64(body.count),
                             sha256: digest ?? SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                             url: origin.appendingPathComponent(path))
        let route = ModelRoute(hosts: ["localhost"], domains: [], schemes: ["http", "https"])
        return DictationModelStore(whisper: directory, parakeet: parakeetDirectory, configuration: .ephemeral, route: route) { _ in [file] }
    }

    private func download(_ store: DictationModelStore) async throws -> DictationModelStore.State {
        store.download(.whisper(.small))
        let task = try XCTUnwrap(store.downloads[.whisper(.small)]?.task)
        await task.value
        return store.state(.whisper(.small))
    }

    /// Nothing is left of a download that did not install.
    private func assertNothingLeft(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], file: file, line: line)
    }

    private nonisolated static func head(_ status: String, _ headers: [String] = []) -> String {
        (["HTTP/1.1 " + status] + headers + ["Connection: close", "", ""]).joined(separator: "\r\n")
    }

    func testAPinnedModelArrivesThroughTheCDNRedirect() async throws {
        let location = cdn.absoluteString + "/cdn/model"
        server.route("/resolve/model") { _ in
            .reply(Self.head("302 Found", ["Location: \(location)", "Set-Cookie: session=sam-example",
                                            "Content-Length: 0"]), Data())
        }
        server.route("/cdn/model") { _ in .reply(Self.head("200 OK", ["Content-Length: \(Self.body.count)"]), Self.body) }
        let store = store("resolve/model")
        let state = try await download(store)
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.installed(.whisper(.small)))), body)
        let requests = server.requests
        XCTAssertEqual(requests.map(\.path), ["/resolve/model", "/cdn/model"])
        XCTAssertEqual(requests.map(\.host), ["127.0.0.1:\(server.port)", "localhost:\(server.port)"])
        for request in requests {
            XCTAssertNil(request.headers["cookie"], "No cookie goes back: \(request.headers)")
            XCTAssertEqual(request.headers["accept-encoding"], "identity")
        }
    }

    func testARedirectToAnUnrelatedHostIsNotFollowed() async throws {
        server.route("/resolve/model") { _ in
            .reply(Self.head("302 Found", ["Location: https://downloads.example.invalid/model", "Content-Length: 0"]), Data())
        }
        let state = try await download(store("resolve/model"))
        XCTAssertEqual(state, .failed("The download was redirected to downloads.example.invalid, which isn’t where models come from."))
        XCTAssertEqual(server.requests.map(\.path), ["/resolve/model"])
        try assertNothingLeft()
    }

    func testTooManyRedirectsEndTheDownload() async throws {
        server.route("/loop") { _ in .reply(Self.head("302 Found", ["Location: /loop", "Content-Length: 0"]), Data()) }
        let state = try await download(store("loop"))
        XCTAssertEqual(state, .failed("The download was redirected to 127.0.0.1, which isn’t where models come from."))
        XCTAssertEqual(server.requests.count, ModelRoute.huggingFace.redirects + 1)
        try assertNothingLeft()
    }

    /// The production route: Hugging Face's origin, its CDN, `https` only, no downgrade, no lookalikes.
    func testTheHuggingFaceRouteAllowsOnlyItsCDNOverHTTPS() {
        let route = ModelRoute.huggingFace
        let origin = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
        for allowed in ["https://us.aws.cdn.hf.co/xet-bridge-us/641ab5d1/edd29d67?X-Xet-Cas-Uid=public",
                        "https://cas-bridge.xethub.hf.co/xet-bridge-us/641ab5d1",
                        "https://cdn-lfs-us-1.huggingface.co/repos/ab/cd/ef",
                        "https://cdn-lfs.hf.co/repos/ab/cd/ef",
                        "https://huggingface.co/api/resolve-cache/models/FluidInference/parakeet/7dd20fe6/vocab.json"] {
            XCTAssertTrue(route.allows(URL(string: allowed)!, after: origin, origin: origin), allowed)
        }
        for refused in ["http://us.aws.cdn.hf.co/xet-bridge-us/641ab5d1",
                        "http://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
                        "https://downloads.example.invalid/ggml-small.bin",
                        "https://hf.co.example.invalid/ggml-small.bin",
                        "https://evilhf.co/ggml-small.bin",
                        "https://huggingface.co.example.invalid/ggml-small.bin",
                        "https://sam:secret@us.aws.cdn.hf.co/xet-bridge-us/641ab5d1",
                        "https://us.aws.cdn.hf.co:8443/xet-bridge-us/641ab5d1",
                        "https://huggingface.co:8443/ggerganov/whisper.cpp",
                        "ftp://us.aws.cdn.hf.co/xet-bridge-us/641ab5d1"] {
            XCTAssertFalse(route.allows(URL(string: refused)!, after: origin, origin: origin), refused)
        }
        // A downgrade is refused even where the route accepts plain http (as the loopback tests' does).
        let lenient = ModelRoute(schemes: ["http", "https"])
        XCTAssertFalse(lenient.allows(URL(string: "http://us.aws.cdn.hf.co/x")!, after: origin, origin: origin))
        XCTAssertTrue(lenient.allows(URL(string: "https://us.aws.cdn.hf.co/x")!, after: origin, origin: origin))
    }

    func testAnUnannouncedLengthIsCountedAndAccepted() async throws {
        // Close-delimited: no Content-Length, the body ends with the connection.
        server.route("/model") { _ in .reply(Self.head("200 OK"), Self.body) }
        let store = store("model")
        let state = try await download(store)
        XCTAssertEqual(state, .installed)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(store.installed(.whisper(.small)))), body)
    }

    func testAFalseAnnouncedLengthEndsTheDownloadAtTheHeaders() async throws {
        // Announces a gigabyte, sends a little and holds the connection: the download ends on the headers.
        server.route("/model") { _ in .stall(Self.head("200 OK", ["Content-Length: \(1 << 30)"]), Data(repeating: 1, count: 1024)) }
        let state = try await download(store("model"))
        XCTAssertEqual(state, .failed("The server announced another size than the published model’s."))
        try assertNothingLeft()
        try await eventually { self.server.closed == 1 }
    }

    func testAnOversizedChunkedBodyIsCutOffPastTheModelsSize() async throws {
        // Chunked, without end: the download stops at the first chunk past the published size.
        server.route("/model") { _ in .chunks(Self.head("200 OK", ["Transfer-Encoding: chunked"]), Data(repeating: 2, count: 64 << 10), limit: 512 << 20) }
        let state = try await download(store("model"))
        XCTAssertEqual(state, .failed("The server sent more than the published model."))
        try assertNothingLeft()
        try await eventually { self.server.closed == 1 }
        XCTAssertLessThan(server.sent, 64 << 20, "The client hung up long before the server's bound")
    }

    func testATruncatedBodyFails() async throws {
        // Announces the right length and closes halfway.
        server.route("/model") { _ in .reply(Self.head("200 OK", ["Content-Length: \(Self.body.count)"]), Self.body.prefix(1000)) }
        guard case .failed = try await download(store("model")) else { return XCTFail("a truncated body installed") }
        try assertNothingLeft()
        // Close-delimited, ending early: only the count tells.
        server.route("/short") { _ in .reply(Self.head("200 OK"), Self.body.prefix(1000)) }
        let state = try await download(store("short"))
        XCTAssertEqual(state, .failed("The download is incomplete."))
        try assertNothingLeft()
    }

    func testAnErrorStatusFails() async throws {
        server.route("/model") { _ in .reply(Self.head("404 Not Found", ["Content-Length: 9"]), Data("not found".utf8)) }
        let state = try await download(store("model"))
        XCTAssertEqual(state, .failed("The server answered 404."))
        try assertNothingLeft()
    }

    func testACancelEndsTheTransfer() async throws {
        server.route("/model") { _ in .stall(Self.head("200 OK", ["Content-Length: \(Self.body.count)"]), Self.body.prefix(1000)) }
        let store = store("model")
        store.download(.whisper(.small))
        let task = try XCTUnwrap(store.downloads[.whisper(.small)]?.task)
        try await eventually { self.server.requests.count == 1 }
        store.cancel(.whisper(.small))
        await task.value
        XCTAssertEqual(store.state(.whisper(.small)), .absent, "a cancel isn't a failure")
        try await eventually { self.server.closed == 1 }
        try assertNothingLeft()
    }

    func testAMismatchedHashIsStillRefused() async throws {
        server.route("/model") { _ in .reply(Self.head("200 OK", ["Content-Length: \(Self.body.count)"]), Self.body) }
        let state = try await download(store("model", digest: String(repeating: "0", count: 64)))
        XCTAssertEqual(state, .failed("The download doesn’t match the published model."))
        try assertNothingLeft()
    }

    private func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            guard Date.now < deadline else {
                XCTFail("timed out", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A one-request-per-connection HTTP/1.1 server on 127.0.0.1 whose answers the test scripts by path.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let host: String
        /// Lowercased names.
        let headers: [String: String]
    }

    enum Answer: Sendable {
        /// The head and body, then the connection closes.
        case reply(String, Data)
        /// The head and the start of a body, then nothing until the client hangs up.
        case stall(String, Data)
        /// The head, then this chunk over and over (chunked encoding) until the client hangs up or `limit` bytes went.
        case chunks(String, Data, limit: Int)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private let lock = NSLock()
    private var routes: [String: @Sendable (Request) -> Answer] = [:]
    private var seen: [Request] = []
    private var closedCount = 0
    private var sentBytes = 0
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = LoopbackServer(listener: try NWListener(using: parameters))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            server.listener.newConnectionHandler = { server.accept($0) }
            server.listener.start(queue: server.queue)
        }
        server.port = server.listener.port?.rawValue ?? 0
        return server
    }

    func stop() { listener.cancel() }

    func route(_ path: String, _ answer: @escaping @Sendable (Request) -> Answer) { lock.withLock { routes[path] = answer } }
    var requests: [Request] { lock.withLock { seen } }
    /// Connections the client hung up on (or that ended).
    var closed: Int { lock.withLock { closedCount } }
    /// Body bytes written in all.
    var sent: Int { lock.withLock { sentBytes } }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return self.answer(connection, String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            }
            if complete || error != nil { return self.end(connection) }
            self.read(connection, buffer)
        }
    }

    private func answer(_ connection: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let request = Request(path: path, host: headers["host"] ?? "", headers: headers)
        let route = lock.withLock { () -> (@Sendable (Request) -> Answer)? in
            seen.append(request)
            return routes[path]
        }
        switch route?(request) ?? .reply("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", Data()) {
        case .reply(let head, let body):
            send(connection, Data(head.utf8) + body) { self.end(connection) }
        case .stall(let head, let body):
            send(connection, Data(head.utf8) + body) { self.waitForHangUp(connection) }
        case .chunks(let head, let chunk, let limit):
            send(connection, Data(head.utf8)) { self.stream(connection, chunk, left: limit) }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data, then next: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { return self.end(connection) }
            self.lock.withLock { self.sentBytes += data.count }
            next()
        })
    }

    private func stream(_ connection: NWConnection, _ chunk: Data, left: Int) {
        guard left > 0 else { return send(connection, Data("0\r\n\r\n".utf8)) { self.end(connection) } }
        let framed = Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8)
        send(connection, framed) { self.stream(connection, chunk, left: left - chunk.count) }
    }

    private func waitForHangUp(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in
            if complete || error != nil { return self.end(connection) }
            self.waitForHangUp(connection)
        }
    }

    private func end(_ connection: NWConnection) {
        guard connection.state != .cancelled else { return }
        connection.cancel()
        lock.withLock { closedCount += 1 }
    }
}

/// Runs its body the first time only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
