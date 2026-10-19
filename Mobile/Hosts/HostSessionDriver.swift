import Foundation

/// A host key the server offered, for trust on first use (plan 3.6).
struct HostKeyOffer: Equatable, Sendable {
    let host: String
    let port: Int
    /// "ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", ...
    let algorithm: String
    /// The SSH wire public key blob.
    let key: Data
    var fingerprint: String { SSHKeyEncoding.fingerprint(key) }
}

/// What a driver reports while it connects and keeps a host connected. `HostSession` applies them in order on the
/// main actor.
enum HostSessionEvent: Sendable {
    /// connecting, authenticating, bootstrapping, reconnecting, failed. `.connected` comes with `.ready`.
    case link(HostLink)
    /// The helper answered `hello` and the session is usable: the link becomes `.connected` in the same update.
    /// `multiplexers` lists only the multiplexers installed on the host (`native` is ignored); `versions` gives
    /// their versions by name ("tmux": "3.7"). Pass the first topology here when it is already known, so no row
    /// shows a connected host without its counts.
    case ready(client: HelperClient, hello: HelperSession.Info, multiplexers: [HelperClient.Multiplexer],
               versions: [String: String], topology: HelperTopology?)
    case topology(HelperTopology)
    /// The followed multiplexer has no server on this connection (none chosen, herdr not running, or tmux's open
    /// failed): the host has no spaces now, so a snapshot kept from the cache or an earlier connection goes.
    case noBackend
    /// The multiplexer whose topology the session follows ("tmux", "herdr"): where the host's spaces are, and where
    /// New space makes one.
    case following(String?)
    /// A `stats.ping` round trip.
    case latency(Duration)
}

/// How the driver starts the helper (docs/ios.md, Helper contract): `command(sha256)` on a plain exec channel, with no
/// PTY and no environment of its own. `sha256` is the shipped helper's version (the hash its install is named by).
struct HelperLaunch: Sendable, Equatable {
    var capabilities = HelperGrant.capabilityList
    var pty = false
    var environment: [String: String] = [:]
    func command(sha256: String) -> String {
        "exec \"\(HelperGrant.path(sha256: sha256))\" --remote --capabilities \(capabilities) --stdio"
    }
}

/// A keyboard-interactive login round (RFC 4256: PAM passwords, one-time codes): the server's name, instruction and
/// prompts; the user answers each prompt or cancels. Not in the mockup: a plain sheet (`HostLoginPromptSheet`).
struct HostLoginChallenge: Equatable, Sendable {
    struct Prompt: Equatable, Sendable {
        let text: String
        /// The answer may be shown while typed (a code), else it is hidden (a password).
        let echo: Bool
    }
    let name: String
    let instruction: String
    let prompts: [Prompt]
}

/// What a session lends its driver.
struct HostSessionContext: Sendable {
    /// The helper's command line and grant.
    var launch = HelperLaunch()
    /// Asks the known-hosts store, and the user on first use. False: abort the connection (the session shows why).
    let verifyHostKey: @Sendable (HostKeyOffer) async -> Bool
    /// The host's key (Face ID prompts on a device), or nil for password hosts.
    let key: @Sendable () async throws -> KeyMaterial?
    let password: @Sendable () async throws -> String?
    /// Yields on `HostSession.retryNow()` (a network change, foregrounding): while the driver waits between reconnect
    /// attempts it tries again at once; while connected it checks that the link still answers (a change of network
    /// can leave it dead without a word) and reconnects when it does not.
    let retries: AsyncStream<Void>
    /// Asks the user a keyboard-interactive round; nil cancels the login.
    var keyboardInteractive: @Sendable (HostLoginChallenge) async -> [String]? = { _ in nil }
    /// Whether the host's key is still on the phone: a driver that keeps the key it read for its reconnects asks before
    /// each one, so a deleted key is never used again.
    var keyAvailable: @Sendable () async -> Bool = { true }
    /// The host's multiplexer preference each time it changes while the run lasts (host detail, Settings): the driver
    /// follows the new choice on the live connection, without reconnecting.
    var preferences: AsyncStream<HostRecord.MultiplexerPreference> = AsyncStream { $0.finish() }
}

/// Connects one host and keeps it connected (`SSHHostSessionDriver` in Mobile/Transport/Integration implements it over SSH; tests and previews use
/// `ScriptedHostSessionDriver`). `run` returns the events of one connection's life, through reconnects; the stream
/// finishes when the driver gives up (after a final `.link(.failed(...))`), and cancelling the consumer
/// (`HostSession.disconnect()`) closes the connection. Never terminates anything on the host.
protocol HostSessionDriver: Sendable {
    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent>
}
