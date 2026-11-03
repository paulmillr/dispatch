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

    func testUnsafePasteApprovalDefaultsOnAndPersistsOptOut() {
        let store = defaults()
        let saved = MobileSettings(defaults: store)
        XCTAssertTrue(saved.autoApproveUnsafePastes)
        saved.autoApproveUnsafePastes = false
        XCTAssertFalse(MobileSettings.autoApprovesUnsafePastes(store))
        XCTAssertFalse(MobileSettings(defaults: store).autoApproveUnsafePastes)
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

    /// The multiplexer preference (Edit host and Settings both set it) reaches the running driver, which
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
        // A move out of Face ID cut short: the copy can be the key's only one, so it stays.
        try vault.set(Data("copy".utf8), for: KeyStore.movingPrefix + KeyStore.privateAccount(key.id), protection: .none)
        known.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: Data([1]))
        let app = ResilienceFixture.composition(hosts)

        app.removeAllData(keepingKeys: true)
        XCTAssertTrue(hosts.store.hosts.isEmpty)
        XCTAssertTrue(known.entries.isEmpty)
        XCTAssertEqual(hosts.keys.keys.map(\.id), [key.id], "the key stays")
        XCTAssertEqual(vault.accounts, [KeyStore.privateAccount(key.id), KeyStore.passphraseAccount(key.id),
                                        KeyStore.movingPrefix + KeyStore.privateAccount(key.id)],
                       "only the kept key's secrets: the host password and a secret of no key go")
        XCTAssertNotNil(try vault.secret(for: KeyStore.privateAccount(key.id), reason: ""))
    }
}

extension SettingsTests {
    func testDictationRemembersParakeet() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        settings.dictationEngine = .parakeet
        XCTAssertEqual(MobileSettings.dictation(store).engine, .parakeet, "what the composer's mic reads")
        XCTAssertEqual(MobileSettings(defaults: store).dictationEngine, .parakeet)
        XCTAssertEqual(MobileSettings(defaults: store).dictationEngine.label(whisper: .small), "Parakeet")
    }
}

/// The Settings app's Dispatch page (`Mobile/App/Settings.bundle`).
extension SettingsTests {
    /// Every row is a key the models read, with their values, titles and default: the page shows what the app does.
    func testSettingsAppPageMatchesTheModels() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Settings", withExtension: "bundle")).appendingPathComponent("Root.plist")
        let page = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let rows = try XCTUnwrap(page["PreferenceSpecifiers"] as? [[String: Any]]).filter { $0["Key"] != nil }
        let fresh = MobileSettings(defaults: defaults())
        typealias Choice = (values: [String], titles: [String], fallback: String)
        func choice<Value: CaseIterable & RawRepresentable<String>>(_ fallback: Value, _ title: (Value) -> String) -> Choice {
            (Value.allCases.map(\.rawValue), Value.allCases.map(title), fallback.rawValue)
        }
        let choices: [String: Choice] = [
            MobileSettings.appearanceKey: choice(fresh.appearance, \.title),
            MobileSettings.themeKey: choice(fresh.theme, \.title),
            MobileSettings.lineSpacingKey: choice(fresh.lineSpacing, \.title),
            MobileSettings.textContrastKey: choice(fresh.textContrast, \.title),
            MobileSettings.cursorKey: choice(fresh.cursor, \.title),
            MobileSettings.chatFontKey: choice(fresh.chatFont, \.rawValue),
            MobileSettings.chatTextSizeKey: choice(fresh.chatTextSize, \.title),
            MobileSettings.notificationSoundKey: choice(fresh.notificationSound, \.title),
            MobileSettings.colorVisionKey: choice(fresh.colorVision, \.title),
        ]
        let switches: [String: Bool] = [
            MobileSettings.ligaturesKey: fresh.ligatures,
            MobileSettings.boldIsBrightKey: fresh.boldIsBright,
            MobileSettings.cursorBlinkKey: fresh.cursorBlink,
            MobileSettings.notifyNeedsYouKey: fresh.notifyNeedsYou,
            MobileSettings.notifyFinishedKey: fresh.notifyFinished,
            MobileSettings.notifyFailedKey: fresh.notifyFailed,
            MobileSettings.notificationTextKey: fresh.notificationText,
            MobileSettings.notificationBadgeKey: fresh.notificationBadge,
            MobileSettings.autoApproveUnsafePastesKey: fresh.autoApproveUnsafePastes,
            MobileSettings.hostColorsKey: fresh.showHostColors,
        ]
        for row in rows {
            let key = try XCTUnwrap(row["Key"] as? String)
            switch row["Type"] as? String {
            case "PSMultiValueSpecifier":
                let expected = try XCTUnwrap(choices[key], "\(key) is no choice the models know")
                XCTAssertEqual(row["Values"] as? [String], expected.values, key)
                XCTAssertEqual(row["Titles"] as? [String], expected.titles, key)
                XCTAssertEqual(row["DefaultValue"] as? String, expected.fallback, key)
            case "PSToggleSwitchSpecifier":
                let expected = try XCTUnwrap(switches[key], "\(key) is no switch the models know")
                XCTAssertEqual(row["DefaultValue"] as? Bool, expected, key)
            default:
                XCTFail("\(key): unexpected row \(row["Type"] ?? "")")
            }
        }
        XCTAssertEqual(rows.compactMap { $0["Key"] as? String }.sorted(), (Array(choices.keys) + Array(switches.keys)).sorted())
    }

    /// What the page writes while the app is away reaches the models, and a terminal setting restyles the terminals.
    func testAChangeFromTheSettingsAppReachesTheModels() async throws {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        let changes = Count()
        settings.followOutsideChanges { changes.value += 1 }
        let restyles = Count()
        let observer = NotificationCenter.default.addObserver(forName: TerminalStyle.changed, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { restyles.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.set("bar", forKey: MobileSettings.cursorKey)
        store.set(false, forKey: MobileSettings.notificationBadgeKey)
        try await TestSupport.eventually { settings.cursor == .bar && !settings.notificationBadge }
        XCTAssertGreaterThan(restyles.value, 0, "the open terminals take the cursor")
        XCTAssertGreaterThan(changes.value, 0, "the badge follows")

        // The model's own write is nothing new: only the outside one after it counts.
        let settled = changes.value
        settings.chatTextSize = .larger
        store.set("tight", forKey: MobileSettings.lineSpacingKey)
        try await TestSupport.eventually { settings.lineSpacing == .tight }
        XCTAssertEqual(changes.value, settled + 1)
        XCTAssertEqual(settings.chatTextSize, .larger)
        XCTAssertEqual(store.string(forKey: MobileSettings.chatTextSizeKey), "larger")
    }

    @MainActor private final class Count { var value = 0 }

    /// The old contrast switch moves to the key the page shows.
    func testTheOldContrastSwitchMovesToTheNewKey() {
        let store = defaults()
        store.set(true, forKey: MobileSettings.terminalContrastKey)
        XCTAssertEqual(MobileSettings(defaults: store).textContrast, .always)
        XCTAssertEqual(store.string(forKey: MobileSettings.textContrastKey), "always")
    }
}

/// Colorblind-friendly and Color-code hosts, as the Mac's.
extension SettingsTests {
    /// The terminal's scheme follows the vision on its own side; a scheme already made for it stays.
    func testColorblindModeConformsTheScheme() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        XCTAssertEqual(settings.colorVision, .typical)
        XCTAssertEqual(settings.terminalScheme, TerminalConfiguration.defaultScheme)
        settings.colorVision = .redGreen
        XCTAssertEqual(settings.terminalScheme, "GitHub Dark Colorblind")
        XCTAssertEqual(store.string(forKey: MobileSettings.terminalSchemeKey), "GitHub Dark Colorblind", "saved, and the terminals restyle")
        settings.terminalScheme = "Modus Vivendi Deuteranopia"
        settings.colorVision = .blueYellow
        XCTAssertEqual(settings.terminalScheme, "Modus Vivendi Tritanopia")
        settings.colorVision = .typical
        XCTAssertEqual(settings.terminalScheme, TerminalConfiguration.defaultScheme, "leaving colorblind mode: Dispatch's")

        settings.terminalScheme = "GitHub Light Default"
        settings.colorVision = .redGreen
        XCTAssertEqual(settings.terminalScheme, "GitHub Light Colorblind", "a light scheme gives way to a light one")
        settings.terminalScheme = "Modus Operandi Deuteranopia"
        settings.colorVision = .redGreen
        XCTAssertEqual(settings.terminalScheme, "Modus Operandi Deuteranopia")
        XCTAssertEqual(MobileSettings(defaults: store).colorVision, .redGreen)
    }

    /// Color scheme lists only the vision's schemes, and typical vision none of them.
    func testColorSchemeListsTheVisionsSchemes() {
        let all = TerminalSchemes.all()
        let made = Set(ColorVision.bundledSchemes.values.flatMap { $0.light + $0.dark })
        XCTAssertEqual(made.count, 6)
        XCTAssertEqual(Set(all.map(\.file)).intersection(made), made, "every one is bundled")
        let typical = TerminalSchemes.listed(all, for: .typical)
        XCTAssertEqual(typical.count, all.count - made.count)
        XCTAssertEqual(typical.first?.file, TerminalConfiguration.defaultScheme)
        XCTAssertEqual(Set(TerminalSchemes.listed(all, for: .redGreen).map(\.file)),
                       ["GitHub Light Colorblind", "Modus Operandi Deuteranopia", "GitHub Dark Colorblind", "Modus Vivendi Deuteranopia"])
        XCTAssertEqual(Set(TerminalSchemes.listed(all, for: .blueYellow).map(\.file)), ["Modus Operandi Tritanopia", "Modus Vivendi Tritanopia"])
    }

    /// Hosts are drawn from the store the settings feed: the vision's colours, or gray with Color-code hosts off.
    func testHostColorsFollowTheSettings() {
        let store = defaults()
        let settings = MobileSettings(defaults: store)
        let colors = HostColorStore()
        colors.enabled = false
        settings.hostColors = colors
        XCTAssertTrue(colors.enabled, "taken at once")
        XCTAssertEqual(colors.vision, .typical)
        settings.colorVision = .blueYellow
        XCTAssertEqual(colors.vision, .blueYellow)
        settings.showHostColors = false
        XCTAssertFalse(colors.enabled)
        XCTAssertFalse(store.bool(forKey: MobileSettings.hostColorsKey))
        XCTAssertFalse(MobileSettings(defaults: store).showHostColors)
        XCTAssertTrue(MobileSettings(defaults: defaults()).showHostColors, "on by default")
    }

    /// Added and removed are the catalog's green and red, and in colorblind mode the vision's schemes' own, per side.
    func testChangeColorsFollowTheVision() {
        func hex(_ color: UIColor, _ vision: ColorVision, _ style: UIUserInterfaceStyle) -> String {
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            color.resolvedColor(with: UITraitCollection { $0.userInterfaceStyle = style; $0[ColorVisionTrait.self] = vision })
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertEqual(hex(CodePalette.added, .typical, style), hex(UIColor.dispatch("Added").resolvedColor(with: traits), .typical, style))
            XCTAssertEqual(hex(CodePalette.removed, .typical, style), hex(UIColor.dispatch("Destructive").resolvedColor(with: traits), .typical, style))
        }
        XCTAssertEqual(hex(CodePalette.added, .redGreen, .dark), "58a6ff", "GitHub Dark Colorblind's blue")
        XCTAssertEqual(hex(CodePalette.removed, .redGreen, .dark), "ec8e2c", "and its orange")
        XCTAssertEqual(hex(CodePalette.added, .redGreen, .light), "0550ae")
        XCTAssertEqual(hex(CodePalette.removed, .redGreen, .light), "b35900")
        XCTAssertEqual(hex(CodePalette.added, .blueYellow, .dark), "44bc44", "Modus Vivendi Tritanopia's green")
        XCTAssertEqual(hex(CodePalette.removed, .blueYellow, .light), "a60000")
    }
}
