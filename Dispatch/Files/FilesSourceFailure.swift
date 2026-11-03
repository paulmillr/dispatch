import Foundation

/// Typed helper failures shared by the two Files adapters. Transport timeouts remain the caller's concern:
/// a Mac write may still have completed when its timer expires.
struct FilesSourceFailure: Sendable {
    enum Code: String, Sendable {
        case notFound = "not_found", permissionDenied = "permission_denied", notDirectory = "not_directory"
        case isDirectory = "is_directory", changed, exists, limit, busy, unsupported
        case unavailable, connectionClosed = "connection_closed", invalidResponse = "invalid_response", offline, cancelled
    }

    enum Context {
        case desktop(host: String?)
        case mobile(host: String)

        var host: String? {
            switch self {
            case .desktop(let host): host
            case .mobile(let host): host
            }
        }

        var isMobile: Bool { if case .mobile = self { true } else { false } }
        var helper: String { host.map { "The helper on " + $0 } ?? "This Mac’s helper" }
    }

    let code: String
    let message: String
    var kind: Code? { Code(rawValue: code) }

    func error(path: String, context: Context) -> FilesSourceError {
        func detail(_ fallback: String) -> String {
            if !message.isEmpty { return message }
            return context.isMobile ? context.helper + " failed (\(code))" : fallback
        }
        switch kind {
        case .notFound: return .notFound(path)
        case .permissionDenied: return .permissionDenied(path)
        case .notDirectory: return .notDirectory(path)
        case .isDirectory: return .isDirectory(path)
        case .changed: return .changed(path)
        case .exists where !context.isMobile: return .exists(path)
        case .limit: return .limit(detail("\(path) is larger than the helper copies at once"))
        case .busy: return .busy(detail(context.helper + " is busy with another copy"))
        case .unsupported: return .unsupported(detail(context.helper + " can’t do this yet"))
        case .unavailable, .connectionClosed, .invalidResponse:
            if let host = context.host { return .offline(host) }
            return .other(code: kind == .invalidResponse ? "disconnected" : code,
                          message: detail(context.helper + " is unavailable"))
        case .offline where context.isMobile:
            return context.host.map(FilesSourceError.offline) ?? .other(code: code, message: detail(context.helper + " failed (\(code))"))
        case .cancelled: return .cancelled
        default: return .other(code: code, message: detail(context.helper + " failed (\(code))"))
        }
    }

    static func map(_ error: any Error, path: String, context: Context) -> FilesSourceError {
        if let error = error as? FilesSourceError { return error }
        if error is CancellationError { return .cancelled }
        if error is HelperWire.Failure || error is HelperBinary.Failure {
            return context.host.map(FilesSourceError.offline)
                ?? .other(code: "disconnected", message: context.helper + " stopped answering")
        }
        guard let failure = error as? HelperFailure else {
            return .other(code: "internal", message: error.localizedDescription)
        }
        return Self(code: failure.code, message: failure.message).error(path: path, context: context)
    }
}
