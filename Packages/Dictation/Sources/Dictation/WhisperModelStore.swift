import CryptoKit
import Foundation
import Observation

/// The Whisper models on this device: Settings downloads and deletes them, dictation reads them. A download goes to a
/// partial file and becomes the model only once its size and SHA-256 match `WhisperModel`'s. Each app makes one, for
/// its models directory.
@MainActor @Observable public final class WhisperModelStore {
    public enum State: Equatable {
        case absent
        /// The fraction downloaded, then verified.
        case downloading(Double)
        case verifying
        case installed
        case failed(String)
    }

    let directory: URL
    private(set) var states: [WhisperModel: State] = [:]
    /// The running download of each model, by id: a cancelled download's last steps leave a newer one alone. (Tests
    /// wait for its task.)
    @ObservationIgnored private(set) var downloads: [WhisperModel: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let session: URLSession

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        for model in WhisperModel.allCases {
            states[model] = FileManager.default.fileExists(atPath: file(model).path) ? .installed : .absent
        }
        // What a quit or crash left mid-download.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func state(_ model: WhisperModel) -> State { states[model] ?? .absent }

    func file(_ model: WhisperModel) -> URL { directory.appendingPathComponent(model.fileName) }

    /// The model's file, when it is downloaded and verified.
    func installed(_ model: WhisperModel) -> URL? { state(model) == .installed ? file(model) : nil }

    public func download(_ model: WhisperModel) {
        guard downloads[model] == nil, state(model) != .installed else { return }
        let id = UUID()
        states[model] = .downloading(0)
        let task = Task { [weak self, session, directory] in
            let partial = directory.appendingPathComponent("\(model.fileName).\(id.uuidString).partial")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let progress = DownloadProgress { fraction in
                    Task { @MainActor in
                        guard let self, self.downloads[model]?.id == id, case .downloading = self.state(model) else { return }
                        self.states[model] = .downloading(fraction)
                    }
                }
                let (location, response) = try await session.download(from: model.url, delegate: progress)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: location)
                    throw DownloadError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                try FileManager.default.moveItem(at: location, to: partial)
                try Task.checkCancellation()
                self?.states[model] = .verifying
                try await Self.verify(partial, model: model)
                guard let self, self.downloads[model]?.id == id else { throw CancellationError() }
                var final = self.file(model)
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: partial, to: final)
                // Hundreds of megabytes the app can download again stay out of the iPhone's backups.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? final.setResourceValues(values)
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

    public func cancel(_ model: WhisperModel) {
        guard let download = downloads.removeValue(forKey: model) else { return }
        download.task.cancel()
        states[model] = .absent
    }

    public func delete(_ model: WhisperModel) {
        cancel(model)
        try? FileManager.default.removeItem(at: file(model))
        states[model] = .absent
    }

    enum DownloadError: LocalizedError {
        case status(Int)
        case size
        case checksum

        var errorDescription: String? {
            switch self {
            case .status(let code): "The server answered \(code)."
            case .size: "The download is incomplete."
            case .checksum: "The download doesn’t match the published model."
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Off the main actor: hashing a model reads up to 900 MB.
    nonisolated private static func verify(_ file: URL, model: WhisperModel) async throws {
        try await Task.detached(priority: .utility) {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64
            guard size == model.bytes else { throw DownloadError.size }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == model.sha256 else { throw DownloadError.checksum }
        }.value
    }
}

/// Reports a download's progress: the task's own, observed from its creation (the async download API gives its task
/// delegate no `didWriteData`).
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
        lock.withLock { self.observation = observation }
    }
}
