import XCTest
import SwiftUI
@testable import DispatchApp

@MainActor
final class HostRegistryTests: XCTestCase {
    private func greeting(_ host: String, uid: UInt32 = 501) -> SSHGreeting {
        SSHGreeting(version: 1, host: host, boot: "boot", uid: uid, home: "/tmp", capabilities: [])
    }

    /// A remote helper's identity names hosts and paths only when it is well formed
    /// (ported from SSHProtocolV2Tests' greeting spoof cases).
    func testGreetingIdentityRejectsMalformedHostsAndPaths() {
        let valid = greeting("build")
        XCTAssertNoThrow(try valid.validate())
        let malformed = [
            SSHGreeting(version: 4, host: "host\nspoof", boot: "boot", uid: 501, home: "/tmp", capabilities: []),
            SSHGreeting(version: 4, host: "", boot: "boot", uid: 501, home: "/tmp", capabilities: []),
            SSHGreeting(version: 4, host: "build", boot: "boot\u{1b}", uid: 501, home: "/tmp", capabilities: []),
            SSHGreeting(version: 4, host: "build", boot: "boot", uid: 501, home: "relative/path", capabilities: []),
            SSHGreeting(version: 4, host: String(repeating: "h", count: 1025), boot: "boot", uid: 501, home: "/tmp", capabilities: []),
            SSHGreeting(version: 4, host: "build", boot: "boot", uid: 501, home: "/tmp", capabilities: ["files.text", "files.text"]),
        ]
        XCTAssertEqual(malformed.map { (try? $0.validate()) == nil }, Array(repeating: true, count: malformed.count))
    }

    func testIdentityMergesAliasesAndUsersWithoutMergingNames() {
        let hosts = HostRegistry(defaults: nil)
        let first = UUID(), second = UUID(), third = UUID(), a = UUID(), b = UUID(), c = UUID()
        hosts.begin(first, generation: a, destination: "alice@build")
        hosts.begin(second, generation: b, destination: "root@build-alias")
        XCTAssertNotEqual(hosts.terminals[first]?.host, hosts.terminals[second]?.host)
        hosts.update(second, generation: b, destination: "root@build-alias", greeting: greeting("one", uid: 0), state: .connected)
        hosts.update(first, generation: a, destination: "alice@build", greeting: greeting("one"), state: .connected)
        let id = HostID.authenticated("one")
        XCTAssertEqual(hosts.terminals[first]?.host, id)
        XCTAssertEqual(hosts.terminals[second]?.host, id)
        XCTAssertEqual(hosts.record(id).name, "build", "The earliest destination remains the display name, regardless of reply order")
        XCTAssertEqual(Set(hosts.record(id).destinations), ["alice@build", "root@build-alias"])
        hosts.begin(third, generation: c, destination: "alice@build")
        hosts.update(third, generation: c, destination: "alice@build", greeting: greeting("two"), state: .connected)
        XCTAssertNotEqual(hosts.terminals[third]?.host, id, "Identical display names do not prove machine identity")
        XCTAssertEqual(hosts.ordered([id, .authenticated("two")]).map(\.id), [.local, id, .authenticated("two")])
    }

    /// A glass strip leads with the active tab's host once any of its tabs is remote, and keeps that slot (showing
    /// the Mac) while a local tab is active, so switching tabs never shifts the tabs after it.
    func testGlassStripLeadsWithTheActiveTabsHost() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace, workspace = Workspace()
        runtime.workspace = workspace
        defer { runtime.workspace = previous }
        let local = TerminalTab(directory: "/tmp"), remote = TerminalTab(directory: "/tmp")
        XCTAssertNil(runtime.ssh.stripHost(active: local, among: [local, remote]), "An all-local strip has no host mark")
        let generation = UUID()
        workspace.hosts.begin(remote.focusedSurfaceID, generation: generation, destination: "strip-fixture")
        // Until the host identifies itself the mark pulses, neutral, under a placeholder identity; landing swaps it.
        let pending = try XCTUnwrap(runtime.ssh.stripHost(active: remote, among: [local, remote]))
        XCTAssertTrue(pending.connecting)
        XCTAssertTrue(pending.provisional)
        workspace.hosts.update(remote.focusedSurfaceID, generation: generation, destination: "strip-fixture",
                               greeting: greeting("strip-fixture"), state: .connected)
        let shown = try XCTUnwrap(runtime.ssh.stripHost(active: remote, among: [local, remote]))
        XCTAssertEqual(shown.record?.id, .authenticated("strip-fixture"))
        XCTAssertFalse(shown.connecting)
        XCTAssertFalse(shown.provisional)
        XCTAssertNotEqual(shown.key, pending.key, "Connecting lands as a host switch")
        XCTAssertEqual(shown.tint, runtime.ssh.tint(for: remote))
        let mac = try XCTUnwrap(runtime.ssh.stripHost(active: local, among: [local, remote]), "A local tab keeps the slot")
        XCTAssertEqual(mac.record?.id, .local)
        XCTAssertNil(mac.tint)
        XCTAssertFalse(mac.connecting)
        XCTAssertNotEqual(mac.key, shown.key, "Switching between local and remote tabs swaps the mark")
        workspace.hosts.remove(remote.focusedSurfaceID)
        XCTAssertNil(runtime.ssh.stripHost(active: local, among: [local, remote]), "The slot goes with the last remote tab")
    }

    /// The host mark's space picker lists spaces in the sidebar's order, under their hosts while the sidebar groups
    /// them.
    func testHostMarkSpacePickerListsSpacesByHost() throws {
        let workspace = Workspace()
        let remote = HostID.authenticated("menu-fixture")
        var local = Space(name: "notes", directory: "/tmp"), first = Space(name: "api", directory: "/srv")
        var second = Space(name: "web", directory: "/srv")
        first.hostID = remote; second.hostID = remote
        local.hostID = .local
        workspace.spaces = [first, local, second]
        workspace.selectSpace(first.id)
        func entries() -> [String] {
            StripSpaceMenu.sections(workspace).flatMap { section in
                (section.host.map { ["[\($0.id == .local ? "local" : $0.name)]"] } ?? []) + section.spaces.map(\.name)
            }
        }
        workspace.spaceOrder = .tree
        let name = workspace.hosts.record(remote).name
        XCTAssertEqual(entries(), workspace.liveHosts.first?.id == .local
            ? ["[local]", "notes", "[\(name)]", "api", "web"]
            : ["[\(name)]", "api", "web", "[local]", "notes"])
        workspace.spaceOrder = .flat
        XCTAssertEqual(entries(), ["api", "notes", "web"], "A flat sidebar lists spaces without host headings")
    }

    /// With every color remembered, a new host still avoids the colors connected hosts show. A connection not yet
    /// identified previews such a color, keeps it while another connects, and the new host it turns out to be keeps it.
    func testNewHostsAvoidColorsConnectedHostsShow() throws {
        let store = HostColorStore.shared, previous = (store.choices, store.automatic)
        defer { store.choices = previous.0; store.automatic = previous.1 }
        store.choices = [:]
        let hosts = HostRegistry(defaults: nil)
        func remember(_ name: String) -> HostID {
            let terminal = UUID(), generation = UUID()
            hosts.begin(terminal, generation: generation, destination: name)
            hosts.update(terminal, generation: generation, destination: name, greeting: greeting(name), state: .connected)
            hosts.remove(terminal)
            return .authenticated(name)
        }
        func color(_ id: HostID) throws -> HostColor { try XCTUnwrap(hosts.record(id).tint).automatic }
        // Every color twice over, none connected.
        let remembered = try (0..<(HostColor.allCases.count * 2)).map { index in
            let id = remember("remembered-\(index)")
            _ = try color(id)
            return id
        }
        XCTAssertEqual(Set(try remembered.map(color)), Set(HostColor.allCases))
        // Three of them connect again.
        var connected = try Set(remembered.prefix(3).map(color))
        for id in remembered.prefix(3) { hosts.seed(UUID(), from: id, generation: UUID()) }
        XCTAssertEqual(connected.count, 3, "Fixture: three different colors on screen")

        let first = UUID(), second = UUID(), generation = UUID()
        hosts.begin(first, generation: generation, destination: "new-one")
        let pending = try XCTUnwrap(hosts.terminals[first]?.host)
        XCTAssertTrue(pending.isProvisional)
        let preview = try color(pending)
        XCTAssertFalse(connected.contains(preview), "A pending connection doesn't borrow a color on screen")
        connected.insert(preview)
        // Another host connecting meanwhile neither takes the preview nor changes it.
        let other = UUID(), otherGeneration = UUID()
        hosts.begin(other, generation: otherGeneration, destination: "new-two")
        hosts.update(other, generation: otherGeneration, destination: "new-two", greeting: greeting("new-two"), state: .connected)
        let otherColor = try color(.authenticated("new-two"))
        XCTAssertFalse(connected.contains(otherColor), "A new host takes a color no connected host shows")
        XCTAssertEqual(try color(pending), preview, "A preview holds while its connection lasts")
        connected.insert(otherColor)

        hosts.update(first, generation: generation, destination: "new-one", greeting: greeting("new-one"), state: .connected)
        XCTAssertEqual(try color(.authenticated("new-one")), preview, "The new host keeps the color it connected with")
        XCTAssertNil(hosts.records[pending], "The placeholder goes once its connection is identified")
        hosts.begin(second, generation: UUID(), destination: "new-three")
        XCTAssertFalse(connected.contains(try color(try XCTUnwrap(hosts.terminals[second]?.host))))
    }

    /// Every host icon is one size, growing with the font, and every kind of glyph draws that size: its longer side
    /// fills the same share of the frame and stays inside it, whether an SF Symbol, an asset or the drawn Ubuntu mark.
    func testHostGlyphsDrawOneSizeAtEveryFontSize() throws {
        let systems: [(String, HostSystem?)] = [
            ("mac", .mac), ("linux", HostSystem(os: "Linux")), ("unknown", nil),
            ("ubuntu", HostSystem(os: "Linux", distribution: "ubuntu")),
            ("debian", HostSystem(os: "Linux", distribution: "debian")), ("freebsd", HostSystem(os: "FreeBSD")),
        ]
        for contentSize: CGFloat in [12.5, 16, 20] {
            let size = AppTypography(contentSize: contentSize).hostIconSize
            XCTAssertEqual(size, 15 * max(1, contentSize / 12.5), accuracy: 0.01)
            for metrics in [SidebarMetrics.compact(contentSize: contentSize), .large(contentSize: contentSize),
                            .icons(contentSize: contentSize)] {
                XCTAssertEqual(metrics.hostIconSize, size, "The sidebar uses the app's host icon size")
            }
            for (name, system) in systems {
                let host = HostRecord(id: HostID(rawValue: "ssh:" + name), name: name, system: system, destinations: [], order: 0)
                let extent = try Self.inkExtent(HostGlyph(host: host, size: size).foregroundStyle(.black), side: size)
                XCTAssertEqual(extent.longer, HostGlyph.fill, accuracy: 0.05,
                               "\(name) at \(contentSize): its longer side fills the shared share of the frame")
                XCTAssertTrue(extent.inside, "\(name) at \(contentSize) stays inside its frame")
            }
        }
    }

    /// The share of a `side`-point square the view's ink spans along its longer side, and whether it stays inside.
    private static func inkExtent(_ view: some View, side: CGFloat) throws -> (longer: CGFloat, inside: Bool) {
        // Rendered in a larger canvas, so ink past the frame shows instead of being cut off.
        let canvas = side * 2, scale: CGFloat = 4
        let renderer = ImageRenderer(content: view.frame(width: canvas, height: canvas))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 25 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, 0, "The glyph draws something")
        let frame = side * scale, origin = (CGFloat(width) - frame) / 2
        let longer = CGFloat(max(maxX - minX + 1, maxY - minY + 1)) / frame
        let inside = CGFloat(minX) >= origin - 1 && CGFloat(maxX) <= origin + frame + 1
            && CGFloat(minY) >= origin - 1 && CGFloat(maxY) <= origin + frame + 1
        return (longer, inside)
    }

    func testHostsGetFreeColorsUntilAllAreTakenAndForgettingFreesOne() throws {
        let store = HostColorStore.shared, previous = (store.choices, store.automatic)
        defer { store.choices = previous.0; store.automatic = previous.1 }
        store.choices = [:]
        let hosts = HostRegistry(defaults: nil)
        func connect(_ name: String) -> HostID {
            let terminal = UUID(), generation = UUID()
            hosts.begin(terminal, generation: generation, destination: name)
            hosts.update(terminal, generation: generation, destination: name, greeting: greeting(name), state: .connected)
            hosts.remove(terminal)
            return .authenticated(name)
        }
        func shown(_ id: HostID) throws -> HostColor { try XCTUnwrap(hosts.record(id).tint).automatic }
        let ids = HostColor.allCases.indices.map { connect("machine-\($0)") }
        let first = try ids.map(shown)
        XCTAssertEqual(Set(first), Set(HostColor.allCases), "No two hosts share a color while one is free")
        let freed = first[2]
        hosts.forget(ids[2])
        XCTAssertEqual(try shown(connect("replacement")), freed, "A forgotten host's color goes to the next new host")
        XCTAssertEqual(try ids.filter { $0 != ids[2] }.map(shown), first.enumerated().filter { $0.offset != 2 }.map(\.element),
                       "Existing hosts keep their colors")

        // Relaunch keeps every color; one saved under a since-removed name is reassigned.
        var saved = Array(hosts.records.values)
        let stale = try XCTUnwrap(saved.firstIndex { $0.id == ids[1] })
        let removed = try shown(ids[1])
        saved[stale].colorName = "plum"
        let before = try Dictionary(uniqueKeysWithValues: saved.filter { $0.id != ids[1] && $0.id != .local }.map { ($0.id, try shown($0.id)) })
        let relaunched = HostRegistry(defaults: nil)
        relaunched.restore(saved)
        for (id, color) in before { XCTAssertEqual(try XCTUnwrap(relaunched.record(id).tint).automatic, color) }
        XCTAssertEqual(try XCTUnwrap(relaunched.record(ids[1]).tint).automatic, removed, "The only free color replaces the removed one")
    }

    func testTreeOrderMovesHostsIncludingLocalAndPersists() throws {
        let suite = "HostRegistryTests.order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosts = HostRegistry(defaults: defaults)
        for name in ["one", "two"] {
            let terminal = UUID(), generation = UUID()
            hosts.begin(terminal, generation: generation, destination: name)
            hosts.update(terminal, generation: generation, destination: name, greeting: greeting(name), state: .connected)
        }
        let one = HostID.authenticated("one"), two = HostID.authenticated("two"), live: Set<HostID> = [one, two]
        XCTAssertEqual(hosts.ordered(live).map(\.id), [.local, one, two])
        hosts.move(two, relativeTo: one, after: false)
        XCTAssertEqual(hosts.ordered(live).map(\.id), [.local, two, one])
        hosts.move(.local, relativeTo: one, after: true)
        XCTAssertEqual(hosts.ordered(live).map(\.id), [two, one, .local])
        hosts.move(one, relativeTo: one, after: true)
        XCTAssertEqual(hosts.ordered(live).map(\.id), [two, one, .local])
        XCTAssertEqual(HostRegistry(defaults: defaults).ordered(live).map(\.id), [two, one, .local], "Order survives relaunch")
    }

    func testStaleCallbacksCannotReplaceAConnectionAndFailuresAggregate() {
        let hosts = HostRegistry(defaults: nil), terminal = UUID(), other = UUID(), old = UUID(), current = UUID(), live = UUID()
        hosts.begin(terminal, generation: old, destination: "old")
        hosts.begin(terminal, generation: current, destination: "new")
        XCTAssertNil(hosts.update(terminal, generation: old, destination: "old", greeting: greeting("old"), state: .connected))
        hosts.remove(terminal, generation: old)
        XCTAssertEqual(hosts.terminals[terminal]?.generation, current)
        hosts.update(terminal, generation: current, destination: "new", greeting: greeting("same"), state: .connected)
        hosts.begin(other, generation: live, destination: "alias")
        hosts.update(other, generation: live, destination: "alias", greeting: greeting("same"), state: .connected)
        hosts.setState(.disconnected, generation: current)
        XCTAssertEqual(hosts.state(.authenticated("same")), .connected)
        hosts.setState(.disconnected, generation: live)
        XCTAssertEqual(hosts.state(.authenticated("same")), .disconnected)
        XCTAssertEqual(hosts.terminals[terminal]?.host, .authenticated("same"), "Helper failure does not make a surviving SSH terminal local")
    }

    func testOldGreetingsMetadataPersistenceSeedsAndEmptyCards() throws {
        let old = try JSONDecoder().decode(SSHGreeting.self, from: Data(#"{"version":1,"host":"old","boot":"b","uid":501,"home":"/tmp","capabilities":[]}"#.utf8))
        XCTAssertNil(old.hostname); XCTAssertNil(old.os)
        let suite = "HostRegistryTests-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosts = HostRegistry(defaults: defaults), terminal = UUID(), generation = UUID()
        hosts.begin(terminal, generation: generation, destination: "user@server")
        var known = greeting("identity")
        known.hostname = "actual-host"; known.os = "Linux"; known.distribution = "ubuntu"; known.osName = "Ubuntu 26.04"
        hosts.update(terminal, generation: generation, destination: "user@server", greeting: known, state: .connected)
        let id = HostID.authenticated("identity"), seed = UUID(), seedGeneration = UUID()
        hosts.seed(seed, from: id, generation: seedGeneration)
        XCTAssertEqual(hosts.terminals[seed]?.host, id)
        XCTAssertEqual(hosts.terminals[seed]?.state, .connecting)
        hosts.update(seed, generation: seedGeneration, destination: "user@server", greeting: greeting("different"), state: .connected)
        XCTAssertEqual(hosts.terminals[seed]?.host, .authenticated("different"))
        let restored = HostRegistry(defaults: defaults)
        XCTAssertEqual(restored.record(id).name, "server")
        XCTAssertEqual(restored.record(id).system?.distribution, "ubuntu")
        XCTAssertEqual(restored.ordered([]).map(\.id), [.local], "Empty remote cards are omitted while metadata persists")
        XCTAssertTrue(restored.terminals.isEmpty, "Restarting cannot fabricate live connections")
        restored.reset()
        XCTAssertNil(defaults.object(forKey: "HostRegistry.v1"))
        XCTAssertEqual(Set(HostRegistry(defaults: defaults).records.keys), [.local])
        restored.begin(terminal, generation: UUID(), destination: "fresh-alias")
        XCTAssertEqual(restored.terminals.count, 1)
        XCTAssertEqual(restored.records.values.first { $0.id != .local }?.order, 0)
    }

    func testPersistedExtremeOrderCannotOverflowWhenAnotherHostArrives() throws {
        let suite = "HostRegistryTests-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = HostRecord(id: .authenticated("saved"), name: "saved", destinations: [], order: Int.max)
        defaults.set(try JSONEncoder().encode([saved]), forKey: "HostRegistry.v1")
        let hosts = HostRegistry(defaults: defaults), generation = UUID()
        hosts.begin(UUID(), generation: generation, destination: "next")
        XCTAssertEqual(hosts.ordered([saved.id, .provisional(generation)]).map(\.name), ["Local", "saved", "next"])
    }

    func testSameLoginSharesPresentationWithoutSharingAuthenticationOrGeneration() throws {
        let hosts = HostRegistry(defaults: nil)
        let scope = try XCTUnwrap(HostRegistry.loginScope(executable: "/usr/bin/ssh", destination: "alice@build",
            configuration: "hostname build\nuser alice\nport 22\nrequesttty auto\nclearallforwardings no\n"))
        let clone = try XCTUnwrap(HostRegistry.loginScope(executable: "/usr/bin/ssh", destination: "alice@build",
            configuration: "hostname build\nuser alice\nport 22\nrequesttty force\nclearallforwardings yes\ncontrolpath /tmp/unique\n"))
        XCTAssertEqual(scope, clone)
        let first = UUID(), second = UUID(), a = UUID(), b = UUID()
        hosts.begin(first, generation: a, destination: scope.destination, state: .unverified, scope: scope)
        hosts.begin(second, generation: b, destination: scope.destination, state: .unverified, scope: clone)
        XCTAssertEqual(hosts.terminals[first]?.host, hosts.terminals[second]?.host)
        XCTAssertNotEqual(hosts.terminals[first]?.generation, hosts.terminals[second]?.generation)
        hosts.update(first, generation: a, destination: scope.destination, greeting: greeting("one"), state: .connected)
        XCTAssertEqual(hosts.terminals[second]?.host, .authenticated("one"))
        XCTAssertEqual(hosts.terminals[second]?.authenticated, false)
        XCTAssertEqual(hosts.terminals[second]?.state, .unverified)
        hosts.update(second, generation: b, destination: scope.destination, greeting: greeting("two"), state: .connected)
        XCTAssertNotEqual(hosts.terminals[first]?.host, hosts.terminals[second]?.host, "Conflicting machine identities split the group")
        let third = UUID()
        hosts.begin(third, generation: UUID(), destination: scope.destination, scope: scope)
        XCTAssertEqual(hosts.terminals[third]?.host, .login(scope), "An ambiguous login must not choose either verified machine")
        hosts.remove(first, generation: b)
        XCTAssertNotNil(hosts.terminals[first], "Another tab cannot end this connection")
    }

    func testLoginGroupingSeparatesRoutesAccountsAndExecutables() throws {
        let configuration = "hostname build\nuser alice\nport 22\nproxyjump none\n"
        let base = try XCTUnwrap(HostRegistry.loginScope(executable: "/usr/bin/ssh", destination: "build", configuration: configuration))
        for changed in [configuration.replacingOccurrences(of: "alice", with: "bob"),
                        configuration.replacingOccurrences(of: "22", with: "2222"),
                        configuration.replacingOccurrences(of: "none", with: "bastion"),
                        configuration.replacingOccurrences(of: "hostname build", with: "hostname other")] {
            XCTAssertNotEqual(base, HostRegistry.loginScope(executable: "/usr/bin/ssh", destination: "build", configuration: changed))
        }
        XCTAssertNotEqual(base, HostRegistry.loginScope(executable: "/opt/bin/ssh", destination: "build", configuration: configuration))
        XCTAssertNil(HostRegistry.loginScope(executable: "/usr/bin/ssh", destination: "build", configuration: "user alice\n"))
        let hosts = HostRegistry(defaults: nil), first = UUID()
        hosts.begin(first, generation: UUID(), destination: "build", scope: base)
        let original = hosts.terminals[first]?.host
        hosts.remove(first)
        let second = UUID()
        hosts.begin(second, generation: UUID(), destination: "build", scope: base)
        XCTAssertEqual(hosts.terminals[second]?.host, original, "Reconnect reuses the stable login group")
    }

}
