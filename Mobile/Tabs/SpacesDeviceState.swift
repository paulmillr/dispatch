import Foundation

/// What Spaces keeps per host on this phone: the space New tab goes to (`recent`), the host sections the user
/// collapsed (M2b), and the phone's order of each host's spaces (M1e). Space keys carry tmux session and herdr workspace
/// names, so this is a private file (`spaces.json` through `PrivateFile`: owner-only, atomic, out of device backups),
/// not UserDefaults, which backups include. Older builds kept these in UserDefaults; they move here once and leave it.
@MainActor
final class SpacesDeviceState {
    struct Document: Codable, Equatable {
        var version = 1
        var recent: SpaceRef?
        var collapsed: [UUID] = []
        /// Host id → space keys in the phone's order.
        var spaceOrder: [String: [String]] = [:]

        init() {}

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = values.lenient(Int.self, forKey: .version, default: 1)
            recent = values.lenient(SpaceRef.self, forKey: .recent)
            collapsed = values.lenientArray(UUID.self, forKey: .collapsed)
            spaceOrder = values.lenientDictionary([String].self, forKey: .spaceOrder)
        }
    }

    static var file: URL { Home.support.appendingPathComponent("spaces.json") }
    static let shared = SpacesDeviceState(url: file, migrating: .standard)
    /// Where older builds kept these values.
    static let legacyKeys = ["tabs.recent", "tabs.collapsed", "tabs.spaceOrder"]

    private(set) var document = Document()
    private let url: URL?

    /// `url` nil keeps everything in memory (tests, previews). `defaults`: an older build's values move from there.
    init(url: URL?, migrating defaults: UserDefaults? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Document.self, from: data) {
            document = saved
        }
        if let defaults { migrate(defaults) }
    }

    var recent: SpaceRef? {
        get { document.recent }
        set { update { $0.recent = newValue } }
    }

    var collapsed: Set<UUID> {
        get { Set(document.collapsed) }
        set { update { $0.collapsed = newValue.map(\.uuidString).sorted().compactMap(UUID.init(uuidString:)) } }
    }

    var spaceOrder: [UUID: [String]] {
        get { Dictionary(document.spaceOrder.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                         uniquingKeysWith: { first, _ in first }) }
        set { update { $0.spaceOrder = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) }) } }
    }

    /// Settings' Remove all data: the file goes.
    func removeAll() {
        document = Document()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func update(_ change: (inout Document) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        document = next
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(document) else { return }
        try? PrivateFile.write(data, to: url, excludedFromBackup: true)
    }

    /// An older build's UserDefaults values: taken where this file has none, then removed from UserDefaults.
    private func migrate(_ defaults: UserDefaults) {
        guard Self.legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        var next = document
        if next.recent == nil, let data = defaults.data(forKey: "tabs.recent") {
            next.recent = try? JSONDecoder().decode(SpaceRef.self, from: data)
        }
        if next.collapsed.isEmpty {
            next.collapsed = (defaults.stringArray(forKey: "tabs.collapsed") ?? []).compactMap(UUID.init(uuidString:))
        }
        if next.spaceOrder.isEmpty, let data = defaults.data(forKey: "tabs.spaceOrder"),
           let order = try? JSONDecoder().decode([UUID: [String]].self, from: data) {
            next.spaceOrder = Dictionary(uniqueKeysWithValues: order.map { ($0.key.uuidString, $0.value) })
        }
        if next != document {
            document = next
            save()
        }
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }
}
