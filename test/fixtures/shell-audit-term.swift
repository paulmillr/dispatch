// Minimal dependencies for compiling the production Launch.swift in isolation.
// No shell parsing, environment injection, or wrapper logic is duplicated here.
public let ghosttyVersion = "audit"
public struct Config {
    public var term = "xterm-256color"
    public struct Integration {
        public var cursor = false, path = false, sshEnv = false
        public var sshTerminfo = false, sudo = false, title = false
    }
    public var shellIntegration = Integration()
    public init() {}
    public static func home(_ env: [String: String]) -> String? { env["HOME"] }
}
