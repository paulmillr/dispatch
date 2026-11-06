import Foundation
import os

extension System {
    /// Waits before trying an interrupted download again, from where it stopped when the server allows.
    static let updateDownloadRetries: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]

    /// Ephemeral HTTPS only, without cookies or credentials. Downloads stream to disk with a bounded size, reporting
    /// each whole percent (or MB, when the size is unknown) received. A connection that drops or stalls (a Wi-Fi
    /// switch, a moment offline) is tried again, resuming the partial file.
    static func updateDownload(_ url: URL, to destination: URL, limit: Int64,
                               progress: @escaping @Sendable (UpdateInstaller.Progress) -> Void = { _ in }) async throws {
        var resume: Data?
        for attempt in 0... {
            do {
                _ = try await AppReplay.run(kind: "update.download", input: AppReplay.value([url.absoluteString, destination.path])) {
                    guard UpdateDownloadDelegate.allowed(url) else { throw UpdateFailure("The update download address is not trusted.") }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.httpCookieStorage = nil
                    configuration.httpShouldSetCookies = false
                    configuration.urlCredentialStorage = nil
                    configuration.urlCache = nil
                    // A stalled connection fails after a minute without data; a slow one that keeps going may take
                    // hours (20 MB at 2 KB/s is under three).
                    configuration.timeoutIntervalForRequest = 60
                    configuration.timeoutIntervalForResource = 6 * 60 * 60
                    let delegate = UpdateDownloadDelegate(limit: limit, destination: destination, progress: progress)
                    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                    request.setValue("Dispatch-Updater", forHTTPHeaderField: "User-Agent")
                    try await delegate.run(resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request))
                    return .null
                }
                return
            } catch let error as URLError where attempt < updateDownloadRetries.count && UpdateDownloadDelegate.interrupted(error) {
                resume = error.downloadTaskResumeData
                try await sleep(for: updateDownloadRetries[attempt], "update download retry")
            }
        }
    }
}

/// Drives one download task. The async `URLSession.download(for:)` never calls `didWriteData`, so neither progress
/// nor the size limit would apply while the file arrives; a plain task does both.
final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int64
    private let destination: URL
    private let progress: @Sendable (UpdateInstaller.Progress) -> Void
    private struct State {
        var finish: CheckedContinuation<Void, Error>?
        /// Why the download failed, when the delegate decided it (size, response, moving the file).
        var failure: Error?
        var moved = false
        var reported: Int64 = -1
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int64, destination: URL = URL(fileURLWithPath: "/dev/null"),
         progress: @escaping @Sendable (UpdateInstaller.Progress) -> Void = { _ in }) {
        self.limit = limit
        self.destination = destination
        self.progress = progress
    }

    /// GitHub and its content hosts. Release downloads redirect to an asset host that GitHub has renamed before
    /// (objects., then release-assets.githubusercontent.com): any of its subdomains, so a rename does not strand every
    /// installed copy. The feed's checksum and the signature checks, not the host, vouch for the file.
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" || (host.hasSuffix(".githubusercontent.com") && !host.dropLast(".githubusercontent.com".count).isEmpty
            && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) })
    }

    /// A connection that dropped, stalled or could not be made: worth trying again in a moment.
    static func interrupted(_ error: URLError) -> Bool {
        [.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    /// Returns once the file is at `destination`; cancelling the calling task cancels the download.
    func run(_ task: URLSessionDownloadTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (finish: CheckedContinuation<Void, Error>) in
                state.withLock { $0.finish = finish }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: { task.cancel() }
    }

    private func fail(_ error: Error, _ task: URLSessionTask) {
        state.withLock { if $0.failure == nil { $0.failure = error } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else {
            let host = request.url?.host ?? "an unknown address"
            state.withLock { if $0.failure == nil { $0.failure = UpdateFailure("The update download was redirected to \(host), which Dispatch does not trust.") } }
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
            return fail(UpdateFailure("The update download has an unexpected size."), downloadTask)
        }
        let expected = max(0, totalBytesExpectedToWrite)
        // Whole percents, or whole MB without a size: at most about a hundred updates for the UI to draw.
        let mark = expected > 0 ? totalBytesWritten * 100 / expected : totalBytesWritten / 1_000_000
        let report = state.withLock { state -> Bool in
            guard mark != state.reported else { return false }
            state.reported = mark
            return true
        }
        if report { progress(.init(received: totalBytesWritten, expected: expected)) }
    }

    /// The file at `location` is deleted when this returns, so it moves now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // 206: a resumed download's remainder; URLSession joins it to the partial file.
            guard let response = downloadTask.response as? HTTPURLResponse, [200, 206].contains(response.statusCode),
                  let final = response.url, Self.allowed(final) else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw UpdateFailure("The update server could not provide the release (HTTP \(status)). Try again later.", transient: true)
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= limit else { throw UpdateFailure("The update download has an unexpected size.") }
            try FileManager.default.moveItem(at: location, to: destination)
            state.withLock { $0.moved = true }
        } catch {
            state.withLock { if $0.failure == nil { $0.failure = error } }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (finish, result) = state.withLock { state -> (CheckedContinuation<Void, Error>?, Result<Void, Error>) in
            defer { state.finish = nil }
            if let failure = state.failure { return (state.finish, .failure(failure)) }
            if let error { return (state.finish, .failure(error)) }
            return (state.finish, state.moved ? .success(()) : .failure(UpdateFailure("The update server could not provide the release. Try again later.", transient: true)))
        }
        finish?.resume(with: result)
    }
}
