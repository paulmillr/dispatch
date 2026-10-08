import SwiftUI
import AppKit

struct SSHSourceContext: Sendable, Equatable {
    let id: SSHConnectionID
    /// Reads a document's current text on that host (document, working directory).
    let source: @Sendable (ToolDocument, String) async throws -> String

    /// One connection reads the same way: ChatView recreates the closure on every render, and an unequal
    /// environment value would re-render every code document in the transcript.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
private struct SSHSourceKey: EnvironmentKey { static let defaultValue: SSHSourceContext? = nil }
extension EnvironmentValues {
    var sshSource: SSHSourceContext? {
        get { self[SSHSourceKey.self] }
        set { self[SSHSourceKey.self] = newValue }
    }
}

@MainActor @Observable
final class CodeDocumentState {
    var sourceMode = false
    var source: String?
    var reload = UUID()
    @ObservationIgnored let diffLines = DiffLinePresentation()
}

/// Reconcile snapshots before drawing. Equal lines retain their identities even
/// when preceding hunks grow; edited lines retain theirs within replacement runs.
@MainActor final class DiffLinePresentation {
    struct Line: Identifiable {
        let id: Int
        let text: String
        var arrival: ChatTranscriptArrivals.Receipt?
    }
    private var path: String?
    private var snapshot: String?
    private var nextID = 0
    private var suspended = false
    private(set) var lines: [Line] = []

    func update(_ diff: String, path: String, animate: Bool) -> [Line] {
        let preview = String(diff.prefix(32_768))
        let animate = animate && snapshot != nil && self.path == path && !suspended
        suspended = false
        if !animate { clearArrivals() }
        guard snapshot != preview || self.path != path else { return lines }
        let old = self.path == path ? lines : []
        let text = preview.components(separatedBy: "\n")
        var prefix = 0, suffix = 0
        while prefix < min(old.count, text.count), old[prefix].text == text[prefix] { prefix += 1 }
        while suffix < min(old.count, text.count) - prefix,
              old[old.count - suffix - 1].text == text[text.count - suffix - 1] { suffix += 1 }
        let before = Array(old[prefix..<(old.count - suffix)].map(\.text))
        let after = Array(text[prefix..<(text.count - suffix)])
        var matches = (0..<prefix).map { (old: $0, new: $0) }
        if before.count * after.count <= 250_000 {
            let changes = after.difference(from: before)
            var removed: Set<Int> = [], inserted: Set<Int> = []
            for change in changes {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var cursor = 0
            for index in after.indices where !inserted.contains(index) {
                while removed.contains(cursor) { cursor += 1 }
                matches.append((prefix + cursor, prefix + index)); cursor += 1
            }
        } else {
            // Bound work for wholesale rewrites and large repeated-line patches.
            // Match ordered occurrences in linear time instead of an unbounded LCS.
            var positions: [String: [Int]] = [:], cursors: [String: Int] = [:]
            for (index, line) in before.enumerated() { positions[line, default: []].append(index) }
            var minimum = 0
            for (index, line) in after.enumerated() {
                guard let candidates = positions[line] else { continue }
                var cursor = cursors[line, default: 0]
                while cursor < candidates.count, candidates[cursor] < minimum { cursor += 1 }
                cursors[line] = cursor + 1
                guard cursor < candidates.count else { continue }
                matches.append((prefix + candidates[cursor], prefix + index))
                minimum = candidates[cursor] + 1
            }
        }
        matches += (0..<suffix).map { (old.count - suffix + $0, text.count - suffix + $0) }
        var result: [Line] = [], oldStart = 0, newStart = 0, animated = 0
        let now = ProcessInfo.processInfo.systemUptime
        for match in matches + [(old.count, text.count)] {
            for index in newStart..<match.new {
                let previous = oldStart + index - newStart
                if previous < match.old, old[previous].text.first == text[index].first {
                    // Growing a partial line or revising a hunk header is an edit,
                    // not another entrance on every streamed snapshot.
                    result.append(Line(id: old[previous].id, text: text[index], arrival: old[previous].arrival))
                } else {
                    let arrival: ChatTranscriptArrivals.Receipt?
                    if animate, animated < 64, !text[index].isEmpty {
                        arrival = .init(time: now); animated += 1
                    } else { arrival = nil }
                    result.append(Line(id: nextID, text: text[index], arrival: arrival)); nextID += 1
                }
            }
            if match.old < old.count { result.append(old[match.old]) }
            oldStart = match.old + 1; newStart = match.new + 1
        }
        self.path = path; snapshot = preview; lines = result
        return lines
    }

    func suspend() { clearArrivals(); suspended = true }
    private func clearArrivals() {
        for index in lines.indices where lines[index].arrival != nil { lines[index].arrival = nil }
    }
}

struct CodeDocumentControls: View {
    @Environment(\.chatTheme) private var theme
    let document: ToolDocument
    let state: CodeDocumentState
    private var displayed: String { state.sourceMode ? (state.source ?? "") : document.diff }
    var body: some View {
        HStack(spacing: 10) {
            if !document.diff.isEmpty {
                Button("Diff") { state.sourceMode = false }.foregroundStyle(state.sourceMode ? theme.muted : theme.ink)
            }
            Button("Source") { state.sourceMode = true; state.reload = UUID() }.foregroundStyle(state.sourceMode ? theme.ink : theme.muted)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(displayed, forType: .string) } label: {
                Image(systemName: "doc.on.doc")
            }.help("Copy displayed code").accessibilityLabel("Copy displayed code").disabled(displayed.isEmpty)
        }.buttonStyle(.plain).font(theme.typography.detail).fixedSize()
    }
}

struct CodeDocumentView: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let document: ToolDocument
    let directory: String
    @Environment(\.sshSource) private var sshSource
    var showHeader = true
    var presentation: CodeDocumentState?
    var animatesChanges = false
    @State private var localState = CodeDocumentState()
    private var state: CodeDocumentState { presentation ?? localState }
    @State private var error: String?
    @State private var loading = false
    private struct SourceRequest: Hashable {
        let path: String
        let workingDirectory: String?
        let directory: String
        let sourceMode: Bool
        let reload: UUID
        let connection: SSHConnectionID?
        let fileAccess: Bool
    }
    private var fileAccess: Bool {
        guard let sshSource else { return true }
        return TerminalRuntime.shared.ssh.grant(sshSource.id)?.selectedFeatures.contains(.files) == true
    }
    private var displayed: String { state.sourceMode ? (state.source ?? "") : document.diff }
    var body: some View {
        let preview = String(displayed.prefix(32_768))
        let diff = state.diffLines.update(document.diff, path: document.path, animate: animatesChanges && !state.sourceMode)
        let rows = state.sourceMode ? preview.components(separatedBy: "\n").enumerated().map {
            DiffLinePresentation.Line(id: -($0.offset + 1), text: $0.element, arrival: nil)
        } : diff
        let lines = rows.map(\.text)
        let numbers = ToolDocument.lineNumbers(lines)
        let highlighted = state.sourceMode
            ? SyntaxHighlight.lines(preview, language: document.path, theme: theme)
            : SyntaxHighlight.diffLines(preview, path: document.path, theme: theme)
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
            HStack(spacing: 10) {
                Text(ChatSearchHighlight.text(AttributedString(document.displayPath(in: directory)), query: query, theme: theme)).lineLimit(1).truncationMode(.middle)
                if !state.sourceMode {
                    Text("+\(lines.filter { $0.hasPrefix("+") }.count)").foregroundStyle(theme.green)
                    Text("−\(lines.filter { $0.hasPrefix("-") }.count)").foregroundStyle(theme.red)
                }
                Spacer(minLength: 4)
                CodeDocumentControls(document: document, state: state)
            }.padding(10).background(theme.window)
            }
            if state.sourceMode {
                Text(sshSource == nil ? "Current file on disk" : "Current file on SSH host").font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 10).padding(.top, 6)
            }
            if loading { ProgressView().controlSize(.small).padding() }
            if state.sourceMode, let error { Text(error).foregroundStyle(theme.muted).padding(10) }
            GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let line = row.text
                        HStack(alignment: .top, spacing: 12) {
                            Text(state.sourceMode ? String(index + 1) : numbers[index].map(String.init) ?? "")
                                .foregroundStyle(theme.muted).frame(width: 38, alignment: .trailing)
                            Text(ChatSearchHighlight.text(line.isEmpty ? AttributedString(" ") : highlighted[index], query: query, theme: theme)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                        .background(!state.sourceMode && line.hasPrefix("+") ? theme.green.opacity(0.10) : (!state.sourceMode && line.hasPrefix("-") ? theme.red.opacity(0.10) : .clear))
                        .opacity(!state.sourceMode && line.hasPrefix("-") ? 0.6 : 1)
                        .modifier(ChatArrivalMotion(receipt: row.arrival, since: 0, reduceMotion: reduceMotion,
                                                    distance: 4, duration: 0.25))
                        .accessibilityIdentifier("code-line-\(row.id)")
                    }
                }.frame(minWidth: geometry.size.width, alignment: .leading)
            }
            }.frame(height: min(360, max(50, CGFloat(lines.count) * (theme.typography.codeDetailLineHeight + 4)
                + (NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0))))
            if preview.count < displayed.count {
                Text("Preview truncated · Copy includes the full text").foregroundStyle(theme.muted).padding(8)
            }
        }
        .font(theme.typography.codeDetail).background(theme.terminal)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
        .onAppear { if document.diff.isEmpty && !animatesChanges { state.sourceMode = true } }
        .onDisappear { state.diffLines.suspend() }
        .task(id: SourceRequest(path: document.path, workingDirectory: document.workingDirectory, directory: directory, sourceMode: state.sourceMode, reload: state.reload, connection: sshSource?.id, fileAccess: fileAccess)) {
            state.source = nil; error = nil; loading = false
            guard state.sourceMode else { return }
            guard fileAccess else { error = "File access is disabled for this host."; return }
            loading = true
            let result: Result<String, Error>
            if let sshSource {
                do { result = .success(try await sshSource.source(document, directory)) }
                catch { result = .failure(error) }
            } else {
                do { result = .success(try await document.source(in: directory)) }
                catch { result = .failure(error) }
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text): state.source = text
            case .failure(let failure): error = failure.localizedDescription
            }
            loading = false
        }
    }
}
