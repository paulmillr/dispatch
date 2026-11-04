import Foundation

/// A plain terminal keeps its host independently of the session manager running
/// in it. SSH arguments come from an owned, live foreground SSH process.
enum TerminalMachine: Equatable, Codable, Sendable {
    case local
    case ssh(SSHShell)

    #if canImport(AppKit)
    /// Where ssh to this machine runs (`SSHShell.workingDirectory`); nil for this Mac or when unknown.
    var sshDirectory: String? {
        guard case .ssh(let shell) = self else { return nil }
        return shell.workingDirectory
    }

    /// What a new terminal on this machine runs; nil = this Mac's login shell.
    func command(running remote: String? = nil) -> String? {
        guard case .ssh(let shell) = self else { return remote }
        return shell.command(running: remote)
    }
    #endif
}

struct SSHShell: Equatable, Codable, Sendable {
    let executable: String
    let options: [String]
    let destination: String
    /// The local folder `ssh` was typed in (absolute), when the launcher knew it. OpenSSH resolves relative paths from the
    /// working directory: `-F ./config`, `-i key`, a configuration's own `IdentityFile key`, `ProxyCommand ./proxy`,
    /// `Match exec`. Reconnect, its configuration check and a clone run ssh from here; nil: as before (the account home
    /// for a login, the app's own directory for `ssh -G`). Saved with the connection, like a local tab's directory.
    var directory: String? = nil

    init(destination: String, options: [String] = [], executable: String = "/usr/bin/ssh", directory: String? = nil) {
        self.executable = executable; self.options = options; self.destination = destination
        self.directory = directory.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    var arguments: [String] {
        // Start a shell even if the originating connection supplied a command.
        // Do not duplicate listeners when cloning a connection with forwarding.
        Self.ownOptions.flatMap { ["-o", $0] } + Self.withoutOwnOptions(options) + ["-tt", "--", destination]
    }
    static let ownOptions = ["RemoteCommand=none", "ClearAllForwardings=yes"]

    /// `options` without the two `arguments` puts first: a connection the app launched carries them already (parsed
    /// back from its command, `SSHInvocation`), and a clone of it would repeat them every generation, a command that
    /// differed with whichever connection a new tab happened to clone.
    static func withoutOwnOptions(_ options: [String]) -> [String] {
        var result: [String] = [], index = 0
        while index < options.count {
            if options[index] == "-o", index + 1 < options.count, ownOptions.contains(options[index + 1]) { index += 2; continue }
            if options[index].hasPrefix("-o"), ownOptions.contains(String(options[index].dropFirst(2))) { index += 1; continue }
            result.append(options[index]); index += 1
        }
        return result
    }
    #if canImport(AppKit)
    /// `directory` while it still exists (an observation): ssh for a connection typed in a folder since removed runs as
    /// before rather than not at all (a configuration with absolute paths needs no folder).
    var workingDirectory: String? {
        guard let directory, System.exists(URL(fileURLWithPath: directory, isDirectory: true)) else { return nil }
        return directory
    }

    /// The command a terminal runs for this connection (running `remote` there instead of a shell):
    /// through the app's ssh launcher, so it is attributed like ssh typed in a terminal, with this
    /// exact ssh executable. A clone runs from the original's folder (`directory`, `DISPATCH_SSH_DIRECTORY`; the launcher
    /// stays where it is when the folder is gone), so its relative paths resolve alike.
    func command(running remote: String? = nil) -> String {
        (["/usr/bin/env", "DISPATCH_SSH_EXECUTABLE=" + executable] + (directory.map { ["DISPATCH_SSH_DIRECTORY=" + $0] } ?? [])
            + [System.executable.path, "--ssh-launch"] + arguments + (remote.map { [$0] } ?? []))
            .map(HerdrLaunch.quote).joined(separator: " ")
    }
    #endif

    /// The options read after the destination, for a command that puts them all before it. OpenSSH keeps the first
    /// value it reads, and a destination's user (`user@host`, `ssh://user@host`) and port (`ssh://host:2222`) count
    /// as read where the destination stands: a `-l`, `-p` or `-o User=`/`Port=` after it is ignored, and is dropped
    /// here (moved in front it would win). `options` are as the parsers keep them: a value option and its value apart.
    static func afterDestination(_ options: [String], destination: String, takingValues values: Set<Character>) -> [String] {
        var authority = Substring(destination)
        let uri = destination.lowercased().hasPrefix("ssh://")
        if uri { authority = authority.dropFirst(6).prefix { $0 != "/" } }
        let user = authority.contains("@")
        var port = false
        if uri {
            let host = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? authority
            port = host.hasPrefix("[") ? host.contains("]:") : host.contains(":")
        }
        var result: [String] = [], index = 0
        while index < options.count {
            let option = options[index]
            let paired = option.count == 2 && values.contains(option.dropFirst().first ?? " ") && index + 1 < options.count
            let value = paired ? options[index + 1] : ""
            let key = option == "-o" ? value.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first?.lowercased() : nil
            let overridden = (user && (option == "-l" || key == "user")) || (port && (option == "-p" || key == "port"))
            if !overridden { result += paired ? [option, value] : [option] }
            index += paired ? 2 : 1
        }
        return result
    }

    /// An interactive login typed as `ssh`: its options and destination, or nil for anything else (a command without
    /// `-t`, `-N`, `-G`, a forwarding-only or multiplexing control use). As OpenSSH reads it: options, the destination,
    /// then options again unless `--` came before the destination (`ssh host -l user`), then the remote command.
    static func parse(executable: String, arguments: [String]) -> Self? {
        guard URL(fileURLWithPath: executable).lastPathComponent == "ssh", arguments.count > 1 else { return nil }
        let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw"), forwarding = Set("DLR")
        // Whether ssh asks for a terminal, as it decides: `-t` yes (twice: force), `-T` no, the last of them wins, and
        // `-o RequestTTY` counts only before either (ssh.c sets it from options only while unset).
        enum TTY { case unset, auto, no, yes, force }
        var index = 1, tty = TTY.unset
        /// One round of options from `index`: what they keep, and whether `--` ended it; nil refuses the command.
        func options() -> (kept: [String], terminated: Bool)? {
            var kept: [String] = []
            while index < arguments.count {
                let value = arguments[index]
                if value == "--" { index += 1; return (kept, true) }
                guard value.hasPrefix("-"), value != "-" else { break }
                let flags = Array(value.dropFirst())
                guard !flags.isEmpty else { return nil }
                var position = 0
                while position < flags.count {
                    let flag = flags[position]
                    if "GNnfsV".contains(flag) { return nil }
                    if flag == "t" { tty = tty == .yes ? .force : .yes; position += 1; continue }
                    if flag == "T" { tty = .no; position += 1; continue }
                    if takesValue.contains(flag) {
                        let argument: String
                        if position + 1 < flags.count { argument = String(flags[(position + 1)...]) }
                        else { index += 1; guard index < arguments.count else { return nil }; argument = arguments[index] }
                        if "OWQ".contains(flag) { return nil }
                        // `-N`, `-f` and `-n` spelt as options: no login either.
                        if flag == "o" {
                            let fields = argument.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).map { $0.lowercased() }
                            switch (fields.first ?? "", fields.dropFirst().first ?? "") {
                            case ("forkafterauthentication", "yes"), ("forkafterauthentication", "true"),
                                 ("stdinnull", "yes"), ("stdinnull", "true"): return nil
                            case ("sessiontype", let type) where type != "default": return nil
                            case ("requesttty", let value) where tty == .unset:
                                tty = ["no", "false"].contains(value) ? .no : ["yes", "true"].contains(value) ? .yes
                                    : value == "force" ? .force : .auto
                            default: break
                            }
                        }
                        if !forwarding.contains(flag) { kept += ["-\(flag)", argument] }
                        break
                    }
                    kept.append("-\(flag)")
                    position += 1
                }
                index += 1
            }
            return (kept, false)
        }
        guard let first = options(), index < arguments.count else { return nil }
        let destination = arguments[index]
        guard !destination.isEmpty, !destination.hasPrefix("-") else { return nil }
        index += 1
        var later: [String] = []
        if !first.terminated, index < arguments.count {
            guard let second = options() else { return nil }
            later = Self.afterDestination(second.kept, destination: destination, takingValues: takesValue)
        }
        // What is left is the remote command: a login with none (and a terminal not refused), or with a terminal asked for.
        guard index == arguments.count ? tty != .no : (tty == .yes || tty == .force) else { return nil }
        return .init(destination: destination, options: first.kept + later, executable: executable)
    }
}
