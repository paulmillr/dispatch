import SwiftUI

/// Reply (Y1, as Messages and Slack reply): a message's long press or details' Reply puts "Replying to Claude" and the
/// message's first words over the composer (`ChatReplyBar`), which stays the user's; the send puts that excerpt before
/// the draft as one Markdown quote line. The agent has the whole message already: the excerpt only points at it. The
/// sent bubble shows a leading quote as a small card on top (`ChatUserMessage`), from the text itself, so a reply
/// read back from the transcript shows the same.
enum ChatReplyQuote {
    /// The excerpt's most characters, "…" included.
    static let limit = 140

    /// The words a reply quotes: the message's first sentence of its first line of prose (a code fence's lines, list
    /// and heading marks, emphasis and code marks dropped), whitespace collapsed, cut at a word before `limit`.
    static func excerpt(_ text: String) -> String {
        var fenced = false
        var line = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { fenced.toggle(); continue }
            if fenced || trimmed.isEmpty { continue }
            line = trimmed
            break
        }
        if line.isEmpty { line = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let end = line.range(of: #"[.!?](?=\s)"#, options: .regularExpression) {
            line = String(line[..<end.upperBound])
        }
        guard line.count > limit else { return line }
        let cut = line.prefix(limit - 1)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    /// The agent as a reply names it: its label with a capital ("claude" reads "Claude").
    static func name(_ agent: String) -> String { agent.prefix(1).uppercased() + agent.dropFirst() }

    /// What a reply sends: the excerpt as one quote line, a blank line, then the draft.
    static func compose(quote: String, text: String) -> String { "> " + quote + "\n\n" + text }

    /// A message that starts with a quote (its "> " lines, a blank line, then more): the quote's words and the rest.
    /// Nil for any other message, a quote alone included.
    static func split(_ text: String) -> (quote: String, body: String)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let quoted = lines.prefix { $0.hasPrefix(">") }
        guard !quoted.isEmpty, quoted.count < lines.count, lines[quoted.count].trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let body = lines[(quoted.count + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let quote = quoted.map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return (quote, body)
    }
}

/// Over the composer while replying (Y1a): the accent's bar, who is answered, the excerpt on one line, and ✕.
struct ChatReplyBar: View {
    let agent: String
    let excerpt: String
    let cancel: () -> Void
    @Environment(\.chatPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(palette.accent).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(ChatReplyQuote.name(agent))").font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                Text(excerpt).font(.footnote).foregroundStyle(palette.muted).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(palette.muted)
                    .frame(width: 26, height: 26).background(Color.chipFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
            .accessibilityIdentifier("chat-reply-cancel")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .chatSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-reply-bar")
    }
}

/// The quote at the top of a sent reply's bubble (Y1b): a bar, who was answered, the excerpt on two lines at most, on
/// a faint fill of the bubble's own text colour.
struct ChatReplyQuoteCard: View {
    let quote: String
    var author: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(.foreground.opacity(0.55)).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 1) {
                if let author { Text(ChatReplyQuote.name(author)).font(.caption.weight(.semibold)) }
                Text(quote).font(.footnote).lineLimit(2)
            }
            .opacity(0.8)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.foreground.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(author.map(ChatReplyQuote.name) ?? "a message"): \(quote)")
    }
}
