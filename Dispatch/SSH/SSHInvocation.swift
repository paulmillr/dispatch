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

/// What consent covers is the connection OpenSSH actually opens. `ssh -G` of the typed invocation is what the user
/// approved, but Dispatch runs others: the login master (its own command, `-tt`) and a reconnect's master (`-N`).
/// OpenSSH resolves each again, and `Match command`, `Match sessiontype` or `Match exec` can give them another host,
/// account, key or proxy. Each generated invocation is resolved (`ssh -G` only, nothing connects) and compared with the
/// approved one, apart from the options that invocation sets on purpose (each its own list: an option the user's
/// configuration sets only for Dispatch's invocation, `ForkAfterAuthentication yes` under `Match sessiontype exec` say,
/// counts); any other difference keeps the helper off.
enum SSHResolvedConnection {
    /// What the login master sets (`SSHInvocation.masterArguments`): its private master (`ControlMaster`, `-S`,
    /// `ControlPersist`), `-tt`, the keepalive (`SSHKeepalive`), and the forwarding every probe shows
    /// (`ClearAllForwardings=no`, passed first to the consent probe and these alike).
    static let login: Set<String> = ["controlmaster", "controlpath", "controlpersist", "requesttty",
                                     "serveraliveinterval", "serveralivecountmax", "clearallforwardings"]
    /// What the login sheet's reconnect master sets (`SSHReconnectLogin.interactiveArguments`): the private master and
    /// keepalive, and `-f -N` (`SessionType`, `ForkAfterAuthentication`, `StdinNull`, and so no TTY).
    static let reconnect = login.union(["sessiontype", "forkafterauthentication", "stdinnull"])
    /// What an automatic reconnect's master sets besides (`SSHReconnectLogin.silentArguments`): `BatchMode`, `ConnectTimeout`.
    static let silentReconnect = reconnect.union(["batchmode", "connecttimeout"])

    /// The resolved options (`ssh -G` keys) in which `actual` differs from `approved`, those in `ignoring` (what the
    /// invocation resolved as `actual` sets itself) aside, sorted. Repeated options (identity files, forwards, SendEnv)
    /// compare as their ordered lists. Empty: the same connection.
    static func differences(approved: String, actual: String, ignoring ownKeys: Set<String>) -> [String] {
        func fields(_ configuration: String) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for line in configuration.split(whereSeparator: \.isNewline) {
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard let key = parts.first?.lowercased(), !ownKeys.contains(key) else { continue }
                result[key, default: []].append(parts.count == 2 ? String(parts[1]) : "")
            }
            return result
        }
        let a = fields(approved), b = fields(actual)
        return Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.sorted()
    }

    /// Why a generated invocation was refused, for the terminal or the reconnect bar.
    static func reason(_ differences: [String]) -> String {
        let shown = differences.prefix(4).joined(separator: ", ") + (differences.count > 4 ? ", …" : "")
        return "its SSH configuration resolves differently for Dispatch's own ssh (\(shown)), as with Match on the command or session type"
    }
}

/// The session environment a connection's own login sends (`SendEnv` in its `ssh -G`), which channels Dispatch opens
/// over the master send as well: OpenSSH's mux client sends only what its own `SendEnv` names, from its own environment,
/// and helper channels run with `-F /dev/null` from the app, whose environment is not the terminal's. The launcher
/// captures these from the environment `ssh` was typed in (the terminal's), when the login starts; they travel in the
/// private launch request and live in memory with the connection, never in saved state. Dispatch's own variables
/// (`DISPATCH_*`) stay behind. The server still decides what it accepts (`AcceptEnv`), as for the login.
enum SSHSessionEnvironment {
    static let maximumCount = 64
    static let maximumBytes = 32_768

    /// The variables of `environment` that `configuration`'s SendEnv patterns name (OpenSSH's `*` and `?` wildcards).
    static func values(configuration: String, environment: [String: String]) -> [String: String] {
        let patterns = configuration.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0].lowercased() == "sendenv", !parts[1].hasPrefix("-") else { return nil }
            return String(parts[1])
        }
        guard !patterns.isEmpty else { return [:] }
        var result: [String: String] = [:], bytes = 0
        for name in environment.keys.sorted() where valid(name) && !name.hasPrefix("DISPATCH_") {
            guard result.count < maximumCount else { break }
            guard patterns.contains(where: { matches(name, $0) }), let value = environment[name] else { continue }
            // One that does not fit is left out; smaller ones after it still go.
            guard bytes + name.utf8.count + value.utf8.count <= maximumBytes else { continue }
            result[name] = value
            bytes += name.utf8.count + value.utf8.count
        }
        return result
    }

    /// A name `SendEnv` can carry as itself (no wildcard of its own).
    static func valid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    /// OpenSSH's `match_pattern`: `*` any run, `?` one character, the rest literal and case-sensitive.
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let text = Array(name.utf8), glob = Array(pattern.utf8)
        var t = 0, g = 0, star = -1, mark = 0
        while t < text.count {
            if g < glob.count, glob[g] == 63 || glob[g] == text[t], glob[g] != 42 { t += 1; g += 1 }
            else if g < glob.count, glob[g] == 42 { star = g; mark = t; g += 1 }
            else if star >= 0 { g = star + 1; mark += 1; t = mark }
            else { return false }
        }
        while g < glob.count, glob[g] == 42 { g += 1 }
        return g == glob.count
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
    /// What the connection's login sent with `SendEnv` (`SSHSessionEnvironment`): every channel over this master sends
    /// the same names and values. Nil or empty: none.
    var environment: [String: String]? = nil

    /// The environment a process opening a channel over this master runs with: the app's, with the session's values.
    /// Nil when there are none (the process inherits the app's as before).
    var processEnvironment: [String: String]? {
        guard let environment, !environment.isEmpty else { return nil }
        return System.inherited.merging(environment) { _, session in session }
    }
    /// This master as capture journals keep it (the mailbox's launch and resume files): the session variables' names,
    /// each value replaced by as many `*` as it has bytes. Replay spawns nothing, so it needs no value.
    var recorded: SSHMaster {
        var copy = self
        copy.environment = environment.map { $0.mapValues { String(repeating: "*", count: $0.utf8.count) } }
        return copy
    }
    /// `-o SendEnv=NAME` for each session variable: the mux client sends only what it names itself.
    private var sendEnvironment: [String] {
        (environment ?? [:]).keys.filter(SSHSessionEnvironment.valid).sorted().flatMap { ["-o", "SendEnv=" + $0] }
    }

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

    /// A helper channel: no PTY, no forwarding of any kind, the session's environment (`environment`).
    func arguments(command: String) -> [String] {
        // Replace sshd's command shell so a helper that execs from this script
        // remains a direct child of sshd, including on a resumed PTY channel.
        ["-F", "/dev/null", "-S", controlPath, "-o", "ControlMaster=no",
         "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes",
         "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=3"] + sendEnvironment +
        ["-T", "--", destination, "exec /bin/sh -c " + HerdrLaunch.quote(command)]
    }

    /// The interactive shell a reconnect resumes over a fresh master: a helper channel's options with a PTY, and the agent
    /// forwarding the connection asked for (`ForwardAgent` or `-A` in its `ssh -G`), which the fresh `-N` master has but
    /// no session of it has requested yet. OpenSSH forwards only when the master forwards too (its own configuration).
    func shellArguments(command: String, forwardAgent: Bool) -> [String] {
        var arguments = self.arguments(command: command)
        if let index = arguments.firstIndex(of: "-T") {
            arguments[index] = "-tt"
            if forwardAgent { arguments.insert(contentsOf: ["-o", "ForwardAgent=yes"], at: index) }
        }
        return arguments
    }

    /// Whether `configuration` (an `ssh -G`) forwards the agent: `yes`, or a socket to forward.
    static func forwardsAgent(_ configuration: String) -> Bool {
        configuration.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0].lowercased() == "forwardagent" && !["no", "false"].contains(parts[1].lowercased())
        }
    }
}
#endif
