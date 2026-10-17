import Foundation
import Darwin

struct HostProcessTarget: Sendable {
    enum Source: Sendable, Equatable {
        case terminal(UInt64)
        /// A PTY known by its device (helper terminals): its foreground group is read from the PTY.
        case device(UInt32)
    }
    let terminal: UUID
    let source: Source
    var tracking: AgentProcess?
}

struct HostProcessObservation: Codable, Sendable {
    let terminal: UUID
    let foreground: UInt64?
    let device: UInt32?
    let process: AgentProcess?
    let shell: SSHShell?
    let scope: SSHIntegrationScope?
    let trackedAlive: Bool
}

/// All proc/sysctl and local socket work happens off the main actor. The caller
/// submits small rotating batches; inactive native panes are included equally.
actor HostProcessWatcher {
    private var arguments: [Int32: (AgentProcess, SSHShell?, SSHIntegrationScope?)] = [:]
    private var epoch = System.uuid()

    static func alive(_ process: AgentProcess?) -> Bool {
        guard let process else { return false }
        return System.process("alive", process) { process.alive }
    }

    static func terminate(_ process: AgentProcess?) {
        guard let process else { return }
        do {
            _ = try AppReplay.query(kind: "process.terminate", input: AppReplay.value(process)) {
                if process.alive { kill(process.pid, SIGTERM) }
                return .null
            }
        } catch { AppReplay.fail(error) }
    }

    func reset() { epoch = System.uuid(); arguments.removeAll() }

    func locate(_ process: AgentProcess, in targets: [HostProcessTarget]) -> UUID? {
        guard process.alive, let info = AgentProcess.info(process.pid),
              info.tty != UInt32.max, info.foreground > 1,
              process.owns(foreground: UInt64(info.foreground)) else { return nil }
        let matches = targets.filter { target in
            switch target.source {
            case .device(let device): return device == info.tty
            case .terminal(let group): return group == UInt64(info.foreground)
            }
        }
        return matches.count == 1 ? matches.first?.terminal : nil
    }

    func probe(_ targets: [HostProcessTarget]) async -> [HostProcessObservation] {
        let epoch = epoch
        var results: [HostProcessObservation] = []
        for target in targets {
            if Task.isCancelled { break }
            let group: UInt64?
            switch target.source {
            case .terminal(let foreground): group = foreground > 1 ? foreground : nil
            case .device(let device): group = AgentProcess.foregroundGroup(device: device)
            }
            var found: AgentProcess?, shell: SSHShell?, scope: SSHIntegrationScope?, device: UInt32?
            if let group, group > 1, group <= Int32.max {
                // No whole-system scan; at most one owned foreground group.
                let members = AgentProcess.members(of: Int32(group), maximum: 64)
                let ssh = members.prefix(64).filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "ssh" }
                for process in ssh {
                    // ssh with ControlPersist forks its master into the same group (until it detaches): the user's ssh
                    // is the one whose parent is no other ssh of the group.
                    let parent = AgentProcess.info(process.pid)?.parent
                    if ssh.contains(where: { $0.pid == parent }) { continue }
                    let parsed: SSHShell?
                    if let cached = arguments[process.pid], cached.0 == process { parsed = cached.1; scope = cached.2 }
                    else {
                        let argv = process.arguments
                        parsed = argv.flatMap { SSHShell.parse(executable: process.executable, arguments: $0) }
                        if let parsed, let argv, let configuration = Self.configuration(parsed.executable, ["-G"] + Array(argv.dropFirst())) {
                            scope = HostRegistry.loginScope(executable: parsed.executable, destination: parsed.destination,
                                configuration: configuration)
                        }
                        guard self.epoch == epoch else { return [] }
                        arguments[process.pid] = (process, parsed, scope)
                    }
                    if let parsed { found = process; shell = parsed; break }
                }
                // The terminal is its ssh's: another member can be leaving it (ssh's ControlPersist master
                // detaching), with no info left or no terminal any more.
                device = ([found].compactMap { $0 } + members).lazy
                    .compactMap { AgentProcess.info($0.pid)?.tty }.first { $0 != UInt32.max }
            }
            results.append(.init(terminal: target.terminal, foreground: group, device: device, process: found,
                                 shell: shell, scope: scope, trackedAlive: target.tracking?.alive == true))
        }
        if arguments.count > 256 { arguments = arguments.filter { $0.value.0.alive } }
        return results
    }

    /// What `ssh -G` resolves only reads configuration: an observation, asked whenever and as often as a probe asks, so
    /// how often a run's probes see an ssh changes nothing recorded. Nil when it fails, takes longer than 2 s or prints
    /// more than 1 MiB. Its output is read while it runs: one larger than the pipe's buffer would block it until the 2 s.
    private static func configuration(_ executable: String, _ arguments: [String]) -> String? {
        (try? System.observe("ssh.config", [executable] + arguments) { () -> String? in
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            output.fileHandleForWriting.closeFile()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
            defer { deadline.cancel() }
            var data = Data()
            while let bytes = try output.fileHandleForReading.read(upToCount: 65_536), !bytes.isEmpty {
                guard data.count + bytes.count <= 1_048_576 else { process.terminate(); process.wait(); return nil }
                data.append(bytes)
            }
            process.wait()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }) ?? nil
    }

    func validate(_ request: SSHLaunchRequest) -> Bool {
        guard let origin = request.origin, let child = request.sshProcess, let device = request.terminalDevice,
              origin.alive, child.alive, let a = AgentProcess.info(origin.pid), let b = AgentProcess.info(child.pid),
              a.tty == device, b.tty == device, device != UInt32.max,
              b.parent == origin.pid, a.foreground == b.foreground,
              origin.owns(foreground: UInt64(a.foreground)),
              URL(fileURLWithPath: child.executable).lastPathComponent == "ssh" else { return false }
        return true
    }
}
