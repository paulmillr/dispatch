import Foundation

/// A plain terminal keeps its host independently of the session manager running
/// in it. SSH arguments come from an owned, live foreground SSH process.
enum TerminalMachine: Equatable, Codable, Sendable {
    case local
    case ssh(SSHShell)

    /// What a new terminal on this machine runs; nil = this Mac's login shell.
    func command(running remote: String? = nil) -> String? {
        guard case .ssh(let shell) = self else { return remote }
        return shell.command(running: remote)
    }
}

struct SSHShell: Equatable, Codable, Sendable {
    let executable: String
    let options: [String]
    let destination: String

    init(destination: String, options: [String] = [], executable: String = "/usr/bin/ssh") {
        self.executable = executable; self.options = options; self.destination = destination
    }

    var arguments: [String] {
        // Start a shell even if the originating connection supplied a command.
        // Do not duplicate listeners when cloning a connection with forwarding.
        ["-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes"] + options + ["-tt", "--", destination]
    }
    /// The command a terminal runs for this connection (running `remote` there instead of a shell):
    /// through the app's ssh launcher, so it is attributed like ssh typed in a terminal, with this
    /// exact ssh executable.
    func command(running remote: String? = nil) -> String {
        (["/usr/bin/env", "DISPATCH_SSH_EXECUTABLE=" + executable, Bundle.main.executablePath ?? "", "--ssh-launch"]
            + arguments + (remote.map { [$0] } ?? []))
            .map(HerdrLaunch.quote).joined(separator: " ")
    }

    static func parse(executable: String, arguments: [String]) -> Self? {
        guard URL(fileURLWithPath: executable).lastPathComponent == "ssh", arguments.count > 1 else { return nil }
        let takesValue = Set("BbcDEeFIiJLlmOopQRSWw"), forwarding = Set("DLR")
        var options: [String] = [], index = 1, forcedTTY = false
        var commandOnly = false
        while index < arguments.count {
            let value = arguments[index]
            if value == "--" { index += 1; break }
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
                    if !forwarding.contains(flag) { options += ["-\(flag)", argument] }
                    break
                }
                options.append("-\(flag)")
                position += 1
            }
            index += 1
        }
        // OpenSSH resumes option parsing after the destination (`host -l user`).
        let next = index + 1 < arguments.count ? arguments[index + 1] : nil
        guard index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("-"),
              forcedTTY || (!commandOnly && index + 1 == arguments.count),
              next.map({ !$0.hasPrefix("-") || $0 == "-" }) ?? true else { return nil }
        return .init(destination: arguments[index], options: options, executable: executable)
    }
}
