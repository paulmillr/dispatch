import Foundation
import MobileTransport

/// Plain SSH shells (`ShellOpener`) on one `SSHConnection`: each a PTY session channel (`SSHConnection.shell`).
struct SSHShellOpener: ShellOpener {
    let connection: SSHConnection

    func open(term: String, columns: Int, rows: Int) async throws -> any ShellChannel {
        SSHShellChannel(try await connection.shell(term: term, columns: columns, rows: rows))
    }
}

/// A `ShellChannel` over an `SSHShell` (qualified: the shared `Dispatch/Terminal/TerminalMachine.swift` has an `SSHShell`
/// of its own). Output is pulled from the shell as the consumer reads (the engine's
/// backpressure reaches the SSH window); a read error ends it like the shell's end, and `exit()` then says how.
final class SSHShellChannel: ShellChannel {
    let output: AsyncStream<Data>
    private let shell: MobileTransport.SSHShell

    init(_ shell: MobileTransport.SSHShell) {
        self.shell = shell
        let reader = Reader(shell.makeAsyncIterator())
        output = AsyncStream(unfolding: { await reader.next() })
    }

    func write(_ data: Data) async throws { try await shell.write(data) }
    func resize(columns: Int, rows: Int) async throws { try await shell.resize(columns: columns, rows: rows) }

    func exit() async -> ShellExit {
        do { return .status(try await shell.exitStatus()) } catch { return .lost }
    }

    func close() async { await shell.close() }

    /// The shell's iterator for the single consumer `output` allows.
    private actor Reader {
        private var iterator: MobileTransport.SSHShell.AsyncIterator
        private var done = false
        init(_ iterator: MobileTransport.SSHShell.AsyncIterator) { self.iterator = iterator }

        func next() async -> Data? {
            guard !done else { return nil }
            // A copy across the suspension (an actor's stored value cannot be mutated across it); the state is the shell's.
            var reading = iterator
            let data = try? await reading.next()
            iterator = reading
            if data == nil { done = true }
            return data
        }
    }
}
