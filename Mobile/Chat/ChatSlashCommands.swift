import SwiftUI

/// One row of the slash-command list (C2): the command, what it does and who carries it out: "Dispatch" for the commands
/// Dispatch itself handles instead of typing them into the agent (side conversations, Terminal, the goal controls),
/// else the agent's name. The commands are the ones the conversation's helper lists (`chat.open` `commands`), plus
/// `/fork` and `/recap` for Codex, which its harness runs (helper/harnesses/codex/src/command.rs) but does not list.
struct ChatSlashCommand: Identifiable, Equatable {
    let name: String
    let detail: String
    let source: String
    var id: String { name }

    /// Handled by Dispatch rather than the agent: `/btw` and `/side` open a side conversation, `/terminal` switches to
    /// Terminal, `/goal` has the goal strip and its sheet (Codex).
    static let dispatch: Set<String> = ["/btw", "/side", "/terminal", "/goal"]

    /// The agent's name as the Mac shows it: the helper's label, else the harness's product name by its key.
    static func agentName(label: String?, key: String?) -> String {
        if let label, !label.isEmpty, label != key { return label }
        switch key {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "pi": return "Pi"
        case "nanocodex": return "Nanocodex"
        default: return label ?? key ?? "The agent"
        }
    }

    /// The commands a conversation offers: the helper's list (`/terminal` always, as the Mac's), Codex's extras after
    /// its own.
    static func available(_ commands: [String], agent key: String?) -> [String] {
        var names = commands.contains("/terminal") ? commands : commands + ["/terminal"]
        if key == "codex" {
            for extra in ["/fork", "/recap"] where !names.contains(extra) { names.append(extra) }
        }
        return names
    }

    /// The commands whose names start with what the draft holds: the draft is one line that starts with "/" and has no
    /// space yet (an argument means the command was chosen).
    static func matching(_ draft: String, commands: [String], agent key: String?, agentName: String) -> [ChatSlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return [] }
        let prefix = draft.lowercased()
        return available(commands, agent: key).filter { $0.lowercased().hasPrefix(prefix) }.map {
            ChatSlashCommand(name: $0, detail: description($0, agent: agentName),
                             source: dispatch.contains($0) ? "Dispatch" : agentName)
        }
    }

    /// What a command does, in a line (the Mac's `commandDescription`, the phone's words).
    static func description(_ command: String, agent: String) -> String {
        switch command {
        case "/btw": "Ask on the side, read-only, kept out of the thread"
        case "/side": "A side conversation with full permissions"
        case "/terminal": "Show the live terminal"
        case "/model": "Switch the model"
        case "/effort": "Change the reasoning effort"
        case "/hooks": "Review configured hooks"
        case "/permissions": "Configure what \(agent) may do"
        case "/resume": "Resume a saved conversation, in Terminal"
        case "/compact": "Summarise the conversation to free context"
        case "/status": "Show the session’s details"
        case "/fast": "Turn Fast mode on or off"
        case "/rename": "Rename this conversation"
        case "/init": "Create repository instructions"
        case "/review": "Review the changes"
        case "/stop": "Stop background terminals"
        case "/copy": "Copy the latest response"
        case "/plan": "Plan before implementing"
        case "/goal": "Set a goal the agent keeps working toward"
        case "/clear", "/new": "Start a fresh conversation"
        case "/fork": "Continue in a new conversation from here"
        case "/pwd": "Show the working directory"
        case "/ps": "List background terminals"
        case "/mcp": "List MCP tools"
        case "/recap": "What happened since you last looked"
        case "/help": "Show the available commands"
        case "/exit", "/quit": "Quit \(agent)"
        default: "Run in \(agent)"
        }
    }
}

/// C2: the list card above the composer while the draft starts with "/": each row the command in mono, its line, its
/// source; the first row is lit: Return (or send) puts it in the composer (`MobileChatSession.sendFromComposer`), as a
/// tap on any row does.
struct ChatSlashList: View {
    let commands: [ChatSlashCommand]
    let choose: (ChatSlashCommand) -> Void
    @Environment(\.chatMeasure) private var measure

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    Button { choose(command) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(command.name).font(.system(.body, design: .monospaced).weight(.semibold))
                                Text(command.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(command.source).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .frame(minHeight: 44)
                        .background { if index == 0 { Color.lens } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(command.name)
                    .accessibilityValue(command.detail + ", " + command.source)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Puts the command in the message")
                    if index < commands.count - 1 {
                        Rectangle().fill(Color.hairline).frame(height: 0.5).padding(.leading, 16)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .frame(maxWidth: measure)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-slash-commands")
    }
}
