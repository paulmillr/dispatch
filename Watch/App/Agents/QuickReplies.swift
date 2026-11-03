import SwiftUI

/// Reply's first step (docs/watch.md, Composer and queue): "Dictate or type" (the system's text input) first, then the
/// quick replies as chips. Either leads to the confirm screen (K5) with the words; nothing is sent from here. watchOS
/// has no suggestions on `TextFieldLink`, so the chips are this sheet's own.
enum QuickReplies {
    /// The fixed list (a user-editable one may follow).
    static let all = ["Continue", "Yes, do it", "Run the tests", "Commit it"]
}

struct QuickReplySheet: View {
    /// What the input asks for ("Queue a message…").
    let prompt: String
    /// The words chosen or dictated: the thread opens the confirm screen with them once this sheet is gone.
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QuickReplyList(prompt: prompt) { text in
                choose(text)
                dismiss()
            }
            .navigationTitle("Reply")
        }
    }
}

/// The sheet's rows, without its stack (the tests draw them as a stack).
struct QuickReplyList: View {
    let prompt: String
    let choose: (String) -> Void

    var body: some View {
        List {
            TextFieldLink(prompt: Text(prompt)) {
                CapsuleLabel(title: "Dictate or type", symbol: "mic.fill", style: .accent)
            } onSubmit: { text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { choose(text) }
            }
            .buttonStyle(.plain)
            .modifier(BareRow(vertical: 4))
            .accessibilityLabel("Dictate or type")
            .accessibilityHint("Your own words, then where they go")
            ForEach(QuickReplies.all, id: \.self) { text in
                CapsuleButton(title: text, hint: "Then where it goes") { choose(text) }
            }
        }
        .environment(\.defaultMinListRowHeight, 0)
    }
}
