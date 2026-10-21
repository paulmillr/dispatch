import Dictation
import SwiftUI

/// The composer's dictation control, beside Send: a microphone that listens until clicked again, then puts what it
/// heard at the draft's caret. While it listens it shows the level and what Apple's engine has heard so far; a failure
/// shows why until clicked.
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
        case .listening: dictation.partial.isEmpty ? "Listening…" : dictation.partial
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
        if active { return dictation.phase == .listening ? "Stop and insert" : "Cancel dictation" }
        let preferences = TerminalRuntime.shared.preferences
        let engine = preferences.dictationEngine == .whisper ? "Whisper \(preferences.whisperModel.title)" : "Apple"
        return "Dictate · \(engine)"
    }

    private func toggle() {
        let preferences = TerminalRuntime.shared.preferences
        dictation.toggle(owner: session.id, engine: preferences.dictationEngine, model: preferences.whisperModel) { [session] text in
            let draft = session.drafts.current
            let next = DictationText.insert(text, into: draft.text, selection: draft.selection)
            session.drafts.edit(text: next.text, selection: next.selection)
            session.focusRequest = System.uuid()
        }
    }
}
