import SwiftUI

/// Source citations are read inside Dispatch, never passed to an external URL handler.
struct ChatFileLink: Identifiable, Equatable {
    let path: String
    let line: Int?
    var id: String { path + (line.map { ":\($0)" } ?? "") }

    init?(_ url: URL) {
        guard url.baseURL == nil, url.user == nil, url.password == nil, url.port == nil,
              url.query == nil,
              url.scheme == nil || url.scheme?.lowercased() == "file",
              url.host == nil || url.host == "" || (url.isFileURL && url.host == "localhost") else { return nil }
        var path = url.path
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var line: Int?
        if let suffix = path.range(of: #":[1-9][0-9]*(?::[1-9][0-9]*)?$"#, options: .regularExpression) {
            line = Int(path[suffix].dropFirst().split(separator: ":")[0])
            guard line != nil else { return nil }
            path.removeSubrange(suffix)
        }
        if let fragment = url.fragment {
            guard fragment.range(of: #"^L[1-9][0-9]*(?:C[1-9][0-9]*)?$"#, options: .regularExpression) != nil,
                  let number = Int(fragment.dropFirst().prefix(while: { $0.isNumber })) else { return nil }
            line = number
        }
        self.path = path; self.line = line
    }

    /// Keep highlighting bounded even when a citation points far into a large file.
    func excerpt(_ source: String) -> (firstLine: Int, text: String) {
        let lines = source.components(separatedBy: "\n")
        let target = min(max(1, line ?? 1), lines.count) - 1
        let start = max(0, target - 40), end = min(lines.count, target + 81)
        return (start + 1, lines[start..<end].joined(separator: "\n"))
    }
}

struct ChatFileLinkPreview: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.sshSource) private var sshSource
    @Environment(\.dismiss) private var dismiss
    let link: ChatFileLink
    @State private var source: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(link.id).font(theme.typography.codeDetail).textSelection(.enabled)
                Spacer(minLength: 12)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(sshSource == nil ? "Current file on disk" : "Current file on SSH host")
                .font(theme.typography.detail).foregroundStyle(theme.muted)
            if let source {
                let excerpt = link.excerpt(source)
                let highlighted = SyntaxHighlight.lines(excerpt.text, language: link.path, theme: theme)
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            // The line number is the row identity: since macOS 27, scrollTo
                            // matches only ForEach identities, not .id() on the rows.
                            ForEach(Array(zip(excerpt.firstLine..., highlighted)), id: \.0) { number, text in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(number)).foregroundStyle(theme.muted).frame(width: 50, alignment: .trailing)
                                    Text(text).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 3).padding(.horizontal, 8)
                                    .background(number == link.line ? theme.blue.opacity(0.15) : .clear)
                            }
                        }.font(theme.typography.codeDetail)
                    }.onAppear { if let line = link.line { proxy.scrollTo(line, anchor: .center) } }
                }
            } else if let failure {
                Text(failure).foregroundStyle(theme.muted).textSelection(.enabled)
                Spacer()
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(18).frame(width: 820, height: 560)
            .background(theme.terminal).foregroundStyle(theme.ink).tint(theme.blue)
            .task(id: link.id) {
                source = nil; failure = nil
                let document = ToolDocument(path: link.path, diff: "")
                do {
                    let text: String
                    if let sshSource {
                        guard TerminalRuntime.shared.ssh.grant(sshSource.id)?.selectedFeatures.contains(.files) == true else {
                            failure = "File access is disabled for this host."; return
                        }
                        text = try await sshSource.source(document, "/")
                    } else {
                        text = try await document.source(in: "/")
                    }
                    guard !Task.isCancelled else { return }
                    source = text
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
    }
}
