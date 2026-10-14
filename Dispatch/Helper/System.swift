import Foundation
#if canImport(AppKit)
import TermApple

/// I/O with what runs outside the app, through the app journal (tests capture it once and replay it
/// without running anything): terminal processes and files other processes write.
enum System {
    private static let lock = NSLock()
    /// Terminal processes by renderer tab: the renderer child's connection joins its pty's stream.
    nonisolated(unsafe) private static var terminals: [String: Terminal] = [:]

    /// One terminal process: its pty's master, the renderer child's control connection and the slave
    /// the app relays are one ordered stream (`slave` is the slave's channel).
    final class Terminal: @unchecked Sendable {
        let ticket: AppReplay.Ticket
        let tab: UUID?, socket: String?
        var grid: HelperTopology.Grid?
        /// The pty's window as the app set it (columns, rows).
        var size: (columns: UInt16, rows: UInt16)? { get { lock.withLock { window } } set { lock.withLock { window = newValue } } }
        private var window: (columns: UInt16, rows: UInt16)?
        private let lock = NSLock()
        weak var connection: HelperTerminal?
        var closed = false, full = false
        /// Replay: the pty's handlers, fed from the journal.
        var read: Pty.Read = { _ in }, exit: Pty.Exit = { _ in }
        init(_ ticket: AppReplay.Ticket, _ environment: [String: String]) {
            (self.ticket, self.socket) = (ticket, environment["DISPATCH_RENDERER_SOCKET"])
            tab = environment["DISPATCH_RENDERER_TAB"].flatMap(UUID.init(uuidString:))
        }
    }

    static func terminal(_ tab: UUID) -> Terminal? { lock.withLock { terminals[tab.uuidString] } }

    /// Pty.journal: what the process prints, what is typed and its end (its window is drawing: the app's).
    static func pty(_ launch: Launch) throws -> Pty.Journal? {
        // The environment carries this run's renderer token and paths; the command and a renderer's tab (a recorded
        // id: views mount in layout order) identify the process.
        let input = [launch.directory ?? ""] + launch.argv + [launch.env["DISPATCH_RENDERER_TAB"] ?? ""]
        guard let ticket = try AppReplay.open(kind: "pty", input: AppReplay.value(input)) else { return nil }
        let terminal = Terminal(ticket, launch.env)
        if let tab = terminal.tab { lock.withLock { terminals[tab.uuidString] = terminal } }
        // The renderer's new size was recorded after the app resized the pty (what tmux redraws after it is drawn for):
        // replay hands it over once the app's pty has that size too, or a size recorded later (an animation's frames
        // fall on other sizes in each run). Until then the stall report says which sizes it waits for.
        ticket.gate { event, later in
            func grid(_ event: AppReplay.Event) -> HelperTopology.Grid? {
                guard event.kind == "in.size" else { return nil }
                return try? AppReplay.decode(HelperTopology.Grid.self, event.value)
            }
            let size = terminal.size
            func reached(_ grid: HelperTopology.Grid) -> Bool { size.map { $0.columns == grid.columns && $0.rows == grid.rows } == true }
            guard let recorded = grid(event), !reached(recorded), !later.contains(where: { grid($0).map(reached) == true }) else { return nil }
            func text(_ grid: HelperTopology.Grid) -> String { "\(grid.columns)x\(grid.rows)" }
            let sizes = later.compactMap(grid).map(text)
            return "the app's pty is " + (size.map { "\($0.columns)x\($0.rows)" } ?? "unsized") + "; recorded " + text(recorded)
                + (sizes.isEmpty ? "" : ", later " + sizes.joined(separator: ", "))
        }
        let output = DispatchQueue(label: "dev.dispatch.system.pty")
        func record(_ body: () throws -> Void) { do { try body() } catch { AppReplay.fail(error) } }
        return Pty.Journal(replaying: ticket.replaying, observe: { read, exit in
            (terminal.read, terminal.exit) = (read, exit)
            guard ticket.replaying else {
                return ({ bytes in record { try ticket.emit(kind: "output", value: .bytes(Data(buffer: bytes))) }; terminal.read(bytes) },
                        { status in record { try ticket.emit(kind: "exit", value: AppReplay.value(status)) }; terminal.exit(status) })
            }
            record {
                ticket.through(output)
                try ticket.listen({ event in
                    switch event.kind {
                    case "in.output": output.async { AppReplay.bytes(event.value).withUnsafeBytes { terminal.read($0.bindMemory(to: UInt8.self)) } }
                    case "in.exit":
                        // Empty: the app hung up first, so the process ended without its exit reaching the app.
                        guard let status = try? AppReplay.decode(Int32.self, event.value) else { return }
                        output.async { DispatchQueue.main.async { MainActor.assumeIsolated { terminal.exit(status) } } }
                    case "in.size": terminal.grid = try? AppReplay.decode(HelperTopology.Grid.self, event.value)
                        if let grid = terminal.grid { DispatchQueue.main.async { MainActor.assumeIsolated { terminal.connection?.resized(grid) } } }
                    case "in.full": terminal.full = true
                    case "in.connect":
                        DispatchQueue.main.async { MainActor.assumeIsolated { HelperRenderer.connect(terminal) } }
                    default: AppReplay.fail(HelperFailure(code: "replay", message: "Unexpected pty journal event: " + event.kind))
                    }
                }, failed: { _ in })
            }
            return ({ _ in }, { _ in })
        }, write: { bytes, accepted in
            // A full pty refuses a write (its child stopped reading): the refusal is the OS's answer.
            terminal.full = false
            record { try ticket.action(kind: "input", value: .bytes(Data(bytes))) }
            if !ticket.replaying, !accepted { record { try ticket.emit(kind: "full") } }
            return ticket.replaying ? !terminal.full : accepted
        },
        resize: { size in
            terminal.size = (size.ws_col, size.ws_row)
            ticket.recheck()
        },
        hangup: {
            guard lock.withLock({ () -> Bool in defer { terminal.closed = true }; return !terminal.closed }) else { return }
            record { try ticket.action(kind: "hangup") }
            // The exit after a hangup never reaches the app: the lifetime ends here.
            if !ticket.replaying { record { try ticket.emit(kind: "exit") } }
        },
        // A process that never started (unseen) has what the OS reports live: nothing.
        process: { live in ticket.unseen ? live : process("pty.process", ticket.id) { live } },
        foreground: { live in ticket.unseen ? live : process("pty.foreground", ticket.id) { live } })
    }

    /// The machine as the app and its tests know it; nothing else reads it (test/xcode.py checks). While testing these
    /// are paths in the run's private root (DISPATCH_TEST_ROOT), the same on every Mac: recordings name no machine's
    /// paths and replay anywhere.
    static let testing = ProcessInfo.processInfo.environment["DISPATCH_TESTING"] == "1"
    private static let root = testing ? ProcessInfo.processInfo.environment["DISPATCH_TEST_ROOT"].map { URL(fileURLWithPath: $0) } : nil

    /// The account's home; while testing the test home (a fresh one without the runner's root).
    static let home = !testing ? URL(fileURLWithPath: NSHomeDirectory())
        : root?.appendingPathComponent("home") ?? FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-home-" + uuid().uuidString)

    static let temporary = root?.appendingPathComponent("tmp") ?? FileManager.default.temporaryDirectory

    /// The checkout the tests run from (fixtures, scripts, test tools), through the runner's link in its root.
    static let checkout = root?.appendingPathComponent("checkout")
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The app bundle, its executable and resources; while testing seen through the checkout link when the bundle was
    /// built inside the checkout.
    static let bundle = linked(Bundle.main.bundleURL)
    static let executable = linked(Bundle.main.executableURL ?? Bundle.main.bundleURL)
    static let resources = linked(Bundle.main.resourceURL ?? Bundle.main.bundleURL)
    private static func linked(_ url: URL) -> URL {
        guard root != nil, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: checkout.path),
              url.path.hasPrefix(target + "/") else { return url }
        return checkout.appendingPathComponent(String(url.path.dropFirst(target.count + 1)))
    }

    /// A path with its links resolved (a disk read: through the checkout link it names this Mac's checkout):
    /// replay answers the recorded one.
    static func resolve(_ url: URL) -> URL { (try? observe("resolve", url.path) { url.resolvingSymlinksInPath() }) ?? url.resolvingSymlinksInPath() }

    /// The machine and the account the app runs as, also while testing: the account's name (the tests' ssh logins), its
    /// own home (where the app must not write; the loopback sshd's remote home), shell and whether login is quiet; the
    /// machine's name (what OSC 7 names) and memory (terminal buffer limits). Replay answers the recorded ones.
    struct Machine: Codable {
        let name: String, home: URL, shell: String?, quiet: Bool, host: String, memory: UInt64
        /// What the terminal engine reads of the machine.
        var launch: Launch.Machine {
            .init(name: name, home: home.path, shell: shell, quiet: quiet, executable: System.executable.path, host: host)
        }
    }
    static var machine: Machine {
        let live = { () -> Machine in
            let machine = Launch.Machine.current
            return Machine(name: machine.name ?? NSUserName(), home: URL(fileURLWithPath: machine.home ?? NSHomeDirectory()),
                           shell: machine.shell, quiet: machine.quiet, host: machine.host,
                           memory: ProcessInfo.processInfo.physicalMemory)
        }
        return (try? observe("machine", "") { live() }) ?? live()
    }

    /// This process's environment (what processes it starts inherit), as the app has set it up (Home.isolate).
    static var inherited: [String: String] { ProcessInfo.processInfo.environment }
    static func environment(_ name: String) -> String? { inherited[name] }

    /// Where processes find programs; while testing (Home.isolate sets it) the checkout's test tools, a test VM's,
    /// Homebrew's, then the system's.
    static let path = testing
        ? checkout.appendingPathComponent("build/test-tools/bin").path + ":/Users/admin/dispatch-tests/test-tools:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        : environment("PATH") ?? "/usr/bin:/bin"

    /// Every id the app makes (rows, layout, tabs, paths, tokens): replay makes the same ones, per site (its file, function
    /// and what it is for) in order.
    static func uuid(for key: String = "", _ file: String = #fileID, _ function: String = #function) -> UUID {
        AppReplay.made(file + ":" + function + "\u{0}" + key) ?? UUID()
    }

    /// The time (the OS's clock, which replay does not wait for): replay answers the time capture read at that point.
    static func date() -> Date { (try? observe("date", "") { Date() }) ?? Date() }

    /// This process's id as the recording saw it (tests stand in for an agent with their own process).
    static var pid: pid_t { process("pid", "self") { getpid() } }
    /// This process's user id as the recording saw it (the processes it owns are the account's).
    static var uid: uid_t { process("uid", "self") { getuid() } }

    /// State other processes change (their table entries, files, a server's answers): asked live in capture,
    /// any number of times; replay answers what capture saw last before the point replay reached.
    static func observe<Value: Codable>(_ name: String, _ input: some Encodable, _ body: () throws -> Value) throws -> Value {
        try AppReplay.decode(Value.self, AppReplay.query(kind: "observe." + name, input: AppReplay.value(input)) {
            try AppReplay.value(body())
        })
    }

    /// Inside a test's polling condition: what it asks there is a read, asked as often as the test polls.
    @TaskLocal static var polling = false

    /// An action on what runs outside the app (write its file, signal it): done live in capture, its recorded
    /// outcome replayed in order.
    static func act<Value: Codable>(_ name: String, _ input: some Encodable, _ body: () throws -> Value) throws -> Value {
        if polling { return try observe(name, input, body) }
        return try AppReplay.decode(Value.self, AppReplay.query(kind: name, input: AppReplay.value(input)) {
            try AppReplay.value(body())
        })
    }

    /// The test's own step (its condition held here): replay continues the test where the recording did. A test's
    /// steps are told apart by their order alone (one journal is one test): moving code keeps a recording valid.
    /// Recorded with the step: `at` (where in the source, for reports only), `mark` and `end` (AppReplay.mark when the
    /// check that held began and returned). Waits inside a polling condition are that poll's (as many as it polls): not steps.
    nonisolated(nonsending) static func step(at: String, mark: Range<Int>? = nil) async throws {
        guard !polling else { return }
        let wake: [String: HelperBinary.Value] = ["at": .string(at)].merging(mark.map {
            ["mark": .unsigned(UInt64($0.lowerBound)), "end": .unsigned(UInt64($0.upperBound))]
        } ?? [:]) { $1 }
        try await AppReplay.reach(kind: "step", input: .null, wake: .object(wake))
    }

    /// A wait before the app's next request (polling, backoff, a grace period): capture sleeps and records the wake,
    /// replay wakes when the recording reaches it. Identified by its file and name, never its line: an edit elsewhere in
    /// the file keeps every recording of it (the duration is the clock's). A test's own pause is a step instead
    /// (TestSupport.pause): the test goes on only after the app handled what came before.
    nonisolated(nonsending) static func sleep(for duration: Duration, _ name: String, _ file: String = #fileID) async throws {
        guard !polling else { return try await Task.sleep(for: duration) }
        _ = try await AppReplay.run(kind: "clock", input: .string(file + ":" + name), caller: true) {
            try await Task.sleep(for: duration)
            return .null
        }
    }

    /// Signals another process (a test's fixture or tool): the outcome is recorded.
    @discardableResult
    static func signal(_ pid: pid_t, _ number: Int32) -> Int32 {
        (try? act("signal", [pid, number]) { kill(pid, number) }) ?? -1
    }

    struct Exit: Codable { let status: Int32, output: Data }
    /// A process run to its end (a test's tool): its status and standard output, recorded.
    static func run(_ process: Process) throws -> Exit {
        try act("process.run", AppReplay.Launch(process)) {
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.wait()
            return Exit(status: process.terminationStatus, output: data)
        }
    }

    /// A process a test drives (another client of a server): its start, its input and its end are recorded
    /// actions and whether it still runs is observed; replay starts nothing.
    final class Child {
        let process: Process
        private let input = Pipe(), name: String
        init(_ process: Process) throws {
            (self.process, name) = (process, ([process.executableURL?.path ?? ""] + (process.arguments ?? [])).joined(separator: " "))
            process.standardInput = input
            _ = try act("child.run", name) { try process.run(); return true }
        }
        func write(_ data: Data) throws {
            _ = try act("child.write", [name, String(decoding: data, as: UTF8.self)]) {
                try input.fileHandleForWriting.write(contentsOf: data)
                return true
            }
        }
        var running: Bool { (try? observe("child.running", name) { process.isRunning }) ?? false }
        /// Ends its input and waits for it to exit on its own.
        @discardableResult
        func finish() -> Int32 {
            (try? act("child.finish", name) { try input.fileHandleForWriting.close(); process.wait(); return process.terminationStatus }) ?? -1
        }
        /// Terminates it if it still runs.
        func stop() {
            _ = try? act("child.stop", name) { if process.isRunning { process.terminate(); process.wait() }; return true }
        }
    }

    /// What the OS reports about another process (its table entry, arguments, files). One capture never asked about
    /// is unknown to replay: what the OS says of a process it does not know (nothing, none, no, -1).
    static func process<Value: Codable>(_ name: String, _ input: some Encodable, _ body: () -> Value) -> Value {
        do { return try observe("process." + name, input, body) } catch {
            if (error as? HelperFailure)?.code == "unrecorded",
               let value = [HelperBinary.Value.null, .array([]), .bool(false), .signed(-1)].lazy
                   .compactMap({ try? AppReplay.decode(Value.self, $0) }).first {
                return value
            }
            AppReplay.fail(error); return body()
        }
    }

    /// A file another process writes (a fixture's state).
    static func read(_ url: URL) throws -> Data { try observe("file", url.path) { try Data(contentsOf: url) } }

    static func exists(_ url: URL) -> Bool {
        (try? observe("file.exists", url.path) { FileManager.default.fileExists(atPath: url.path) }) ?? false
    }

    /// A directory another process changes: its entries' names.
    static func list(_ url: URL) throws -> [String] {
        try observe("file.list", url.path) { try FileManager.default.contentsOfDirectory(atPath: url.path) }
    }

    /// Changes to files other processes use (a fixture's, a remote account's): recorded actions.
    static func remove(_ url: URL) throws {
        _ = try act("file.remove", url.path) { try FileManager.default.removeItem(at: url); return true }
    }

    static func move(_ url: URL, to target: URL) throws {
        _ = try act("file.move", [url.path, target.path]) { try FileManager.default.moveItem(at: url, to: target); return true }
    }

    static func link(_ url: URL, to target: URL) throws {
        _ = try act("file.link", [url.path, target.path]) {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return true
        }
    }

    static func directory(_ url: URL) throws {
        _ = try act("file.directory", url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        }
    }

    /// The recorded input holds the content itself (bytes; the capture is compressed).
    static func write(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        struct Input: Encodable { let path: String; let bytes: Data; let permissions: Int? }
        _ = try act("file.write", Input(path: url.path, bytes: data, permissions: permissions)) {
            try data.write(to: url, options: .atomic)
            if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            return true
        }
    }
}

extension Process {
    /// waitUntilExit without running the caller's run loop: inside recorded live work other app work must not
    /// run (it would be taken for part of that work and go unrecorded).
    func wait() {
        while isRunning { usleep(1_000) }
    }
}
#endif
