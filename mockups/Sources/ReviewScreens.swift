import SwiftUI

struct DiffRow: View {
    let line: MockGit.Line
    var selected = false
    var background: Color {
        if selected { return Color.stateUnread.opacity(0.22) }
        switch line.kind {
        case .added: return Color.added.opacity(0.16)
        case .removed: return Color.destructive.opacity(0.16)
        case .hunk: return Color.stateUnread.opacity(0.10)
        case .context: return .clear
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.kind == .hunk {
                Text(line.text).foregroundStyle(Color.stateUnread).padding(.leading, 12)
            } else {
                Text(line.old.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                Text(line.new.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width: 30, alignment: .trailing)
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                    .foregroundStyle(line.kind == .added ? Color.added : Color.destructive)
                    .frame(width: 16)
                Text(Syntax.color(line.text)).lineLimit(1)
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.stateUnread).frame(width: 3) }
        }
    }
}

