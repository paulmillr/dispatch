import Observation
import XCTest
@testable import Dictation

/// The dictation model store against stub servers: what it finds on disk, a download that doesn't match, and cancels.
@MainActor
final class DictationModelStoreTests: XCTestCase {
    func testStoreFindsInstalledModelsAndDeletesThem() throws {
        let directory = try temporaryDirectory()
        try Data("model".utf8).write(to: directory.appendingPathComponent(WhisperModel.turbo.fileName))
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory))
        XCTAssertEqual(store.state(.whisper(.small)), .absent)
        XCTAssertNil(store.installed(.whisper(.small)))
        XCTAssertEqual(store.state(.whisper(.turbo)), .installed)
        XCTAssertEqual(store.installed(.whisper(.turbo)), directory.appendingPathComponent(WhisperModel.turbo.fileName))
        store.delete(.whisper(.turbo))
        XCTAssertEqual(store.state(.whisper(.turbo)), .absent)
        XCTAssertNil(store.installed(.whisper(.turbo)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(WhisperModel.turbo.fileName).path))
    }

    func testStoreRemovesWhatAnInterruptedDownloadLeft() throws {
        let directory = try temporaryDirectory()
        let leftover = directory.appendingPathComponent("\(WhisperModel.small.fileName).\(UUID().uuidString).partial")
        try Data("half a model".utf8).write(to: leftover)
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory))
        XCTAssertEqual(store.state(.whisper(.small)), .absent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testStoreRefusesADownloadThatDoesNotMatch() async throws {
        let directory = try temporaryDirectory()
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory), session: session(serving: StubModelServer.self))
        store.download(.whisper(.small))
        XCTAssertEqual(store.state(.whisper(.small)), .downloading(0))
        let download = try XCTUnwrap(store.downloads[.whisper(.small)]?.task)
        await download.value
        XCTAssertEqual(store.state(.whisper(.small)), .failed("The download is incomplete."))
        XCTAssertNil(store.installed(.whisper(.small)))
        XCTAssertNil(store.downloads[.whisper(.small)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testStoreCancelsADownloadInFlight() async throws {
        let directory = try temporaryDirectory()
        StalledModelServer.events.reset()
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory), session: session(serving: StalledModelServer.self))
        for attempt in 1...2 {
            store.download(.whisper(.small))
            XCTAssertEqual(store.state(.whisper(.small)), .downloading(0))
            let download = try XCTUnwrap(store.downloads[.whisper(.small)]?.task)
            // The server has answered and sent the first bytes, and then sends nothing more.
            try await eventually { StalledModelServer.events.started == attempt }
            store.cancel(.whisper(.small))
            XCTAssertEqual(store.state(.whisper(.small)), .absent)
            await download.value
            try await eventually { StalledModelServer.events.stopped == attempt }
            XCTAssertEqual(store.state(.whisper(.small)), .absent, "a cancel isn't a failure")
            XCTAssertNil(store.installed(.whisper(.small)))
            XCTAssertNil(store.downloads[.whisper(.small)])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testStoreCancelWhileVerifyingRemovesThePartialFile() async throws {
        let directory = try temporaryDirectory()
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory), session: session(serving: StubModelServer.self))
        let seen = SeenFiles()
        // Cancels on the main actor's next turn after the download turns to verifying: the store's task has then moved
        // the download to its partial file and waits for the (detached) verification.
        whenStates(of: store, satisfy: { $0.state(.whisper(.small)) == .verifying }) { store in
            seen.partials = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".partial") }
            store.cancel(.whisper(.small))
        }
        store.download(.whisper(.small))
        let download = try XCTUnwrap(store.downloads[.whisper(.small)]?.task)
        await download.value
        XCTAssertEqual(seen.partials.count, 1, "cancelled while the partial file was there")
        XCTAssertEqual(store.state(.whisper(.small)), .absent, "cancelled, not failed")
        XCTAssertNil(store.installed(.whisper(.small)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        // Deleting a model (here one put in place by hand) removes its file.
        try Data("model".utf8).write(to: store.location(.whisper(.small)))
        let reopened = DictationModelStore(whisper: directory, parakeet: parakeet(directory))
        XCTAssertEqual(reopened.installed(.whisper(.small)), store.location(.whisper(.small)))
        reopened.delete(.whisper(.small))
        XCTAssertEqual(reopened.state(.whisper(.small)), .absent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testStoreFindsParakeetsFolderAndDeletesIt() throws {
        let directory = try temporaryDirectory()
        let folder = parakeet(directory).appendingPathComponent(ParakeetModel.folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Decoder.mlmodelc"), withIntermediateDirectories: true)
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory))
        XCTAssertEqual(store.state(.parakeet), .installed)
        XCTAssertEqual(store.installed(.parakeet)?.path, folder.path)
        XCTAssertEqual(store.state(.whisper(.small)), .absent, "each engine's models in its own directory")
        store.delete(.parakeet)
        XCTAssertEqual(store.state(.parakeet), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testStoreRemovesAnInterruptedParakeetFolder() throws {
        let directory = try temporaryDirectory()
        let leftover = parakeet(directory).appendingPathComponent("\(ParakeetModel.folder).\(UUID().uuidString).partial/Encoder_v2.mlmodelc")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory))
        XCTAssertEqual(store.state(.parakeet), .absent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parakeet(directory).path), [])
    }

    /// Parakeet is a folder of files: each is fetched from the pinned revision into the partial folder, and none is
    /// kept when one doesn't match.
    func testStoreFetchesEveryParakeetFileAndRefusesAMismatch() async throws {
        let directory = try temporaryDirectory()
        RecordingModelServer.requests.reset()
        let store = DictationModelStore(whisper: directory, parakeet: parakeet(directory), session: session(serving: RecordingModelServer.self))
        store.download(.parakeet)
        let download = try XCTUnwrap(store.downloads[.parakeet]?.task)
        await download.value
        XCTAssertEqual(store.state(.parakeet), .failed("The download is incomplete."))
        XCTAssertNil(store.installed(.parakeet))
        XCTAssertEqual(RecordingModelServer.requests.paths, ParakeetModel.files.map {
            "/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(ParakeetModel.revision)/\($0.path)"
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parakeet(directory).path), [])
    }

    // MARK: - Helpers

    /// Parakeet's directory, beside the Whisper one.
    private func parakeet(_ directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-parakeet")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [parakeet = parakeet(directory)] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: parakeet)
        }
        return directory
    }

    private func session(serving server: URLProtocol.Type) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [server]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    /// Waits (polling) until `condition` holds, failing after `timeout` seconds.
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

/// What the verifying test saw in the directory when it cancelled.
@MainActor private final class SeenFiles {
    var partials: [String] = []
}

/// Runs `action` once, on the main actor's first turn after a change to the store's states makes `condition` hold.
@MainActor private func whenStates(of store: DictationModelStore, satisfy condition: @escaping @MainActor (DictationModelStore) -> Bool,
                                   _ action: @escaping @MainActor (DictationModelStore) -> Void) {
    withObservationTracking { _ = store.states } onChange: {
        Task { @MainActor in
            if condition(store) { action(store) } else { whenStates(of: store, satisfy: condition, action) }
        }
    }
}

/// Serves a few bytes for any model: not the published file.
private final class StubModelServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Data("not a model".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serves a few bytes for any file, as `StubModelServer` does, and keeps the paths asked for.
private final class RecordingModelServer: URLProtocol {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        var paths: [String] { lock.withLock { seen } }
        func add(_ path: String) { lock.withLock { seen.append(path) } }
        func reset() { lock.withLock { seen = [] } }
    }

    static let requests = Requests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.add(request.url!.path)
        let body = Data("not a model".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Announces the whole model, sends its first bytes and stalls: a download only a cancel ends.
private final class StalledModelServer: URLProtocol {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (started: 0, stopped: 0)

        var started: Int { lock.withLock { counts.started } }
        var stopped: Int { lock.withLock { counts.stopped } }
        func start() { lock.withLock { counts.started += 1 } }
        func stop() { lock.withLock { counts.stopped += 1 } }
        func reset() { lock.withLock { counts = (0, 0) } }
    }

    static let events = Events()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(WhisperModel.small.bytes)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 64 << 10))
        Self.events.start()
    }

    override func stopLoading() { Self.events.stop() }
}
