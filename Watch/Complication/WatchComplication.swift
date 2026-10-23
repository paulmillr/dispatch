import Foundation

/// The entry's file in the App Group container both the watch app and its widget extension sign with
/// (`com.apple.security.application-groups`, the group in each Info.plist's `DispatchAppGroup`). A plain JSON file, not
/// UserDefaults: no required-reason API (docs/watch.md, Targets).
enum WatchComplicationStore {
    static let fileName = "complication.json"

    /// The App Group (`group.yachts.dispatch.mobile` plus the bundle id suffix) from the running target's Info.plist.
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "DispatchAppGroup") as? String }

    /// The shared container; nil when the target is not signed into the group (a device build without it on the team).
    static func directory(group: String? = group) -> URL? {
        guard let group, !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// Data protection class C (`completeUntilFirstUserAuthentication`), as the phone's own files: the widget draws the
    /// face while the watch is locked, which class A would refuse.
    static func write(_ entry: WatchComplicationEntry, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entry).write(to: directory.appendingPathComponent(fileName),
                                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(from directory: URL?) -> WatchComplicationEntry? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WatchComplicationEntry.self, from: data)
    }
}
