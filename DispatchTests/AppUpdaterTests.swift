import AppKit
import os
import Security
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class AppUpdaterTests: XCTestCase {
    private let cask = #"""
    cask "dispatch" do
      version "0.2.0"
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      url "https://github.com/paulmillr/dispatch/releases/download/#{version}/Dispatch-#{version}.dmg"
    end
    """#
    private let context = UpdateInstaller.Context(target: URL(fileURLWithPath: "/Applications/Dispatch.app"), version: "0.1.9", build: "20260101.1000",
        identities: [UpdateIdentity(team: "ABC123DE45", bundle: "yachts.dispatch.pilot.app")])

    private func operations(_ release: UpdateRelease) -> AppUpdater.Operations {
        .init(context: { self.context }, latest: { release },
              prepare: { release, context, _ in .init(context: context, release: release, directory: URL(fileURLWithPath: "/fictional/update")) },
              discard: { _ in }, install: { _ in })
    }

    func testOptInDefaultsAndPersistence() throws {
        XCTAssertNil(Preferences().automaticUpdates)
        XCTAssertNil(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).automaticUpdates)
        for choice in [true, false] {
            var settings = Preferences(); settings.automaticUpdates = choice
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(settings)).automaticUpdates, choice)
        }
    }

    /// The setup sheet (LocalAgentsConsent) offers updates checked, yet saves nothing, so makes no request, until
    /// Let's roll! (Continue alone); Skip leaves the question unanswered. A fresh install pages Chat, Tabs, then the
    /// choices: Return goes on, Escape skips to the choices and there asks later. Existing installations get the
    /// updates section alone.
    func testSetupSheetOffersUpdatesCheckedAndSavesOnlyOnContinue() async throws {
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        for agents in [true, false] {
            let directory = System.temporary.appendingPathComponent("update-onboarding-" + System.uuid().uuidString)
            defer { try? System.remove(directory) }
            let settings = SettingsStore(file: directory.appendingPathComponent("settings.json"))
            let sheet = LocalAgentsConsent.Sheet(chat: chat, settings: settings, agents: agents)
            defer { sheet.close() }
            XCTAssertEqual(sheet.updates.state, .on)
            XCTAssertNil(settings.values.automaticUpdates, "Showing the sheet answers nothing")
            let escape = TerminalTestSupport.keyEvent(53, "\u{1b}", in: sheet)
            let enter = TerminalTestSupport.keyEvent(36, "\r", in: sheet)
            if agents {
                let height = sheet.frame.height
                for (page, name) in ["setup-chat", "setup-tabs", "setup-prefs"].enumerated() {
                    XCTAssertEqual(sheet.page, page)
                    XCTAssertEqual(sheet.frame.height, height, "Every page is the same height")
                    _ = try PresentationTestSupport.render(XCTUnwrap(sheet.contentView), named: name, in: "update-audit")
                    if page < 2 { XCTAssertTrue(sheet.performKeyEquivalent(with: enter)) }
                }
                XCTAssertNil(settings.values.automaticUpdates, "Next saves nothing")
                let fresh = LocalAgentsConsent.Sheet(chat: chat, settings: settings, agents: true)
                defer { fresh.close() }
                XCTAssertTrue(fresh.performKeyEquivalent(with: TerminalTestSupport.keyEvent(53, "\u{1b}", in: fresh)))
                XCTAssertEqual(fresh.page, 2, "Skip goes to the choices")
                XCTAssertNil(settings.values.automaticUpdates, "Skip saves nothing")
            } else {
                _ = try PresentationTestSupport.render(XCTUnwrap(sheet.contentView), named: "setup-updates", in: "update-audit")
            }
            XCTAssertTrue(sheet.performKeyEquivalent(with: escape))
            XCTAssertNil(settings.values.automaticUpdates, "Ask later saves nothing")
            if agents { continue }
            sheet.updates.performClick(nil)
            XCTAssertEqual(sheet.updates.state, .off)
            sheet.updates.performClick(nil)
            XCTAssertTrue(sheet.performKeyEquivalent(with: TerminalTestSupport.keyEvent(36, "\r", in: sheet)))
            XCTAssertEqual(settings.values.automaticUpdates, true)
        }
    }

    /// The setup sheet shows once per Mac: not after it was shown (answered or skipped, by this build or another reading
    /// the same settings), not once updates are answered, and never over settings that could not be read.
    func testSetupSheetShowsOncePerMac() throws {
        let directory = System.temporary.appendingPathComponent("update-once-" + System.uuid().uuidString)
        defer { try? System.remove(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let settings = SettingsStore(file: file)
        XCTAssertTrue(LocalAgentsConsent.shouldAsk(settings), "A fresh install asks")
        LocalAgentsConsent.markShown(settings)
        XCTAssertFalse(LocalAgentsConsent.shouldAsk(settings))
        let other = SettingsStore(file: file)
        XCTAssertFalse(LocalAgentsConsent.shouldAsk(other), "Another build reading the same settings")
        XCTAssertNil(other.values.automaticUpdates, "Shown is not answered: no automatic requests")
        let answered = SettingsStore(file: directory.appendingPathComponent("answered.json"))
        var values = answered.values
        values.automaticUpdates = false
        try answered.save(values)
        XCTAssertFalse(LocalAgentsConsent.shouldAsk(answered), "An answer from before the flag counts as shown")
        let broken = directory.appendingPathComponent("broken.json")
        try PrivateFile.write(Data("{".utf8), to: broken)
        XCTAssertFalse(LocalAgentsConsent.shouldAsk(SettingsStore(file: broken)), "Unreadable settings are never saved over")
        XCTAssertEqual(try System.read(broken), Data("{".utf8))
    }

    /// Settings › Troubleshooting › Reset deletes Dispatch's data (settings with the setup sheet's record, spaces,
    /// drafts…), its diagnostics and this build's defaults; the dictation models, your color schemes and another
    /// build's defaults stay.
    func testResetDeletesDataButDictationModels() throws {
        let root = System.temporary.appendingPathComponent("reset-" + System.uuid().uuidString)
        defer { try? System.remove(root) }
        let support = root.appendingPathComponent("Dispatch"), home = root.appendingPathComponent("home")
        for name in ["Local", "Whisper", "Parakeet"] { try System.directory(support.appendingPathComponent(name)) }
        for name in ["Local/settings.json", "host-session.json", "drafts.json", "Whisper/ggml-base.bin", "Parakeet/model.bin"] {
            try System.write(Data("x".utf8), to: support.appendingPathComponent(name))
        }
        let targets = DispatchRemoval.resetTargets(support: support, home: home)
        XCTAssertEqual(targets.map(\.path), ["Local", "drafts.json", "host-session.json"].map { support.appendingPathComponent($0).path }
            + [home.appendingPathComponent("Library/Logs/Dispatch/Diagnostics").path])
        XCTAssertFalse(targets.contains(CustomThemes.directory), "Your color schemes are kept")
        let suite = "ResetTests-\(System.uuid())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let otherSuite = suite + "-other", other = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { other.removePersistentDomain(forName: otherSuite) }
        defaults.set("yes", forKey: LocalAgentsConsent.key)
        other.set("yes", forKey: LocalAgentsConsent.key)
        // The scratch folder's entries only: the real color schemes and logs are never touched here.
        XCTAssertEqual(DispatchRemoval.resetData(targets: Array(targets.prefix(3)), defaults: defaults, domain: suite), [])
        XCTAssertEqual(try System.list(support).sorted(), ["Parakeet", "Whisper"])
        XCTAssertNil(defaults.string(forKey: LocalAgentsConsent.key), "This build's defaults are gone")
        XCTAssertEqual(other.string(forKey: LocalAgentsConsent.key), "yes", "Another build's stay")
        XCTAssertTrue(LocalAgentsConsent.shouldAsk(SettingsStore(file: support.appendingPathComponent("Local/settings.json"))),
                      "The setup sheet shows again")
    }

    func testSettingsShowUpdateControls() async throws {
        let directory = System.temporary.appendingPathComponent("update-settings-" + System.uuid().uuidString)
        defer { try? System.remove(directory) }
        let updater = AppUpdater(operations: operations(try UpdateRelease(cask: cask)), defaults: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let content = NSHostingView(rootView: SettingsView(store: SettingsStore(file: directory.appendingPathComponent("settings.json")), workspace: Workspace(), updater: updater))
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        _ = try PresentationTestSupport.render(content, named: "update-settings", in: "update-audit")
        XCTAssertFalse(updater.automatic)
        await updater.stop()
    }

    func testCaskParsingAndNumericVersions() throws {
        let release = try UpdateRelease(cask: cask)
        XCTAssertEqual(release.url.absoluteString, "https://github.com/paulmillr/dispatch/releases/download/0.2.0/Dispatch-0.2.0.dmg")
        XCTAssertEqual(try UpdateRelease.compare("0.10.0", "0.9.9"), .orderedDescending)
        XCTAssertEqual(try UpdateRelease.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(try UpdateRelease.compare("1.0.0", "1.0.1"), .orderedAscending)
        for version in ["", "v1.0", "1.0-beta", "1..0", "1.0/../../x", "99999999999999999999999", "١.٠"] {
            XCTAssertThrowsError(try UpdateRelease(cask: cask.replacingOccurrences(of: "0.2.0", with: version)))
        }
    }

    func testFeedRejectsAmbiguousChecksumAndForeignAssets() throws {
        for altered in [cask + "\nversion \"0.3.0\"", cask.replacingOccurrences(of: "aaaaaaaa", with: "gggggggg"),
                        cask.replacingOccurrences(of: "github.com", with: "example.invalid"),
                        cask.replacingOccurrences(of: "Dispatch-#{version}.dmg", with: "malware.dmg")] {
            XCTAssertThrowsError(try UpdateRelease(cask: altered))
        }
        for address in ["http://github.com/release", "https://github.com.example.invalid/release", "https://user@github.com/release", "https://github.com:444/release", "file:///tmp/app"] {
            XCTAssertFalse(UpdateDownloadDelegate.allowed(try XCTUnwrap(URL(string: address))))
        }
        for address in ["https://githubusercontent.com/release", "https://evilgithubusercontent.com/release",
                        "https://release-assets.githubusercontent.com.example.invalid/release", "https://gist.github.com.example.invalid/x"] {
            XCTAssertFalse(UpdateDownloadDelegate.allowed(try XCTUnwrap(URL(string: address))), address)
        }
        // GitHub has renamed its asset host before; any of its content subdomains keeps installed copies updating.
        for address in ["https://release-assets.githubusercontent.com/release", "https://objects.githubusercontent.com/release",
                        "https://raw.githubusercontent.com/cask", "https://assets-next.githubusercontent.com/release", "https://github.com/release"] {
            XCTAssertTrue(UpdateDownloadDelegate.allowed(try XCTUnwrap(URL(string: address))), address)
        }
    }

    /// Restore All Defaults resets every setting, host colors and the space order included, but never this Mac's
    /// answers: automatic updates stay as chosen (an update stays downloaded) and the setup sheet doesn't come back.
    func testRestoreAllDefaultsKeepsUpdatesAndTheSetupSheetsRecord() {
        var current = Preferences()
        current.automaticUpdates = true
        current.setupShown = true
        current.fontSize = 18
        current.spaceOrder = .tree
        current.hostColors = ["build.example": .red]
        let restored = SettingsView.restoredDefaults(keeping: current)
        XCTAssertEqual(restored.automaticUpdates, true)
        XCTAssertTrue(restored.setupShown)
        XCTAssertEqual(restored.fontSize, Preferences().fontSize)
        XCTAssertEqual(restored.spaceOrder, Preferences().spaceOrder)
        XCTAssertEqual(restored.hostColors, [:])
    }

    /// A copy that can't update itself (not writable, not a signed release) still checks the feed: it says a newer
    /// release is out, offering its download, or that it is up to date.
    func testACopyThatCannotUpdateItselfStillReportsNewerReleases() async throws {
        let release = try UpdateRelease(cask: cask)
        var ops = operations(release)
        ops.context = { throw UpdateFailure("Move Dispatch to a writable Applications folder before updating.") }
        ops.installedVersion = { "0.1.0" }
        let older = AppUpdater(operations: ops, defaults: nil)
        older.check()
        try await TestSupport.eventually { older.state != .checking }
        XCTAssertEqual(older.available?.version, release.version)
        XCTAssertTrue(older.status.hasPrefix("Dispatch \(release.version) is available"), older.status)
        await older.stop()
        ops.installedVersion = { release.version }
        let current = AppUpdater(operations: ops, defaults: nil)
        current.check()
        try await TestSupport.eventually { current.state != .checking }
        XCTAssertEqual(current.state, .upToDate)
        XCTAssertNil(current.available)
        await current.stop()
    }

    /// A network failure is retried sooner than daily and is not saved as a check, so a relaunch tries again; a
    /// failure the network did not cause (no newer version, a bad signature) counts as the day's check.
    func testNetworkFailuresAreRetriedNotSavedAsChecks() async throws {
        XCTAssertTrue(AppUpdater.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(AppUpdater.isTransient(UpdateFailure("HTTP 503", transient: true)))
        XCTAssertFalse(AppUpdater.isTransient(URLError(.cancelled)))
        XCTAssertFalse(AppUpdater.isTransient(UpdateFailure("Invalid signature")))
        XCTAssertTrue(UpdateDownloadDelegate.interrupted(URLError(.networkConnectionLost)))
        XCTAssertFalse(UpdateDownloadDelegate.interrupted(URLError(.badServerResponse)))
        XCTAssertEqual(AppUpdater.retries, [300, 1800, 7200] as [TimeInterval])

        let suite = "AppUpdaterTests-\(System.uuid())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = try UpdateRelease(cask: cask)
        var ops = operations(release)
        ops.latest = { throw URLError(.notConnectedToInternet) }
        let offline = AppUpdater(operations: ops, defaults: defaults)
        offline.check()
        try await TestSupport.eventually { offline.state != .checking }
        XCTAssertEqual(offline.state, .failed(URLError(.notConnectedToInternet).localizedDescription))
        XCTAssertTrue(offline.status.hasPrefix("Could not check for updates ("), offline.status)
        XCTAssertNil(defaults.object(forKey: "dispatchUpdateLastCheck"), "Offline is no check")
        await offline.stop()

        ops.prepare = { _, _, _ in throw UpdateFailure("Invalid signature") }
        ops.latest = { release }
        let invalid = AppUpdater(operations: ops, defaults: defaults)
        invalid.check()
        try await TestSupport.eventually { invalid.state == .failed("Invalid signature") }
        XCTAssertNotNil(defaults.object(forKey: "dispatchUpdateLastCheck"))
        await invalid.stop()
    }

    /// Turning automatic updates off stops only the daily check's work: an update started with Check for updates
    /// stays, downloading or ready.
    func testOptOutKeepsManualUpdate() async throws {
        var discarded = 0
        var ops = operations(try UpdateRelease(cask: cask))
        ops.discard = { _ in discarded += 1 }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.check()
        try await TestSupport.eventually { updater.state == .ready }
        updater.setAutomaticUpdates(true)
        updater.setAutomaticUpdates(false)
        XCTAssertEqual(updater.state, .ready)
        XCTAssertEqual(discarded, 0)
        await updater.stop()
    }

    /// A check waiting on a slow network can be cancelled too.
    func testCheckCanBeCancelled() async throws {
        var signature: CheckedContinuation<Void, Never>?
        var ops = operations(try UpdateRelease(cask: cask))
        ops.context = { await withCheckedContinuation { signature = $0 }; return self.context }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.check()
        try await TestSupport.eventually { signature != nil }
        XCTAssertTrue(updater.cancellable)
        updater.cancel()
        XCTAssertEqual(updater.state, .idle)
        signature?.resume()
        await updater.stop()
        XCTAssertEqual(updater.state, .idle, "The cancelled check changes nothing when it returns")
    }

    /// Launch removes interrupted updates' folders beside the app once they are a day old; younger ones may be a
    /// download in progress, and other files stay.
    func testSweepRemovesOldLeftoverUpdateFolders() async throws {
        let parent = System.temporary.appendingPathComponent("update-sweep-" + System.uuid().uuidString)
        defer { try? System.remove(parent) }
        let old = parent.appendingPathComponent(".Dispatch-update-old"), young = parent.appendingPathComponent(".Dispatch-update-young")
        let file = parent.appendingPathComponent(".Dispatch-update-file"), other = parent.appendingPathComponent("Other.app")
        for directory in [old, young, other] { try System.directory(directory.appendingPathComponent("Dispatch.app")) }
        try System.write(Data("x".utf8), to: file)
        let past = System.date().addingTimeInterval(-UpdateInstaller.leftoverAge - 60)
        for url in [old, file, other] { try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path) }
        await UpdateInstaller().sweep(in: parent)
        XCTAssertEqual(try System.list(parent).sorted(), [".Dispatch-update-file", ".Dispatch-update-young", "Other.app"])
    }

    func testSigningAccountTransitionRequiresExplicitTrustedPair() throws {
        let old = UpdateIdentity(team: "ABC123DE45", bundle: "yachts.dispatch.pilot.app")
        let next = UpdateIdentity(team: "FGH678JK90", bundle: "yachts.dispatch.app")
        let requirement = try UpdateIdentity.requirement([old, next])
        var compiled: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &compiled), errSecSuccess)
        XCTAssertNotNil(compiled)
        XCTAssertTrue(requirement.contains("(certificate leaf[subject.OU] = \"FGH678JK90\" and identifier \"yachts.dispatch.app\")"))
        XCTAssertFalse(try UpdateIdentity.requirement([old]).contains(next.team))
        XCTAssertThrowsError(try UpdateIdentity.requirement([]))
        XCTAssertThrowsError(try UpdateIdentity.requirement([.init(team: "ABC123DE45", bundle: "x\" or true")]))
    }

    /// Check for updates asks for the one release it finds: it downloads it at once, without the main window's prompt
    /// (Settings, where it was clicked, offers Restart and install), and opts into nothing.
    func testManualCheckDownloadsWithoutOptingInOrPrompting() async throws {
        let release = try UpdateRelease(cask: cask)
        var calls: [String] = []
        var prompts = 0
        var ops = operations(release)
        ops.latest = { calls.append("check"); return release }
        ops.prepare = { release, context, _ in calls.append("download"); return .init(context: context, release: release, directory: URL(fileURLWithPath: "/fictional/update")) }
        ops.install = { _ in calls.append("install") }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.onReady = { prompts += 1 }
        updater.setAutomaticUpdates(false)
        XCTAssertTrue(calls.isEmpty)
        updater.check()
        updater.check() // Coalesces concurrent checks.
        try await TestSupport.eventually { updater.state == .ready }
        XCTAssertEqual(calls, ["check", "download"])
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(updater.status, "Dispatch 0.2.0 is ready to install.")
        XCTAssertFalse(updater.automatic)
        await updater.stop()
    }

    /// The feed request does not wait for the installed app's signature check.
    func testFeedRequestOverlapsSignatureCheck() async throws {
        let release = try UpdateRelease(cask: cask)
        var signature: CheckedContinuation<Void, Never>?
        var requested = false
        var ops = operations(release)
        ops.context = { await withCheckedContinuation { signature = $0 }; return self.context }
        ops.latest = { requested = true; return release }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.check()
        try await TestSupport.eventually { signature != nil && requested }
        XCTAssertEqual(updater.state, .checking)
        signature?.resume()
        try await TestSupport.eventually { updater.state == .ready }
        await updater.stop()
    }

    /// Settings shows the download's size and progress, then verification, and can cancel either: the partial
    /// update is discarded, and a cancelled download's late progress changes nothing.
    func testDownloadProgressAndCancel() async throws {
        let release = try UpdateRelease(cask: cask)
        var step: (@Sendable (UpdateInstaller.Step) -> Void)?
        var pending: CheckedContinuation<UpdateInstaller.Prepared, Never>?
        var discarded = 0
        var ops = operations(release)
        ops.prepare = { _, _, report in step = report; return await withCheckedContinuation { pending = $0 } }
        ops.discard = { _ in discarded += 1 }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.check()
        try await TestSupport.eventually { pending != nil }
        XCTAssertEqual(updater.status, "Downloading Dispatch 0.2.0…")
        XCTAssertTrue(updater.cancellable)
        step?(.downloading(.init(received: 21_000_000, expected: 62_000_000)))
        try await TestSupport.eventually { updater.progress?.received == 21_000_000 }
        XCTAssertEqual(updater.status, "Downloading Dispatch 0.2.0… 21 MB of 62 MB")

        let directory = System.temporary.appendingPathComponent("update-progress-" + System.uuid().uuidString)
        defer { try? System.remove(directory) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let content = NSHostingView(rootView: SettingsView(store: SettingsStore(file: directory.appendingPathComponent("settings.json")), workspace: Workspace(), updater: updater))
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        _ = try PresentationTestSupport.render(content, named: "update-settings-downloading", in: "update-audit")

        step?(.verifying)
        try await TestSupport.eventually { updater.state == .verifying }
        XCTAssertEqual(updater.status, "Verifying Dispatch 0.2.0…")
        XCTAssertNil(updater.progress)
        step?(.downloading(.init(received: 62_000_000, expected: 62_000_000)))
        updater.cancel()
        XCTAssertEqual(updater.state, .idle)
        XCTAssertFalse(updater.busy)
        pending?.resume(returning: .init(context: context, release: release, directory: URL(fileURLWithPath: "/fictional/update")))
        try await TestSupport.eventually { discarded == 1 }
        XCTAssertEqual(updater.state, .idle)
        XCTAssertNil(updater.progress, "Late progress from the cancelled download")
        await updater.stop()
    }

    /// The download reports each whole percent once, and stops past its size limit while the file arrives.
    func testDownloadDelegateReportsPercentsAndEnforcesLimit() throws {
        let reports = OSAllocatedUnfairLock(initialState: [Int64]())
        let delegate = UpdateDownloadDelegate(limit: 1000) { progress in reports.withLock { $0.append(progress.received) } }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: try XCTUnwrap(URL(string: "https://github.com/fictional/update.dmg")))
        for received: Int64 in [1, 5, 9, 10, 15, 500, 501, 1000] {
            delegate.urlSession(session, downloadTask: task, didWriteData: 0, totalBytesWritten: received, totalBytesExpectedToWrite: 1000)
        }
        XCTAssertEqual(reports.withLock { $0 }, [1, 10, 500, 1000])
        XCTAssertEqual(task.state, .suspended)
        delegate.urlSession(session, downloadTask: task, didWriteData: 0, totalBytesWritten: 1001, totalBytesExpectedToWrite: -1)
        XCTAssertNotEqual(task.state, .suspended, "Past the limit, the download is cancelled")
        XCTAssertEqual(reports.withLock { $0 }.count, 4)
    }

    func testAutomaticDownloadWaitsForExplicitRestartAndQuit() async throws {
        var installs = 0, prompts = 0, restarts = 0
        var ops = operations(try UpdateRelease(cask: cask))
        ops.install = { _ in installs += 1 }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.onReady = { prompts += 1 }
        updater.onRestart = { restarts += 1 }
        updater.setAutomaticUpdates(true)
        try await TestSupport.eventually { updater.state == .ready }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(installs, 0)
        updater.restart()
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(installs, 0, "Normal quit confirmation and cleanup must run first")
        try await updater.installOnQuit()
        XCTAssertEqual(installs, 1)
        await updater.stop()
    }

    func testOptOutDiscardsDownloadThatFinishesAfterCancellation() async throws {
        let release = try UpdateRelease(cask: cask)
        var pending: CheckedContinuation<UpdateInstaller.Prepared, Never>?
        var discarded = 0, prompts = 0
        var ops = operations(release)
        ops.prepare = { _, _, _ in await withCheckedContinuation { pending = $0 } }
        ops.discard = { _ in discarded += 1 }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.onReady = { prompts += 1 }
        updater.setAutomaticUpdates(true)
        try await TestSupport.eventually { pending != nil }
        updater.setAutomaticUpdates(false)
        pending?.resume(returning: .init(context: context, release: release, directory: URL(fileURLWithPath: "/fictional/update")))
        try await TestSupport.eventually { discarded == 1 }
        XCTAssertEqual(updater.state, .idle)
        XCTAssertEqual(prompts, 0)
        await updater.stop()
    }

    func testFailuresAndOlderVersionsNeverInstall() async throws {
        let release = try UpdateRelease(cask: cask)
        var ops = operations(release)
        ops.prepare = { _, _, _ in throw UpdateFailure("Invalid signature") }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.check()
        try await TestSupport.eventually { updater.state == .failed("Invalid signature") }
        XCTAssertTrue(updater.status.hasPrefix("Could not download Dispatch 0.2.0 ("), updater.status)
        XCTAssertTrue(updater.status.hasSuffix("): Invalid signature"), updater.status)
        do { try await updater.installOnQuit(); XCTFail("No verified update to install") } catch {}
        await updater.stop()

        ops.context = { .init(target: self.context.target, version: "0.3.0", build: "1", identities: self.context.identities) }
        let newer = AppUpdater(operations: ops, defaults: nil)
        newer.check()
        try await TestSupport.eventually { newer.state == .upToDate }
        XCTAssertNil(newer.release)
        await newer.stop()
    }

    func testAtomicReplacementAndRollbackKeepWholeBundles() throws {
        let directory = System.temporary.appendingPathComponent("update-fixture-" + System.uuid().uuidString)
        try System.directory(directory)
        defer { try? System.remove(directory) }
        let old = directory.appendingPathComponent("Dispatch.app"), new = directory.appendingPathComponent("New.app")
        for (app, contents) in [(old, "original"), (new, "updated")] {
            try System.directory(app)
            try System.write(Data(contents.utf8), to: app.appendingPathComponent("version"))
        }
        try System.updateExchange(old, new)
        XCTAssertEqual(try System.read(old.appendingPathComponent("version")), Data("updated".utf8))
        XCTAssertEqual(try System.read(new.appendingPathComponent("version")), Data("original".utf8))
        try System.updateExchange(old, new)
        XCTAssertEqual(try System.read(old.appendingPathComponent("version")), Data("original".utf8))
        XCTAssertThrowsError(try System.updateExchange(old, directory.appendingPathComponent("missing")))
        XCTAssertEqual(try System.read(old.appendingPathComponent("version")), Data("original".utf8))
    }

    func testChecksumAndUnsignedBundleAreRejected() throws {
        let directory = System.temporary.appendingPathComponent("update-fixture-" + System.uuid().uuidString)
        try System.directory(directory)
        defer { try? System.remove(directory) }
        let file = directory.appendingPathComponent("digest")
        try System.write(Data("abc".utf8), to: file)
        XCTAssertEqual(try System.updateDigest(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let contents = directory.appendingPathComponent("Dispatch.app/Contents")
        try System.directory(contents)
        let info = ["CFBundleIdentifier": "yachts.dispatch.pilot.app", "CFBundleShortVersionString": "0.2.0", "LSMinimumSystemVersion": "14.0"]
        try System.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: contents.appendingPathComponent("Info.plist"))
        let prepared = UpdateInstaller.Prepared(context: context, release: try UpdateRelease(cask: cask), directory: directory)
        XCTAssertThrowsError(try System.updateValidate(prepared))
    }
}
