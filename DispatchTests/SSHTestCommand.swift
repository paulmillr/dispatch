import Foundation
import Darwin
@testable import DispatchApp

/// Test setup/cleanup uses the authenticated ordinary SSH transport. It never
/// grants arbitrary execution to the helper or opens another authenticated link.
enum SSHTestCommand {
    static func run(master: SSHMaster, argv: [String], input: Data = Data()) async throws -> SSHCommand.Result {
        try await SSHCommand.run(executable: master.executable,
            arguments: master.arguments(command: argv.map(HerdrLaunch.quote).joined(separator: " ")), input: input)
    }

    /// The production helper intentionally cannot stop an entire herdr server.
    /// A disposable fixture stops its own server through its exact private socket.
    static func stopHerdr(master: SSHMaster, socket: String) async throws {
        let stop = """
        import json, os, socket, struct, sys
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3)
            client.connect(sys.argv[1])
            _, uid, _ = struct.unpack('3i', client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            assert uid == os.getuid()
            client.sendall(json.dumps({'id':'cleanup','method':'server.stop','params':{}}).encode()+b'\\n')
            reply = json.loads(client.makefile('rb').readline(65536))
            assert reply.get('id') == 'cleanup' and 'error' not in reply, reply
        """
        let result = try await run(master: master, argv: ["/usr/bin/python3", "-c", stop, socket])
        guard result.status == 0 else { throw HerdrFailure("Cannot stop the herdr fixture: " + String(decoding: result.output, as: UTF8.self)) }
    }
}

/// A Linux model-fixture process owned by its test, with a separate ordinary
/// master channel. PID/start-time checks prevent cleanup from killing a reused
/// PID. No remote helper stream or production execution endpoint is involved.
@MainActor
final class SSHTestDaemon {
    private let master: SSHMaster
    private let process = Process()
    private var output: URL?
    private let pidFile: String
    private var log: FileHandle?

    init(master: SSHMaster, argv: [String], pidFile: String) throws {
        self.master = master; self.pidFile = pidFile
        let launch = """
        import json, os, pathlib, sys
        os.umask(0o077)
        def started(): return pathlib.Path('/proc/self/stat').read_text().rsplit(') ', 1)[1].split()[19]
        pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':os.getpid(),'start':started()}))
        os.execv(sys.argv[2], sys.argv[2:])
        """
        process.executableURL = URL(fileURLWithPath: master.executable)
        process.arguments = master.arguments(command: (["/usr/bin/python3", "-c", launch, pidFile] + argv).map(HerdrLaunch.quote).joined(separator: " "))
        process.standardInput = FileHandle.nullDevice
        _ = try AppReplay.query(kind: "fixture.launch", input: JSONEncoder().encode(AppReplay.Launch(process))) {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-fixture-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
            let log = try FileHandle(forWritingTo: output)
            self.output = output; self.log = log
            process.standardOutput = log; process.standardError = log
            do { try process.run() }
            catch { try? log.close(); try? FileManager.default.removeItem(at: output); throw error }
            return Data()
        }
    }

    func waitUntilReady(marker: String = "Local Codex endpoint:") async throws {
        _ = try await AppReplay.run(kind: "fixture.ready", input: JSONEncoder().encode(["pidFile": pidFile, "marker": marker])) {
            guard let output = self.output else { throw HerdrFailure("Fixture output is unavailable") }
            try await TestSupport.eventually(timeout: .seconds(10)) {
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw HerdrFailure("Remote model fixture output exceeded its limit") }
                let text = try String(contentsOf: output, encoding: .utf8)
                if text.contains(marker) { return true }
                guard self.process.isRunning else { throw HerdrFailure("Remote model fixture exited: " + text) }
                return false
            }
            return Data()
        }
    }

    func stop() async {
        let terminate = """
        import json, os, pathlib, signal, sys
        path = pathlib.Path(sys.argv[1])
        if path.exists():
            value = json.loads(path.read_text())
            try:
                current = pathlib.Path('/proc/' + str(value['pid']) + '/stat').read_text().rsplit(') ', 1)[1].split()[19]
                if current == value['start']: os.kill(value['pid'], signal.SIGTERM)
            except FileNotFoundError: pass
            path.unlink(missing_ok=True)
        """
        _ = try? await SSHTestCommand.run(master: master, argv: ["/usr/bin/python3", "-c", terminate, pidFile])
        do {
            _ = try await AppReplay.run(kind: "fixture.stop", input: JSONEncoder().encode(pidFile)) {
                if process.isRunning { process.terminate() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? log?.close(); if let output { try? FileManager.default.removeItem(at: output) }
                return Data()
            }
        } catch { AppReplay.fail(error) }
    }
}
