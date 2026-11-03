import Foundation

/// What Spaces keeps per host on this phone: the space New tab goes to (`recent`), the host sections the user
/// collapsed (M2b), and the phone's order of each host's spaces (M1e). Space keys carry tmux session and herdr workspace
/// names, so this is a private file (`spaces.json` through `PrivateFile`: owner-only, atomic, out of device backups),
/// not UserDefaults, which backups include.
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
    static let shared = SpacesDeviceState(url: file)
    /// Only for Remove all data; these obsolete defaults are never read.
    static let legacyKeys = ["tabs.recent", "tabs.collapsed", "tabs.spaceOrder"]

    private(set) var document = Document()
    private let url: URL?

    /// `url` nil keeps everything in memory (tests, previews).
    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Document.self, from: data) {
            document = saved
        }
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
}
