import Foundation

/// Where finger scrolling goes (M6a). The history above the screen is one stack: the emulator's own scrollback
/// (tmux and the native multiplexer replay theirs into it), then the multiplexer's history (herdr keeps it on the
/// server, reached with `terminals.scroll`). Scrolling toward older output uses the local scrollback until its top,
/// then the server's; scrolling back first returns the server to its live screen, then the local viewport to the
/// bottom. A gesture's lines are split exactly at those boundaries, so nothing jumps.
///
/// When the program takes the wheel itself (mouse reporting, or the alternate screen's arrow-key scrolling) every
/// line goes to the server while it may own history (herdr forwards the wheel to its pane), else to the emulator,
/// which encodes it for the program. The first `scrollback_app_owned` answer makes the server's share local for
/// good, as on the Mac (`HelperWorkspace.scroll`): the step that learned it is replayed locally.
struct TerminalScrollModel: Equatable, Sendable {
    enum Server: Equatable, Sendable { case unknown, available, appOwned }

    /// The emulator's viewport.
    struct Local: Equatable, Sendable {
        /// Rows of scrollback above the viewport.
        var above: Int
        /// Rows between the viewport and the live screen.
        var below: Int
        /// The program reads the wheel (mouse reporting or alternate scroll).
        var programTakesWheel = false
    }

    /// Lines for each side; positive goes toward older output.
    struct Plan: Equatable, Sendable {
        var local = 0
        var server = 0
    }

    private(set) var server = Server.unknown
    /// The server's position (lines back from its live screen) as last reported or predicted.
    private(set) var serverOffset: UInt64 = 0
    private(set) var serverMaximum: UInt64?
    /// Finger travel in points not yet a whole line.
    private(set) var pending = 0.0

    /// Finger travel (points, positive: the finger moves down, toward older output) as whole lines; the remainder
    /// carries over to the next movement.
    mutating func lines(points: Double, lineHeight: Double) -> Int {
        guard lineHeight > 0, points.isFinite else { return 0 }
        let total = pending + points
        let lines = (total / lineHeight).rounded(.towardZero)
        pending = total - lines * lineHeight
        return Int(lines)
    }

    /// A gesture ended or changed direction: the partial line is dropped.
    mutating func endGesture() { pending = 0 }

    /// Splits `lines` between the emulator and the server, predicting the server's new position.
    mutating func route(_ lines: Int, local: Local) -> Plan {
        guard lines != 0 else { return Plan() }
        if local.programTakesWheel { return server == .appOwned ? Plan(local: lines) : Plan(server: lines) }
        var plan = Plan()
        if lines > 0 {
            plan.local = min(lines, max(0, local.above))
            let rest = lines - plan.local
            guard rest > 0 else { return plan }
            // A server known to be at its oldest line takes no more; the emulator's top is a no-op either way.
            if server == .appOwned || serverMaximum.map({ server == .available && serverOffset >= $0 }) == true {
                plan.local += rest
            } else {
                plan.server = rest
                serverOffset = serverOffset &+ UInt64(rest)
                if let serverMaximum { serverOffset = min(serverOffset, serverMaximum) }
            }
        } else {
            let wanted = -lines
            let toServer = server == .appOwned ? 0 : Int(min(UInt64(wanted), serverOffset))
            serverOffset -= UInt64(toServer)
            plan.server = -toServer
            plan.local = -(wanted - toServer)
        }
        return plan
    }

    /// The server answered a plan's server step; the lines to replay locally (the server leaves history to us).
    mutating func answered(_ result: TerminalScrollResult, for plan: Plan) -> Int {
        switch result {
        case .server:
            server = .available
            return 0
        case .appOwned:
            server = .appOwned
            serverOffset = 0
            serverMaximum = nil
            return plan.server
        case .failed:
            // Undo the prediction; the position report (if any) corrects it again.
            if plan.server > 0 { serverOffset -= min(serverOffset, UInt64(plan.server)) } else { serverOffset += UInt64(-plan.server) }
            return 0
        }
    }

    /// The server reported its position (`terminal.scroll`).
    mutating func history(_ position: TerminalHistoryPosition) {
        server = .available
        serverOffset = min(position.offset, position.maximum)
        serverMaximum = position.maximum
    }

    /// The backend kind decides it up front when known (tmux: the client's, herdr: the server's).
    init(scrollback: TerminalScrollback = .unknown) { learn(scrollback) }

    /// The backend kind, known after the model was made: decides who owns history unless an answer already did.
    mutating func learn(_ scrollback: TerminalScrollback) {
        guard server == .unknown else { return }
        switch scrollback {
        case .client: server = .appOwned
        case .server: server = .available
        case .unknown: break
        }
    }

    /// A new attachment of the same terminal: the server's position is reported again; who owns history stays.
    mutating func reattached() {
        serverOffset = 0
        serverMaximum = nil
        pending = 0
    }
}
