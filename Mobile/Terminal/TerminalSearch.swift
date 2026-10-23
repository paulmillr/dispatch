import Foundation

/// The terminal's search (T1): the search capsule's state over Ghostty's search, which runs in the local terminal
/// (helper terminals and plain shells alike: the emulator's screen and scrollback, not the server's history beyond
/// it). The surface does the work through its binding actions (`search:<needle>`, `navigate_search:next|previous`,
/// `end_search`) and answers with its total and the selected match's index (`TerminalSession.Event`), which `apply`
/// takes. Matches are counted newest first, as Ghostty and the Mac count them: "1 of 3" is the match nearest the
/// bottom, and the next match is the one above it (older output).
///
/// A new needle selects the newest match, so the count and the brighter highlight say where the search is from the
/// first character; stepping goes round the ends. Closing ends the search (its highlights go) and keeps the needle
/// for the next opening, as the Mac's find bar does.
@MainActor @Observable
final class TerminalSearch {
    /// The capsule shows (in place of the key capsule).
    private(set) var visible = false
    private(set) var query = ""
    /// Matches in the terminal (nil: no search running, an empty needle).
    private(set) var total: Int?
    /// The selected match, 0 the newest (nil: none selected).
    private(set) var selected: Int?
    /// Changes when the field should take the focus (an opening, ⌘F again).
    private(set) var focusRequest = 0

    /// Performs a binding action on the terminal's surface (`TerminalHostView.bindingAction`); the surface's answers
    /// come back through `apply` before it returns.
    @ObservationIgnored var perform: (String) -> Void = { _ in }
    /// A needle runs once typing pauses this long: each search reads the whole history on the main actor (8–12 ms for
    /// a long one), which every keystroke paid before. Zero runs at once (tests).
    @ObservationIgnored var debounce = Duration.milliseconds(60)
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// "2 of 3" (the Mac's "N of M"); empty without a needle or before the search answered.
    var count: String {
        guard !query.isEmpty, let total else { return "" }
        return "\(selected.map { $0 + 1 } ?? 0) of \(total)"
    }

    /// There is a match to step to.
    var canStep: Bool { (total ?? 0) > 0 }

    /// Shows the capsule and focuses its field; reopened with a needle, the search runs again.
    func open(focus: Bool = true) {
        if !visible {
            visible = true
            if !query.isEmpty { run() }
        }
        if focus { focusRequest &+= 1 }
    }

    /// The field's text changed.
    func update(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        guard visible else { return }
        pending?.cancel()
        pending = nil
        guard debounce > .zero, !query.isEmpty else { return run() }
        let wait = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.run()
        }
    }

    /// A needle still waiting for its pause runs now (a step or Return right after typing acts on it).
    func flush() {
        guard let task = pending else { return }
        task.cancel()
        pending = nil
        run()
    }

    /// A needle is waiting for typing to pause.
    var waiting: Bool { pending != nil }

    /// The next match: the one above (older output), round to the newest after the oldest. Return, ⌘G, the up chevron.
    func next() { step("navigate_search:next") }

    /// The previous match: the one below (newer output), round to the oldest. ⇧Return, ⇧⌘G, the down chevron.
    func previous() { step("navigate_search:previous") }

    /// Done, Esc: the capsule goes and the highlights with it; the needle stays for the next opening.
    func close() {
        guard visible else { return }
        pending?.cancel()
        pending = nil
        visible = false
        perform("end_search")
        total = nil
        selected = nil
    }

    /// What the surface told.
    func apply(_ event: TerminalSession.Event) {
        switch event {
        case .searchTotal(let value): total = visible ? value : nil
        case .searchSelected(let value): selected = visible ? value : nil
        default: break
        }
    }

    private func step(_ action: String) {
        guard visible, !query.isEmpty else { return }
        flush()
        perform(action)
    }

    private func run() {
        guard !query.isEmpty else {
            // An empty needle stops the search (its highlights go); the capsule stays.
            perform("search:")
            total = nil
            selected = nil
            return
        }
        perform("search:" + query)
        if selected == nil, canStep { perform("navigate_search:next") }
    }
}
