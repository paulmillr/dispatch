import Dictation
import SwiftUI

/// Over the top of the window: what "Dispatch, …" heard while it listens for commands alone, then where a command went
/// (or why it went nowhere) for a moment. Click to dismiss.
struct VoiceNavigationNote: View {
    @Environment(\.appTypography) private var typography
    private var navigation: VoiceNavigation { .shared }
    private var dictation: Dictation { .shared }

    var body: some View {
        if let content {
            Button {
                if navigation.listening { return dictation.cancel() }
                navigation.dismiss()
                if dictation.error(for: VoiceNavigation.owner) != nil { dictation.dismissError() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: content.symbol).foregroundStyle(content.failed ? Chrome.accent : Chrome.palette.secondary)
                    Text(content.text).lineLimit(1).truncationMode(.head)
                }
                .font(typography.font(offset: -1)).foregroundStyle(Chrome.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .liquidGlass(in: Capsule(), fallback: Chrome.sidebar, interactive: true)
                .frame(maxWidth: 520)
            }
            .buttonStyle(.plain)
            .help(navigation.listening ? "Cancel" : "Dismiss")
            .padding(.top, 10)
            .transition(.opacity)
            .accessibilityIdentifier("voice-navigation-note")
        }
    }

    private var content: (text: String, symbol: String, failed: Bool)? {
        if let command = ChatDictation.shared.command { return (command, "mic.fill", false) }
        if navigation.listening {
            switch dictation.phase {
            case .transcribing: return ("…", "waveform", false)
            default: return (dictation.partial.isEmpty ? "Listening · “Dispatch, …”" : dictation.partial, "mic.fill", false)
            }
        }
        if let error = dictation.error(for: VoiceNavigation.owner) { return (error, "exclamationmark.triangle.fill", true) }
        return navigation.note.map { ($0.text, $0.failed ? "questionmark.circle" : "arrow.right", $0.failed) }
    }
}
