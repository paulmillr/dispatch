import Foundation

/// A value decoded without failing its container: nil when this element cannot be read (a field of another version, a
/// shape this build does not know). Persisted collections decode their elements through it, so one unreadable entry
/// costs that entry, never the whole file.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The key's value, or `fallback` when it is missing or unreadable (an older or newer file's shape).
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback()
    }

    /// The key's value, or nil when it is missing or unreadable.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// A dictionary whose unreadable entries are left out.
    func lenientDictionary<T: Decodable>(_ type: T.Type, forKey key: Key) -> [String: T] {
        lenient([String: Lenient<T>].self, forKey: key, default: [:]).compactMapValues(\.value)
    }

    /// An array whose unreadable elements are left out.
    func lenientArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        lenient([Lenient<T>].self, forKey: key, default: []).compactMap(\.value)
    }
}
