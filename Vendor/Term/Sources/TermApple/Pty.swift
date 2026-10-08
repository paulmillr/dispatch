// A process on a pseudo terminal, like Ghostty's termio/Exec.zig: what runs comes from Launch
// (argv, environment, working directory); the window size follows the grid; output is read by
// Ghostty's two-stage read pipeline (ReadThread: a gather thread and a parse thread), writes go out
// in order on the pty's own queue (Ghostty's writer: a full pty never blocks a caller).
#if canImport(Darwin) && canImport(AppKit)
import Darwin
import Foundation

public final class Pty {
    private static let reaperQueue = DispatchQueue(
        label: "com.mitchellh.ghostty.pty-reaper",
        qos: .utility,
        attributes: .concurrent
    )

    /// The child until it is reaped (Ghostty's Subprocess.externalExit): its PID may then belong to
    /// another process, which must never be signaled or waited for. Main queue.
    public private(set) var pid: pid_t?
    var exit: DispatchSourceProcess?
    let master: Master

    /// Starts `launch` with `size` as its window; `onRead` gets each batch of output on the parse
    /// thread (with the pty, to answer), `onExit` the status on the main queue.
    public init(size: winsize, launch: Launch, onRead: @escaping @Sendable (Pty, UnsafeBufferPointer<UInt8>) -> Void,
                onExit: @escaping @MainActor (Int32) -> Void) throws {
        // Like Command.zig + Pty.childPreExec: fork; the child gets a new session with the slave
        // as its controlling terminal on 0-2 (forkpty's login_tty: setsid + TIOCSCTTY; macOS gives
        // no controlling terminal for just opening the tty, so posix_spawn can't), default signal
        // handlers, the working directory, then exec. Everything the child uses is made before the
        // fork. (No allocation in the child: another thread may hold the allocator's lock at the fork.)
        let cArgs = launch.argv.map { strdup($0) } + [nil], cEnv = launch.env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cDir: UnsafeMutablePointer<CChar>? = launch.directory.flatMap { strdup($0) }
        defer { (cArgs + cEnv).forEach { free($0) }; free(cDir) }
        let signals = [SIGABRT, SIGALRM, SIGBUS, SIGCHLD, SIGFPE, SIGHUP, SIGILL, SIGINT, SIGPIPE, SIGSEGV, SIGTRAP, SIGTERM, SIGQUIT]
        var (m, ws) = (Int32(-1), size)
        let child = forkpty(&m, nil, nil, &ws)
        if child == 0 {
            var dfl = sigaction()
            for sig in signals { sigaction(sig, &dfl, nil) }
            if let cDir { chdir(cDir) }
            execve(cArgs[0], cArgs, cEnv)
            _exit(127)
        }
        guard child > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        pid = child
        do { master = try Master(m) } catch { Darwin.close(m); kill(child, SIGKILL); waitpid(child, nil, 0); throw error }
        master.start { [weak self] bytes in if let self { onRead(self, bytes) } }
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            self?.pid = nil
            MainActor.assumeIsolated { onExit(status) }
        }
        exit.resume()
        self.exit = exit
    }

    /// Queued with bounded backpressure: false when a stalled child has filled the write budget.
    @discardableResult public func write(_ bytes: [UInt8]) -> Bool { master.write(bytes) }

    /// The terminal's foreground process group (ghostty_surface_foreground_pid).
    public var foregroundPID: pid_t { tcgetpgrp(master.fd) }

    /// TIOCSWINSZ: the grid and its pixel size.
    public func resize(_ size: winsize) {
        var ws = size
        _ = ioctl(master.fd, TIOCSWINSZ, &ws)
    }

    /// Ends the process like Ghostty's Exec killCommand: SIGHUP to its process group, followed by
    /// SIGKILL if needed. Termination and reaping run off the caller so close cannot block the UI.
    public func close() {
        guard let exit else { return }
        exit.setEventHandler {}
        exit.cancel()
        self.exit = nil
        defer { pid = nil; master.stop() }
        guard let pid else { return }
        let parentGroup = getpgid(0)
        Self.reaperQueue.async {
            Self.terminateAndReap(pid: pid, parentGroup: parentGroup)
        }
    }

    private static func terminateAndReap(pid: pid_t, parentGroup: pid_t) {
        // forkpty creates a new session in the child. Give it a short period to finish that setup
        // before choosing a process-group target; directly signal the child if setup never finishes.
        let groupDeadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        var processGroup = getpgid(pid)
        while processGroup == parentGroup, DispatchTime.now().uptimeNanoseconds < groupDeadline {
            usleep(1_000)
            processGroup = getpgid(pid)
        }

        func send(_ signal: Int32) {
            let group = getpgid(pid)
            if group > 0, group != parentGroup {
                _ = killpg(group, signal)
            } else {
                _ = kill(pid, signal)
            }
        }

        func hasExited() -> Bool {
            var result: pid_t
            repeat {
                result = waitpid(pid, nil, WNOHANG)
            } while result < 0 && errno == EINTR
            return result != 0
        }

        send(SIGHUP)
        let hangupDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while DispatchTime.now().uptimeNanoseconds < hangupDeadline {
            if hasExited() { return }
            usleep(10_000)
        }

        // A child may ignore SIGHUP. The blocking reap stays on this utility queue, so even an
        // uninterruptible process cannot hang the main actor.
        send(SIGKILL)
        var result: pid_t
        repeat {
            result = waitpid(pid, nil, 0)
        } while result < 0 && errno == EINTR
    }

    deinit { close() }
}

/// The pty's master side: its descriptor, Ghostty's read pipeline and the write queue. The
/// descriptor lives as long as this object (the Pty, the pipeline's threads and queued writes hold
/// it), so no read, write or ioctl can reach a closed or reused descriptor.
///
/// Ghostty's ReadThread (termio/Exec.zig): the gather thread drains the pty into a ring of
/// buffers, the parse thread hands each batch to the terminal. macOS gives the master at most
/// 1 KiB per read; a writer that filled it is a bulk stream, so the gather thread bridges the
/// writer's refill gaps (immediate retries, then short polls while the parse stage is busy) and
/// hands over big batches instead of waking once per KiB. The pipeline ends with the pty (EOF,
/// EIO: the last output is not lost) or when stopped.
final class Master {
    /// Ghostty's constants (measured there on an M4 Max): 4 buffers of 64 KiB; a batch of 1 KiB
    /// marks a saturated stream; 16 retries before a 1 ms poll; 3 ms at most per batch.
    static let count = 4, capacity = 64 * 1024, saturated = 1024, spins = 16, pollMs: Int32 = 1, budget: UInt64 = 3_000_000
    static let writeLimit = 1024 * 1024, writeChunk = 64 * 1024

    let fd: Int32
    let buffers = UnsafeMutableRawPointer.allocate(byteCount: count * capacity, alignment: 16)
    let ring = NSCondition()
    let writeRing = NSCondition()
    // Under `ring`: each batch's length, the next slot to fill / to parse, published batches, the
    // gather thread waiting in a bridge poll, the stream is over.
    var lens = [Int](repeating: 0, count: count), head = 0, tail = 0, published = 0, bridging = false, done = false
    // Under `writeRing`: a bounded FIFO. Small replies coalesce so metadata is bounded as well.
    var pendingWrites: [[UInt8]] = [], writeHead = 0, pendingWriteBytes = 0, writeDone = false, writeActive = false
    /// quit: stops the gather thread's polls; idle: the parse stage ran dry while the gather thread bridges.
    let quit: (read: Int32, write: Int32), idle: (read: Int32, write: Int32)

    init(_ fd: Int32) throws {
        func pipe() throws -> (Int32, Int32) {
            var fds: [Int32] = [0, 0]
            guard Darwin.pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
            return (fds[0], fds[1])
        }
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)   // Ghostty's read thread setNonblock
        (quit, idle) = (try pipe(), try pipe())
    }

    deinit {
        for fd in [fd, quit.read, quit.write, idle.read, idle.write] { Darwin.close(fd) }
        buffers.deallocate()
    }

    /// Queued in order without one retained closure per write. A process that stops reading cannot
    /// make terminal replies grow the app indefinitely.
    @discardableResult func write(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        writeRing.lock()
        defer { writeRing.unlock() }
        guard !writeDone, bytes.count <= Self.writeLimit - pendingWriteBytes else { return false }
        let last = pendingWrites.count - 1
        if pendingWrites.count > writeHead, !(writeActive && last == writeHead),
           pendingWrites[last].count + bytes.count <= Self.writeChunk
        {
            pendingWrites[last] += bytes
        } else {
            pendingWrites.append(bytes)
        }
        pendingWriteBytes += bytes.count
        writeRing.signal()
        return true
    }

    /// Both threads, user-initiated (Ghostty's setQosClass: wakeups on efficiency cores are slow
    /// next to the pty's ~10 µs producer/consumer cadence).
    func start(_ parse: @escaping (UnsafeBufferPointer<UInt8>) -> Void) {
        for body in [{ self.gather() }, { self.parse(parse) }, { self.writer() }] {
            let thread = Thread(block: body)
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Ends the gather thread; the parse thread delivers what was gathered, then ends too.
    func stop() {
        writeRing.lock()
        writeDone = true
        writeRing.broadcast()
        writeRing.unlock()
        _ = Darwin.write(quit.write, "q", 1)
    }

    func writer() {
        while true {
            writeRing.lock()
            while writeHead == pendingWrites.count && !writeDone { writeRing.wait() }
            guard !writeDone else {
                (pendingWrites, writeHead, pendingWriteBytes) = ([], 0, 0)
                writeActive = false
                writeRing.unlock()
                return
            }
            let bytes = pendingWrites[writeHead]
            writeActive = true
            writeRing.unlock()

            var rest = bytes[...], failed = false
            while !rest.isEmpty {
                let n = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN {
                    var room = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&room, 1, 100)
                    writeRing.lock(); let stopped = writeDone; writeRing.unlock()
                    if stopped { failed = true; break }
                    continue
                }
                if n <= 0 { failed = true; break }
                rest = rest.dropFirst(n)
            }

            writeRing.lock()
            writeActive = false
            pendingWriteBytes -= bytes.count
            writeHead += 1
            if writeHead == pendingWrites.count {
                (pendingWrites, writeHead) = ([], 0)
            } else if writeHead >= 64 {
                pendingWrites.removeFirst(writeHead)
                writeHead = 0
            }
            if failed {
                (pendingWrites, writeHead, pendingWriteBytes, writeDone) = ([], 0, 0, true)
            }
            writeRing.unlock()
            if failed { return }
        }
    }

    func buffer(_ slot: Int) -> UnsafeMutablePointer<UInt8> { (buffers + slot * Self.capacity).assumingMemoryBound(to: UInt8.self) }

    func gather() {
        defer { ring.lock(); done = true; ring.signal(); ring.unlock() }
        var bridge = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: quit.read, events: Int16(POLLIN), revents: 0),
                      pollfd(fd: idle.read, events: Int16(POLLIN), revents: 0)]
        var wait = Array(bridge[0..<2])
        while true {
            ring.lock()
            while published == Self.count { ring.wait() }
            let slot = head
            ring.unlock()
            let buf = buffer(slot)
            var (total, spins, bridgeStart, fatal) = (0, 0, UInt64?.none, false)
            while total < Self.capacity {
                let n = read(fd, buf + total, Self.capacity - total)
                if n < 0, errno == EINTR { continue }
                if n < 0, errno != EAGAIN { fatal = true; break }   // EIO: the pty ended
                if n < 0 {
                    // A trickle is delivered at once; a saturated stream bridges the writer's refill gap.
                    if total < Self.saturated { break }
                    if spins < Self.spins { spins += 1; continue }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if let start = bridgeStart, now - start >= Self.budget { break }
                    bridgeStart = bridgeStart ?? now
                    // Bridging only hides behind parse time: an idle parse stage gets the batch now.
                    ring.lock()
                    let parserIdle = published == 0
                    bridging = !parserIdle
                    ring.unlock()
                    if parserIdle { break }
                    let r = poll(&bridge, 3, Self.pollMs)
                    ring.lock(); bridging = false; ring.unlock()
                    if r <= 0 { break }
                    if bridge[1].revents & Int16(POLLIN) != 0 { fatal = true; break }
                    if bridge[2].revents & Int16(POLLIN) != 0 { var trash = (0, 0); while read(idle.read, &trash, 16) == 16 {}; break }
                    if bridge[0].revents & Int16(POLLIN) == 0 { break }
                    continue
                }
                if n == 0 { break }   // macOS once the child is gone (not EAGAIN): the poll below sees HUP
                total += n
                spins = 0
            }
            if total > 0 {
                ring.lock()
                (lens[slot], head, published) = (total, (head + 1) % Self.count, published + 1)
                ring.signal()
                ring.unlock()
            }
            if fatal { return }
            if total == Self.capacity { continue }   // still hot: the next buffer without a poll
            _ = poll(&wait, 2, -1)
            if wait[1].revents & Int16(POLLIN) != 0 || wait[0].revents & Int16(POLLHUP) != 0 { return }
        }
    }

    func parse(_ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        while true {
            ring.lock()
            while published == 0 && !done { ring.wait() }
            if published == 0 { ring.unlock(); return }
            let (slot, length) = (tail, lens[tail])
            ring.unlock()
            body(UnsafeBufferPointer(start: buffer(slot), count: length))
            ring.lock()
            (tail, published) = ((tail + 1) % Self.count, published - 1)
            let wake = published == 0 && bridging
            ring.signal()
            ring.unlock()
            // Ran dry while the gather thread bridges a refill gap: end its poll now.
            if wake { _ = Darwin.write(idle.write, "i", 1) }
        }
    }
}
#endif
