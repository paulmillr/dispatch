import Foundation
import UIKit

extension HostSessions {
    /// The app's hosts: the saved stores in the app container and the Keychain, connected at once (the app starts
    /// in the foreground). `DISPATCH_MOBILE_SCRIPTED=1` (Debug) shows scripted demo hosts in memory instead, for
    /// screenshots and UI tests; nothing is read or written.
    static func app(environment: [String: String] = ProcessInfo.processInfo.environment) -> HostSessions {
        #if DEBUG
        if let scripted = environment["DISPATCH_MOBILE_SCRIPTED"], scripted != "0" {
            return demo(empty: scripted == "empty", studio: scripted == "empty" ? .trust : DemoStudio(rawValue: scripted) ?? .connects)
        }
        #endif
        #if DEBUG
        // Live UI tests against a fixture sshd (docs/ios.md, Testing): nothing saved, no Face ID.
        if environment["DISPATCH_MOBILE_STORE"] == "memory" {
            let sessions = HostSessions(store: HostStore(url: nil), knownHosts: KnownHostStore(url: nil),
                                        keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none))
            sessions.testHooks(environment)
            return sessions
        }
        #endif
        let sessions = HostSessions(store: HostStore(), knownHosts: KnownHostStore(), keys: KeyStore(keyProtection: Self.keyProtection))
        #if DEBUG
        sessions.testHooks(environment)
        #endif
        return sessions
    }

    /// The app's sessions over SSH, connecting in the foreground. A launch in the background (the app refresh task)
    /// connects nothing until the app comes to the foreground: the refresh has its own sessions.
    convenience init(store: HostStore, knownHosts: KnownHostStore, keys: KeyStore) {
        self.init(store: store, keys: keys, knownHosts: knownHosts, driver: SSHHostSessionDriver(),
                  active: UIApplication.shared.applicationState != .background)
    }

    /// Face ID guards private keys on a device; the simulator has no enrolled face, so its keys are plain Keychain
    /// items (the device checks in docs/ios.md cover biometry).
    static var keyProtection: KeyProtection {
        #if targetEnvironment(simulator)
        .none
        #else
        .biometry
        #endif
    }

    #if DEBUG
    /// Debug hooks for live runs against fixture hosts:
    /// `DISPATCH_MOBILE_HOST_ENV` (JSON `{"address:port": {"HOME": "/tmp/x/h", …}}`) runs the helper (and its install)
    /// with that environment on that host; `DISPATCH_MOBILE_AUTHORIZE_KEYS` (a path) appends every new key's
    /// `authorized_keys` line to that file (the fixture sshd's).
    private func testHooks(_ environment: [String: String]) {
        if let text = environment["DISPATCH_MOBILE_HOST_ENV"], let data = text.data(using: .utf8),
           let table = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            launch = { record in
                var launch = HelperLaunch()
                launch.environment = table["\(record.address):\(record.port)"] ?? [:]
                return launch
            }
        }
        if let path = environment["DISPATCH_MOBILE_AUTHORIZE_KEYS"] {
            keys.added = { key in
                guard let handle = FileHandle(forWritingAtPath: path) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((key.publicKey + "\n").utf8))
            }
        }
    }
    #endif

    /// How the demo's "studio" (and any host added in the demo) connects: as the mockups show it, asking about its
    /// host key, offering a key that differs from the trusted one, or without tmux or herdr.
    enum DemoStudio: String { case connects, trust, mismatch, nomux }

    /// The mockups' hosts over the scripted driver: two Macs with agents, a third Mac, and an offline Linux VPS.
    static func demo(empty: Bool = false, studio: DemoStudio = .connects) -> HostSessions {
        let studioKey = SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(5), count: 32))
        let now = Date()
        let hosts = empty ? [] : [
            HostRecord(name: "ai", address: "ai.tail3f.ts.net", user: "alex", auth: .password, order: 0,
                       lastConnected: now.addingTimeInterval(-600), tintSeed: "demo-ai", system: .mac, osLabel: "macOS 26.1"),
            HostRecord(name: "mba2", address: "mba2.tail3f.ts.net", user: "alex", auth: .password, order: 1,
                       lastConnected: now, tintSeed: "demo-mba2", system: .mac, osLabel: "macOS 26.1"),
            HostRecord(name: "studio", address: "studio.tail3f.ts.net", user: "alex", auth: .password, order: 2,
                       lastConnected: now.addingTimeInterval(-1800), tintSeed: "demo-studio", system: .mac, osLabel: "macOS 26.1"),
            HostRecord(name: "vps", address: "vps.example.net", user: "root", auth: .password, order: 3,
                       lastConnected: now.addingTimeInterval(-5 * 86_400), tintSeed: "demo-vps",
                       system: HostSystem(os: "Linux", distribution: "ubuntu", name: "Ubuntu 24.04.1 LTS"), osLabel: "Ubuntu 24.04"),
        ]
        let driver = ScriptedHostSessionDriver { host in
            switch host.name {
            case "vps": return [.event(.link(.connecting)), .sleep(.milliseconds(100)), .event(.link(.failed("Connection timed out")))]
            case "ai":
                return [.event(.link(.connecting)), .sleep(.milliseconds(85)), .event(.following("herdr")),
                        .ready(hello: HostFixture.hello(identity: "demo-ai", hostname: "ai"), multiplexers: HostFixture.multiplexers(["herdr", "tmux"]),
                               versions: ["herdr": "0.9.3", "tmux": "3.7"],
                               topology: HostFixture.topology([.init(name: "dispatch", cwd: "/Users/alex/src/dispatch", tabs: 2, agents: 2),
                                                               .init(name: "notes", cwd: "/Users/alex/notes", tabs: 1, agents: 0)])),
                        .event(.latency(.milliseconds(24))), .hold]
            case "mba2":
                return [.event(.link(.connecting)), .sleep(.milliseconds(95)), .event(.following("tmux")),
                        .ready(hello: HostFixture.hello(identity: "demo-mba2", hostname: "mba2"), multiplexers: HostFixture.multiplexers(["tmux"]),
                               versions: ["tmux": "3.7"],
                               topology: HostFixture.topology([.init(name: "web", cwd: "/Users/alex/src/web", tabs: 3, agents: 1),
                                                               .init(name: "infra", cwd: "/Users/alex/src/infra", tabs: 2, agents: 1)])),
                        .event(.latency(.milliseconds(41))), .hold]
            default:
                let offer = HostKeyOffer(host: host.address, port: host.port, algorithm: "ssh-ed25519", key: studioKey)
                switch studio {
                case .connects: return ScriptedHostSessionDriver.connects(host, latency: .milliseconds(38))
                case .trust, .mismatch:
                    return [.event(.link(.connecting)), .hostKey(offer)] + ScriptedHostSessionDriver.connects(host, latency: .milliseconds(38))
                case .nomux:
                    return [.ready(hello: HostFixture.hello(), multiplexers: [], versions: [:], topology: nil),
                            .event(.latency(.milliseconds(38))), .hold]
                }
            }
        }
        let knownHosts = KnownHostStore(url: nil)
        if studio == .mismatch {
            knownHosts.trust(host: "studio.tail3f.ts.net", port: 22, algorithm: "ssh-ed25519",
                             key: SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(6), count: 32)),
                             at: now.addingTimeInterval(-90 * 86_400))
        }
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false)
        if !empty {
            _ = try? keys.importKey(Data(demoKey.utf8), label: "id_ed25519")
            _ = try? keys.generateED25519(label: "studio")
        }
        return HostSessions(store: HostStore(url: nil, hosts: hosts), keys: keys, knownHosts: knownHosts,
                            driver: driver, active: true)
    }

    /// A throwaway key for the demo list (never used to log in anywhere).
    private static let demoKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACAj+Gf1IL3tFrgavF5xeU+nqdBgNYbTsASg2hBXL+UqHwAAAJhu0vrYbtL6
    2AAAAAtzc2gtZWQyNTUxOQAAACAj+Gf1IL3tFrgavF5xeU+nqdBgNYbTsASg2hBXL+UqHw
    AAAEBo03pLWHLr7Q0NakzhHyJt5ZtxIkmC3GfCPHwrtco+uiP4Z/Ugve0WuBq8XnF5T6ep
    0GA1htOwBKDaEFcv5SofAAAAD3ZlY3RvckBkaXNwYXRjaAECAwQFBg==
    -----END OPENSSH PRIVATE KEY-----
    """
}
