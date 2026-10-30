import Dictation
import SwiftUI

/// Settings › Features › Dictation and Keyboard › Voice in effect, for the composers and the voice key; TerminalRuntime
/// applies it.
@MainActor @Observable
final class DictationStore {
    static let shared = DictationStore()
    var enabled = true
    var key = VoiceKey.rightCommand
    /// The voice key while dictation is on and a key is chosen, for the shortcut and its hints.
    var shortcut: VoiceKey? { enabled && key != .off ? key : nil }
    var navigation = true
    var readReplies = true
    var wakeWords = VoiceCommand.defaultWakeWords
    /// How commands are said, for hints: "Dispatch".
    var wakeWord: String { WakeWordsSetting.title(wakeWords.first ?? "dispatch") }
}

/// The composer's dictation control, beside Send: a microphone that listens until clicked again (ChatDictation: what
/// it hears shows in the draft as it comes). While it listens it shows the level and how to finish; a failure shows
/// why until clicked.
struct ChatDictationButton: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    private var dictation: Dictation { .shared }

    var body: some View {
        let active = dictation.active(session.id)
        HStack(spacing: 6) {
            if active || dictation.error(for: session.id) != nil { status(active: active) }
            Button(action: toggle) { glyph(active: active) }
                .buttonStyle(.plain)
                .help(help(active: active))
                .accessibilityLabel(active ? "Stop dictation" : "Dictate")
                .accessibilityIdentifier("chat-dictate")
        }
    }

    @ViewBuilder private func status(active: Bool) -> some View {
        if let error = dictation.error(for: session.id), !active {
            Button { dictation.dismissError() } label: {
                Label(error, systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                    .foregroundStyle(theme.red)
            }.buttonStyle(.plain).help("Dismiss")
                .font(theme.typography.detail).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .trailing)
                .accessibilityIdentifier("chat-dictation-error")
        } else {
            Text(statusText).font(theme.typography.detail).foregroundStyle(theme.muted)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: 260, alignment: .trailing)
                .accessibilityIdentifier("chat-dictation-status")
        }
    }

    private var statusText: String {
        switch dictation.phase {
        case .idle: ""
        case .starting: "Starting…"
        case .listening: ChatDictation.shared.conversation
            ? "Conversation · “\(DictationStore.shared.wakeWord), send” · " + (DictationStore.shared.shortcut.map { "tap \($0.name) to stop" } ?? "click to stop")
            : "Listening · ↩ sends · esc cancels"
        case .transcribing: "Transcribing…"
        }
    }

    private func glyph(active: Bool) -> some View {
        let size = max(24, theme.typography.detailLineHeight + 10)
        return ZStack {
            if active && dictation.phase == .listening {
                Circle().fill(theme.red.opacity(0.18))
                    .scaleEffect(0.7 + 0.5 * CGFloat(dictation.level))
                    .animation(.easeOut(duration: 0.12), value: dictation.level)
            }
            if active && dictation.phase != .listening {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: active ? "mic.fill" : "mic")
                    .font(.system(size: theme.typography.detailSize + 1, weight: .medium))
                    .foregroundStyle(active ? theme.red : theme.muted)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }

    private func help(active: Bool) -> String {
        if active {
            if ChatDictation.shared.conversation { return "End conversation mode" }
            return dictation.phase == .listening ? "Stop and insert" : "Cancel dictation"
        }
        let preferences = TerminalRuntime.shared.preferences
        let engine = preferences.dictationEngine.label(whisper: preferences.whisperModel)
        return "Conversation mode · \(engine)" + (DictationStore.shared.shortcut.map { " · or tap \($0.name); hold it for one message" } ?? "")
    }

    private func toggle() {
        if dictation.active(session.id), dictation.phase != .listening { return ChatDictation.shared.cancel() }
        ChatDictation.shared.toggle(session)
    }
}
