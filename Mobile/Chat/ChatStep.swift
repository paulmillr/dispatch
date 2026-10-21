import SwiftUI

/// One step of a turn as the phone lists it (M5f's live log, M5b's step list): a kind badge, what it acted on (a path
/// relative to the conversation's directory, or the command) and a short result. Built from the shared tool
/// presentation (ToolPresentation), never from tool-specific parsing of its own.
struct ChatStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case read, patch, run, search, think, web, tool

        /// M5b's word and M5f's badge (upper-cased there).
        var label: String {
            switch self {
            case .read: "Read"; case .patch: "Patch"; case .run: "Run"; case .search: "Search"
            case .think: "Think"; case .web: "Web"; case .tool: "Tool"
            }
        }

        /// The mockup's badge colours: read blue, think purple, run amber, patch green.
        /// Deeper in light so the 11 pt word reads on its faint tint (asset catalog).
        var tint: Color {
            switch self {
            case .read, .search, .web: Color("StepRead")
            case .think: Color("StepThink")
            case .run: Color("StepRun")
            case .patch: .added
            case .tool: Color("StepTool")
            }
        }
    }

    let item: ChatItem
    let kind: Kind
    let title: String
    /// "+4 −1", "1 failed · exit 1", the last line of a command's output; nil when there is nothing short to say.
    let detail: String?
    let additions: Int
    let deletions: Int
    let failed: Bool
    let running: Bool
    var id: String { item.id }

    static var added: Color { .added }
    static var removed: Color { .destructive }

    init(_ item: ChatItem, directory: String?) {
        self.item = item
        let directory = directory ?? item.directory ?? ""
        if item.kind == .reasoning {
            kind = .think
            let rawTitle = item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Thinking"
            title = TextRendering.visible(TextRendering.prefix(rawTitle, scalars: 512).text)
            detail = nil; additions = 0; deletions = 0; failed = false; running = !item.completed
            return
        }
        let tool = ToolPresentation(item)
        let category = item.source?.tool?.kind
        if tool.isPatch || ChatPatch.isPatchOperation(item) || category == "patch" {
            kind = .patch
        } else if tool.readCommand != nil || category == "read" || tool.title == "Read" {
            kind = .read
        } else if category == "search" || tool.title == "Search" || item.source?.tool?.search != nil {
            // Before shell: an `rg` or `grep` run is a search, as the Mac's tool cards title it.
            kind = .search
        } else if tool.commandPresentation != nil || category == "shell" || item.source?.tool?.shell != nil {
            kind = .run
        } else if WebToolPresentation.matches(item.title) {
            kind = .web
        } else { kind = .tool }
        // A patch that did not apply (declined, failed, interrupted) changed nothing: its state shows, not its counts
        // (ChatToolCard's "Patch declined").
        let unapplied = item.patch.flatMap { [.interrupted, .failed, .declined].contains($0.state) ? $0.state : nil }
        additions = unapplied == nil ? tool.additions : 0
        deletions = unapplied == nil ? tool.deletions : 0
        failed = tool.failed || unapplied != nil
        running = !item.completed
        // Relative to the conversation's directory, else to the directory the agent recorded for the call.
        let bases = [directory, item.directory ?? "", item.source?.tool?.directory ?? ""].filter { !$0.isEmpty }
        func relative(_ path: String) -> String {
            for directory in bases {
                let base = directory.hasSuffix("/") ? directory : directory + "/"
                if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
            }
            return path
        }
        switch kind {
        case .patch where !tool.documents.isEmpty:
            title = TextRendering.visible(TextRendering.prefix(
                tool.documents.map { relative($0.path) }.joined(separator: ", "), scalars: 512).text)
        case .read where tool.readCommand != nil:
            title = TextRendering.visible(TextRendering.prefix(relative(tool.readCommand!.path), scalars: 512).text)
        case .read:
            let path = (ToolPresentation.json(item.text) as? [String: Any])?["file_path"] as? String
            title = TextRendering.visible(TextRendering.prefix(
                path.map(relative) ?? tool.displaySummary(in: directory), scalars: 512).text)
        case .run:
            let command = item.source?.tool?.shell?.command ?? tool.input
            let rawTitle = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? tool.displaySummary(in: directory)
            title = TextRendering.visible(TextRendering.prefix(rawTitle, scalars: 512).text)
        default:
            let summary = tool.displaySummary(in: directory)
            title = TextRendering.visible(TextRendering.prefix(
                summary.isEmpty ? tool.displayTitle : summary, scalars: 512).text)
        }
        switch kind {
        case .patch:
            detail = unapplied.map { "Patch " + $0.rawValue } ?? (additions + deletions > 0 ? "+\(additions) −\(deletions)" : nil)
        case .run:
            let last = tool.output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
            let exit = tool.exitCode.flatMap { $0 == 0 ? nil : "exit \($0)" }
            detail = [last.map { TextRendering.visible(TextRendering.prefix($0, scalars: 80).text) }, exit]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        default:
            detail = nil
        }
    }

    /// A turn's steps, in order: its tools as the caption counts them, and its reasoning summaries in the live log
    /// (Claude's thinking is a row of the thread itself).
    static func steps(_ turn: ChatTurn, directory: String?, reasoning: Bool) -> [ChatStep] {
        ChatTurnSummary.displayed(turn.items, turnID: turn.id)
            .filter { $0.kind == .tool || reasoning && $0.kind == .reasoning && !$0.isNarration && !$0.text.isEmpty }
            .map { ChatStep($0, directory: directory) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// M5f's kind badge: the word in mono caps on a faint tint, 50 points wide whatever the word, so the log's paths line up.
struct ChatStepBadge: View {
    let kind: ChatStep.Kind
    @ScaledMetric(relativeTo: .caption2) private var width: CGFloat = 50
    var body: some View {
        Text(kind.label.uppercased())
            .font(.caption2.weight(.bold).monospaced())
            .tracking(0.44)
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: width, minHeight: 20, alignment: .leading)
            .background(kind.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(kind.label)
    }
}
