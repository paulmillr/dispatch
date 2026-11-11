import SwiftUI

/// One usage window of `chat.limits`, as the agent reports it.
struct ChatLimitWindow: Decodable, Equatable, Sendable {
    let name: String
    let used: Int
    let resets_at: TimeInterval

    /// "5-hour", "Weekly"; another length (`window_<minutes>`, Codex) in the largest whole unit.
    var title: String {
        if name == "five_hour" { return "5-hour" }
        if name == "seven_day" { return "Weekly" }
        guard name.hasPrefix("window_"), let minutes = Int(name.dropFirst("window_".count)), minutes > 0 else { return name }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
    var resets: Date { Date(timeIntervalSince1970: resets_at) }

    /// "resets in 2h 18m" within a day, then "resets Thu 9:40am".
    func resetText(now: Date, timeZone: TimeZone = .current) -> String {
        let left = resets.timeIntervalSince(now)
        if left < 24 * 3600 { return "resets in " + ChatTranscript.elapsed(max(0, left)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.amSymbol = "am"; formatter.pmSymbol = "pm"
        formatter.dateFormat = "EEE h:mma"
        return "resets " + formatter.string(from: resets)
    }
}

extension HelperChat {
    func limits() async throws -> [ChatLimitWindow] { try await call("chat.limits", input: Input(route)) }
}

/// One row a limits extension reports (`chat.limits.rows`); without `used`, nothing to measure against, so no bar.
struct ChatLimitRow: Decodable, Equatable, Sendable {
    let label: String
    let detail: String
    let value: String
    let used: Int?
}

/// `chat.limits.rows`: the extension reporting limits for this session, if any, and its rows.
struct ChatLimitRows: Decodable, Equatable, Sendable {
    let source: String?
    let rows: [ChatLimitRow]
}

extension HelperChat {
    /// `read` nil only names the extension, which contacts nobody; its name reads it.
    func limitRows(read: String?) async throws -> ChatLimitRows {
        var input = Input(route)
        input.read = read
        return try await call("chat.limits.rows", input: input)
    }
}

/// What the popover says about one agent's limits.
struct ChatLimitsWording: Equatable {
    let agent: String
    let title: String
    let plan: String
    let explanation: String
    let none: String

    /// A Pi extension the user installed.
    static func `extension`(_ name: String) -> Self {
        Self(agent: name, title: "Show limits from \(name)?", plan: "From \(name)",
             explanation: "This Pi extension, which you installed, contacts its provider when you open this popover, at most once a minute. Dispatch only shows what it reports.",
             none: "\(name) reported no limits.")
    }

    static func of(_ agentID: String) -> Self? {
        switch agentID {
        case "claude":
            Self(agent: "Claude Code", title: "Show Claude Code limits here?", plan: "Your Claude plan",
                 explanation: "Dispatch asks Claude Code only when you open this popover, at most once a minute. It sets Claude Code's status line for a moment, then puts it back.",
                 none: "No limits to show. Claude Code reports them for Pro, Max and Ultra plans, after a session's first reply.")
        case "codex":
            Self(agent: "Codex", title: "Show Codex limits here?", plan: "Your ChatGPT plan",
                 explanation: "Dispatch asks Codex only when you open this popover, at most once a minute. Codex then asks OpenAI for your plan's usage.",
                 none: "No limits to show. Codex reports them when you sign in with ChatGPT.")
        default: nil
        }
    }
}

/// The agents' plan limits for the activity popover. Nothing is asked before the user agrees for that agent, and then
/// only as a popover opens, at most once a minute per helper and agent; readings stay in memory (docs/security.md,
/// Agent chat).
@MainActor @Observable
final class ChatLimitsStore {
    enum Reading: Equatable, Sendable {
        case windows([ChatLimitWindow])
        case rows([ChatLimitRow])
    }

    enum Phase: Equatable {
        case reading
        case shown(Reading, at: Date)
        case failed
    }

    /// A helper's agent: the account a reading belongs to, as far as the app can tell.
    struct Key: Hashable {
        let endpoint: AnyHashable
        let agent: String
    }

    static let shared = ChatLimitsStore()
    /// How long a reading answers for itself.
    static let reuse: TimeInterval = 60
    private static func consentKey(_ agent: String) -> String { "chatLimitsConsent." + agent }

    private(set) var phases: [Key: Phase] = [:]
    private var consents: Set<String> = []
    /// Not Now: until the app next starts.
    private var declines: Set<String> = []
    /// The Pi extension reporting limits for a chat, as last asked.
    private(set) var sources: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let clock: () -> Date

    init(defaults: UserDefaults? = .app, clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    var now: Date { clock() }
    func consented(_ agent: String) -> Bool { consents.contains(agent) || defaults?.bool(forKey: Self.consentKey(agent)) == true }
    func declined(_ agent: String) -> Bool { declines.contains(agent) }

    /// A Pi chat's popover opened: which extension, if any, reports its provider's limits. Contacts nobody.
    func describe(_ session: ChatSession) async {
        guard session.agentID == "pi", HelperSession.features.contains(HelperSession.chatLimitRows),
              let helper = session.helper else { return }
        let answer = try? await helper.limitRows(read: nil)
        sources[ObjectIdentifier(session)] = answer?.source
    }

    func accept(_ agent: String) {
        consents.insert(agent)
        defaults?.set(true, forKey: Self.consentKey(agent))
    }

    func decline(_ agent: String) { declines.insert(agent) }

    /// A popover opened: reads unless one is under way or the last answered within the minute. A failure is not kept.
    func open(_ key: Key, read: @escaping @MainActor () async throws -> Reading) {
        guard consented(key.agent) else { return }
        switch phases[key] {
        case .reading: return
        case .shown(_, let at) where clock().timeIntervalSince(at) < Self.reuse: return
        default: break
        }
        phases[key] = .reading
        Task { @MainActor in
            do {
                let reading = try await read()
                phases[key] = .shown(reading, at: clock())
            } catch {
                phases[key] = .failed
            }
        }
    }
}

/// The popover's limits, under a rule; a chat of an agent that reports them, unless the user said Not Now.
struct ChatLimitsSection: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    var store = ChatLimitsStore.shared

    /// Whose limits these are: the agent's own, or for Pi the extension reporting them. Consent and the minute go by it.
    private var subject: (id: String, source: String?, wording: ChatLimitsWording)? {
        if session.agentID == "pi" {
            return store.sources[ObjectIdentifier(session)].map { ("pi:" + $0, $0, .extension($0)) }
        }
        return ChatLimitsWording.of(session.agentID).map { (session.agentID, nil, $0) }
    }

    var body: some View {
        if let subject, let helper = session.helper, !store.declined(subject.id) {
            Rectangle().fill(theme.ink.opacity(0.09)).frame(height: 1)
            content(helper, subject.id, subject.source, subject.wording)
                .onAppear { open(helper, subject.id, subject.source) }.accessibilityIdentifier("chat-limits")
        }
    }

    private func key(_ helper: HelperChat, _ id: String) -> ChatLimitsStore.Key {
        .init(endpoint: AnyHashable(helper.endpoint), agent: id)
    }

    private func open(_ helper: HelperChat, _ id: String, _ source: String?) {
        store.open(key(helper, id)) {
            if let source { return .rows(try await helper.limitRows(read: source).rows) }
            return .windows(try await helper.limits())
        }
    }

    @ViewBuilder private func content(_ helper: HelperChat, _ id: String, _ source: String?, _ wording: ChatLimitsWording) -> some View {
        if !store.consented(id) {
            VStack(alignment: .leading, spacing: 10) {
                Text(wording.title).foregroundStyle(theme.ink)
                Text(wording.explanation).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Not Now") { store.decline(id) }.controlSize(.small).accessibilityIdentifier("chat-limits-decline")
                    Button("Show Limits") { store.accept(id); open(helper, id, source) }.controlSize(.small).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("chat-limits-accept")
                }
            }
        } else {
            switch store.phases[key(helper, id)] {
            case .shown(.windows(let windows), let at):
                shown(windows.filter { $0.resets > store.now }, at: at, wording)
            case .shown(.rows(let rows), let at):
                extensionRows(rows, at: at, wording)
            case .failed:
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Couldn't read limits.").foregroundStyle(theme.ink)
                    Spacer(minLength: 0)
                    Button("Try Again") { open(helper, id, source) }.controlSize(.small).accessibilityIdentifier("chat-limits-retry")
                }
            case .reading, nil:
                HStack(spacing: 6) {
                    ChatComposerOrbit(moving: false)
                    Text("Asking \(wording.agent)…")
                }
            }
        }
    }

    @ViewBuilder private func shown(_ windows: [ChatLimitWindow], at: Date, _ wording: ChatLimitsWording) -> some View {
        if windows.isEmpty {
            Text(wording.none).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) { ForEach(windows, id: \.name) { row($0) } }
                Text(wording.plan + " · " + Self.age(store.now.timeIntervalSince(at)))
                    .foregroundStyle(theme.muted.opacity(0.75))
            }
        }
    }

    @ViewBuilder private func extensionRows(_ rows: [ChatLimitRow], at: Date, _ wording: ChatLimitsWording) -> some View {
        if rows.isEmpty {
            Text(wording.none).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) { ForEach(Array(rows.enumerated()), id: \.offset) { extensionRow($0.element) } }
                Text(wording.plan + " · " + Self.age(store.now.timeIntervalSince(at)))
                    .foregroundStyle(theme.muted.opacity(0.75))
            }
        }
    }

    private func extensionRow(_ row: ChatLimitRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: row.label).foregroundStyle(theme.ink)
                if !row.detail.isEmpty { Text(verbatim: row.detail) }
                Spacer(minLength: 8)
                Text(verbatim: row.value).monospacedDigit().foregroundStyle((row.used ?? 0) >= 80 ? tone(row.used ?? 0) : theme.ink)
            }
            if let used = row.used {
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.border)
                        Capsule().fill(tone(used)).frame(width: box.size.width * min(1, CGFloat(used) / 100))
                    }
                }.frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.label, row.detail, row.value].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func row(_ window: ChatLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(window.title).foregroundStyle(theme.ink)
                Text(window.resetText(now: store.now))
                Spacer(minLength: 8)
                Text("\(window.used)%").monospacedDigit().foregroundStyle(window.used >= 80 ? tone(window.used) : theme.ink)
            }
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.border)
                    Capsule().fill(tone(window.used)).frame(width: box.size.width * min(1, CGFloat(window.used) / 100))
                }
            }.frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title) limit, \(window.used) percent used, \(window.resetText(now: store.now))")
    }

    private func tone(_ used: Int) -> Color {
        used >= 95 ? theme.red : used >= 80 ? theme.yellow : theme.ink.opacity(0.62)
    }

    /// "read just now", then "read 40s ago".
    static func age(_ seconds: TimeInterval) -> String {
        seconds < 5 ? "read just now" : "read \(Int(seconds))s ago"
    }
}
