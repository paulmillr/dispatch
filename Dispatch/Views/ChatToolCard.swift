import SwiftUI

struct ChatToolCard: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let item: ChatItem
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let directory: String
    var requested = false
    var embedded = false
    var layouts: ChatToolLayoutCache?
    var layoutWidth: CGFloat = 0
    var live = false
    @State private var formatted: (id: UUID, value: ToolPresentation)?
    @State private var rawExpanded = false
    @State private var singleFileState = CodeDocumentState()
    var body: some View {
        let cached = formatted == nil ? ToolPresentationCache.shared.cached(for: item) : nil
        let tool = formatted?.value ?? cached
        let reserved = expanded && tool == nil
            ? layouts?.height(for: item.presentationID, width: layoutWidth, typography: theme.typography) : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
            Button { expanded.toggle() } label: {
                header(tool)
                    .padding(.horizontal, embedded ? 0 : 12).padding(.vertical, embedded ? 3 : 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("tool-header-\(item.id)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded, let tool, tool.isPatch, tool.documents.count == 1, let document = tool.documents.first {
                CodeDocumentControls(document: document, state: singleFileState)
                    .padding(.trailing, embedded ? 0 : 12)
            }
            }
            if expanded, let tool {
            VStack(alignment: .leading, spacing: 10) {
                if let directory = tool.directory {
                    Label(directory, systemImage: "folder").font(theme.typography.detail).foregroundStyle(theme.muted)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let state = item.patch?.state, [.interrupted, .failed, .declined].contains(state) {
                    Text("Patch " + state.rawValue).font(theme.typography.detail).foregroundStyle(theme.muted)
                }
                if let patch = item.patch, !item.completed {
                    Text(patch.state == .generating ? "Generating changes…" : "Applying changes…")
                        .font(theme.typography.detail).foregroundStyle(theme.muted)
                }
                if !tool.input.isEmpty && item.patch == nil && !tool.usesRawDetails {
                    ChatCodeBlock(code: tool.input, language: tool.language, title: tool.language == "shell" ? "Command" : "Input")
                }
                ForEach(tool.requests) { request in
                    let operation = ToolPresentation(request)
                    if let read = operation.readCommand {
                        Label(read.summary(in: directory), systemImage: "doc.text")
                            .font(theme.typography.detail).foregroundStyle(theme.muted)
                    } else if let action = operation.commandPresentation {
                        let summary = operation.displaySummary(in: directory)
                        Label(action.title + (summary.isEmpty ? "" : " · " + summary), systemImage: action.symbol)
                            .font(theme.typography.detail).foregroundStyle(theme.muted)
                    } else if !operation.input.isEmpty {
                        ChatCodeBlock(code: operation.input, language: operation.language, title: "Requested command")
                    }
                    ForEach(operation.documents) { document in
                        CodeDocumentView(document: document, directory: directory, animatesChanges: live)
                    }
                }
                if tool.isOrchestration && tool.requests.isEmpty && tool.output.isEmpty {
                    Text("Agent tool activity").font(theme.typography.detail).foregroundStyle(theme.muted)
                }
                ForEach(tool.documents) { document in
                    let singleFile = tool.isPatch && tool.documents.count == 1
                    CodeDocumentView(document: document, directory: directory, showHeader: !singleFile,
                                     presentation: singleFile ? singleFileState : nil, animatesChanges: live)
                }
                if !tool.output.isEmpty && !(tool.documents.contains { !$0.diff.isEmpty } && (tool.output.contains("+++ ") || tool.output.contains("*** Update File:"))) {
                    if let read = tool.sourceReadPreview {
                        ChatCodeBlock(code: tool.output, language: SyntaxHighlight.language((read.path as NSString).pathExtension),
                                      title: "Captured output", firstLine: read.firstLine)
                    } else {
                        ChatToolOutput(output: tool.output, blocks: tool.outputBlocks)
                    }
                } else if !tool.isPatch && tool.completed && tool.output.isEmpty && item.patch == nil {
                    Text(tool.failed ? "Failed with no output" : "Done").font(theme.typography.detail).foregroundStyle(theme.muted)
                }
                Button { rawExpanded.toggle() } label: {
                    HStack {
                        Image(systemName: rawExpanded ? "chevron.down" : "chevron.right")
                        Text(tool.usesRawDetails ? "Raw details" : "Tool details")
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).font(theme.typography.detail).foregroundStyle(theme.muted)
                    .accessibilityValue(rawExpanded ? "Expanded" : "Collapsed")
                if rawExpanded {
                    VStack(spacing: 8) {
                        Text(ChatSearchHighlight.text(AttributedString(item.title), query: query, theme: theme))
                            .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(theme.muted)
                        if !item.text.isEmpty { ChatCodeBlock(code: item.text, language: tool.isOrchestration ? "javascript" : (ToolPresentation.json(item.text) == nil ? "text" : "json"), title: "Raw input") }
                        if !item.output.isEmpty { ChatCodeBlock(code: item.output, language: ToolPresentation.json(item.output) == nil ? "text" : "json", title: "Raw output") }
                    }.padding(.top, 6).font(theme.typography.detail).foregroundStyle(theme.muted)
                }
            }.padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 2)
            }
        }
        .background {
            if expanded, layouts != nil {
            GeometryReader { geometry in
                Color.clear.onAppear { rememberHeight(geometry.size, cached: cached) }
                    .onChange(of: geometry.size) { _, size in rememberHeight(size, cached: cached) }
                    .onChange(of: formatted?.id) { _, _ in rememberHeight(geometry.size, cached: cached) }
            }
            }
        }
        .frame(minHeight: reserved, alignment: .top)
        .chatPanel(embedded ? Color.clear : nil, cornerRadius: 7, bordered: !embedded)
        .accessibilityIdentifier("tool-\(item.id)")
        .task(id: item.presentationID) {
            guard !Task.isCancelled else { return }
            let value = await ToolPresentationCache.shared.presentation(for: item)
            guard !Task.isCancelled else { return }
            formatted = (item.presentationID, value)
        }
        // An expanded row must keep its laid-out contents when it leaves the
        // viewport. Clearing them shrinks the row to its header; on return the
        // async refill pushes visible messages by the entire output height.
        // Collapsed rows have a fixed header and can release their payload.
        .onDisappear { if !expanded { formatted = nil } }
    }
    private func rememberHeight(_ size: CGSize, cached: ToolPresentation?) {
        guard expanded, !rawExpanded,
              formatted?.id == item.presentationID || (formatted == nil && cached != nil),
              let tool = formatted?.value ?? cached,
              tool.documents.isEmpty, tool.requests.isEmpty else { return }
        // Source/diff panels own a separate asynchronous presentation state;
        // their measured source height must not be reused for a default diff.
        layouts?.remember(size, for: item.presentationID, typography: theme.typography)
    }
    private func header(_ tool: ToolPresentation?) -> some View {
            HStack(spacing: 9) {
                Image(systemName: tool?.symbol ?? "wrench.and.screwdriver").foregroundStyle(theme.muted).frame(width: 14)
                Text(ChatSearchHighlight.text(AttributedString((requested ? tool?.title : tool?.displayTitle) ?? "Tools"), query: query, theme: theme)).fontWeight(.semibold).fixedSize()
                Text(ChatSearchHighlight.text(AttributedString(String((tool?.displaySummary(in: directory) ?? "").prefix(180))), query: query, theme: theme))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(theme.muted)
                Spacer(minLength: 0)
                if let result = tool?.confirmedResult {
                    Text(result).foregroundStyle(theme.green).lineLimit(1)
                }
                if let tool, tool.additions > 0 { Text("+\(tool.additions)").foregroundStyle(theme.green).fixedSize() }
                if let tool, tool.deletions > 0 { Text("−\(tool.deletions)").foregroundStyle(theme.red).fixedSize() }
                if let tool, tool.failed {
                    Text(tool.exitCode.map { $0 != 0 ? "exit \($0)" : "Failed" } ?? "Failed").foregroundStyle(theme.yellow).fixedSize()
                }
                if !requested {
                    statusIcon(failed: tool?.failed == true, completed: tool?.completed ?? item.completed)
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.12), value: expanded).frame(width: 8).foregroundStyle(theme.muted)
                }
            }.font(theme.typography.detail).padding(.vertical, 1)
    }

    private func statusIcon(failed: Bool, completed: Bool) -> some View {
        let symbol = failed ? "exclamationmark.circle" : completed ? "checkmark.circle" : "circle.dotted"
        return ZStack {
            Image(systemName: symbol)
                .foregroundStyle(failed ? theme.yellow : completed ? theme.green : theme.muted)
                .id(symbol).transition(.opacity)
        }
        .frame(width: 14)
        .animation(.easeOut(duration: 0.12), value: symbol)
        .accessibilityLabel(failed ? "Failed" : completed ? "Completed" : "Running")
        .accessibilityIdentifier("tool-status-\(item.id)")
    }
}
