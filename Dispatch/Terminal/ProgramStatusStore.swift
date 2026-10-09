import Foundation
import Observation
import Term

/// Program status records (OSC 7501) by terminal surface, as each terminal last reported them.
/// Programs report these themselves; nothing here is scraped from the screen. A done or error
/// record shows until the user types in its terminal (the engine still keeps it).
@MainActor @Observable
final class ProgramStatusStore {
    private(set) var records: [UUID: [ProgramStatus]] = [:]
    /// Per surface, the newest done/error record the user has seen: older ones stop showing.
    private var seen: [UUID: UInt64] = [:]

    func update(_ id: UUID, _ new: [ProgramStatus]) {
        records[id] = new.isEmpty ? nil : new
    }

    /// The records worth showing: working, blocked and idle ones, and unseen done and error ones.
    func visible(_ id: UUID) -> [ProgramStatus] {
        let seen = seen[id] ?? 0
        return (records[id] ?? []).filter { !$0.finished || $0.serial > seen }
    }

    func visible(_ ids: [UUID]) -> [ProgramStatus] { ids.flatMap(visible) }

    /// The user typed in the terminal: its done and error records have been seen.
    func acknowledge(_ id: UUID) {
        guard let newest = records[id]?.filter(\.finished).map(\.serial).max(), newest > seen[id] ?? 0 else { return }
        seen[id] = newest
    }

    /// The terminal is gone (or replaced: a new engine numbers its reports from 1 again).
    func close(_ id: UUID) {
        records[id] = nil
        seen[id] = nil
    }
}

extension ProgramStatus {
    var finished: Bool { state == .done || state == .error }

    /// What the record needs from the user, for the tab's hover card: "terraform · Awaiting approval: Apply 3 to add…".
    var summary: String {
        let name = Self.display(title) ?? app ?? "Program"
        var activity: String
        switch state {
        case .idle: activity = "Idle"
        case .working: activity = "Working"
        case .done: activity = "Done"
        case .error: activity = "Failed"
        case .blocked:
            activity = switch kind {
            case .permission: "Awaiting approval"
            case .question: "Question for you"
            case .auth: "Needs authentication"
            case nil: "Blocked"
            }
        }
        if let progress { activity += " \(progress)%" }
        guard let message = Self.display(message) else { return name + " · " + activity }
        let short = message.count > 120 ? String(message.prefix(119)) + "…" : message
        return name + " · " + activity + ": " + short
    }

    /// Program text as shown outside the grid: format characters (bidirectional overrides and
    /// isolates, zero-width joiners and spaces) removed, runs of whitespace collapsed; nil when empty.
    static func display(_ text: String?) -> String? {
        guard let text else { return nil }
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let compact = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? nil : compact
    }
}
