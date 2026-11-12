import CryptoKit
import Foundation
import Security

/// All blocking work stays off the UI actor. Only macOS tools and frameworks are used.
actor UpdateInstaller {
    struct Context: Codable, Sendable {
        let target: URL
        let version: String
        let build: String
        let identities: [UpdateIdentity]
    }
    struct Progress: Equatable, Sendable {
        let received: Int64
        /// Zero when the server does not say.
        let expected: Int64
    }
    /// What `prepare` is doing: downloading, then checking the checksum, copying the app out and verifying it.
    enum Step: Equatable, Sendable {
        case downloading(Progress)
        case verifying
    }
    struct Prepared: Sendable {
        let context: Context
        let release: UpdateRelease
        let directory: URL
        var app: URL { directory.appendingPathComponent("Dispatch.app") }
    }

    func context() throws -> Context {
        let resolved = System.resolve(System.bundle)
        return try System.observe("update.context", System.bundle.path) {
            let target = System.bundle
            let files = FileManager.default
            guard target.pathExtension == "app", target == resolved,
                  !target.path.contains("/AppTranslocation/"), !target.path.hasPrefix("/Volumes/"),
                  files.isWritableFile(atPath: target.path), files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw UpdateFailure("Move Dispatch to a writable Applications folder before updating.")
            }
            // Bundle caches Info.plist by path. Read it afresh to notice a Homebrew replacement during download.
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
            var code: SecStaticCode?, information: CFDictionary?
            guard SecStaticCodeCreateWithPath(target as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let values = information as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
                  let identifier = info["CFBundleIdentifier"] as? String else {
                throw UpdateFailure("Automatic updates require a Developer ID signed release of Dispatch.")
            }
            var identities = [UpdateIdentity(team: team, bundle: identifier)]
            let currentRequirement = try UpdateIdentity.requirement(identities)
            var currentRule: SecRequirement?
            guard SecRequirementCreateWithString(currentRequirement as CFString, [], &currentRule) == errSecSuccess,
                  let currentRule, SecStaticCodeCheckValidity(code, [], currentRule) == errSecSuccess else {
                throw UpdateFailure("Automatic updates require a valid Developer ID signed release of Dispatch.")
            }
            if let additional = info["DispatchUpdateTrustedIdentities"] {
                guard let entries = additional as? [[String: String]], entries.allSatisfy({ $0["team"] != nil && $0["bundle"] != nil }) else {
                    throw UpdateFailure("The app’s trusted update identities are invalid.")
                }
                identities += entries.map { UpdateIdentity(team: $0["team"]!, bundle: $0["bundle"]!) }
            }
            _ = try UpdateIdentity.requirement(identities)
            guard let version = info["CFBundleShortVersionString"] as? String,
                  let build = info["CFBundleVersion"] as? String else {
                throw UpdateFailure("The installed app has no version number.")
            }
            return Context(target: target, version: version, build: build, identities: identities)
        }
    }

    /// Off the actor: the request must not wait behind `context()`'s signature check, which runs meanwhile.
    nonisolated func latest() async throws -> UpdateRelease {
        let file = System.temporary.appendingPathComponent("dispatch-update-" + System.uuid().uuidString)
        defer { try? System.remove(file) }
        try await System.updateDownload(UpdateRelease.feed, to: file, limit: 64 * 1024)
        return try UpdateRelease(cask: String(decoding: System.read(file), as: UTF8.self))
    }

    /// The release's notes (`UpdateNotes`), from GitHub's API; off the actor, beside the download.
    nonisolated func notes(_ release: UpdateRelease) async throws -> UpdateNotes {
        let file = System.temporary.appendingPathComponent("dispatch-update-notes-" + System.uuid().uuidString)
        defer { try? System.remove(file) }
        try await System.updateDownload(UpdateNotes.api(release.version), to: file, limit: UpdateNotes.sizeLimit)
        return try UpdateNotes(version: release.version, release: System.read(file))
    }

    func prepare(_ release: UpdateRelease, context: Context, step: @escaping @Sendable (Step) -> Void = { _ in }) async throws -> Prepared {
        guard try UpdateRelease.compare(release.version, context.version) == .orderedDescending else {
            throw UpdateFailure("This update is not newer than the installed app.")
        }
        let directory = context.target.deletingLastPathComponent().appendingPathComponent(".Dispatch-update-" + System.uuid().uuidString)
        let prepared = Prepared(context: context, release: release, directory: directory)
        let disk = directory.appendingPathComponent("update.dmg"), mount = directory.appendingPathComponent("mount")
        try System.updateDirectory(directory)
        var mounting = false
        do {
            try await System.updateDownload(release.url, to: disk, limit: 512 * 1024 * 1024) { step(.downloading($0)) }
            step(.verifying)
            guard try System.updateDigest(disk) == release.sha256 else { throw UpdateFailure("The update’s checksum does not match Homebrew’s release.") }
            try Task.checkCancellation()
            try System.directory(mount)
            mounting = true
            try await command("/usr/bin/hdiutil", ["attach", disk.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path])
            try await command("/usr/bin/ditto", [mount.appendingPathComponent("Dispatch.app").path, prepared.app.path])
            guard await detach(mount) else { throw UpdateFailure("Could not unmount the update disk image. Eject it in Finder and try again.") }
            mounting = false
            try System.remove(disk)
            try await validate(prepared)
            try Task.checkCancellation()
            return prepared
        } catch {
            // Never traverse a still-mounted image during cleanup.
            let unmounted = mounting ? await detach(mount) : true
            if unmounted { try? System.remove(directory) }
            throw error
        }
    }

    func discard(_ prepared: Prepared) { try? System.remove(prepared.directory) }

    /// Folders older than this beside the app are an interrupted update's: a download, its staged app, or the backup an
    /// interrupted relaunch kept. Younger ones may be another running copy's download (at most `updateDownload`'s six
    /// hours) or a relaunch still finishing.
    static let leftoverAge: TimeInterval = 24 * 60 * 60

    /// Removes interrupted updates' folders beside the app, ejecting a disk image still mounted in one first; a folder
    /// whose image will not eject stays.
    func sweep(in parent: URL = System.bundle.deletingLastPathComponent()) async {
        guard let names = try? System.list(parent) else { return }
        for name in names where name.hasPrefix(".Dispatch-update-") {
            let directory = parent.appendingPathComponent(name)
            guard let modified = System.updateModified(directory),
                  System.date().timeIntervalSince(modified) > Self.leftoverAge else { continue }
            let mount = directory.appendingPathComponent("mount")
            if System.updateMounted(mount), await !detach(mount) { continue }
            try? System.remove(directory)
        }
    }

    private func detach(_ mount: URL) async -> Bool {
        // Cancellation must not leave a disk image mounted. This task belongs to cleanup, not the cancelled download.
        await Task.detached {
            let result = try? await SSHCommand.run(executable: "/usr/bin/hdiutil", arguments: ["detach", mount.path], timeout: 30)
            if result?.status != 0 {
                let forced = try? await SSHCommand.run(executable: "/usr/bin/hdiutil", arguments: ["detach", "-force", mount.path], timeout: 30)
                return forced?.status == 0
            }
            return true
        }.value
    }

    private func command(_ executable: String, _ arguments: [String]) async throws {
        let result = try await SSHCommand.run(executable: executable, arguments: arguments, timeout: 120)
        guard result.status == 0 else { throw UpdateFailure("Could not prepare the update (\(URL(fileURLWithPath: executable).lastPathComponent), status \(result.status)).") }
    }

    private func validate(_ prepared: Prepared) async throws {
        try System.updateValidate(prepared)
        // Gatekeeper verifies notarization too. The ticket is stapled to the release app; never clear quarantine.
        try await command("/usr/sbin/spctl", ["--assess", "--type", "execute", prepared.app.path])
        #if arch(arm64)
        try await command("/usr/bin/lipo", ["-verify_arch", "arm64", prepared.app.appendingPathComponent("Contents/MacOS/Dispatch").path])
        #else
        throw UpdateFailure("The published update requires an Apple silicon Mac.")
        #endif
    }

    /// Called only after normal quit confirmation and runtime cleanup. Both bundles are on the same volume:
    /// rename's atomic exchange always leaves a complete app at the launch path, even if power is lost.
    func install(_ prepared: Prepared) async throws {
        let current = try context()
        guard current.target == prepared.context.target, current.version == prepared.context.version,
              current.build == prepared.context.build, current.identities == prepared.context.identities else {
            throw UpdateFailure("Dispatch changed on disk while the update was downloading. Check for updates again.")
        }
        try await validate(prepared)
        try System.updateExchange(current.target, prepared.app)
        do { try System.updateRelaunch(current.target, cleanup: prepared.directory) }
        catch {
            try System.updateExchange(current.target, prepared.app)
            throw error
        }
    }
}

extension System {
    /// A folder's last change, nil when it is not a folder.
    static func updateModified(_ url: URL) -> Date? {
        try? observe("update.modified", url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true, let date = values.contentModificationDate else {
                throw UpdateFailure("Not a folder.")
            }
            return date
        }
    }

    /// Whether a volume is mounted at `url`: a different device than its parent folder.
    static func updateMounted(_ url: URL) -> Bool {
        (try? observe("update.mounted", url.path) {
            var mount = stat(), parent = stat()
            guard lstat(url.path, &mount) == 0, lstat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
            return mount.st_dev != parent.st_dev
        }) ?? false
    }

    static func updateDirectory(_ url: URL) throws {
        _ = try act("update.directory", url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return true
        }
    }

    static func updateDigest(_ url: URL) throws -> String {
        try observe("update.digest", url.path) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func updateValidate(_ prepared: UpdateInstaller.Prepared) throws {
        let requirement = try UpdateIdentity.requirement(prepared.context.identities)
        let resolved = resolve(prepared.app)
        _ = try observe("update.validate", [prepared.app.path, requirement, prepared.release.version]) {
            let app = prepared.app
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
            guard app == resolved,
                  let identifier = info["CFBundleIdentifier"] as? String, prepared.context.identities.contains(where: { $0.bundle == identifier }),
                  info["CFBundleShortVersionString"] as? String == prepared.release.version,
                  let minimum = info["LSMinimumSystemVersion"] as? String,
                  let parts = UpdateRelease.components(minimum) else { throw UpdateFailure("The downloaded app has invalid release information.") }
            let os = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(os) else { throw UpdateFailure("This update requires macOS \(minimum) or later.") }
            var code: SecStaticCode?, rule: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
                  SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code, let rule,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), rule) == errSecSuccess else {
                throw UpdateFailure("The downloaded app’s signature is invalid or its signing identity is not trusted.")
            }
            return true
        }
    }

    static func updateExchange(_ installed: URL, _ staged: URL) throws {
        _ = try act("update.exchange", [installed.path, staged.path]) {
            guard renamex_np(installed.path, staged.path, UInt32(RENAME_SWAP)) == 0 else {
                throw UpdateFailure("Could not replace Dispatch: " + String(cString: strerror(errno)))
            }
            return true
        }
    }

    /// The tiny launcher has no installer authority: Swift already validated and atomically exchanged the apps.
    /// Paths are positional arguments, never shell source. An unsuccessful launch retains the previous bundle.
    static let updateRelaunchScript = #"""
    count=0
    while /bin/kill -0 "$1" 2>/dev/null; do
        count=$((count + 1))
        [ "$count" -lt 120 ] || exit 1
        /bin/sleep 1
    done
    /usr/bin/open -n "$2" && /bin/rm -rf "$3"
    """#

    static func updateRelaunch(_ app: URL, cleanup: URL) throws {
        let parent = String(pid)
        _ = try act("update.relaunch", [app.path, cleanup.path]) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", updateRelaunchScript, "dispatch-update", parent, app.path, cleanup.path]
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return true
        }
    }
}
