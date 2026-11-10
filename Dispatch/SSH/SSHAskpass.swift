import Foundation
import Darwin

/// A prompt ssh asked a reconnect's login through `SSH_ASKPASS` (`SSHAskpassCommand`), posted to the launch mailbox as
/// `<id>.sshaskpass`. Its answer goes back over the FIFO `<id>.sshanswer` the asking process made beside it: the answer
/// is never a file, and the FIFO is gone once the asking process ends.
struct SSHAskpassRequest: Codable, Sendable, Equatable {
    let id: UUID
    /// The terminal identity the asking ssh runs under (`DISPATCH_HERDR_TAB`): a reconnect's login or a restored tab.
    let tabID: UUID
    let token: String
    /// ssh's prompt, as it gives it (`dev@host's password:`, a key's passphrase, a host key question).
    let prompt: String
    /// `SSH_ASKPASS_PROMPT`: `confirm` (yes or no), `none` (a notice, as a security key's touch); nil asks for text.
    var hint: String?
    /// A restored tab logging in again in its own terminal (`DISPATCH_ASKPASS_TERMINAL`): its terminals share the
    /// launch identity of their helper, so the tab is named.
    var terminal: UUID?
    /// The waiting `Dispatch --ssh-askpass` process, and its direct parent ssh. The app checks both live identities
    /// before showing a trusted prompt; a ProxyCommand or other child that inherited the launch token is not ssh.
    var requester: AgentProcess? = nil
    var ssh: AgentProcess? = nil

    enum Kind: Sendable, Equatable { case secret, confirm, notice }
    /// A question OpenSSH asks as text but answers yes or no (an unknown host key's `(yes/no/[fingerprint])`) is a
    /// confirmation too: its answer is the word.
    var kind: Kind {
        switch hint {
        case "confirm": .confirm
        case "none": .notice
        default: prompt.lowercased().contains("(yes/no") ? .confirm : .secret
        }
    }

    /// The request still comes from this app's askpass process, directly under the ssh it names. Old capture replays
    /// predate these fields; replay starts no process and may use their recorded request.
    var hasValidRequester: Bool {
        if AppReplay.replaying, requester == nil, ssh == nil { return true }
        guard let requester, let ssh, requester.alive, ssh.alive,
              requester.executable == System.resolve(System.executable).path,
              AgentProcess.info(requester.pid)?.parent == ssh.pid else { return false }
        return true
    }

    /// The parent is the executable this login was started with. A script's kernel process is its interpreter, whose
    /// argv still names the script; custom ssh wrappers therefore remain supported without accepting another child.
    func isFromSSH(executable expected: String) -> Bool {
        if AppReplay.replaying, ssh == nil { return true }
        guard let ssh, ssh.alive else { return false }
        let resolved = System.resolve(URL(fileURLWithPath: expected)).path
        if ssh.executable == resolved { return true }
        return ssh.arguments?.prefix(3).contains(where: { $0 == expected || $0 == resolved }) == true
    }
}

/// The asking process's answer: the text ssh reads, or nil to refuse (ssh's prompt fails, as a cancelled one).
struct SSHAskpassAnswer: Codable, Sendable {
    let value: String?
}

enum SSHAskpass {
    /// The script ssh runs as its askpass program (`SSH_ASKPASS` names a program, run with the prompt as its one
    /// argument): this app's binary in its askpass mode.
    static let program = "dispatch-askpass"

    static func script(executable: String) -> String {
        "#!/bin/sh\nexec \(HerdrLaunch.quote(executable)) --ssh-askpass \"$@\"\n"
    }

    /// What a login's ssh needs to ask through the strip: OpenSSH 8.4 and later ask every prompt through the program
    /// (`SSH_ASKPASS_REQUIRE=force`), with or without a terminal or `DISPLAY`. An older one prompts on its terminal as
    /// before, which the reconnect's log shows (`SSHReconnectController.awaitingTerminal`).
    static func environment(directory: URL, terminal: UUID? = nil) -> [String: String] {
        var environment = ["SSH_ASKPASS": directory.appendingPathComponent("bin").appendingPathComponent(program).path,
                           "SSH_ASKPASS_REQUIRE": "force"]
        if let terminal { environment["DISPATCH_ASKPASS_TERMINAL"] = terminal.uuidString }
        return environment
    }

    /// Writes `answer` to the asking process. Only whether there was one is recorded: replay starts no askpass.
    @MainActor static func reply(_ request: SSHAskpassRequest, directory: URL, answer: String?) {
        struct Recorded: Encodable { let path: String; let answered: Bool }
        let path = directory.appendingPathComponent(request.id.uuidString + ".sshanswer").path
        do {
            _ = try AppReplay.query(kind: "ssh.askpass.answer", input: AppReplay.value(Recorded(path: path, answered: answer != nil))) {
                guard var line = try? JSONEncoder().encode(SSHAskpassAnswer(value: answer)) else { return .null }
                line.append(0x0A)
                // A FIFO the asker holds open: this never blocks, and fails (ENXIO, ENOENT) once it is gone. A file put
                // there instead of the FIFO is not written to.
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return .null }
                let descriptor = open(path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
                guard descriptor >= 0 else { return .null }
                defer { Darwin.close(descriptor) }
                _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                return .null
            }
        } catch { AppReplay.fail(error) }
    }
}

/// `dispatch-askpass`: runs as ssh's askpass program for a reconnect's login. It posts the prompt to the app's launch
/// mailbox with its terminal's token and waits for the answer on a FIFO of its own, printing it for ssh. No answer
/// within ten minutes, or the mailbox gone, refuses the prompt.
enum SSHAskpassCommand {
    nonisolated(unsafe) private static var fifo: UnsafeMutablePointer<CChar>?

    static func run(_ arguments: [String]) -> Int32 {
        let environment = System.inherited
        guard let directory = environment["DISPATCH_HERDR_DIRECTORY"],
              let tab = environment["DISPATCH_HERDR_TAB"].flatMap(UUID.init(uuidString:)),
              let token = environment["DISPATCH_HERDR_TOKEN"],
              let requester = AgentProcess.capture(System.pid),
              let ssh = AgentProcess.capture(getppid()) else { return 1 }
        let root = URL(fileURLWithPath: directory)
        let request = SSHAskpassRequest(id: System.uuid(), tabID: tab, token: token,
                                        prompt: String((arguments.first ?? "").prefix(2048)), hint: environment["SSH_ASKPASS_PROMPT"],
                                        terminal: environment["DISPATCH_ASKPASS_TERMINAL"].flatMap(UUID.init(uuidString:)),
                                        requester: requester, ssh: ssh)
        let answer = root.appendingPathComponent(request.id.uuidString + ".sshanswer")
        guard mkfifo(answer.path, 0o600) == 0 else { return 1 }
        fifo = strdup(answer.path)
        // ssh ends a notice's askpass (a security key's touch) with SIGTERM once the key answered.
        for signal in [SIGTERM, SIGHUP, SIGINT] {
            Darwin.signal(signal) { _ in
                if let fifo = SSHAskpassCommand.fifo { unlink(fifo) }
                _exit(1)
            }
        }
        defer { unlink(answer.path) }
        // Read and write: opening never waits for the app, and the FIFO never reads as ended between writers.
        let descriptor = open(answer.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else { return 1 }
        defer { Darwin.close(descriptor) }
        let file = root.appendingPathComponent(request.id.uuidString + ".sshaskpass")
        guard let data = try? JSONEncoder().encode(request), (try? data.write(to: file, options: .atomic)) != nil else { return 1 }
        var received = Data()
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, FileManager.default.fileExists(atPath: directory) {
            var descriptors = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptors, 1, 200) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { continue }
            received.append(contentsOf: buffer[0..<count])
            guard received.count < 65_536 else { return 1 }
            guard let end = received.firstIndex(of: 0x0A) else { continue }
            guard let reply = try? JSONDecoder().decode(SSHAskpassAnswer.self, from: received[..<end]),
                  let value = reply.value else { return 1 }
            FileHandle.standardOutput.write(Data((value + "\n").utf8))
            return 0
        }
        try? FileManager.default.removeItem(at: file)
        return 1
    }
}
