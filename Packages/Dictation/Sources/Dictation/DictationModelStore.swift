import CryptoKit
import Foundation
import Observation

/// The dictation models on this device: Settings downloads and deletes them, dictation reads them. Whisper's are files
/// in one directory, Parakeet's a folder of files in another. A download goes to a partial file (or folder) and becomes
/// the model only once every file's size and SHA-256 match `DictationModel`'s. Each app makes one, for its directories.
///
/// Downloads use their own ephemeral session: no cookies, cache or credentials, and `Accept-Encoding: identity` so the
/// bytes counted are the file's. Every redirect must stay on the route `ModelRoute` allows (the model's origin and
/// Hugging Face's CDN, `https` only); anything else ends the download before it is followed. A response must be a 200
/// whose declared length, when it declares one, is the file's; the bytes are counted as they arrive and the download
/// stops at the first byte past the file's size. The size and SHA-256 checks still decide before the model moves in.
@MainActor @Observable public final class DictationModelStore {
    public enum State: Equatable {
        case absent
        /// The fraction downloaded, then verified.
        case downloading(Double)
        case verifying
        case installed
        case failed(String)
    }

    let whisperDirectory: URL
    let parakeetDirectory: URL
    private(set) var states: [DictationModel: State] = [:]
    /// The running download of each model, by id: a cancelled download's last steps leave a newer one alone. (Tests
    /// wait for its task.)
    @ObservationIgnored private(set) var downloads: [DictationModel: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Never invalidated: each app's store lives as long as the app, and a download's task (which holds the session,
    /// not the store) could otherwise create its next file's request on an invalidated session, which raises.
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let route: ModelRoute
    @ObservationIgnored private let catalog: @Sendable (DictationModel) -> [ModelFile]

    public convenience init(whisper: URL, parakeet: URL) {
        self.init(whisper: whisper, parakeet: parakeet, configuration: .ephemeral)
    }

    /// `configuration` is hardened whatever it is (tests add their protocol classes); `catalog` stands in for the
    /// published files in tests.
    init(whisper: URL, parakeet: URL, configuration: URLSessionConfiguration, route: ModelRoute = .huggingFace,
         catalog: @escaping @Sendable (DictationModel) -> [ModelFile] = { $0.files }) {
        whisperDirectory = whisper
        parakeetDirectory = parakeet
        session = URLSession(configuration: ModelRoute.harden(configuration))
        self.route = route
        self.catalog = catalog
        for model in DictationModel.all {
            states[model] = FileManager.default.fileExists(atPath: location(model).path) ? .installed : .absent
        }
        // What a quit or crash left mid-download.
        for directory in [whisper, parakeet] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".partial") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    public func state(_ model: DictationModel) -> State { states[model] ?? .absent }

    /// The model's file, or Parakeet's folder.
    func location(_ model: DictationModel) -> URL {
        switch model {
        case .whisper(let whisper): whisperDirectory.appendingPathComponent(whisper.fileName)
        case .parakeet: parakeetDirectory.appendingPathComponent(ParakeetModel.folder)
        }
    }

    /// The model's file or folder, when it is downloaded and verified.
    func installed(_ model: DictationModel) -> URL? { state(model) == .installed ? location(model) : nil }

    public func download(_ model: DictationModel) {
        guard downloads[model] == nil, state(model) != .installed else { return }
        let id = UUID()
        states[model] = .downloading(0)
        let final = location(model)
        let task = Task { [weak self, session, route, catalog] in
            let partial = final.deletingLastPathComponent().appendingPathComponent("\(final.lastPathComponent).\(id.uuidString).partial")
            do {
                try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                let files = catalog(model)
                let total = Double(files.reduce(0) { $0 + $1.bytes })
                var done: Int64 = 0
                for file in files {
                    try Task.checkCancellation()
                    let target = file.path.isEmpty ? partial : partial.appendingPathComponent(file.path)
                    let before = done
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await ModelFetch.fetch(file, to: target, session: session, route: route) { received in
                        Task { @MainActor in
                            guard let self, self.downloads[model]?.id == id, case .downloading = self.state(model) else { return }
                            self.states[model] = .downloading(total > 0 ? Double(before + received) / total : 0)
                        }
                    }
                    done += file.bytes
                }
                try Task.checkCancellation()
                self?.states[model] = .verifying
                try await Self.verify(partial, files: files)
                guard let self, self.downloads[model]?.id == id else { throw CancellationError() }
                var installed = final
                try? FileManager.default.removeItem(at: installed)
                try FileManager.default.moveItem(at: partial, to: installed)
                // Hundreds of megabytes the app can download again stay out of the iPhone's backups.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? installed.setResourceValues(values)
                self.states[model] = .installed
            } catch {
                try? FileManager.default.removeItem(at: partial)
                guard let self, self.downloads[model]?.id == id else { return }
                self.states[model] = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? .absent : .failed(Self.describe(error))
            }
            if self?.downloads[model]?.id == id { self?.downloads[model] = nil }
        }
        downloads[model] = (id, task)
    }

    public func cancel(_ model: DictationModel) {
        guard let download = downloads.removeValue(forKey: model) else { return }
        download.task.cancel()
        states[model] = .absent
    }

    public func delete(_ model: DictationModel) {
        cancel(model)
        // Parakeet's models stay loaded for a while after a dictation: deleted, they are freed now.
        if model == .parakeet { ParakeetTranscriber.shared.unload() }
        try? FileManager.default.removeItem(at: location(model))
        states[model] = .absent
    }

    enum DownloadError: LocalizedError, Equatable, Sendable {
        case status(Int)
        case size
        case checksum
        /// The response declared another length than the published file's.
        case length
        /// More bytes arrived than the published file has.
        case oversize
        /// A redirect left the allowed route: another host, a downgrade to `http`, or too many hops.
        case redirect(String)

        var errorDescription: String? {
            switch self {
            case .status(let code): "The server answered \(code)."
            case .size: "The download is incomplete."
            case .checksum: "The download doesn’t match the published model."
            case .length: "The server announced another size than the published model’s."
            case .oversize: "The server sent more than the published model."
            case .redirect(let host): "The download was redirected to \(host), which isn’t where models come from."
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Off the main actor: hashing a model reads up to 900 MB.
    nonisolated private static func verify(_ partial: URL, files: [ModelFile]) async throws {
        try await Task.detached(priority: .utility) {
            for file in files {
                let url = file.path.isEmpty ? partial : partial.appendingPathComponent(file.path)
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
                guard size == file.bytes else { throw DownloadError.size }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: chunk)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == file.sha256 else { throw DownloadError.checksum }
            }
        }.value
    }
}

/// Where a model download may go. The first request is the catalog's own URL; each redirect must keep `https` (never a
/// downgrade), name no user or password, and reach the origin's host or one of Hugging Face's: `huggingface.co`
/// answers a model file with a redirect to its CDN (`us.aws.cdn.hf.co` and the like today, `cdn-lfs*.huggingface.co`
/// and `cas-bridge.xethub.hf.co` before) or, for a small file, to `/api/resolve-cache/…` on itself.
struct ModelRoute: Sendable {
    /// Hosts any redirect may reach besides the origin's.
    var hosts: Set<String> = ["huggingface.co", "hf.co"]
    /// Domains whose subdomains a redirect may reach.
    var domains: [String] = ["huggingface.co", "hf.co"]
    /// Plain `http` is accepted only where the origin is `http` already (loopback tests); `https` → `http` never.
    var schemes: Set<String> = ["https"]
    var redirects = 5

    static let huggingFace = ModelRoute()

    func allows(_ url: URL, after previous: URL, origin: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
              previous.scheme?.lowercased() != "https" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), let originHost = origin.host?.lowercased() else { return false }
        if host == originHost { return url.port == origin.port }
        guard url.port == nil || url.port == origin.port else { return false }
        return hosts.contains(host) || domains.contains { host.hasSuffix("." + $0) }
    }

    /// No cookies, cache or stored credentials; identity encoding, so the bytes counted are the file's.
    static func harden(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        return configuration
    }
}

/// One model file's download into `target`: its redirects checked against the route, its status and declared length
/// checked as the response arrives, and its bytes counted as they are written, the transfer cancelled at the first
/// byte past the file's size.
final class ModelFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: ModelFile
    private let route: ModelRoute
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var output: FileHandle?
    private var received: Int64 = 0
    /// What progress last reported: it reports about every half percent of the file, not every chunk.
    private var reported: Int64 = 0
    private var hops = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?

    private init(file: ModelFile, output: FileHandle, route: ModelRoute, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file
        self.output = output
        self.route = route
        self.progress = progress
    }

    static func fetch(_ file: ModelFile, to target: URL, session: URLSession, route: ModelRoute,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let fetch = ModelFetch(file: file, output: try FileHandle(forWritingTo: target), route: route, progress: progress)
        var request = URLRequest(url: file.url)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        task.delegate = fetch
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetch.lock.withLock { fetch.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Ends the transfer with `error`; the completion reports it.
    private func fail(_ error: Error, _ task: URLSessionTask) {
        lock.withLock { if failure == nil { failure = error } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let previous = response.url ?? file.url
        let hop = lock.withLock { hops += 1; return hops }
        guard let url = request.url, hop <= route.redirects, route.allows(url, after: previous, origin: file.url) else {
            fail(DictationModelStore.DownloadError.redirect(request.url?.host ?? "another address"), task)
            return completionHandler(nil)
        }
        var next = request
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            fail(DictationModelStore.DownloadError.status(status), dataTask)
            return completionHandler(.cancel)
        }
        let declared = response.expectedContentLength
        if declared >= 0, declared != file.bytes { // -1: none declared
            fail(DictationModelStore.DownloadError.length, dataTask)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result: Result<Int64?, Error> = lock.withLock {
            guard failure == nil, let output else { return .failure(CancellationError()) }
            guard received + Int64(data.count) <= file.bytes else { return .failure(DictationModelStore.DownloadError.oversize) }
            do {
                try output.write(contentsOf: data)
            } catch {
                return .failure(error)
            }
            received += Int64(data.count)
            guard received - reported >= max(file.bytes / 200, 1) || received == file.bytes else { return .success(nil) }
            reported = received
            return .success(received)
        }
        switch result {
        case .success(let received): if let received { progress(received) }
        case .failure(let error) where !(error is CancellationError): fail(error, dataTask)
        case .failure: break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, received) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?, Int64) in
            try? output?.close()
            output = nil
            defer { self.continuation = nil }
            return (self.continuation, self.failure, self.received)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if received != file.bytes {
            // A body that ended early without the connection saying so (no declared length).
            continuation?.resume(throwing: DictationModelStore.DownloadError.size)
        } else {
            continuation?.resume()
        }
    }
}
