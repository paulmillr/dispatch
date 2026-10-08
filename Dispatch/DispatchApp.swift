import AppKit

@main
enum DispatchApp {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--ssh-launch" {
            exit(SSHLauncherCommand.run(Array(CommandLine.arguments.dropFirst(2))))
        }
        Home.isolate()
        AppFont.register()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
