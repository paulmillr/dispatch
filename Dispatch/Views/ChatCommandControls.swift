import SwiftUI

struct ChatCommandControls: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.command != nil {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Running command…") }
                    .font(theme.typography.detail).foregroundStyle(theme.muted)
            }
            if let question = session.questions.first {
                ChatSideQuestionForm(request: question, agent: session.agentTitle) { skip in coordinator.answerQuestion(question, skip: skip, session: session) }
                    .frame(height: 270)
            }
            if let result = session.commandResult {
                ChatCommandResultView(result: result) {
                    withAnimation(InterfaceMotion.animation(reduce: reduceMotion)) {
                        if session.commandResult == result { session.commandResult = nil }
                    }
                }
                .id(result)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
        }
    }
}

/// What a command printed. A one-line result is a small toast that leaves by itself after a few seconds (not while the
/// pointer rests on it); anything longer keeps a header, takes only the height its text needs up to a cap, and stays
/// until dismissed.
private struct ChatCommandResultView: View {
    @Environment(\.chatTheme) private var theme
    let result: ChatCommandResult
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var expired = false

    /// How long a toast stays.
    static let lifetime: Duration = .seconds(6)

    private var shellOutput: Bool { result.title.hasPrefix("!") }
    private var compact: Bool {
        !shellOutput && result.title != "Session status" && !result.text.contains("\n") && result.text.count <= 140
    }

    var body: some View {
        Group {
            if compact { toast } else { panel }
        }
        .font(theme.typography.detail)
        .onHover { inside in
            hovering = inside
            if !inside && expired { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-command-result")
    }

    private var toast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
            if !result.title.isEmpty { label }
            Text(result.text).foregroundStyle(theme.ink).lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            close.opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .liquidGlass(in: Capsule(), fallback: theme.sidebar)
        .overlay { if !LiquidGlassStore.shared.active { Capsule().strokeBorder(theme.border) } }
        .fixedSize(horizontal: false, vertical: true)
        .task {
            do { try await Task.sleep(for: Self.lifetime) } catch { return }
            expired = true
            if !hovering { dismiss() }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                label
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(theme.muted).help("Copy").accessibilityLabel("Copy command result")
                close
            }
            // The text's own height while it fits; a scroll view only past the cap.
            ViewThatFits(in: .vertical) {
                output
                ScrollView(shellOutput ? [.horizontal, .vertical] : .vertical) { output }
            }
            .frame(maxHeight: result.title == "Session status" ? 220 : 120, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).chatPanel()
    }

    private var output: some View {
        Text(result.text).foregroundStyle(theme.ink).textSelection(.enabled)
            .fixedSize(horizontal: shellOutput, vertical: true)
            .frame(maxWidth: shellOutput ? nil : .infinity, alignment: .leading)
            .font(shellOutput ? theme.typography.codeDetail : theme.typography.detail)
    }

    /// The command, as a small monospaced chip.
    private var label: some View {
        Text(result.title).font(theme.typography.codeDetail).foregroundStyle(theme.muted).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(theme.ink.opacity(0.06), in: Capsule())
    }

    private var close: some View {
        Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
            .buttonStyle(.plain).foregroundStyle(theme.muted).accessibilityLabel("Dismiss command result")
    }
}
