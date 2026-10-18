import SwiftUI

/// A non-modal notice at the foot of Spaces: what the phone could not save (`SpacesHostActions.saveFailure`, with
/// Retry) and trusted host keys it cannot read (`knownHostsUnreadable`, with Retry and Reset). Not in the mockup; in
/// the app's grammar (a glass card, the app tint for actions). Shown until the cause is gone.
struct SpacesNotice: View {
    struct Action: Identifiable {
        let title: String
        var destructive = false
        /// Asked first (title, message) for an action that forgets something.
        var confirmation: (title: String, message: String)? = nil
        let run: () -> Void
        var id: String { title }
    }

    let message: String
    let actions: [Action]
    @State private var confirming: Action?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(actions) { action in
                Button(action.title) {
                    if action.confirmation != nil { confirming = action } else { action.run() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(action.destructive ? Color.red : Color.dispatchPink)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .confirmationDialog(confirming?.confirmation?.title ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible, presenting: confirming) { action in
            Button(action.title, role: action.destructive ? .destructive : nil) { action.run() }
        } message: { action in
            Text(action.confirmation?.message ?? "")
        }
    }
}

extension SpacesNotice {
    /// The notices Spaces shows for `actions`, most important first (none: everything is saved and readable).
    @MainActor static func notices(_ actions: SpacesHostActions) -> [SpacesNotice] {
        var notices: [SpacesNotice] = []
        if actions.knownHostsUnreadable {
            notices.append(SpacesNotice(message: KnownHostStore.unreadableNotice, actions: [
                Action(title: "Retry", run: actions.retryKnownHosts),
                Action(title: "Reset", destructive: true,
                       confirmation: ("Reset trusted host keys?", "Every host asks about its key again at its next connection. The unreadable file stays on this iPhone until Remove all data."),
                       run: actions.resetKnownHosts),
            ]))
        }
        if let failure = actions.saveFailure {
            notices.append(SpacesNotice(message: failure, actions: [Action(title: "Retry", run: actions.retrySave)]))
        }
        return notices
    }
}
