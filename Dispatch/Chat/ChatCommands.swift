import AppKit
import Observation

/// Only these exact forms have a chat workflow. Unrecognized commands retain
/// Codex's native UI; unsupported arguments to known commands never become prompts.
enum ChatCommand: Equatable {
    case fast, compact, rename(String), initialize, review(String), stop, copy, model
    case plan(String), goal(String), goalEdit(String), clear(String), status, shell(String)
    case fork, pwd, ps, mcp, recap, resume

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!"), !trimmed.hasPrefix("!!"), trimmed.count > 1 {
            self = .shell(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let argument = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch parts.first.map(String.init) {
        case "/fast" where argument.isEmpty: self = .fast
        case "/compact" where argument.isEmpty: self = .compact
        case "/rename": self = .rename(argument)
        case "/init" where argument.isEmpty: self = .initialize
        case "/review": self = .review(argument)
        case "/stop" where argument.isEmpty: self = .stop
        case "/copy" where argument.isEmpty: self = .copy
        case "/model" where argument.isEmpty: self = .model
        case "/plan": self = .plan(argument)
        case "/goal": self = .goal(argument)
        case "/clear": self = .clear(argument)
        // Codex 0.159 /new starts the same fresh thread as /clear.
        case "/new" where argument.isEmpty: self = .clear("")
        case "/fork" where argument.isEmpty: self = .fork
        case "/pwd" where argument.isEmpty: self = .pwd
        case "/ps" where argument.isEmpty: self = .ps
        case "/mcp" where argument.isEmpty: self = .mcp
        case "/recap" where argument.isEmpty: self = .recap
        case "/status" where argument.isEmpty: self = .status
        case "/resume" where argument.isEmpty: self = .resume
        default: return nil
        }
    }
    static let names = ["/fast", "/compact", "/rename", "/init", "/review", "/stop", "/copy", "/model", "/plan", "/goal", "/clear", "/new",
                        "/fork", "/status", "/pwd", "/ps", "/mcp", "/recap", "/resume"]
    var startsTurn: Bool {
        switch self { case .compact, .initialize, .review: true; case .plan(let prompt): !prompt.isEmpty; default: false }
    }
    /// The agent's own picker (Claude's and Codex's session list) takes its terminal: Chat
    /// switches to Terminal once the agent has the command, and follows whatever is picked there.
    var opensTerminal: Bool { self == .resume }
    var replacesConversation: Bool {
        switch self { case .clear, .fork: true; default: false }
    }
    /// Shown once Chat follows the conversation this command started.
    var replacementResult: ChatCommandResult? {
        switch self {
        // A fork's rollout refers to its parent instead of copying it.
        case .fork: .init(title: "Conversation forked", text: "Chat now follows the fork. Earlier messages stay in the original conversation.")
        case .clear: .init(title: "New conversation", text: "Ready for a new message.")
        default: nil
        }
    }
    var allowsBusy: Bool {
        switch self { case .copy, .status, .stop, .goal, .goalEdit: true; default: false }
    }
}

struct ChatAgentSettings: Sendable {
    var model: String
    var effort: String?
    var serviceTier: String?
    var mode: String?
    var directory: String?
    var permissions: String?
    init?(_ value: [String: Any]) {
        guard let model = value["model"] as? String else { return nil }
        self.model = model; effort = value["reasoning_effort"] as? String ?? value["effort"] as? String
        serviceTier = value["service_tier"] as? String
        mode = (value["collaboration_mode"] as? [String: Any])?["mode"] as? String
        directory = value["cwd"] as? String; permissions = value["approval_policy"] as? String
    }
}

struct ChatGoal: Sendable, Equatable {
    let objective: String
    let status: String
    let tokensUsed: Int
    let timeUsedSeconds: Int
    let tokenBudget: Int?
    var statusLabel: String {
        switch status {
        case "usageLimited": "usage limited"
        case "budgetLimited": "budget limited"
        default: status
        }
    }
    init?(_ value: [String: Any]) {
        guard let objective = value["objective"] as? String, let status = value["status"] as? String else { return nil }
        self.objective = objective; self.status = status
        tokensUsed = value["tokensUsed"] as? Int ?? 0; timeUsedSeconds = value["timeUsedSeconds"] as? Int ?? 0
        tokenBudget = value["tokenBudget"] as? Int
    }
    var summary: String {
        var text = "\(status.capitalized)\n\(objective)\n\nTokens used: \(tokensUsed) · Time used: \(timeUsedSeconds)s"
        if let tokenBudget { text += "\nToken budget: \(tokenBudget)" }
        return text
    }
}

struct ChatCommandResult: Equatable {
    var title: String
    var text: String
}

@MainActor @Observable
final class ChatCommandRequest {
    let id = UUID()
    /// The composer text the harness runs; `command` when the app knows its form (goal controls).
    let text: String
    let command: ChatCommand?
    var shellResult: ChatCommandResult?
    var shellSubmitted = false
    @ObservationIgnored var task: Task<Void, Never>?
    init(_ command: ChatCommand) { self.command = command; text = "" }
    init(text: String) { self.text = text; command = ChatCommand(text) }
    func cancel() { task?.cancel(); task = nil }
}

/// A bounded structural view of native questions. It never synthesizes an
/// approval or interprets assistant prose as a question/confirmation.
struct ChatNativePrompt: Equatable {
    struct Choice: Identifiable, Equatable {
        let number: Int
        let label: String
        var id: Int { number }
    }
    let title: String
    let choices: [Choice]
    let selected: Int
    let screen: String
    init?(_ screen: String) {
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard screen.utf8.count <= 65_536,
              let footer = lines.lastIndex(where: {
                  $0.contains("enter to submit answer") || AgentModelMenu.isFooter($0)
              }), lines.dropFirst(footer + 1).allSatisfy({ $0.isEmpty }) else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"^(›\s*)?(\d{1,3})\.\s+(.+)$"#)
        var choices: [Choice] = [], selected: Int?, first: Int?
        for index in (0..<footer).reversed() {
            let line = lines[index]
            if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let numberRange = Range(match.range(at: 2), in: line), let number = Int(line[numberRange]),
               let labelRange = Range(match.range(at: 3), in: line) {
                choices.insert(.init(number: number, label: String(line[labelRange])), at: 0)
                if match.range(at: 1).location != NSNotFound { selected = number }
                first = index
            } else if !choices.isEmpty, !line.isEmpty { break }
        }
        guard let selected, let first, !choices.isEmpty, choices.count <= 20,
              Set(choices.map(\.number)).count == choices.count else { return nil }
        // Only known planning/review/goal surfaces may own these buttons.
        let starts = lines[..<first].indices.filter {
            lines[$0].hasPrefix("Question ") || lines[$0].contains("Implement this plan?")
                || lines[$0].contains("Would you like to implement") || lines[$0] == "Select a review preset"
                || lines[$0].hasPrefix("Replace goal") || lines[$0].hasPrefix("Replace the current goal")
                || lines[$0] == "Resume paused goal?"
        }
        guard let start = starts.last else { return nil }
        title = lines[start..<first].filter { !$0.isEmpty }.joined(separator: "\n")
        self.choices = choices; self.selected = selected
        self.screen = lines[start...footer].joined(separator: "\n")
    }
}

struct ChatNativeStatus {
    let sessionID: String
    let text: String
    let name: String?
    init?(_ screen: String) {
        let lines = screen.components(separatedBy: .newlines)
        let stripped = lines.map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│"))) }
        guard let start = stripped.lastIndex(where: { $0.hasPrefix("Model:") }) else { return nil }
        // Codex 0.158 and older draw a box; 0.159 prints the same fields
        // unbordered, ending before the next prompt or transcript item.
        let end: Int
        if lines[start].contains("│") {
            guard let close = lines[start...].firstIndex(where: { $0.contains("╰") }) else { return nil }
            end = close
        } else {
            end = stripped[start...].firstIndex(where: { $0.hasPrefix("›") || $0.hasPrefix("•") || $0.hasPrefix("■") }) ?? lines.endIndex
        }
        // An echoed command below an old status box is not its response.
        guard !lines.dropFirst(end + 1).contains(where: { $0.contains("/status") }) else { return nil }
        var content = Array(stripped[start..<end])
        while content.last?.isEmpty == true { content.removeLast() }
        func field(_ key: String) -> String? {
            content.first(where: { $0.hasPrefix(key + ":") }).map {
                String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let id = field("Session"), UUID(uuidString: id) != nil, field("Permissions") != nil else { return nil }
        sessionID = id; name = field("Thread name"); text = content.joined(separator: "\n")
    }
}

enum ChatNativeFork {
    static let notice = "• Fork created. You can continue here."
    static func created(before: String, screen: String) -> Bool {
        func count(_ text: String) -> Int { text.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces) == notice }.count }
        return count(screen) > count(before)
    }
}

/// Output Codex prints only to the screen. A report is accepted once a new
/// copy is the last item above the idle composer; anything else stays in Terminal.
enum ChatNativeReport {
    static func title(_ command: ChatCommand) -> String {
        switch command {
        case .pwd: "Working directory"
        case .ps: "Background terminals"
        case .mcp: "MCP tools"
        default: "Recap"
        }
    }

    static func text(_ command: ChatCommand, before: String, screen: String) -> String? {
        let heading: (String) -> Bool
        switch command {
        case .pwd: heading = { $0.hasPrefix("• Current working directory:") }
        case .recap: heading = { $0.hasPrefix("↳ Recap:") }
        case .ps: heading = { $0 == "Background terminals" }
        case .mcp: heading = { $0.hasSuffix("MCP Tools") }
        default: return nil
        }
        func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } }
        let current = lines(screen)
        guard screen.utf8.count <= 65_536, current.filter(heading).count > lines(before).filter(heading).count,
              let composer = current.lastIndex(where: { $0.hasPrefix("›") }),
              let start = current[..<composer].lastIndex(where: heading),
              current.dropFirst(composer + 1).filter({ !$0.isEmpty }).count <= 2,
              !current.dropFirst(composer + 1).contains(where: { $0.contains("esc to interrupt") }) else { return nil }
        var body = Array(current[start..<composer])
        while body.last?.isEmpty == true { body.removeLast() }
        // Lists hold indented "•" items; single reports end at the next item.
        let list = command == .ps || command == .mcp
        guard !body.dropFirst().contains(where: { $0.hasPrefix("■") || $0.hasPrefix("›") || $0.contains("esc to interrupt")
                  || (!list && ($0.hasPrefix("•") || $0.hasPrefix("↳"))) }) else { return nil }
        switch command {
        case .pwd:
            // A long path wraps onto indented continuation lines.
            return String(body.joined().dropFirst("• Current working directory:".count)).trimmingCharacters(in: .whitespaces)
        case .recap:
            var summary: [String] = [], next: [String] = []
            for line in body where !line.isEmpty {
                if line.hasPrefix("Next:") || !next.isEmpty { next.append(line) } else { summary.append(line) }
            }
            let text = String(summary.joined(separator: " ").dropFirst("↳ Recap:".count)).trimmingCharacters(in: .whitespaces)
            return next.isEmpty ? text : text + "\n\n" + next.joined(separator: " ")
        default:
            return body.dropFirst().drop(while: \.isEmpty).joined(separator: "\n")
        }
    }
}

/// A completed native shell result followed by the original idle composer.
/// Unknown layouts, truncated results, and interactive screens stay in Terminal.
enum ChatNativeShellResult {
    static func output(command: String, before: String, screen: String) -> String? {
        guard screen != before, screen.utf8.count <= 65_536, !command.contains("\n") else { return nil }
        let previous = before.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let headings = ["• You ran " + command, "• Ran " + command]
        guard let prompt = previous.last(where: { $0.hasPrefix("›") }),
              let composer = lines.lastIndex(of: prompt),
              let start = lines[..<composer].lastIndex(where: { headings.contains($0) }),
              let separator = lines[(start + 1)..<composer].firstIndex(where: {
                  $0.count >= 3 && $0.allSatisfy { $0 == "─" }
              }),
              lines[(separator + 1)..<composer].allSatisfy(\.isEmpty),
              lines.dropFirst(composer + 1).filter({ !$0.isEmpty }).count <= 2,
              !lines.dropFirst(composer + 1).contains(where: { $0.contains("esc to interrupt") || $0.contains("confirm") }) else { return nil }
        let body = Array(lines[(start + 1)..<separator]).drop(while: \.isEmpty)
        guard let first = body.first, first.hasPrefix("└") else { return nil }
        var output = [String(first.dropFirst()).trimmingCharacters(in: .whitespaces)] + body.dropFirst()
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }
}

/// A shell execution as reported by Codex itself. Unlike terminal-screen
/// extraction, this preserves the complete, unwrapped stdout/stderr payload.
enum ChatCommandExecution {
    static func item(_ value: [String: Any], completed: Bool) -> ChatItem? {
        guard let id = value["id"] as? String, !id.isEmpty,
              let rawCommand = value["command"], let command = shellCommand(rawCommand) else { return nil }
        let source = value["source"] as? String
        var input: [String: Any] = ["command": rawCommand]
        if let cwd = value["cwd"] as? String {
            input["cwd"] = cwd.hasPrefix("file:") ? URL(string: cwd)?.path ?? cwd : cwd
        }
        let output = value["aggregatedOutput"] as? String ?? value["aggregated_output"] as? String
            ?? value["formattedOutput"] as? String ?? value["formatted_output"] as? String
            ?? [value["stdout"] as? String, value["stderr"] as? String].compactMap { $0 }.joined(separator: "\n")
        let status = value["status"] as? String
        var item = ChatItem(id: "tool-" + id, kind: .tool, text: printable(input), title: "Shell",
                            output: output, completed: completed && status != "inProgress",
                            exitCode: value["exitCode"] as? Int ?? value["exit_code"] as? Int,
                            processID: (value["processId"] ?? value["process_id"]).map(printable))
        item.shellCommand = command
        item.commandSource = source
        return item
    }

    static func isUserShell(_ source: String?) -> Bool {
        source?.lowercased().replacingOccurrences(of: "_", with: "") == "usershell"
    }

    private static func shellCommand(_ value: Any) -> String? {
        if let command = value as? String { return command }
        guard let arguments = value as? [String], !arguments.isEmpty else { return nil }
        if arguments.count >= 3, ["-c", "-lc"].contains(arguments[arguments.count - 2]) { return arguments.last }
        return arguments.count == 1 ? arguments[0] : arguments.joined(separator: " ")
    }

    private static func printable(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ChatNativeGoalStatus {
    let text: String
    let hasGoal: Bool
    init?(_ screen: String) {
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func empty(_ line: String) -> Bool {
            line == "No goal is currently set." ||
                (line.hasPrefix("• Usage: /goal ") && line.hasSuffix("No goal is currently set."))
        }
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Status:") || empty($0) }) else { return nil }
        let end: Int
        if empty(lines[start]) {
            end = start
            text = "No goal is currently set."; hasGoal = false
        } else {
            // SSH can deliver the heading and objective before the footer.
            // An incomplete status must never clear the live goal.
            guard let footer = lines[start...].firstIndex(where: { $0.hasPrefix("Commands: /goal") }),
                  lines[start..<footer].contains(where: { $0.hasPrefix("Objective:") }) else { return nil }
            end = footer
            text = lines[start..<end].joined(separator: "\n"); hasGoal = true
        }
        // A later notice or partial response supersedes the old report, even
        // while SSH has delivered only the composer redraw for this command.
        let tail = lines.dropFirst(end + 1).drop(while: \.isEmpty)
        guard tail.first.map({ $0.hasPrefix("›") }) ?? true,
              !tail.contains(where: { $0.contains("/goal") }) else { return nil }
    }
}

struct ChatNativeGoalEditor {
    let text: String
    init?(_ screen: String) {
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.lastIndex(where: { $0 == "▌ Edit goal" || $0 == "Edit goal" }),
              let end = lines[start...].firstIndex(where: AgentModelMenu.isFooter),
              lines.dropFirst(end + 1).allSatisfy({ $0.isEmpty }) else { return nil }
        let marker = lines[start].hasPrefix("▌") ? "▌" : "›"
        let content = lines[(start + 1)..<end].filter { $0.hasPrefix(marker) }.map {
            String($0.dropFirst()).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ")
        text = content == "Type a goal objective and press Enter" ? "" : content
    }
}

extension ChatCoordinator {
    func receiveCommandExecution(_ item: ChatItem, session: ChatSession) {
        guard item.completed, ChatCommandExecution.isUserShell(item.commandSource),
              let request = session.command, request.shellSubmitted,
              case .shell(let command)? = request.command, item.shellCommand == command else { return }
        request.shellResult = ChatCommandResult(title: "!" + command,
            text: item.output.isEmpty ? "Command completed with no output." : item.output)
    }

    /// A command the UI issues (not the composer's draft): the harness runs it as its own command.
    func submitCommand(_ command: ChatCommand, text: String, session: ChatSession) {
        guard enabled, sessions[session.id] === session, let helper = session.helper, session.active,
              !session.inputBlocked, session.submissionID == nil else { return }
        let id = UUID()
        session.submissionID = id; session.submissionFailure = nil
        var input = HelperChat.Input(helper.route)
        input.text = text
        session.helperTask = operations.run(for: session.id) { [weak session] in
            guard let session else { return }
            do {
                let outcome: HelperChat.Outcome = try await helper.call("chat.command", input: input)
                try outcome.confirmed()
                guard session.helper === helper, session.submissionID == id else { return }
                session.commandResult = outcome.result(agent: session.agentTitle)
            } catch {
                guard session.helper === helper, session.submissionID == id else { return }
                session.submissionFailure = error.localizedDescription
            }
            guard session.helper === helper, session.submissionID == id else { return }
            session.submissionID = nil; session.helperTask = nil
        }
    }
}
