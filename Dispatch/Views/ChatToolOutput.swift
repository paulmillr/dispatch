import AppKit
import SwiftUI

struct ChatToolOutput: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let output: String
    let blocks: [ToolOutput.Block]
    // Bound the whole preview, not each item: a tool can emit thousands of
    // small content blocks as well as one very large string.
    private var preview: (blocks: [ToolOutput.Block], truncated: Bool) {
        var remaining = 32_768
        var visible: [ToolOutput.Block] = []
        for block in blocks.prefix(40) {
            let text = String(block.text.prefix(remaining))
            visible.append(.init(kind: block.kind, text: text))
            remaining -= text.count
            if remaining == 0 { return (visible, true) }
        }
        return (visible, visible.count < blocks.count)
    }
    var body: some View {
        let preview = preview
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output").foregroundStyle(theme.muted)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }.buttonStyle(.plain).accessibilityLabel("Copy full tool output")
            }.font(theme.typography.detail)
            ForEach(Array(preview.blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .code(let language): ChatCodeBlock(code: block.text, language: language)
                case .markdown: ChatMarkdown(text: block.text)
                case .attachment:
                    Text(ChatSearchHighlight.text(AttributedString(block.text), query: query, theme: theme))
                        .font(theme.typography.detail).foregroundStyle(theme.muted).textSelection(.enabled)
                }
            }
            if preview.truncated {
                Text("Preview shortened · Copy includes the full output")
                    .font(theme.typography.detail).foregroundStyle(theme.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
