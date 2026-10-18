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

/// Terminal bytes in, input, size and scroll steps out, for one terminal node (docs/ios-contracts.md, Terminal).
/// `HelperTerminalFeed` speaks the helper protocol; `ScriptedTerminalFeed` plays fixtures for tests and previews.
///
/// Lifecycle: `attach(_:)` starts an attachment at a size and returns its events; `detach()` ends it (the stream
/// finishes). Detaching only stops observing: the server-owned session keeps running. A later `attach` starts a new
/// attachment whose output repaints the screen. Input, resizes and scroll steps are delivered in the order they were
/// made, and only while attached.
protocol TerminalFeed: AnyObject, Sendable {
    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent>
    func detach()
    /// Bytes for the program (keys, pastes, the emulator's replies).
    func send(_ input: Data)
    func resize(_ size: TerminalFeedSize)
    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult
    /// The screen the helper verifies chat input against (`terminals.publish`); only the latest matters.
    func publish(_ screen: TerminalScreen)
}
