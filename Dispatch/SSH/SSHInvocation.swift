import Foundation

/// Parse only invocations whose terminal semantics we can preserve. The original
/// argv is kept for passthrough; remote command words use OpenSSH's space joining.
struct SSHInvocation: Equatable, Sendable {
    let options: [String]
    let destination: String
    let command: String?
    let forcedTTY: Bool

    static func parse(_ arguments: [String], isTerminal: Bool) -> Self? {
        guard isTerminal else { return nil }
        let values = Set("BbcDEeFIiJLlmopPRw")
        let simple = Set("46AaCKkqvXxYy")
        var options: [String] = [], index = 0, tty = false
        while index < arguments.count {
            let value = arguments[index]
            if value == "--" { index += 1; break }
            guard value.hasPrefix("-"), value != "-" else { break }
            let flags = Array(value.dropFirst())
            guard !flags.isEmpty else { return nil }
            var position = 0
            while position < flags.count {
                let flag = flags[position]
                if flag == "t" { tty = true; position += 1; continue }
                // No commands, subsystem, background, multiplex management, or
                // explicit master settings; these must go to ssh unchanged.
                guard flag != "T", !"GNnfsVMOSQW".contains(flag) else { return nil }
                if values.contains(flag) {
                    let argument: String
                    if position + 1 < flags.count { argument = String(flags[(position + 1)...]) }
                    else {
                        index += 1
                        guard index < arguments.count else { return nil }
                        argument = arguments[index]
                    }
                    if flag == "o" {
                        let fields = argument.split(whereSeparator: { $0 == "=" || $0.isWhitespace })
                        let key = fields.first?.lowercased() ?? ""
                        guard !["controlmaster", "controlpath", "controlpersist", "sessiontype", "requesttty", "stdinnull", "forkafterauthentication"].contains(key) else { return nil }
                        if key == "remotecommand", fields.dropFirst().map(String.init).joined(separator: " ").lowercased() != "none" { return nil }
                    }
                    options += ["-\(flag)", argument]
                    break
                }
                guard simple.contains(flag) else { return nil }
                options.append("-\(flag)"); position += 1
            }
            index += 1
        }
        guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-") else { return nil }
        let destination = arguments[index]
        let words = Array(arguments.dropFirst(index + 1))
        // OpenSSH resumes option parsing after the destination (`host -l user`).
        guard words.isEmpty || tty, words.first.map({ !$0.hasPrefix("-") || $0 == "-" }) ?? true else { return nil }
        return .init(options: options, destination: destination,
                     command: words.isEmpty ? nil : words.joined(separator: " "), forcedTTY: tty)
    }

    /// ssh -G resolves Host/Match and Include directives. An existing user master
    /// or configured remote command takes precedence over automatic enhancement.
    func supports(configuration: String) -> Bool {
        var fields: [String: String] = [:]
        for line in configuration.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if parts.count == 2 { fields[String(parts[0]).lowercased()] = String(parts[1]) }
        }
        guard fields["hostname"] != nil, fields["user"] != nil else { return false }
        for (key, allowed) in ["controlmaster": ["false", "no"], "controlpath": ["none"],
                               "controlpersist": ["no", "0"], "remotecommand": ["none"],
                               "sessiontype": ["default"], "stdinnull": ["no"],
                               "forkafterauthentication": ["no"], "requesttty": ["auto", "yes", "force"]] {
            if let value = fields[key], !allowed.contains(value.lowercased()) { return false }
        }
        return true
    }

    func masterArguments(controlPath: String, remoteCommand: String) -> [String] {
        // Dispatch closes its private master after checking the shell's exit
        // receipt and releasing native consumers. A one-second idle timeout can
        // race the mailbox poll, especially after the helper has been disabled.
        ["-o", "ControlMaster=yes", "-o", "ControlPersist=yes", "-S", controlPath] + options +
        ["-tt", "--", destination, remoteCommand]
    }
}

struct SSHConnectionID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Auxiliary processes may use only this authenticated master. ProxyCommand
/// closes the fallback path if the socket disappears between check and use.
struct SSHMaster: Codable, Sendable {
    let executable: String
    let controlPath: String
    let destination: String

    func controlArguments(_ operation: String) -> [String] {
        ["-F", "/dev/null", "-S", controlPath, "-o", "ProxyCommand=/usr/bin/false",
         "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "-O", operation, "--", destination]
    }

    func arguments(command: String) -> [String] {
        // Replace sshd's command shell so a helper that execs from this script
        // remains a direct child of sshd, including on a resumed PTY channel.
        ["-F", "/dev/null", "-S", controlPath, "-o", "ControlMaster=no",
         "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes",
         "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=3",
         "-T", "--", destination, "exec /bin/sh -c " + HerdrLaunch.quote(command)]
    }
}
