import Foundation

/// The grid a terminal host shows: cells, and one cell in pixels (programs size images by it).
struct TerminalFeedSize: Equatable, Sendable {
    var columns: Int
    var rows: Int
    var cellWidth: Int = 0
    var cellHeight: Int = 0
}

/// A scroll gesture's step for the server's history (`terminals.scroll`): positive lines go toward older output.
struct TerminalScrollRequest: Equatable, Sendable {
    var lines: Int
    var page = false
    /// The cell under the finger, for programs that take the wheel.
    var column: Int?
    var row: Int?
    /// shift 1, alt 2, control 4.
    var modifiers: UInt8 = 0
}

/// Who answered a scroll step.
enum TerminalScrollResult: Equatable, Sendable {
    /// The multiplexer scrolled its own history (herdr); `terminal.scroll` reports where it is.
    case server
    /// The multiplexer leaves history to the renderer (tmux, the native multiplexer): scroll locally from now on.
    case appOwned
    /// The step was not delivered (no attachment, a transport error); nothing changed.
    case failed
}

/// The multiplexer's history position (`terminal.scroll`), counted from the bottom like the helper reports it.
struct TerminalHistoryPosition: Equatable, Sendable {
    /// Lines scrolled back from the live screen.
    var offset: UInt64
    /// The most lines that can be scrolled back.
    var maximum: UInt64
    /// The rows the server shows.
    var viewport: UInt32
}

/// How a `terminals.follow` call went (`TerminalFeed.follow`).
enum TerminalFollowResult: Equatable, Sendable {
    /// The helper took it: `false` holds the attachment's output, `true` queued one whole repaint as its next output.
    case done
    /// The terminal's multiplexer cannot repaint (native), or the feed holds nothing: it keeps following.
    case unsupported
    /// The call failed. A failed `true` leaves the output held: only a new attachment brings a fresh screen.
    case failed
    /// The attachment ended before the call went out: nothing was sent.
    case stale
}

/// What an attachment delivers, in order.
enum TerminalFeedEvent: Equatable, Sendable {
    /// Program output for the emulator.
    case output(Data)
    /// The attachment is complete: the screen the server sent so far is current.
    case attached
    /// The server's history position changed.
    case history(TerminalHistoryPosition)
    /// A program in the multiplexer copied text (tmux `load-buffer -w`).
    case clipboard(Data)
    /// The terminal's process ended (status when known); the stream finishes after it.
    case exited(Int32?)
    /// The attachment failed; the stream finishes after it. Input is not retried (docs/architecture.md, Delivery).
    case failed(String)
}

/// Terminal bytes in, input, size and scroll steps out, for one terminal node (docs/ios.md, Areas and seams).
/// `HelperTerminalFeed` speaks the helper protocol; `PlainShellFeed` is a PTY shell on a plain SSH host's own
/// connection; `ScriptedTerminalFeed` plays fixtures for tests and previews.
///
/// Lifecycle: `attach(_:)` starts an attachment at a size and returns its events; `detach()` ends it (the stream
/// finishes). Detaching only stops observing: the server-owned session keeps running. A later `attach` starts a new
/// attachment whose output repaints the screen. Input, resizes and scroll steps are delivered in the order they were
/// made, and only while attached.
///
/// The one semantic difference: detaching a plain shell (`PlainShellFeed`) ends it. Nothing on the host keeps it, so
/// its channel is closed and a later `attach` is refused (`.failed`); whoever shows a plain shell keeps it attached
/// for as long as the shell should live.
protocol TerminalFeed: AnyObject, Sendable {
    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent>
    func detach()
    /// Bytes for the program (keys, pastes, the emulator's replies).
    func send(_ input: Data)
    func resize(_ size: TerminalFeedSize)
    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult
    /// The screen the helper verifies chat input against (`terminals.publish`); only the latest matters. A feed whose
    /// helper reads the screen itself (`hostsScreens`) sends nothing.
    func publish(_ screen: TerminalScreen)
    /// `terminals.follow` on the current attachment, after the calls made before it: `false` holds its output (dropped
    /// on the host, nothing buffered), `true` asks for one whole repaint, which arrives as the next output.
    func follow(_ following: Bool) async -> TerminalFollowResult

    /// The helper reads this terminal's screens from tmux or herdr itself (its hello accepted `screens.host`): the
    /// presence publishes nothing, since one publication turns those reads off until the attachment ends.
    var hostsScreens: Bool { get }
    /// The attachment's output can be held while no view shows the terminal (the hello accepted `terminals.follow`
    /// and `screens.host`: sends are verified against the helper's own reads, which need nothing from the phone).
    var holdsOutput: Bool { get }

    /// Which side keeps the history, when the feed knows it regardless of the multiplexer (`.unknown`: ask the
    /// topology, or learn it from the first scroll answer).
    var scrollback: TerminalScrollback { get }
    /// Whether the emulator may write the phone's pasteboard for the program (OSC 52, kitty clipboard): only a feed
    /// whose programs the user started directly (a plain shell). Reading the pasteboard is never allowed.
    var clipboardWrite: Bool { get }
    /// Detaching ends the program (a plain shell): nothing reattaches to repaint its screen.
    var endsOnDetach: Bool { get }
}

extension TerminalFeed {
    func follow(_ following: Bool) async -> TerminalFollowResult { .unsupported }
    var hostsScreens: Bool { false }
    var holdsOutput: Bool { false }
    var scrollback: TerminalScrollback { .unknown }
    var clipboardWrite: Bool { false }
    var endsOnDetach: Bool { false }
}
