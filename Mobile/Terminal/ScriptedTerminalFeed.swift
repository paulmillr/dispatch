import Foundation
import Synchronization

/// A `TerminalFeed` that plays a script, for tests, previews and benchmarks. Each attachment plays the script
/// from the start (output in chunks of `chunk` bytes, as a helper's notifications arrive); what the host sends is
/// recorded. With `echo`, typed input comes back the way a shell's line editor shows it, so previews are
/// interactive. Scroll steps answer `scroll` (tmux: `appOwned`; herdr: `server`, which also reports a history
/// position of up to `history` lines).
final class ScriptedTerminalFeed: TerminalFeed {
    enum Step: Sendable {
        case output(Data)
        case attached
        case pause(Duration)
        case history(TerminalHistoryPosition)
        case exit(Int32?)
    }

    struct Options: Sendable {
        var chunk = 65_536
        var echo = false
        /// Every input comes back on a line of its own in caret notation (ESC as `^[`, Ctrl-C as `^C`), so a UI test
        /// reads a key's encoding off the screen (`-DispatchTerminalEcho keys`).
        var echoKeys = false
        var prompt = "\u{1B}[32m~/src/app\u{1B}[0m \u{1B}[38;2;111;111;120m$\u{1B}[0m "
        var scroll = TerminalScrollResult.appOwned
        var history: UInt64 = 0
        /// Output paced at this many bytes a second (nil: as fast as the host takes it).
        var rate: Int?
    }

    /// What the host did, in order.
    struct Record: Sendable {
        var attachments: [TerminalFeedSize] = []
        var detaches = 0
        var input: [Data] = []
        var resizes: [TerminalFeedSize] = []
        var scrolls: [TerminalScrollRequest] = []
        var screens: [TerminalScreen] = []
        var sent: Data { input.reduce(Data(), +) }
    }

    private struct State {
        var record = Record()
        var events: AsyncStream<TerminalFeedEvent>.Continuation?
        var player: Task<Void, Never>?
        var offset: UInt64 = 0
        var viewport: UInt32 = 0
        var line = ""
    }

    let steps: [Step]
    let options: Options
    private let state = Mutex(State())

    init(_ steps: [Step], options: Options = Options()) {
        self.steps = steps
        self.options = options
    }

    convenience init(output: Data, options: Options = Options()) {
        self.init([.output(output), .attached], options: options)
    }

    var record: Record { state.withLock { $0.record } }

    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent> {
        let (events, continuation) = AsyncStream<TerminalFeedEvent>.makeStream()
        let steps = steps, chunk = max(1, options.chunk), rate = options.rate
        let player = Task {
            let clock = ContinuousClock(), started = clock.now
            var sent = 0
            for step in steps {
                if Task.isCancelled { return }
                switch step {
                case .output(let data):
                    var start = data.startIndex
                    while start < data.endIndex {
                        let end = data.index(start, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
                        continuation.yield(.output(data[start..<end]))
                        sent += end - start
                        start = end
                        if let rate, rate > 0 {
                            try? await clock.sleep(until: started + .microseconds(Int64(sent) * 1_000_000 / Int64(rate)))
                            if Task.isCancelled { return }
                        }
                    }
                case .attached: continuation.yield(.attached)
                case .pause(let duration): try? await Task.sleep(for: duration)
                case .history(let position): continuation.yield(.history(position))
                case .exit(let status):
                    continuation.yield(.exited(status))
                    continuation.finish()
                    return
                }
            }
        }
        let previous = state.withLock { state in
            defer {
                state.record.attachments.append(size)
                state.events = continuation
                state.player = player
                state.viewport = UInt32(clamping: size.rows)
            }
            return (state.events, state.player)
        }
        previous.1?.cancel()
        previous.0?.finish()
        return events
    }

    func detach() {
        let previous = state.withLock { state in
            defer {
                state.record.detaches += 1
                state.events = nil
                state.player = nil
            }
            return (state.events, state.player)
        }
        previous.1?.cancel()
        previous.0?.finish()
    }

    func send(_ input: Data) {
        let echo = state.withLock { state -> (AsyncStream<TerminalFeedEvent>.Continuation, Data)? in
            guard state.events != nil else { return nil }
            state.record.input.append(input)
            guard options.echo || options.echoKeys, let events = state.events else { return nil }
            if options.echoKeys { return (events, Data(("\r\n" + Self.caret(input)).utf8)) }
            return (events, Self.echo(input, line: &state.line, prompt: options.prompt))
        }
        if let (events, bytes) = echo, !bytes.isEmpty { events.yield(.output(bytes)) }
    }

    func resize(_ size: TerminalFeedSize) {
        state.withLock { state in
            guard state.events != nil else { return }
            state.record.resizes.append(size)
            state.viewport = UInt32(clamping: size.rows)
        }
    }

    func publish(_ screen: TerminalScreen) {
        state.withLock { state in
            guard state.events != nil else { return }
            state.record.screens.append(screen)
        }
    }

    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult {
        let (result, position, events) = state.withLock { state -> (TerminalScrollResult, TerminalHistoryPosition?, AsyncStream<TerminalFeedEvent>.Continuation?) in
            guard state.events != nil else { return (.failed, nil, nil) }
            state.record.scrolls.append(request)
            guard options.scroll == .server else { return (options.scroll, nil, nil) }
            let moved = Int64(clamping: state.offset) + Int64(request.lines)
            state.offset = UInt64(max(0, min(Int64(clamping: options.history), moved)))
            return (.server, .init(offset: state.offset, maximum: options.history, viewport: state.viewport), state.events)
        }
        if let position { events?.yield(.history(position)) }
        return result
    }

    /// Bytes as `cat -v` shows them: C0 controls as `^@` to `^_`, DEL as `^?`, the rest as text.
    static func caret(_ input: Data) -> String {
        var out = ""
        for scalar in String(decoding: input, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F: out += "^" + String(UnicodeScalar(UInt8(scalar.value + 0x40)))
            case 0x7F: out += "^?"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    #if DEBUG
    /// The Spaces sample's terminal (`-DispatchTabsSample`): `output`, and with `-DispatchTerminalEcho keys` every
    /// input echoed in caret notation (UI tests of hardware keys).
    static func sample(output: Data) -> ScriptedTerminalFeed {
        var options = Options()
        options.echoKeys = UserDefaults.standard.string(forKey: "DispatchTerminalEcho") == "keys"
        return ScriptedTerminalFeed(output: output, options: options)
    }
    #endif

    /// A shell line editor's echo: printable text as typed, backspace erases, return runs nothing and prompts again.
    static func echo(_ input: Data, line: inout String, prompt: String) -> Data {
        var out = ""
        for scalar in String(decoding: input, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x0D:
                out += "\r\n" + prompt
                line = ""
            case 0x7F, 0x08:
                if !line.isEmpty { line.removeLast(); out += "\u{8} \u{8}" }
            case 0x03:
                out += "^C\r\n" + prompt
                line = ""
            case 0x20...0x7E, 0xA0...:
                line.unicodeScalars.append(scalar)
                out.unicodeScalars.append(scalar)
            default: break
            }
        }
        return Data(out.utf8)
    }
}
