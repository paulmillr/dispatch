import Foundation

#if canImport(AppKit)
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

    /// `configuration`: this invocation's `ssh -G`, which decides the keepalive (`SSHKeepalive`).
    func masterArguments(controlPath: String, remoteCommand: String, configuration: String?) -> [String] {
        // Dispatch closes its private master after checking the shell's exit
        // receipt and releasing native consumers. A one-second idle timeout can
        // race the mailbox poll, especially after the helper has been disabled.
        ["-o", "ControlMaster=yes", "-o", "ControlPersist=yes", "-S", controlPath] + options +
        SSHKeepalive.options(configuration: configuration) + ["-tt", "--", destination, remoteCommand]
    }
}
#endif

/// What every master the app starts adds after the connection's own options: a keepalive every 15 s, the link given up
/// after 8 unanswered (about two minutes), so a link that died while idle ends its master instead of waiting for TCP's
/// two-hour keepalive, while a blip of 40 s or so is survived. A connection with a keepalive of its own keeps it: OpenSSH
/// uses the first value it is given for an option, so these come after the user's `-o` options, and are left out when
/// the connection's `ssh -G` (`configuration`, which ssh_config feeds) already sets an interval. Only the master owns the
/// TCP connection: channels opened over its socket (`SSHMaster.arguments`) inherit it.
enum SSHKeepalive {
    static let interval = 15
    static let count = 8

    static func options(configuration: String?) -> [String] {
        let own = configuration?.split(separator: "\n").contains { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[0].lowercased() == "serveraliveinterval" && fields[1] != "0"
        } ?? false
        return own ? [] : ["-o", "ServerAliveInterval=\(interval)", "-o", "ServerAliveCountMax=\(count)"]
    }
}

struct SSHConnectionID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID = System.uuid()) { self.rawValue = rawValue }
}

#if canImport(AppKit)
/// Auxiliary processes may use only this authenticated master. ProxyCommand
/// closes the fallback path if the socket disappears between check and use.
struct SSHMaster: Codable, Sendable {
    let executable: String
    let controlPath: String
    let destination: String

    /// Ends this master (`ssh -O exit`) once: a caller asking while that exit runs, or after it succeeded,
    /// shares it. Whether two callers send one command or two so never depends on when the first one
    /// finished (a capture holds the same commands replay makes). Only after a failed exit (the master was
    /// not listening yet) does a caller send another.
    @MainActor @discardableResult func exit() -> Task<Void, Never> {
        if let sent = Self.exits[controlPath], !sent.failed { return sent.task }
        let path = controlPath
        let task = Task { @MainActor in
            let result = try? await SSHCommand.run(executable: executable, arguments: controlArguments("exit"), timeout: 3)
            if result?.status != 0 { Self.exits[path]?.failed = true }
        }
        Self.exits[path] = (task, false)
        return task
    }
    @MainActor private static var exits: [String: (task: Task<Void, Never>, failed: Bool)] = [:]

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
#endif
