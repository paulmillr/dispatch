import Foundation

/// A PTY shell on a host's own SSH connection (plain SSH mode, docs/ios.md). Unlike helper terminals nothing on the host
/// keeps it: closing it ends the shell.
protocol ShellChannel: AnyObject, Sendable {
    /// PTY output (stdout and stderr merged by the server); finishes when the shell ends. Single consumer.
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    /// Waits for the end of the shell.
    func exit() async -> ShellExit
    func close() async
}

/// How a shell ended: its exit status (128 when a signal ended it, the SSH shell's convention), or lost (the channel or
/// connection closed before a status).
enum ShellExit: Equatable, Sendable {
    case status(Int32)
    case lost
}

/// Opens shells on a connected plain host (`HostSessionEvent.plain`, `HostSession.shellOpener`). Valid for that
/// connection only: after it drops, opening fails and the next connection lends a new opener.
protocol ShellOpener: Sendable {
    func open(term: String, columns: Int, rows: Int) async throws -> any ShellChannel
}
