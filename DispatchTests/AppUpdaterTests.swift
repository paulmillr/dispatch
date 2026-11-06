import AppKit
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
              prepare: { release, context in .init(context: context, release: release, directory: URL(fileURLWithPath: "/fictional/update")) },
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
    /// drafts…), your color schemes and diagnostics, and this build's defaults; the dictation models and another
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
            + [CustomThemes.directory.path, home.appendingPathComponent("Library/Logs/Dispatch/Diagnostics").path])
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
        XCTAssertTrue(UpdateDownloadDelegate.allowed(URL(string: "https://release-assets.githubusercontent.com/release")!))
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

    func testManualCheckDoesNotOptInDownloadOrInstall() async throws {
        let release = try UpdateRelease(cask: cask)
        var calls: [String] = []
        var ops = operations(release)
        ops.latest = { calls.append("check"); return release }
        ops.prepare = { _, _ in calls.append("download"); throw UpdateFailure("Unexpected download") }
        ops.install = { _ in calls.append("install") }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.setAutomaticUpdates(false)
        XCTAssertTrue(calls.isEmpty)
        updater.check()
        updater.check() // Coalesces concurrent checks.
        try await TestSupport.eventually { updater.state == .available }
        XCTAssertEqual(calls, ["check"])
        XCTAssertFalse(updater.automatic)
        await updater.stop()
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
        ops.prepare = { _, _ in await withCheckedContinuation { pending = $0 } }
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
        ops.prepare = { _, _ in throw UpdateFailure("Invalid signature") }
        let updater = AppUpdater(operations: ops, defaults: nil)
        updater.check(download: true)
        try await TestSupport.eventually { updater.state == .failed("Invalid signature") }
        do { try await updater.installOnQuit(); XCTFail("No verified update to install") } catch {}
        await updater.stop()

        ops.context = { .init(target: self.context.target, version: "0.3.0", build: "1", identities: self.context.identities) }
        let newer = AppUpdater(operations: ops, defaults: nil)
        newer.check(download: true)
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
