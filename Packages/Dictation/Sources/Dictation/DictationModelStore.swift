import CryptoKit
import Foundation
import Observation

/// The dictation models on this device: Settings downloads and deletes them, dictation reads them. Whisper's are files
/// in one directory, Parakeet's a folder of files in another. A download goes to a partial file (or folder) and becomes
/// the model only once every file's size and SHA-256 match `DictationModel`'s. Each app makes one, for its directories.
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
    @ObservationIgnored private let session: URLSession

    public init(whisper: URL, parakeet: URL, session: URLSession = .shared) {
        whisperDirectory = whisper
        parakeetDirectory = parakeet
        self.session = session
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
        let task = Task { [weak self, session] in
            let partial = final.deletingLastPathComponent().appendingPathComponent("\(final.lastPathComponent).\(id.uuidString).partial")
            do {
                try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                let files = model.files
                let total = Double(model.bytes)
                var done: Int64 = 0
                for file in files {
                    try Task.checkCancellation()
                    let target = file.path.isEmpty ? partial : partial.appendingPathComponent(file.path)
                    let before = done
                    let progress = DownloadProgress { fraction in
                        Task { @MainActor in
                            guard let self, self.downloads[model]?.id == id, case .downloading = self.state(model) else { return }
                            self.states[model] = .downloading((Double(before) + fraction * Double(file.bytes)) / total)
                        }
                    }
                    let (location, response) = try await session.download(from: file.url, delegate: progress)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        try? FileManager.default.removeItem(at: location)
                        throw DownloadError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: location, to: target)
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
