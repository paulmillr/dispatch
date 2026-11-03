import Foundation

extension System {
    /// Ephemeral HTTPS only, without cookies or credentials. Downloads stream to disk with a bounded size.
    static func updateDownload(_ url: URL, to destination: URL, limit: Int64) async throws {
        _ = try await AppReplay.run(kind: "update.download", input: AppReplay.value([url.absoluteString, destination.path])) {
            guard UpdateDownloadDelegate.allowed(url) else { throw UpdateFailure("The update download address is not trusted.") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900
            let delegate = UpdateDownloadDelegate(limit: limit)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Dispatch-Updater", forHTTPHeaderField: "User-Agent")
            let (file, response) = try await session.download(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let final = response.url, UpdateDownloadDelegate.allowed(final) else {
                throw UpdateFailure("The update server could not provide the release. Try again later.")
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= limit else { throw UpdateFailure("The update download has an unexpected size.") }
            try FileManager.default.moveItem(at: file, to: destination)
            return .null
        }
    }
}

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }

    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["raw.githubusercontent.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
