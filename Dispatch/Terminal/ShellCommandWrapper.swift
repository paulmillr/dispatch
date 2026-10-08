import Foundation

/// One command definition for PATH shims, interactive shell functions, and
/// exported bash functions used by persistent native terminal backends:
/// `name args...` runs `$variable arguments... args...`.
struct ShellCommandWrapper: Equatable, Sendable {
    let name: String
    let arguments: [String]
    /// Environment variable holding the program that serves the command.
    let variable: String

    /// The app's own launcher; agent programs come from the helper's list (`helper(program:key:)`).
    static let ssh = app("ssh")
    static let allCases = [ssh]
    private static func app(_ name: String) -> Self {
        Self(name: name, arguments: ["--\(name)-launch"], variable: "DISPATCH_EXECUTABLE")
    }
    /// A helper-listed program, run by the helper's typed launcher.
    static func helper(program: String, key: String) -> Self {
        Self(name: program, arguments: ["launch", key], variable: "DISPATCH_HELPER4_EXECUTABLE")
    }

    var rawValue: String { name }
    init?(rawValue: String) {
        guard let wrapper = Self.allCases.first(where: { $0.name == rawValue }) else { return nil }
        self = wrapper
    }
    private init(name: String, arguments: [String], variable: String) {
        self.name = name; self.arguments = arguments; self.variable = variable
    }

    private var argument: String { arguments.map(HerdrLaunch.quote).joined(separator: " ") }
    private var body: String { "command \"$\(variable)\" \(argument) \"$@\";" }
    var bashVariable: String { "BASH_FUNC_\(name)%%" }
    var bashFunction: String { "() { \(body) }" }

    func definition(fish: Bool = false) -> String {
        let definition = fish
            ? "function \(name)\n command $\(variable) \(argument) $argv\nend\n"
            : "function \(name) { \(body) }\n"
        return Self.preservingUserCommand(name, definition: definition, fish: fish)
    }

    static func preservingUserCommand(_ name: String, definition: String, fish: Bool) -> String {
        if fish { return "if not functions -q \(name)\n\(definition)end\n" }
        return "if ! typeset -f \(name) >/dev/null 2>&1 && ! alias \(name) >/dev/null 2>&1; then\n\(definition)fi\n"
    }

    /// Resolve the user's PATH, including empty entries, without re-entering
    /// current or retired Dispatch shims retained by persistent shells.
    func executable(in environment: [String: String]) -> String? {
        let shim = environment["DISPATCH_HERDR_DIRECTORY"].map {
            URL(fileURLWithPath: $0 + "/bin/" + name).resolvingSymlinksInPath().path
        }
        return (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { URL(fileURLWithPath: ($0.isEmpty ? "." : String($0)) + "/" + name).path }
            .first { path in
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                var directory: ObjCBool = false
                guard resolved != shim, FileManager.default.fileExists(atPath: path, isDirectory: &directory),
                      !directory.boolValue, FileManager.default.isExecutableFile(atPath: path) else { return false }
                if let file = FileHandle(forReadingAtPath: path) {
                    defer { try? file.close() }
                    if let bytes = try? file.read(upToCount: 1024), String(decoding: bytes, as: UTF8.self).contains(arguments.joined(separator: " ")) { return false }
                }
                return true
            }
    }

    func shim(executable: String) -> String {
        "#!/bin/sh\nexec \(HerdrLaunch.quote(executable)) \(argument) \"$@\"\n"
    }
}
