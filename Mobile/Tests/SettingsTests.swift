import Dictation
import XCTest
@testable import DispatchMobile

/// Settings: every switch's effect on the models.
@MainActor
final class SettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "settings-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testAppearanceIsTheSharedStringKey() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        XCTAssertEqual(settings.appearance, .dark, "dark by default, as the app is")
        settings.appearance = .light
        XCTAssertEqual(store.string(forKey: "appearance"), "light")
        settings.appearance = .system
        XCTAssertEqual(store.string(forKey: "appearance"), "system")
        XCTAssertEqual(MobileSettings(defaults: store).appearance, .system)
        XCTAssertEqual(MobileSettings.Appearance.allCases.map(\.rawValue), ["system", "dark", "light"])
    }

    func testDictationDefaultsToAppleAndRemembersWhisper() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        XCTAssertEqual(settings.dictationEngine, .apple)
        XCTAssertEqual(settings.whisperModel, .small)
        settings.dictationEngine = .whisper
        settings.whisperModel = .turbo
        XCTAssertEqual(MobileSettings.dictation(store).engine, .whisper, "what the composer's mic reads")
        XCTAssertEqual(MobileSettings.dictation(store).model, .turbo)
        XCTAssertEqual(MobileSettings(defaults: store).dictationEngine, .whisper)
        store.set("unknown", forKey: MobileSettings.dictationEngineKey)
        store.set("unknown", forKey: MobileSettings.whisperModelKey)
        XCTAssertEqual(MobileSettings(defaults: store).dictationEngine, .apple)
        XCTAssertEqual(MobileSettings(defaults: store).whisperModel, .small)
    }

    func testTerminalFontSizeIsTheTerminalsDefault() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        XCTAssertEqual(settings.terminalFontSize, TerminalController.defaultFontSize, "the device class's default")
        settings.terminalFontSize = 15
        XCTAssertEqual(store.double(forKey: TerminalController.fontSizeKey), 15, "the key pinch zoom writes and terminals read")
        XCTAssertEqual(MobileSettings(defaults: store).terminalFontSize, 15)
        XCTAssertEqual(MobileSettings.fontSizeRange.lowerBound, TerminalConfiguration.fontSizes.lowerBound.rounded(.up))
        XCTAssertEqual(MobileSettings.fontSizeRange.upperBound, TerminalConfiguration.fontSizes.upperBound.rounded(.down))
    }

    /// A pinch writes the size behind Settings' back, in half points up to 28: the slider shows that size, and
    /// sliding back to the size it showed before the pinch is saved.
    func testTheFontSizeFollowsAPinchAndASlideAlwaysSaves() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        XCTAssertEqual(settings.terminalFontSize, TerminalController.defaultFontSize)
        store.set(13.5, forKey: TerminalController.fontSizeKey)
        XCTAssertEqual(settings.terminalFontSize, 13.5)
        XCTAssertTrue(MobileSettings.fontSizeRange.contains(13.5))
        XCTAssertEqual(MobileSettings.fontSizeLabel(13.5), "13.5 pt")
        XCTAssertEqual(MobileSettings.fontSizeLabel(12), "12 pt")
        settings.terminalFontSize = 12
        XCTAssertEqual(store.double(forKey: TerminalController.fontSizeKey), 12, "The slide replaced the pinch's size")
    }

    /// Chat off: the helper runs without hooks and agent capabilities, and the host's agents are terminals only.
    func testChatOffReducesTheGrantAndShowsTerminalsOnly() async throws {
        let quiet = ResilienceFixture.host("quiet", chat: false)
        let helper = ScriptedHelper.scripted { _ in nil }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([quiet], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { app.tabs.workspace(quiet.id)?.host.state == .connected }
        let capabilities = Set(try XCTUnwrap(driver.launches.first).capabilities.split(separator: ",").map(String.init))
        XCTAssertFalse(capabilities.contains("hooks.configure"))
        XCTAssertFalse(capabilities.contains { $0.hasPrefix("agent.") })
        XCTAssertTrue(capabilities.isSuperset(of: ["tmux.pane", "herdr.terminal", "file.read", "stats.ping", "host.identity"]))
        XCTAssertEqual(capabilities, Set(HelperGrant.chatOffCapabilities))

        let workspace = try XCTUnwrap(app.tabs.workspace(quiet.id))
        XCTAssertEqual(workspace.tabs.count, 3, "every tab still listed")
        XCTAssertTrue(workspace.tabs.allSatisfy { $0.agentPane == nil }, "no agents: terminals only")
        XCTAssertTrue(app.conversations.conversations.isEmpty)
        XCTAssertNotNil(hosts.session(quiet.id)?.topology?.nodes.first { $0.agent != nil }, "the session keeps what the helper said")
    }

    /// Turning Chat off withdraws the capabilities from the running helper without reconnecting; turning it on
    /// reconnects with the full grant (a grant only shrinks).
    func testTheChatSwitchOnALiveConnection() async throws {
        let studio = ResilienceFixture.host("studio")
        let helper = ScriptedHelper.scripted { $0.method == "permissions.reduce" ? .empty : nil }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { !app.conversations.conversations.isEmpty }

        var record = studio
        record.chat = false
        hosts.update(record)
        try await TestSupport.eventually { !helper.requests("permissions.reduce").isEmpty }
        let reduced = try XCTUnwrap(helper.requests("permissions.reduce").first?.params["capabilities"] as? [String])
        XCTAssertEqual(reduced, HelperGrant.chatOffCapabilities.sorted())
        XCTAssertEqual(driver.runs, 1, "no reconnect")
        XCTAssertTrue(app.conversations.conversations.isEmpty, "the host's agents are terminals only at once")
        XCTAssertEqual(hosts.store.record(studio.id)?.chat, false, "saved")

        record.chat = true
        hosts.update(record)
        try await TestSupport.eventually { driver.runs == 2 }
        XCTAssertEqual(driver.launches.last?.capabilities, HelperGrant.capabilityList)
        try await TestSupport.eventually { !app.conversations.conversations.isEmpty }
    }

    /// The multiplexer preference (host detail and Settings share the control) reaches the running driver, which
    /// re-follows on the same connection; Spaces detects again for New space.
    func testTheMultiplexerPreferenceIsFollowedWithoutReconnecting() async throws {
        let studio = ResilienceFixture.host("studio")
        let helper = ScriptedHelper.scripted { _ in nil }
        let driver = ClientDriver { _ in helper }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        _ = ResilienceFixture.composition(hosts)
        try await TestSupport.eventually { hosts.session(studio.id)?.link == .connected }
        var record = studio
        record.multiplexer = .herdr
        hosts.update(record)
        try await TestSupport.eventually { driver.preferences == [.herdr] }
        XCTAssertEqual(driver.runs, 1)
        record.multiplexer = .herdr
        record.name = "studio 2"
        hosts.update(record)
        record.multiplexer = .automatic
        hosts.update(record)
        try await TestSupport.eventually { driver.preferences == [.herdr, .automatic] }
    }

    /// When the followed multiplexer changes, the old one's spaces leave and Spaces detects where New space goes again.
    func testAFollowedSwitchReplacesTheSpaces() async throws {
        let studio = ResilienceFixture.host("studio")
        let driver = ScriptedHostSessionDriver { host in
            [.event(.following("tmux"))] + Array(ScriptedHostSessionDriver.connects(host).dropLast())
                + [.sleep(.milliseconds(100)), .event(.following("herdr")), .hold]
        }
        let hosts = ResilienceFixture.sessions([studio], driver: driver)
        let app = ResilienceFixture.composition(hosts)
        let session = try XCTUnwrap(hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected && !(app.tabs.workspace(studio.id)?.spaces.isEmpty ?? true) }
        try await TestSupport.eventually { session.following == "herdr" }
        XCTAssertNil(session.topology, "tmux's snapshot is not this host's spaces any more")
        XCTAssertEqual(app.tabs.workspace(studio.id)?.spaces.count, 0)
        XCTAssertEqual(MobileComposition.input(session).multiplexer, "herdr")
    }

    /// Remove all data: hosts, Keychain secrets, trusted host keys, markers, the cache, drafts, the outbox, the
    /// remembered models (`chat-models.json`) and Spaces' per-host values (`spaces.json` and older UserDefaults keys);
    /// appearance and the font size stay.
    /// The Apple Watch row says what WatchConnectivity says: no watch, a watch without the app, the app installed.
    func testTheAppleWatchRowFollowsTheSession() {
        let app = ResilienceFixture.composition(ResilienceFixture.sessions([], active: false))
        XCTAssertNil(app.watch, "hidden without a bridge (no WatchConnectivity)")
        let session = ScriptedWatchSession()
        let bridge = WatchBridge(composition: app, session: session, backgroundTask: { _ in {} })
        XCTAssertEqual(bridge.status.pairing.label, "Not paired")
        session.isPaired = true
        bridge.watchStateChanged()
        XCTAssertEqual(bridge.status.pairing.label, "Not installed")
        XCTAssertTrue(SettingsView.watchFooter(bridge.status.pairing).contains("Install Dispatch from the Watch app"))
        session.isWatchAppInstalled = true
        bridge.watchStateChanged()
        XCTAssertEqual(bridge.status.pairing.label, "Installed")
    }

    func testRemoveAllData() async throws {
        let vault = MemoryVault()
        let known = KnownHostStore(url: nil)
        let studio = ResilienceFixture.host("studio")
        let hosts = ResilienceFixture.sessions([studio], vault: vault, knownHosts: known)
        try hosts.keys.setPassword("secret", for: studio.id)
        _ = try hosts.keys.generateED25519(label: "phone")
        known.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: Data([1]))
        known.trust(host: "elsewhere", port: 2222, algorithm: "ssh-ed25519", key: Data([2]))
        let cache = HostCache(url: nil)
        cache.replace(ResilienceFixture.entry(), for: studio.id)
        let markers = ChatMarkers(store: ChatMarkerMemoryStore())
        markers.markSeen(host: studio.id, conversation: "c", through: 5)
        markers.setMuted(true, host: studio.id, node: "n")
        let outbox = ChatOutbox(store: ChatOutboxMemoryStore())
        let drafts = ChatDraftRepository(store: ChatDraftMemoryStore())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remove-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let modelsFile = folder.appendingPathComponent("chat-models.json"), spacesFile = folder.appendingPathComponent("spaces.json")
        let memory = ChatModelMemory(url: modelsFile)
        memory.remember(agent: "claude", model: "opus", effort: "high")
        let defaults = UserDefaults(suiteName: "remove-all-\(UUID().uuidString)")!
        defaults.set("light", forKey: "appearance")
        defaults.set(["stale"], forKey: "tabs.collapsed")
        let tabs = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults, deviceState: SpacesDeviceState(url: spacesFile))
        let app = ResilienceFixture.composition(hosts, cache: cache, markers: markers, outbox: outbox, drafts: drafts,
                                                settings: MobileSettings(defaults: defaults), modelMemory: memory, tabs: tabs)
        tabs.visited(SpaceRef(host: studio.id, key: "tmux:studio:work"))
        defaults.set(["stale"], forKey: "tabs.collapsed")  // as an older build left it
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelsFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spacesFile.path))
        _ = outbox.add(ChatOutboxItem(id: UUID(), key: ChatConversationKey(host: studio.id, node: "n"), conversation: "c",
                                      text: "later", created: Date(), state: .waiting))
        app.settings.backgroundRefresh = true
        XCTAssertFalse(vault.accounts.isEmpty)

        app.removeAllData()
        XCTAssertTrue(hosts.store.hosts.isEmpty)
        XCTAssertTrue(hosts.sessions.isEmpty)
        XCTAssertTrue(hosts.keys.keys.isEmpty)
        XCTAssertTrue(vault.accounts.isEmpty, "every Keychain secret")
        XCTAssertTrue(known.entries.isEmpty, "every trusted host key, also of hosts no longer saved")
        XCTAssertNil(cache.entry(studio.id))
        XCTAssertEqual(markers.document, ChatMarkers.Document())
        XCTAssertTrue(outbox.items.isEmpty)
        XCTAssertTrue(drafts.buckets.isEmpty)
        XCTAssertTrue(app.tabs.workspaces.isEmpty)
        XCTAssertFalse(app.settings.backgroundRefresh)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelsFile.path), "chat-models.json")
        XCTAssertNil(memory.lastAgent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spacesFile.path), "spaces.json")
        XCTAssertNil(tabs.recent)
        XCTAssertNil(defaults.object(forKey: "tabs.collapsed"), "an older build's per-host keys")
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light", "appearance stays")
    }

    /// Remove all data except SSH keys: the same removal, but the keys, their private halves and passphrases stay;
    /// host passwords go with the hosts.
    func testRemoveAllDataExceptSSHKeys() async throws {
        let vault = MemoryVault()
        let known = KnownHostStore(url: nil)
        let studio = ResilienceFixture.host("studio")
        let hosts = ResilienceFixture.sessions([studio], vault: vault, knownHosts: known)
        try hosts.keys.setPassword("secret", for: studio.id)
        let key = try hosts.keys.generateED25519(label: "phone")
        try vault.set(Data("words".utf8), for: KeyStore.passphraseAccount(key.id), protection: .none)
        try vault.set(Data("orphan".utf8), for: KeyStore.privateAccount(UUID()), protection: .none)
        known.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: Data([1]))
        let app = ResilienceFixture.composition(hosts)

        app.removeAllData(keepingKeys: true)
        XCTAssertTrue(hosts.store.hosts.isEmpty)
        XCTAssertTrue(known.entries.isEmpty)
        XCTAssertEqual(hosts.keys.keys.map(\.id), [key.id], "the key stays")
        XCTAssertEqual(vault.accounts, [KeyStore.privateAccount(key.id), KeyStore.passphraseAccount(key.id)],
                       "only the kept key's secrets: the host password and a secret of no key go")
        XCTAssertNotNil(try vault.secret(for: KeyStore.privateAccount(key.id), reason: ""))
    }
}
