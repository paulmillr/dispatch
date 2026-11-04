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

    /// An interactive login typed as `ssh`: its options and destination, or nil for anything else (a command without
    /// `-t`, `-N`, `-G`, a forwarding-only or multiplexing control use). As OpenSSH reads it: options, the destination,
    /// then options again unless `--` came before the destination (`ssh host -l user`), then the remote command.
    static func parse(executable: String, arguments: [String]) -> Self? {
        guard URL(fileURLWithPath: executable).lastPathComponent == "ssh", arguments.count > 1 else { return nil }
        let takesValue = Set("BbcDEeFIiJLlmOopQRSWw"), forwarding = Set("DLR")
        var index = 1, forcedTTY = false, commandOnly = false
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
                    if flag == "t" { forcedTTY = true; position += 1; continue }
                    if flag == "T" { commandOnly = true; position += 1; continue }
                    if takesValue.contains(flag) {
                        let argument: String
                        if position + 1 < flags.count { argument = String(flags[(position + 1)...]) }
                        else { index += 1; guard index < arguments.count else { return nil }; argument = arguments[index] }
                        if "OWQ".contains(flag) { return nil }
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
            // The connection's command puts every option before the destination. OpenSSH keeps the first user it
            // reads: a `user@` destination's wins over a `-l` after it, which would win once moved in front.
            var rest = second.kept[...]
            while let option = rest.first {
                let pair = takesValue.contains(option.dropFirst().first ?? " ") && option.count == 2
                if option == "-l", destination.contains("@") { rest = rest.dropFirst(2); continue }
                later += pair ? Array(rest.prefix(2)) : [option]
                rest = rest.dropFirst(pair ? 2 : 1)
            }
        }
        // What is left is the remote command: a login only with a forced terminal, or with none at all.
        guard forcedTTY || (!commandOnly && index == arguments.count) else { return nil }
        return .init(destination: destination, options: first.kept + later, executable: executable)
    }
}
