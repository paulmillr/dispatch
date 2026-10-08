import SwiftUI

/// A snapshot of reported activity; historical reasoning never becomes live
/// merely because a new request is waiting for the agent to acknowledge it.
@MainActor
struct AgentWorkingState: Equatable {
    var visible: Bool
    var waiting: Bool
    let loading: Bool
    var fragment: String
    let started: Date?
    private let usesLocalClock: Bool
    var label: String
    var finishedAt: Date?
    struct Detail: Identifiable, Equatable {
        let id: String
        let title: String
        let text: String
    }
    let details: [Detail]

    init(_ session: ChatSession) {
        // Discovering the first rollout can start a history read after Submit.
        // Keep that submitted turn visible while its acknowledgement is loading.
        loading = session.loadingHistory && !session.awaitingPromptAck
        visible = loading || (session.active && session.busy)
        waiting = !loading && (session.approvals.contains(where: \.pending) || session.waitingForAnswer
            || (session.questions.isEmpty && session.nativePrompt != nil))
        let turn: ChatTurn?
        if let id = session.activeTurnID { turn = session.turns.last { $0.id == id } }
        else { turn = session.turns.last }
        let current = turn != nil && turn?.ended == nil && !session.awaitingPromptAck
        // A record without a time starts its turn at the epoch: unknown, so count from appearance.
        let reported = turn.flatMap { current && $0.started.timeIntervalSince1970 > 0 ? $0.started : nil }
        started = loading ? nil : (session.submittedThinkingAt ?? reported)
        usesLocalClock = started == nil || session.submittedThinkingAt != nil
        let items = visible && current && !loading ? (turn?.items ?? []) : []
        details = items.lazy.filter { $0.kind == .tool }.suffix(3).map { item in
            Detail(id: item.id, title: item.completed ? "Completed tool" : "Tool activity",
                   text: Self.toolDescription(item).text)
        }
        if loading {
            label = "Loading conversation…"; fragment = ""
        } else if waiting {
            let question = session.waitingForAnswer || session.nativePrompt != nil || session.approvals.contains { $0.pending && $0.questions != nil }
            label = question ? "Waiting for your answer…" : "Waiting for your approval…"; fragment = ""
        } else if items.last?.kind == .reasoning {
            label = "thinking"; fragment = ""
        } else if let tool = items.last(where: { $0.kind == .tool && !$0.completed }) {
            let activity = Self.toolDescription(tool)
            label = activity.label; fragment = Self.preview(activity.text)
        } else {
            label = "thinking"; fragment = ""
        }
    }

    func finished(at date: Date, label: String, receivedAt: Date = .now) -> Self {
        var value = self
        value.visible = false; value.waiting = false
        value.label = label
        // A local start must also finish on the local clock, as must an end without a time.
        value.finishedAt = usesLocalClock || date.timeIntervalSince1970 <= 0 ? receivedAt : date
        return value
    }

    private static func preview(_ text: String) -> String {
        String(text.prefix(180)).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func toolDescription(_ item: ChatItem) -> (label: String, text: String) {
        // Status updates must not format full tool outputs or parse huge payloads.
        let value = item.text.utf8.count <= 32_768 ? ToolPresentation.json(item.text) : nil
        let object = value as? [String: Any]
        let command = ToolPresentation.command(object?["cmd"] ?? object?["command"] ?? value)
        let name = item.title.components(separatedBy: ".").last?.lowercased() ?? ""
        let rawShell = ["shell", "bash", "exec_command", "shell_command"].contains(name) && object == nil
        if let command = command ?? (rawShell ? item.text : nil) {
            let directory = object?["workdir"] as? String ?? object?["cwd"] as? String ?? item.directory
            let shown = String((ToolCommandWords.droppingRedundantCd(command, directory: directory) ?? command).prefix(8_192))
            let executable = String(shown.drop(while: { $0.isWhitespace }).prefix(while: { !$0.isWhitespace }))
            let base = (executable as NSString).lastPathComponent
            let label = ["rg", "grep", "find"].contains(base) ? "searching"
                : (["cat", "head", "tail", "sed"].contains(base) ? "reading" : "running")
            return (label, shown)
        }
        let target = object?["file_path"] as? String ?? object?["path"] as? String
            ?? object?["query"] as? String ?? object?["description"] as? String
        let label = ["read", "read_file"].contains(name) ? "reading" : (["search", "web_search"].contains(name) ? "searching" : "working")
        return (label, String((target ?? (item.title.isEmpty ? "Tool activity" : item.title)).prefix(8_192)))
    }
}

struct AgentWorkingIndicator: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    var canStop = false
    var stop: () -> Void = {}
    @State private var retained: AgentWorkingState?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = AgentWorkingState(session)
        Group {
            if current.loading {
                AgentWorkingAnimation(session: session, reduceMotion: reduceMotion, presentation: current)
            } else if let state = current.visible ? current : retained {
                VStack(alignment: .leading, spacing: 6) {
                    Button { expanded.toggle() } label: {
                        AgentWorkingAnimation(session: session, reduceMotion: reduceMotion, presentation: state)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(state.label). Activity controls")
                        .accessibilityIdentifier("chat-activity-details").help("Show activity controls")
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                        .disabled(!state.visible)
                    if expanded && state.visible {
                        VStack(alignment: .leading, spacing: 10) {
                            ChatSessionStats(session: session)
                            Button(action: stop) {
                                Label(session.interruptionID == nil ? "Stop thinking" : "Stopping…", systemImage: "stop.fill")
                            }
                            .disabled(!canStop || session.interruptionID != nil)
                            .accessibilityIdentifier("chat-activity-stop")
                        }.font(theme.typography.detail).padding(.bottom, 8)
                    }
                }
            }
        }
        .onAppear { update(current) }
        .onChange(of: current) { _, value in update(value) }
        .onChange(of: session.activeTurnID) { _, _ in expanded = false }
        .onChange(of: session.sessionID) { _, _ in retained = nil; expanded = false; update(current) }
    }

    private func update(_ state: AgentWorkingState) {
        // History reads are transient and must not leave a finished activity row.
        guard !state.loading else { expanded = false; return }
        if state.visible { retained = state }
        else if let previous = retained, previous.finishedAt == nil {
            expanded = false
            let turn = session.turns.last { $0.id == session.activeTurnID }
            let label = !session.active ? "Disconnected" : (turn?.ended != nil ? "Finished" : "Stopped")
            retained = previous.finished(at: turn?.ended ?? .now, label: label)
        }
    }
}

/// The timeline invalidates only this small indicator, never transcript rows.
struct AgentWorkingAnimation: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    let reduceMotion: Bool
    var presentation: AgentWorkingState? = nil
    @State private var visible = false
    @State private var appeared = Date()
    @State private var finishedClock = Date()

    static func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    /// With Reduce Motion a running clock counts the first 10 seconds, then steps every 5 (10s, 15s, 20s…), so it
    /// changes less often; a finished turn keeps its exact duration.
    static func timeText(_ state: AgentWorkingState, now: Date, appeared: Date, timeZone: TimeZone = .current,
                         reduceMotion: Bool = false) -> String {
        if state.label == "Finished", let finished = state.finishedAt, now.timeIntervalSince(finished) >= 300 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mma"
            return formatter.string(from: finished).lowercased()
        }
        let elapsed = (state.finishedAt ?? now).timeIntervalSince(state.started ?? appeared)
        guard reduceMotion, state.finishedAt == nil, elapsed >= 10 else { return elapsedText(elapsed) }
        return elapsedText((elapsed / 5).rounded(.down) * 5)
    }

    var body: some View {
        let state = presentation ?? AgentWorkingState(session)
        // A summary can arrive late or not at all. The activity indicator must
        // still animate throughout an acknowledged/submitted active turn.
        let thinking = state.visible && !state.waiting
        #if DISPATCH_BENCHMARK
        let benchmarkPaused = HostScalingAnimationProbe.paused
        #else
        let benchmarkPaused = false
        #endif
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil,
                                paused: !visible || !session.showChat || state.waiting || !state.visible || benchmarkPaused)) { timeline in
            #if DISPATCH_BENCHMARK
            let _ = HostScalingAnimationProbe.tick?(session.id)
            #endif
            let date = state.visible ? timeline.date : finishedClock
            let seconds = date.timeIntervalSinceReferenceDate
            let moving = !reduceMotion && !state.waiting && state.visible && !benchmarkPaused
            let pulse = (1 - cos(seconds * 2 * .pi / 1.6)) / 2
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ZStack {
                        Text("◆").foregroundStyle(theme.accent)
                            .opacity(moving ? 0.55 + 0.45 * pulse : 1)
                            .scaleEffect(moving ? 0.92 + 0.16 * pulse : 1)
                        if moving {
                            Circle().fill(theme.accent).frame(width: 3, height: 3)
                                .shadow(color: theme.accent.opacity(0.7), radius: 3)
                                .offset(y: -8)
                                .rotationEffect(.degrees(seconds.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
                        }
                    }.frame(width: 18, height: 20).accessibilityHidden(true)
                    Text(state.label)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.muted).fixedSize()
                        .opacity(moving ? 0.65 + 0.35 * pulse : 1)
                        .overlay {
                            if thinking && moving {
                                GeometryReader { geometry in
                                    LinearGradient(colors: [.clear, theme.ink, .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: 35)
                                        .offset(x: (geometry.size.width + 35) * seconds.truncatingRemainder(dividingBy: 2.4) / 2.4 - 35)
                                }.mask(Text(state.label).fontWeight(.medium))
                            }
                        }
                    if !state.waiting && !state.loading {
                        Text("· \(Self.timeText(state, now: date, appeared: appeared, reduceMotion: reduceMotion))")
                            .monospacedDigit().foregroundStyle(theme.muted).fixedSize()
                    }
                    if !state.fragment.isEmpty {
                        Text("·").foregroundStyle(theme.muted.opacity(0.55))
                        HStack(spacing: 2) {
                            Text(state.fragment)
                                .italic().lineLimit(1)
                        }
                        .foregroundStyle(theme.muted.opacity(0.85))
                        .accessibilityElement(children: .ignore).accessibilityLabel(state.fragment)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 20)
                if thinking {
                    GeometryReader { geometry in
                        Rectangle().fill(theme.border)
                        if moving {
                            let phase = seconds.truncatingRemainder(dividingBy: 2.2) / 2.2
                            let progress = (1 - cos(phase * .pi)) / 2
                            LinearGradient(colors: [.clear, theme.accent.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.3)
                                .offset(x: geometry.size.width * (progress * 1.3 - 0.3))
                        }
                    }.frame(height: 1).clipped().accessibilityHidden(true)
                } else {
                    Color.clear.frame(height: 1).accessibilityHidden(true)
                }
            }
        }.font(theme.typography.detail).padding(.vertical, 8)
            .accessibilityElement(children: .combine).accessibilityIdentifier("chat-working")
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: state.label == "Finished" ? state.finishedAt : nil) {
                finishedClock = .now
                guard state.label == "Finished", let finished = state.finishedAt else { return }
                let delay = finished.addingTimeInterval(300).timeIntervalSinceNow
                guard delay > 0 else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                finishedClock = .now
            }
            .onChange(of: state.visible) { _, running in if running { appeared = .now } }
            .onChange(of: session.activeTurnID) { _, _ in appeared = .now }
            .onChange(of: session.awaitingPromptAck) { _, waiting in if waiting { appeared = .now } }
    }
}

#if DISPATCH_BENCHMARK
/// Opt-in instrumentation, absent from ordinary app builds. Counts timeline
/// evaluations rather than claiming physical display frames.
@MainActor
enum HostScalingAnimationProbe {
    static var tick: ((UUID) -> Void)?
    static var paused = false
}
#endif
