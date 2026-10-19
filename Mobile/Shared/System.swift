import Foundation

/// The iPhone app's stand-in for the Mac's `System` (Dispatch/Helper/System.swift, AppKit only): the shared sources
/// ask it for ids, the time and the app's folders. The Mac's journal (capture and replay of everything the app does
/// outside itself) has no iOS counterpart, so every answer here is live. The planned `SystemProvider` seam
/// (docs/ios.md) replaces this file.
enum System {
    /// The iPhone app has no test home or test tools of its own: unit tests run in the simulator's app container.
    static let testing = false

    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let temporary = FileManager.default.temporaryDirectory
    static let bundle = Bundle.main.bundleURL
    static let executable = Bundle.main.executableURL ?? Bundle.main.bundleURL
    static let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL

    static var inherited: [String: String] { ProcessInfo.processInfo.environment }
    static func environment(_ name: String) -> String? { inherited[name] }

    /// Every id the shared sources make; the Mac's replay makes the same ones per site, here they are always new.
    static func uuid(for key: String = "", _ file: String = #fileID, _ function: String = #function) -> UUID { UUID() }

    static func date() -> Date { Date() }

    /// The Mac's replay reads a test's polling checks differently; nothing polls a journal here.
    static var polling: Bool { false }
}

/// Where the iPhone app's own files live, as `Home` (Dispatch/Settings.swift) says for the Mac app.
enum Home {
    static var support: URL { System.home.appendingPathComponent("Library/Application Support/Dispatch") }
}
