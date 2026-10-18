import Foundation
import SwiftUI

/// Inline Markdown from a remote agent. Formatting is preserved, but only credential-free HTTP(S) links remain
/// active; the environment check is a second boundary in case attributed content reaches the view another way.
enum MobileChatMarkdown {
    static func text(_ text: String) -> AttributedString {
        var value = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link, !isWebLink(url) else { return nil }
            return run.range
        }
        for range in unsafe { value[range].link = nil }
        return value
    }

    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
            && url.user == nil && url.password == nil
    }

    static var openURL: OpenURLAction {
        OpenURLAction { isWebLink($0) ? .systemAction : .discarded }
    }
}
