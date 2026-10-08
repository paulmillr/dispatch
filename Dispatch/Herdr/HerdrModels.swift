import Foundation

/// A failure with a message the app shows as is.
struct HerdrFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
