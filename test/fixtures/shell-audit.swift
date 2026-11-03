import Foundation
import Term

// Compile alongside the production wrapper generators, without the UI app.
enum System {
    static var home: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!) }
    static func resolve(_ url: URL) -> URL { url.resolvingSymlinksInPath() }
}
enum HerdrLaunch {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

@main
struct Audit {
    static func main() throws {
        if CommandLine.arguments[1] == "--launch" {
            // The production surface launch: its command, environment and whether Ghostty's integration went in
            // (what HelperWorkspace.environment reports to the helper as `integrated`).
            let env = ProcessInfo.processInfo.environment
            let machine = Launch.Machine(name: nil, home: env["HOME"], shell: CommandLine.arguments[2], quiet: true,
                                         executable: nil, host: "audit")
            let launch = try Launch(command: CommandLine.arguments[2], directory: nil, overrides: [], config: Config(),
                                    environment: env, machine: machine, resources: CommandLine.arguments[3], id: 1)
            let output: [String: Any] = ["command": launch.command, "injected": launch.integrated, "environment": launch.env]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let wrappers: [ShellCommandWrapper] = [.ssh, .helper(program: "codex", key: "codex")]
        try NativeSSHEnvironment.install(in: root, functions: wrappers)
        let env = NativeSSHEnvironment.variables(directory: root, inheriting: ProcessInfo.processInfo.environment, functions: wrappers)
        let output: [String: Any] = [
            "environment": env,
            "posix": wrappers.map { $0.definition() }.joined(),
            "fish": wrappers.map { $0.definition(fish: true) }.joined(),
            "tmuxFish": NativeSSHEnvironment.tmuxFunction(fish: true),
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
