import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The redesign's foundation for Files (docs/ios.md, Tab screen and Files): the capsule's segments, the Files & git
/// grant and switch, Files' availability per host state, and the tabs' git facts.
@MainActor
final class FilesFoundationTests: XCTestCase {
    // MARK: Segments

    /// Every tab has Terminal · Chat · Files; a plain SSH shell tab has no Chat. Chat's glyph is the Mac's.
    func testTheCapsuleOffersFilesOnEveryTab() throws {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app().topology)
        XCTAssertEqual(TabSegment.available(for: try XCTUnwrap(workspace.tab("herdr:app:1"))), [.terminal, .chat, .files])
        XCTAssertEqual(TabSegment.available(for: try XCTUnwrap(workspace.tab("herdr:app:3"))), [.terminal, .chat, .files],
                       "a tab without an agent keeps Chat")
        XCTAssertEqual(TabSegment.chat.symbol, "text.bubble")
        XCTAssertEqual(TabSegment.files.symbol, "folder")
        XCTAssertEqual(FilesMode.allCases.map(\.symbol), ["folder", "pencil.and.list.clipboard", "clock.arrow.circlepath"])
        XCTAssertEqual(FilesMode.available(repository: true), [.files, .review, .commits])
        XCTAssertEqual(FilesMode.available(repository: false), [.files], "outside a repository only Files")
        XCTAssertEqual(TabSegmentCapsule.headerWidth(3), 124)
    }

    func testAPlainShellTabHasTerminalAndFiles() throws {
        let shells = ShellFixtures.sessions()
        XCTAssertNotNil(shells.newTab())
        let model = ShellFixtures.model()
        model.sync([ShellFixtures.input(shells)])
        let tab = try XCTUnwrap(model.workspace(ShellFixtures.host.id)?.tabs.first { $0.isShell })
        XCTAssertEqual(TabSegment.available(for: tab), [.terminal, .files])
    }

    /// The capsule is a container of buttons labelled with the segments' titles, the shown one selected, the Files
    /// badge spoken as its value.
    func testTheCapsuleIsButtonsLabelledByTitle() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let (window, host) = try show(TabSegmentCapsule(selection: .constant(.chat), badge: 3).frame(width: 370))
        defer { window.isHidden = true }
        var elements: [NSObject] = []
        try await TestSupport.eventually(timeout: .seconds(2)) {
            elements = accessibilityElements(host.view)
            return elements.contains { $0.accessibilityLabel == "Files" }
        }
        let labels = elements.compactMap(\.accessibilityLabel)
        for title in ["Terminal", "Chat", "Files"] { XCTAssertTrue(labels.contains(title), "\(title) in \(labels)") }
        let chat = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Chat" })
        XCTAssertTrue(chat.accessibilityTraits.contains(.selected))
        XCTAssertTrue(chat.accessibilityTraits.contains(.button))
        let files = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Files" })
        XCTAssertEqual(files.accessibilityValue, "3 comments")
    }

    /// The capsule keeps its bar height at xxxLarge and larger sizes (the large content viewer takes over).
    func testTheCapsuleFitsAPhoneAtTheLargestSizes() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            final class Box { var size = CGSize.zero }
            let box = Box()
            let capsule = TabSegmentCapsule(selection: .constant(.terminal), badge: 3)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { box.size = $0 }
                .frame(width: 370)
                .environment(\.dynamicTypeSize, size)
            let (window, _) = try show(capsule)
            window.isHidden = true
            XCTAssertEqual(box.size.width, 370, accuracy: 0.5, "\(size)")
            XCTAssertGreaterThanOrEqual(box.size.height, 34, "\(size)")
            XCTAssertLessThan(box.size.height, 64, "\(size): a bar's control")
        }
    }

    /// The tab screen shows the Files segment's explanation for a plain SSH host (S1), the modes for a granted one, and
    /// Not now returns to the segment shown before.
    func testFilesExplainsAPlainHostAndNotNowGoesBack() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let (model, ref) = tabModel(plain: true)
        model.segments[ref] = .chat
        let screen = TabScreen(model: model, ref: ref, path: .constant([.tab(ref)]),
                               terminal: { _, _ in Text("terminal-body") }, chat: { _, _ in Text("chat-body") })
        let (window, host) = try show(NavigationStack { screen }, size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        try await TestSupport.eventually(timeout: .seconds(2)) {
            accessibilityElements(host.view).contains { $0.accessibilityLabel == "Files" }
        }
        try tap("Files", in: host.view)
        try await TestSupport.eventually(timeout: .seconds(2)) {
            accessibilityElements(host.view).contains { $0.accessibilityLabel == "Files needs the helper on mba2" }
        }
        var labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains("Install helper…"), "\(labels)")
        XCTAssertEqual(model.segments[ref], .files)
        try tap("Not now", in: host.view)
        XCTAssertEqual(model.segments[ref], .chat, "back to the segment shown before Files")
        try await TestSupport.eventually(timeout: .seconds(2)) {
            !accessibilityElements(host.view).contains { $0.accessibilityLabel == "Files needs the helper on mba2" }
        }
        labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains("Install helper…"))
    }

    // MARK: Availability

    func testAvailabilityFollowsTheHost() {
        var host = TabsFixtures.host
        XCTAssertEqual(MobileFilesAvailability(host), .available)
        host.files = false
        XCTAssertEqual(MobileFilesAvailability(host), .notGranted(host: "mba2"))
        host.plain = true
        XCTAssertEqual(MobileFilesAvailability(host), .plainSSH(host: "mba2"), "plain SSH first: there is no helper to grant")
        host.plain = false
        host.files = true
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        host.state = .offline
        host.offlineSince = since
        XCTAssertEqual(MobileFilesAvailability(host), .offline(host: "mba2", since: since))
        XCTAssertTrue(MobileFilesAvailability(host).showsModes, "offline keeps the modes, dimmed")
        XCTAssertFalse(MobileFilesAvailability.plainSSH(host: "mba2").showsModes)
        XCTAssertFalse(MobileFilesAvailability.notGranted(host: "mba2").showsModes)
        host.state = .connecting
        XCTAssertEqual(MobileFilesAvailability(host), .available, "a connection being made is not offline (no dimmed frame)")
        host.reconnecting = true
        XCTAssertEqual(MobileFilesAvailability(host), .offline(host: "mba2", since: since), "reconnecting after a drop is")

        XCTAssertEqual(FilesUnavailableView.copy(.plainSSH(host: "mba2"))?.title, "Files needs the helper on mba2")
        XCTAssertEqual(FilesUnavailableView.copy(.plainSSH(host: "mba2"))?.action, "Install helper…")
        XCTAssertEqual(FilesUnavailableView.copy(.notGranted(host: "mba2"))?.title, "Files is not allowed on mba2")
        XCTAssertEqual(FilesUnavailableView.copy(.notGranted(host: "mba2"))?.action, "Change integration…")
        XCTAssertNil(FilesUnavailableView.copy(.available))
        let now = since.addingTimeInterval(125)
        XCTAssertEqual(FilesOfflineAccessory.ago(since, now: now), "2m ago")
        XCTAssertEqual(FilesOfflineAccessory.ago(since, now: since.addingTimeInterval(20)), "just now")
        XCTAssertEqual(FilesOfflineAccessory.ago(since, now: since.addingTimeInterval(3 * 3600)), "3h ago")
    }

    /// The composition maps a session to the host Files sees: its switch, and when a reconnect started.
    func testTheCompositionMapsTheSwitchAndTheOutage() async throws {
        var quiet = ResilienceFixture.host("quiet")
        quiet.files = false
        let helper = ScriptedHelper.scripted { _ in nil }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([quiet], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { app.tabs.workspace(quiet.id)?.host.state == .connected }
        let host = try XCTUnwrap(app.tabs.workspace(quiet.id)?.host)
        XCTAssertFalse(host.files)
        XCTAssertEqual(MobileFilesAvailability(host), .notGranted(host: "quiet"))
        XCTAssertNil(host.offlineSince)
    }

    // MARK: Grant

    func testTheGrantAddsGitReadWithFilesAndNeverWrites() {
        XCTAssertTrue(HelperGrant.capabilities.contains("git.read"))
        XCTAssertFalse(HelperGrant.capabilities.contains("file.write"))
        XCTAssertEqual(HelperGrant.capabilities, HelperGrant.capabilities.sorted(), "listed in order")
        XCTAssertEqual(HelperGrant.capabilities(chat: true, files: true), HelperGrant.capabilities)
        let noFiles = HelperGrant.capabilities(chat: true, files: false)
        XCTAssertFalse(noFiles.contains("git.read"))
        XCTAssertTrue(noFiles.contains("file.read"), "Files & git off keeps what Chat reads")
        XCTAssertEqual(Set(HelperGrant.capabilities).subtracting(noFiles), ["git.read"])
        let neither = Set(HelperGrant.capabilities(chat: false, files: false))
        XCTAssertFalse(neither.contains { $0.hasPrefix("agent.") || $0 == "hooks.configure" || $0 == "git.read" })
        XCTAssertTrue(HelperGrant.chatOffCapabilities.contains("git.read"))
        for capabilities in [HelperGrant.capabilities, noFiles, Array(neither)] {
            XCTAssertFalse(capabilities.contains("file.write"))
        }
        XCTAssertTrue(HelperGrant.statement.contains("git status, diffs and history"))
    }

    func testTheFilesSwitchFollowsTheHelper() throws {
        var record = HostRecord(name: "ai", address: "ai.local", user: "alex", auth: .password)
        XCTAssertTrue(record.files, "on by default")
        record.helper = false
        XCTAssertFalse(record.files, "turning the helper off turns Files off")
        record.files = true
        XCTAssertFalse(record.files, "and keeps it off")
        XCTAssertFalse(HostRecord(name: "ai", address: "ai.local", user: "alex", auth: .password, helper: false, files: true).files)

        // Saved before the field existed: on; saved without the helper: off whatever the file says.
        let old = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "ai", "address": "ai.local",
                                                              "user": "alex", "auth": ["password": [:]]])
        XCTAssertTrue(try JSONDecoder().decode(HostRecord.self, from: old).files)
        var off = HostRecord(name: "ai", address: "ai.local", user: "alex", auth: .password)
        off.files = false
        XCTAssertFalse(try JSONDecoder().decode(HostRecord.self, from: JSONEncoder().encode(off)).files)

        var draft = HostFeatureDraft()
        XCTAssertTrue(draft.files)
        draft.files = false
        var applied = HostRecord(name: "ai", address: "ai.local", user: "alex", auth: .password)
        draft.apply(to: &applied)
        XCTAssertFalse(applied.files)
        draft.helper = false
        draft.apply(to: &applied)
        XCTAssertFalse(applied.files)
        XCTAssertTrue(HostFeatureDraft(applied).files, "a host saved without the helper gets Files on with it")
    }

    /// Files & git off: the helper launches without `git.read`. Turned on, the host reconnects with the full grant;
    /// turned off on a live connection, the running helper's grant shrinks without a reconnect.
    func testTheFilesSwitchOnALiveConnection() async throws {
        var studio = ResilienceFixture.host("studio")
        studio.files = false
        let helper = ScriptedHelper.scripted { $0.method == "permissions.reduce" ? .empty : nil }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { app.tabs.workspace(studio.id)?.host.state == .connected }
        XCTAssertEqual(driver.launches.first?.capabilities, HelperGrant.capabilityList(chat: true, files: false))

        var record = studio
        record.files = true
        hosts.update(record)
        try await TestSupport.eventually { driver.runs == 2 }
        XCTAssertEqual(driver.launches.last?.capabilities, HelperGrant.capabilityList)
        try await TestSupport.eventually { app.tabs.workspace(studio.id)?.host.state == .connected }

        record.files = false
        hosts.update(record)
        try await TestSupport.eventually { !helper.requests("permissions.reduce").isEmpty }
        let reduced = try XCTUnwrap(helper.requests("permissions.reduce").first?.params["capabilities"] as? [String])
        XCTAssertEqual(reduced, HelperGrant.capabilities(chat: true, files: false).sorted())
        XCTAssertEqual(driver.runs, 2, "no reconnect")
        XCTAssertEqual(hosts.store.record(studio.id)?.files, false, "saved")
    }

    /// Install helper… on a host whose switch is off turns it on (Chat and Files with it); on one whose helper is on
    /// already it connects again.
    func testInstallHelperTurnsTheHelperOn() async throws {
        let plain = HostRecord(name: "pi", address: "pi.local", user: "alex", auth: .password, helper: false, tintSeed: "pi")
        let helper = ScriptedHelper.scripted { _ in nil }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([plain], driver: driver)
        hosts.useHelper(host: plain.id)
        let saved = try XCTUnwrap(hosts.store.record(plain.id))
        XCTAssertTrue(saved.helper)
        XCTAssertTrue(saved.chat)
        XCTAssertTrue(saved.files)
        try await TestSupport.eventually { driver.runs >= 1 }
        let runs = driver.runs
        hosts.useHelper(host: plain.id)
        try await TestSupport.eventually { driver.runs == runs + 1 }
    }

    // MARK: Git facts

    private static func gitHelper(root: @escaping @Sendable (String?) -> String? = { _ in "/Users/alex/src/app" },
                                  branch: String = "main") -> ScriptedHelper {
        ScriptedHelper.scripted { request in
            switch request.method {
            case "files.git":
                if let top = root(request.params["path"] as? String) {
                    return .result(["status": 0, "output": top + "\n", "truncated": false])
                }
                return .result(["status": 128, "output": "fatal: not a git repository", "truncated": false])
            case "files.branch": return .result(branch)
            default: return nil
            }
        }
    }

    /// The facts come from the helper: the root by `files.git rev-parse --show-toplevel` in the folder, then the branch
    /// by `files.branch`; outside a repository git's 128 gives no root and no branch question. The root is read once per
    /// folder and connection.
    func testGitFactsReadTheRootAndTheBranch() async throws {
        let helper = Self.gitHelper(root: { $0 == "/Users/alex/src/web/src" ? "/Users/alex/src/web" : nil }, branch: "dark-mode")
        let facts = SpaceGitFacts()
        facts.client = { _ in helper.client }
        let host = UUID()
        let web = SpaceGitFacts.Key(host: host, key: "herdr:web:1")
        await facts.resolve(web, directory: "/Users/alex/src/web/src")
        XCTAssertEqual(facts.facts(web), SpaceGitFacts.Facts(directory: "/Users/alex/src/web/src", root: "/Users/alex/src/web",
                                                              branch: "dark-mode"))
        XCTAssertEqual(facts.isRepository(web), true)
        let git = try XCTUnwrap(helper.requests("files.git").first)
        XCTAssertEqual(git.params["args"] as? [String], ["rev-parse", "--show-toplevel"])
        XCTAssertEqual(helper.requests("files.branch").first?.params["path"] as? String, "/Users/alex/src/web/src")
        await facts.resolve(web, directory: "/Users/alex/src/web/src")
        XCTAssertEqual(helper.requests("files.git").count, 1, "once per folder and connection")
        facts.invalidate(host: host)
        await facts.resolve(web, directory: "/Users/alex/src/web/src")
        XCTAssertEqual(helper.requests("files.git").count, 2, "a new connection or grant reads it again")

        let home = SpaceGitFacts.Key(host: host, key: "herdr:home:1")
        await facts.resolve(home, directory: "/Users/alex")
        XCTAssertEqual(facts.isRepository(home), false)
        XCTAssertNil(facts.facts(home)?.branch)
        XCTAssertEqual(helper.requests("files.branch").count, 2, "no branch outside a repository")
        XCTAssertNil(facts.facts(web, directory: "/Users/alex"), "facts are for their folder")

        facts.retain(host: host, keys: ["herdr:home:1"])
        XCTAssertNil(facts.facts(web), "a closed tab's facts go")
        XCTAssertNotNil(facts.facts(home))
        facts.forget(host: host)
        XCTAssertNil(facts.facts(home))
    }

    /// Without a granted helper nothing is asked; a failed read keeps what was known.
    func testGitFactsNeedTheGrantAndKeepTheLastAnswer() async throws {
        let helper = ScriptedHelper.scripted { request in
            request.method == "files.git" ? .failure(code: "permission_denied", message: "git.read not granted") : nil
        }
        let facts = SpaceGitFacts()
        let key = SpaceGitFacts.Key(host: UUID(), key: "tmux:docs:@1")
        facts.client = { _ in nil }
        await facts.resolve(key, directory: "/Users/alex/src/docs")
        XCTAssertNil(facts.facts(key))
        XCTAssertTrue(helper.requests.isEmpty)

        let known = SpaceGitFacts.Facts(directory: "/Users/alex/src/docs", root: "/Users/alex/src/docs", branch: "main")
        facts.seed(key, known)
        facts.client = { _ in helper.client }
        facts.invalidate(host: key.host)
        await facts.resolve(key, directory: "/Users/alex/src/docs")
        XCTAssertEqual(facts.facts(key), known, "a refused read keeps the last facts")
        XCTAssertEqual(helper.requests("files.git").count, 1)
        await facts.resolve(key, directory: "/Users/alex/src/docs")
        XCTAssertEqual(helper.requests("files.git").count, 2, "a failed read is asked again")
    }

    /// A watch reads the root once, then only the branch every interval (10 s, the Mac's for a shown branch) until its
    /// task ends; a new connection reads the root again at the next tick.
    func testGitFactsWatchPollsTheBranchOnly() async throws {
        XCTAssertEqual(SpaceGitFacts().interval, .seconds(10))
        XCTAssertEqual(SpaceGitFacts.branchInterval, .seconds(10))
        let helper = Self.gitHelper()
        let ticks = Ticks()
        let facts = SpaceGitFacts(interval: .seconds(2), sleep: { _ in try await ticks.next() })
        facts.client = { _ in helper.client }
        let key = SpaceGitFacts.Key(host: UUID(), key: "herdr:app:1")
        let watch = Task { await facts.watch(key, directory: "/Users/alex/src/app") }
        try await TestSupport.eventually { facts.facts(key)?.branch == "main" && ticks.waiting }
        XCTAssertEqual(helper.requests("files.git").count, 1)
        XCTAssertEqual(helper.requests("files.branch").count, 1)
        ticks.tick()
        _ = try await helper.wait(for: "files.branch", count: 2)
        XCTAssertEqual(helper.requests("files.git").count, 1, "the branch alone")
        try await TestSupport.eventually { ticks.waiting }
        facts.invalidate(host: key.host)
        ticks.tick()
        _ = try await helper.wait(for: "files.git", count: 2)
        try await TestSupport.eventually { ticks.waiting }
        watch.cancel()
        ticks.end()
        await watch.value
        XCTAssertEqual(helper.requests("files.git").count, 2, "an ended watch reads no more")
        XCTAssertEqual(helper.requests("files.branch").count, 3)
    }

    /// A folder change keeps the previous facts until the new read answers, and a read asked meanwhile runs after it
    /// with the latest folder.
    func testGitFactsFollowTheLatestFolder() async throws {
        let gate = Ticks()
        let asked = Asked()
        let reader = SpaceGitFacts.Reader(root: { _, directory in
            await asked.add(directory)
            try await gate.next()
            return directory
        }, branch: { _, _ in "main" })
        let helper = ScriptedHelper.scripted { _ in nil }
        let facts = SpaceGitFacts(reader: reader)
        facts.client = { _ in helper.client }
        let key = SpaceGitFacts.Key(host: UUID(), key: "herdr:app:1")
        let previous = SpaceGitFacts.Facts(directory: "/a", root: "/a", branch: "main")
        facts.seed(key, previous)
        let first = Task { await facts.resolve(key, directory: "/b") }
        try await TestSupport.eventually { gate.waiting }
        XCTAssertEqual(facts.facts(key), previous, "the previous facts until the read answers")
        await facts.resolve(key, directory: "/c")
        gate.tick()
        try await TestSupport.eventually { await asked.directories == ["/b", "/c"] && gate.waiting }
        gate.tick()
        await first.value
        XCTAssertEqual(facts.facts(key)?.directory, "/c")
        XCTAssertEqual(facts.facts(key)?.root, "/c")
    }

    /// The tab screen reads the root once on Terminal and polls the branch only while Files shows.
    func testTheTabPollsOnlyWhileFilesShows() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let helper = Self.gitHelper(root: { _ in "/Users/alex/src/app" })
        let ticks = Ticks()
        let facts = SpaceGitFacts(interval: .seconds(2), sleep: { _ in try await ticks.next() })
        facts.client = { _ in helper.client }
        let (model, ref) = tabModel()
        model.segments[ref] = .terminal
        let screen = TabScreen(model: model, ref: ref, path: .constant([.tab(ref)]),
                               terminal: { _, _ in Text("terminal-body") }, chat: { _, _ in Text("chat-body") }, gitFacts: facts)
        let (window, host) = try show(NavigationStack { screen }, size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        try await TestSupport.eventually { helper.requests("files.branch").count == 1 }
        XCTAssertEqual(helper.requests("files.git").count, 1)
        XCTAssertFalse(ticks.waiting, "no polling on Terminal")
        try await TestSupport.eventually(timeout: .seconds(2)) {
            accessibilityElements(host.view).contains { $0.accessibilityLabel == "Files" }
        }
        try tap("Files", in: host.view)
        try await TestSupport.eventually { ticks.waiting }
        XCTAssertEqual(helper.requests("files.git").count, 1, "the root is known")
        ticks.tick()
        _ = try await helper.wait(for: "files.branch", count: 2)
        try await TestSupport.eventually { ticks.waiting }
        try tap("Terminal", in: host.view)
        try await TestSupport.eventually { model.segments[ref] == .terminal }
        ticks.tick()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(helper.requests("files.branch").count, 2, "hidden: no more polling")
        XCTAssertFalse(ticks.waiting)
        XCTAssertEqual(helper.requests("files.git").count, 1)
    }

    /// The composition asks git only through a connected helper with the Files & git grant.
    func testGitFactsAskOnlyGrantedConnectedHelpers() async throws {
        let studio = ResilienceFixture.host("studio")
        var quiet = ResilienceFixture.host("quiet", order: 1)
        quiet.files = false
        let plain = HostRecord(name: "pi", address: "pi.local", user: "alex", auth: .password, helper: false, order: 2, tintSeed: "pi")
        let helper = ScriptedHelper.scripted { _ in nil }
        let driver = MixedDriver(helper: ClientDriver { _ in helper })
        let hosts = ResilienceFixture.sessions([studio, quiet, plain], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually {
            [studio.id, quiet.id].allSatisfy { app.tabs.workspace($0)?.host.state == .connected }
                && hosts.session(plain.id)?.isPlain == true
        }
        XCTAssertNotNil(app.gitFacts.client(studio.id))
        XCTAssertNil(app.gitFacts.client(quiet.id), "Files & git off")
        XCTAssertNil(app.gitFacts.client(plain.id), "plain SSH")
        let generation = app.gitFacts.generation(studio.id)
        hosts.session(studio.id)?.disconnect()
        try await TestSupport.eventually { app.tabs.workspace(studio.id)?.host.state == .offline }
        XCTAssertNil(app.gitFacts.client(studio.id), "disconnected")
        XCTAssertGreaterThan(app.gitFacts.generation(studio.id), generation, "a new connection reads the roots again")
    }

    /// Closing a tab takes the screens its Files modes pushed off the stack, in the split's detail column too.
    func testClosingATabTakesItsFilesScreens() {
        let model = TabsSample.model()
        let navigator = SpacesNavigator(model: model)
        let tab = TabRef(host: TabsSample.mba2.id, key: "herdr:app:2")
        let space = SpaceRef(host: tab.host, key: "herdr:app")
        let file = TabsRoute.files(tab, FilesRoute(mode: .files, path: "src/theme.ts"))
        navigator.split = true
        navigator.path = [.space(space), .tab(tab), file]
        XCTAssertEqual(navigator.splitPath.tab, tab)
        XCTAssertEqual(navigator.splitPath.detail, [file])
        navigator.closed(.tab(tab))
        XCTAssertEqual(navigator.path, [.space(space)])
        navigator.path = [.space(space), .tab(tab), file]
        navigator.closed(.space(space))
        XCTAssertEqual(navigator.path, [])
    }

    // MARK: Chrome

    func testChromePieces() {
        XCTAssertEqual(AgentGlyph.kind("claude"), .claude)
        XCTAssertEqual(AgentGlyph.kind("codex"), .codex)
        XCTAssertEqual(AgentGlyph.kind("nanocodex"), .codex)
        XCTAssertEqual(AgentGlyph.kind("pi"), .pi)
        XCTAssertEqual(AgentGlyph.kind(nil), .terminal)
        XCTAssertEqual(GitStatusBadge.spoken("?"), "Untracked")
        XCTAssertEqual(MobileChangeRow.split("src/components/Sidebar.tsx").folder, "src/components/")
        XCTAssertEqual(MobileChangeRow.split("README.md").folder, "")
        XCTAssertEqual(MobileChangeRow.accessibilityLabel(status: "M", path: "src/main.tsx", added: 3, deleted: 1, comments: 2),
                       "src/main.tsx, Modified, 3 added, 1 deleted, 2 comments")
        XCTAssertEqual(MobileCounts.spoken(added: 0, deleted: 4), "4 deleted")
    }

    // MARK: Support

    private func tabModel(plain: Bool = false, files: Bool = true) -> (MobileTabs, TabRef) {
        let suite = "files-foundation"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        var host = TabsFixtures.host
        host.plain = plain
        host.files = files
        model.sync([TabsHostInput(host: host, client: nil, topology: TabsFixtures.app().topology)])
        return (model, TabRef(host: host.id, key: "herdr:app:1"))
    }

    private func show(_ view: some View, size: CGSize = CGSize(width: 402, height: 200)) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (window, host)
    }

    private func accessibilityElements(_ view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ element: NSObject) {
            if element.isAccessibilityElement { found.append(element) }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        return found
    }

    private func tap(_ label: String, in view: UIView) throws {
        let element = try XCTUnwrap(accessibilityElements(view).first { $0.accessibilityLabel == label }, "no \(label)")
        XCTAssertTrue(element.accessibilityActivate(), "\(label) did not activate")
    }
}

/// The folders a reader was asked for, in order.
private actor Asked {
    private(set) var directories: [String] = []
    func add(_ directory: String) { directories.append(directory) }
}

/// Helper hosts through `helper`; a host with its Helper switch off connects as plain SSH.
private final class MixedDriver: HostSessionDriver, @unchecked Sendable {
    let helper: ClientDriver
    init(helper: ClientDriver) { self.helper = helper }

    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
        guard !host.helper else { return helper.run(host, context: context) }
        let (stream, continuation) = AsyncStream<HostSessionEvent>.makeStream()
        continuation.yield(.link(.connecting))
        continuation.yield(.plain(reason: nil, shells: ScriptedShellOpener()))
        return stream
    }
}

/// A test's clock for `SpaceGitFacts.watch`: each sleep waits for `tick`; `end` ends them all.
@MainActor
private final class Ticks {
    private var sleepers: [CheckedContinuation<Void, any Error>] = []
    private var ended = false
    var waiting: Bool { !sleepers.isEmpty }

    func next() async throws {
        if ended { throw CancellationError() }
        try await withCheckedThrowingContinuation { sleepers.append($0) }
    }

    func tick() { if !sleepers.isEmpty { sleepers.removeFirst().resume() } }

    func end() {
        ended = true
        for sleeper in sleepers { sleeper.resume(throwing: CancellationError()) }
        sleepers = []
    }
}
