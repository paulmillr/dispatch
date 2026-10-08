import Foundation
import Darwin

struct AgentProcess: Equatable, Codable, Sendable {
    let executable: String
    let pid: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value))) == MemoryLayout.size(ofValue: value) else { return nil }
        return value
    }
    static func capture(_ pid: pid_t) -> AgentProcess? {
        guard let info = info(pid), info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return AgentProcess(executable: executable, pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }
    var alive: Bool { Self.capture(pid) == self }
    var directory: String? {
        guard alive else { return nil }
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              alive else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.hasPrefix("/") ? path : nil
    }
    var foregroundGroup: UInt64 {
        guard alive, let info = Self.info(pid), info.e_tpgid > 1 else { return 0 }
        return UInt64(info.e_tpgid)
    }
    func owns(foreground: UInt64) -> Bool { alive && foreground > 1 && UInt64(max(0, getpgid(pid))) == foreground }
}

// Compatibility for the hook transport's Codex-specific ancestor checks.
typealias CodexProcess = AgentProcess

extension AgentProcess {
    /// Read only a requested routing value; never retain or log the process's
    /// credentials or its complete environment.
    func environmentValue(_ name: String) -> String? {
        guard ["CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "CODEX_HOME", "HOME"].contains(name), alive else { return nil }
        return processEnvironmentValue(name)
    }

    /// Forward only the provider's launch settings to its own child process.
    /// Credentials stay in memory and are never included in diagnostics.
    func sideEnvironment(agentID: String) -> [String: String] {
        let names = agentID == "claude"
            ? ["HOME", "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING"]
            : ["HOME", "CODEX_HOME", "OPENAI_BASE_URL", "OPENAI_API_KEY"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            processEnvironmentValue(name).map { (name, $0) }
        })
    }

    private func processEnvironmentValue(_ name: String) -> String? {
        guard alive else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 262_144
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 8192 else { return nil }
        var offset = 4
        while offset < size && bytes[offset] != 0 { offset += 1 }
        while offset < size && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc {
            while offset < size && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        let prefix = Array((name + "=").utf8)
        while offset < size {
            while offset < size && bytes[offset] == 0 { offset += 1 }
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            let value = bytes[start..<offset]
            if value.starts(with: prefix), alive {
                return String(decoding: value.dropFirst(prefix.count), as: UTF8.self)
            }
        }
        return nil
    }

    /// The foreground process group of a terminal device, from the processes attached to it.
    static func foregroundGroup(device: UInt32) -> UInt64? {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = proc_listpids(UInt32(PROC_TTY_ONLY), device, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        return pids.prefix(Int(count) / MemoryLayout<pid_t>.size).lazy.compactMap { info($0) }
            .first { $0.e_tpgid > 1 }.map { UInt64($0.e_tpgid) }
    }

    static func members(of group: pid_t, maximum: Int = 262_144) -> [AgentProcess] {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard bytes > 0, bytes < 1_048_576 else { return [] }
        var pids = [pid_t](repeating: 0, count: min(max(1, maximum), Int(bytes) / MemoryLayout<pid_t>.size + 32))
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count) / MemoryLayout<pid_t>.size).compactMap(capture).filter { $0.owns(foreground: UInt64(group)) }
    }
    var arguments: [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 262_144
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 8192 else { return nil }
        var offset = 4
        while offset < size && bytes[offset] != 0 { offset += 1 } // executable path
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { return nil }
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            args.append(String(decoding: bytes[start..<offset], as: UTF8.self)); offset += 1
        }
        return args
    }
    struct OpenFile {
        let path: String
        let inode: UInt64
        let device: UInt32
        func prefix(limit: Int) -> Data? {
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  UInt64(st.st_ino) == inode, UInt32(bitPattern: st.st_dev) == device else { return nil }
            var bytes = [UInt8](repeating: 0, count: limit)
            let count = Darwin.read(fd, &bytes, bytes.count)
            return count >= 0 ? Data(bytes.prefix(count)) : nil
        }
    }
    var openFiles: [OpenFile]? {
        guard alive else { return nil }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0, bytes < 4_194_304 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 32)
        let count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard count > 0 else { return nil }
        return fds.prefix(Int(count) / MemoryLayout<proc_fdinfo>.size).compactMap { fd in
            guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            return OpenFile(path: path, inode: info.pvip.vip_vi.vi_stat.vst_ino, device: info.pvip.vip_vi.vi_stat.vst_dev)
        }
    }
}
