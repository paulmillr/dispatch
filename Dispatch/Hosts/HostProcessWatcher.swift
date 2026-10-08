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
    private var epoch = UUID()

    static func alive(_ process: AgentProcess?) -> Bool {
        guard let process else { return false }
        do {
            return try JSONDecoder().decode(Bool.self, from: AppReplay.query(kind: "process.alive", input: JSONEncoder().encode(process)) {
                try JSONEncoder().encode(process.alive)
            })
        } catch { AppReplay.fail(error); return false }
    }

    static func terminate(_ process: AgentProcess?) {
        guard let process else { return }
        do {
            _ = try AppReplay.query(kind: "process.terminate", input: JSONEncoder().encode(process)) {
                if process.alive { kill(process.pid, SIGTERM) }
                return Data()
            }
        } catch { AppReplay.fail(error) }
    }

    func reset() { epoch = UUID(); arguments.removeAll() }

    func locate(_ process: AgentProcess, in targets: [HostProcessTarget]) -> UUID? {
        guard !AppReplay.replaying, process.alive, let info = AgentProcess.info(process.pid),
              info.e_tdev != UInt32.max, info.e_tpgid > 1,
              process.owns(foreground: UInt64(info.e_tpgid)) else { return nil }
        let matches = targets.filter { target in
            switch target.source {
            case .device(let device): return device == info.e_tdev
            case .terminal(let group): return group == UInt64(info.e_tpgid)
            }
        }
        return matches.count == 1 ? matches.first?.terminal : nil
    }

    func probe(_ targets: [HostProcessTarget]) async -> [HostProcessObservation] {
        guard !AppReplay.replaying else {
            AppReplay.fail(HelperFailure(code: "replay", message: "Live host process polling during replay")); return []
        }
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
                device = members.first.flatMap { AgentProcess.info($0.pid)?.e_tdev }
                for process in members.prefix(64) where URL(fileURLWithPath: process.executable).lastPathComponent == "ssh" {
                    let parsed: SSHShell?
                    if let cached = arguments[process.pid], cached.0 == process { parsed = cached.1; scope = cached.2 }
                    else {
                        let argv = process.arguments
                        parsed = argv.flatMap { SSHShell.parse(executable: process.executable, arguments: $0) }
                        if let parsed, let argv,
                           let result = try? await SSHCommand.run(executable: parsed.executable,
                               arguments: ["-G"] + Array(argv.dropFirst()), timeout: 2), result.status == 0 {
                            scope = HostRegistry.loginScope(executable: parsed.executable, destination: parsed.destination,
                                configuration: String(decoding: result.output, as: UTF8.self))
                        }
                        guard self.epoch == epoch else { return [] }
                        arguments[process.pid] = (process, parsed, scope)
                    }
                    if let parsed { found = process; shell = parsed; break }
                }
            }
            results.append(.init(terminal: target.terminal, foreground: group, device: device, process: found,
                                 shell: shell, scope: scope, trackedAlive: target.tracking?.alive == true))
        }
        if arguments.count > 256 { arguments = arguments.filter { $0.value.0.alive } }
        return results
    }

    func validate(_ request: SSHLaunchRequest) -> Bool {
        guard !AppReplay.replaying else {
            AppReplay.fail(HelperFailure(code: "replay", message: "Live host process validation during replay")); return false
        }
        guard let origin = request.origin, let child = request.sshProcess, let device = request.terminalDevice,
              origin.alive, child.alive, let a = AgentProcess.info(origin.pid), let b = AgentProcess.info(child.pid),
              a.e_tdev == device, b.e_tdev == device, device != UInt32.max,
              b.pbi_ppid == UInt32(origin.pid), a.e_tpgid == b.e_tpgid,
              origin.owns(foreground: UInt64(a.e_tpgid)),
              URL(fileURLWithPath: child.executable).lastPathComponent == "ssh" else { return false }
        return true
    }
}
