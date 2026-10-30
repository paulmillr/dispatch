import AppKit

/// Removing Dispatch from a machine: the helper's `uninstall` (every Dispatch hook, Pi's extension, `~/.dispatch`)
/// where it runs: this Mac's bundled helper, or an SSH host's stable helper copy. It refuses (status 3) while
/// Dispatch helpers run there, so callers end their own first and wait for them to exit.
@MainActor
enum DispatchRemoval {
    struct Outcome: Equatable {
        let status: Int32
        let output: String
        var removed: Bool { status == 0 }
        /// The host has no stable helper copy: Dispatch never ran there, or was removed already.
        var absent: Bool { status == 127 }
        /// The stable helper copy is there but cannot run: the host's home folder cannot run programs (mounted noexec).
        var cannotRun: Bool { status == 126 }
    }

    /// What to do by hand where the home folder cannot run programs, so the helper there cannot remove itself.
    static let cannotRunAdvice = "Its home folder cannot run programs, so Dispatch’s helper there cannot remove itself. "
        + "If a copy runs from its runtime folder, run $XDG_RUNTIME_DIR/dispatch/bin/versions/*/dispatch-helper uninstall there "
        + "(it removes every Dispatch hook too). Otherwise delete ~/.dispatch and $XDG_RUNTIME_DIR/dispatch, and remove "
        + "Dispatch’s hook entries from ~/.claude/settings.json and ~/.codex/hooks.json if the iPhone app installed any."

    /// What to run by hand where the app cannot reach.
    static let command = "~/.dispatch/bin/dispatch-helper uninstall"

    /// `uninstall` on `machine`; `attempts` > 1 waits a second between refusals while helpers still exit.
    static func run(on machine: TerminalMachine, dry: Bool, attempts: Int = 1) async -> Outcome {
        var outcome = Outcome(status: 1, output: "")
        for attempt in 1...max(1, attempts) {
            if attempt > 1 { try? await Task.sleep(for: .seconds(1)) }
            outcome = await once(on: machine, dry: dry)
            if outcome.status != 3 { break }
        }
        return outcome
    }

    private static func once(on machine: TerminalMachine, dry: Bool) async -> Outcome {
        let executable: String, arguments: [String]
        switch machine {
        case .local:
            guard let helper = HelperApp.executable else { return Outcome(status: 1, output: "The bundled helper is missing.") }
            executable = helper.path
            arguments = ["uninstall"] + (dry ? ["--dry-run"] : [])
        case .ssh(let shell):
            // Keys or the SSH agent only: a removal never prompts; an unreachable host is reported instead.
            executable = shell.executable
            arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes"]
                + shell.options + ["-T", "--", shell.destination, command + (dry ? " --dry-run" : "")]
        }
        do {
            let result = try await SSHCommand.run(executable: executable, arguments: arguments, timeout: 30, errors: true)
            let text = String(decoding: result.output + (result.errors ?? Data()), as: UTF8.self)
            return Outcome(status: result.status, output: tidy(text))
        } catch {
            return Outcome(status: 1, output: error.localizedDescription)
        }
    }

    /// The report without the dry run's note about the helpers the removal itself stops first, and with the
    /// home folder as `~`.
    static func tidy(_ text: String) -> String {
        let home = System.home.path
        return text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("note: ") }
            .map { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
            .joined(separator: "\n")
    }

    /// This Mac, as Dispatch quits (its helpers stopped): `uninstall`, then, with `data`, the app's own settings,
    /// drafts, saved hosts and defaults. Reports the outcome before the app exits.
    static func finishLocal(data: Bool) async {
        let outcome = await run(on: .local, dry: false, attempts: 10)
        var problems: [String] = []
        if data {
            do {
                if FileManager.default.fileExists(atPath: Home.support.path) { try FileManager.default.removeItem(at: Home.support) }
            } catch { problems.append("\(Home.support.path): \(error.localizedDescription)") }
            if let defaults = UserDefaults.app, let domain = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: domain)
                defaults.synchronize()
            }
        }
        let alert = NSAlert()
        if outcome.removed && problems.isEmpty {
            alert.messageText = "Dispatch was removed from this Mac"
            alert.informativeText = "You can move Dispatch to the Trash now. SSH hosts keep their own copy: remove it there from Settings › Hosts before, or run \(command) on them."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Dispatch couldn’t remove everything"
            alert.informativeText = ([outcome.output] + problems).filter { !$0.isEmpty }.joined(separator: "\n")
                + "\n\nFix the problem, then run \(command) in a terminal."
        }
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A removal's result for an SSH host, after it was forgotten.
    static func report(_ outcome: Outcome, host: String) {
        let alert = NSAlert()
        if outcome.cannotRun {
            alert.alertStyle = .warning
            alert.messageText = "Dispatch couldn’t be removed from \(host)"
            alert.informativeText = cannotRunAdvice + "\n\nThe host was forgotten."
        } else if outcome.removed || outcome.absent {
            alert.messageText = outcome.absent ? "Dispatch wasn’t installed on \(host)" : "Dispatch was removed from \(host)"
            alert.informativeText = outcome.absent ? "The host was forgotten." : outcome.output
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Dispatch couldn’t be removed from \(host)"
            alert.informativeText = (outcome.output.isEmpty ? "" : outcome.output + "\n\n")
                + "The host was forgotten. Run \(command) on it yourself."
        }
        alert.runModal()
    }
}
