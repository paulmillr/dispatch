#if DEBUG
import AppKit
import Foundation

/// Debug builds only: the updater against the real feed, from a build playing an older release
/// (`DISPATCH_UPDATE_DEMO=0.1.7`), to try the update sheet end to end on a Mac. It reads the real cask and the release's
/// notes, downloads the real DMG and checks it as a release copy does (the cask's checksum, the published release's
/// signing identity, Gatekeeper, the architecture), beside a stand-in app in "Update demo" next to the running build.
/// Restart and install moves the verified app into that folder in place of the stand-in and shows it in Finder; the
/// running build is never replaced or relaunched.
enum UpdateDemo {
    /// The published release's signer (`codesign -dv` of 0.1.8's app), which a Debug build's own signature is not.
    static let identity = UpdateIdentity(team: "TKHPX2BB85", bundle: "yachts.dispatch.pilot.app")

    /// The version the demo plays, from `DISPATCH_UPDATE_DEMO`; nil runs the real updater.
    static var version: String? {
        guard let value = System.environment("DISPATCH_UPDATE_DEMO"), UpdateRelease.components(value) != nil else { return nil }
        return value
    }

    static func operations(_ installer: UpdateInstaller = UpdateInstaller()) -> AppUpdater.Operations? {
        guard let version else { return nil }
        let folder = System.bundle.deletingLastPathComponent().appendingPathComponent("Update demo")
        let target = folder.appendingPathComponent("Dispatch.app")
        let context = UpdateInstaller.Context(target: target, version: version, build: "0", identities: [identity])
        var operations = AppUpdater.Operations.live(installer)
        operations.context = {
            // The stand-in the download goes beside (the real updater's folder is the installed app's).
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return context
        }
        operations.installedVersion = { version }
        operations.install = { prepared in
            try await MainActor.run {
                let files = FileManager.default
                try? files.removeItem(at: target)
                try files.moveItem(at: prepared.app, to: target)
                try? files.removeItem(at: prepared.directory)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
        return operations
    }
}
#endif
