import Foundation

/// A host the user added on this phone (M8a): where it is, who logs in and how. Saved by `HostStore`; secrets (a
/// password, a private key) stay in the Keychain under `KeyStore`, never here. The Mac's `HostRecord` (a machine seen
/// through its helper) is AppKit-only; this one answers `system` like it, so `HostGlyph` draws both.
struct HostRecord: Identifiable, Equatable, Codable, Sendable {
    /// How the phone logs in.
    enum Auth: Equatable, Codable, Sendable {
        /// The password is in the Keychain under the host's id (`KeyStore.password(for:)`).
        case password
        /// A key from `KeyStore`.
        case key(UUID)
    }

    /// Which multiplexer's sessions become spaces (plan 3.2): herdr when both are installed, unless the host says.
    enum MultiplexerPreference: String, Codable, CaseIterable, Sendable {
        case automatic = "auto", herdr, tmux
        var title: String {
            switch self { case .automatic: "Automatic"; case .herdr: "herdr"; case .tmux: "tmux" }
        }
    }

    let id: UUID
    var name: String
    var address: String
    var port: Int = 22
    var user: String
    var auth: Auth
    var multiplexer: MultiplexerPreference = .automatic
    /// Upload and run the helper (docs/ios.md, Plain SSH): off, the phone only opens PTY shells on its own SSH
    /// connection, without Chat, Agents, Files, spaces from a server or background refresh. Turning it off turns `chat`
    /// and `files` off too.
    var helper = true {
        didSet {
            if !helper, chat { chat = false }
            if !helper, files { files = false }
        }
    }
    /// Chat with the host's agents (Settings): off runs the helper without hooks or agent capabilities
    /// (`HelperGrant.capabilities(chat:)`), and the host's agents show as terminals only. Always off without the
    /// helper (`helper`): setting it then keeps it off.
    var chat = true {
        didSet { if chat, !helper { chat = false } }
    }
    /// Files & git (Settings, host detail, New host): on, the helper's grant adds `git.read` (`HelperGrant`), so the tab
    /// screen's Files segment lists, diffs and reads the log; off, Files explains it is not allowed (S2). The same
    /// policy as `chat`: on by default, always off without the helper.
    var files = true {
        didSet { if files, !helper { files = false } }
    }
    var order: Int = 0
    var lastConnected: Date?
    /// Seeds `HostTint`: the machine identity the helper reported when the host was verified (the Mac app colours the
    /// same machine from the same identity), else the record's id. Fixed once saved, so a row never changes colour.
    var tintSeed: String
    /// The colour given when the host was added, as the Mac's HostRegistry gives one: the colour fewest other hosts
    /// show, `tintSeed`'s hash breaking ties. Nil for hosts saved before it: their hash's colour, as they always showed.
    var color: HostColor?
    /// The user chose `color` (the stats sheet's Color picker); false: Automatic, the colour the host was given.
    var colorPicked = false
    /// What the helper last reported about the operating system: the glyph and line three of an offline row.
    var system: HostSystem?
    /// "macOS 26.1", "Ubuntu 24.04".
    var osLabel: String?

    init(id: UUID = UUID(), name: String, address: String, port: Int = 22, user: String, auth: Auth,
         multiplexer: MultiplexerPreference = .automatic, helper: Bool = true, chat: Bool = true, files: Bool = true, order: Int = 0,
         lastConnected: Date? = nil, tintSeed: String? = nil, system: HostSystem? = nil, osLabel: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.auth = auth
        self.multiplexer = multiplexer
        self.helper = helper
        self.chat = chat && helper
        self.files = files && helper
        self.order = order
        self.lastConnected = lastConnected
        self.tintSeed = tintSeed ?? id.uuidString
        self.system = system
        self.osLabel = osLabel
    }

    var tint: HostTint { HostTint(hostID: tintSeed) }

    /// Whether `other` reaches the same account the same way: only then may a live connection carry over an edit.
    func sameConnection(as other: HostRecord) -> Bool {
        address == other.address && port == other.port && user == other.user && auth == other.auth
    }

    /// The operating system line: the helper's label, else what the system names itself.
    static func osLabel(_ identity: HelperSession.Info.Identity) -> String {
        if let label = identity.os_label, !label.isEmpty { return label }
        // Older helpers: os-release's PRETTY_NAME already carries a version; macOS has none to add.
        if let name = identity.os_name, !name.isEmpty { return name }
        let system = HostSystem(os: identity.os, distribution: identity.distribution, name: nil)
        return [system.label, identity.os_version].compactMap { $0 }.joined(separator: " ")
    }
}

extension HostRecord {
    /// Records saved before a field existed read with its default (`helper`, `chat` and `files` on); a record without
    /// the helper reads with Chat and Files off whatever the file says.
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        address = try fields.decode(String.self, forKey: .address)
        port = try fields.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try fields.decode(String.self, forKey: .user)
        auth = try fields.decode(Auth.self, forKey: .auth)
        // A preference this build does not know (a newer build's, after a downgrade) is Automatic, not an unreadable file.
        multiplexer = (try? fields.decodeIfPresent(MultiplexerPreference.self, forKey: .multiplexer)) ?? .automatic
        helper = try fields.decodeIfPresent(Bool.self, forKey: .helper) ?? true
        chat = try (fields.decodeIfPresent(Bool.self, forKey: .chat) ?? true) && helper
        files = try (fields.decodeIfPresent(Bool.self, forKey: .files) ?? true) && helper
        order = try fields.decodeIfPresent(Int.self, forKey: .order) ?? 0
        lastConnected = try fields.decodeIfPresent(Date.self, forKey: .lastConnected)
        tintSeed = try fields.decodeIfPresent(String.self, forKey: .tintSeed) ?? id.uuidString
        system = try fields.decodeIfPresent(HostSystem.self, forKey: .system)
        osLabel = try fields.decodeIfPresent(String.self, forKey: .osLabel)
        color = try? fields.decodeIfPresent(HostColor.self, forKey: .color)
        colorPicked = (try? fields.decodeIfPresent(Bool.self, forKey: .colorPicked)) ?? false
    }
}
