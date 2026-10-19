    public indirect enum Value: Hashable, Sendable {
        case null
        case bool(Bool)
        case unsigned(UInt64)
        case signed(Int64)
        case real(Double)
        case string(String)
        case bytes(Data)
        case array([Value])
        case object([String: Value])
    }
    /// `schema: false` (captures): no schema prefix and no generated names, readable by any version.
    public static func encode(_ value: Value, schema names: Bool = true) throws -> Data {
        var out = Data(names ? schema : [])
        func number(_ value: UInt64, _ count: Int) {
            for shift in 0..<count { out.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        func text(_ value: String) throws {
            let bytes = Array(value.utf8)
            guard bytes.count <= Int(UInt32.max) else { throw Failure.limit }
            number(UInt64(bytes.count), 4)
            out.append(contentsOf: bytes)
        }
        func write(_ value: Value, _ depth: Int) throws {
            guard depth > 0 else { throw Failure.limit }
            switch value {
            case .null: out.append(0)
            case .bool(let value): out.append(value ? 2 : 1)
            case .unsigned(let value): out.append(3); number(value, 8)
            case .signed(let value): out.append(4); number(UInt64(bitPattern: value), 8)
            case .real(let value):
                guard value.isFinite else { throw Failure.invalid }
                out.append(5); number(value.bitPattern, 8)
            case .string(let value):
                if names, let index = symbols.firstIndex(of: value) {
                    out.append(9); number(UInt64(index), 2)
                } else { out.append(6); try text(value) }
            case .bytes(let value):
                guard value.count <= Int(UInt32.max) else { throw Failure.limit }
                out.append(11); number(UInt64(value.count), 4); out.append(value)
            case .array(let items):
                guard items.count <= Int(UInt32.max) else { throw Failure.limit }
                out.append(7); number(UInt64(items.count), 4)
                for item in items { try write(item, depth - 1) }
            case .object(let fields):
                guard fields.count <= Int(UInt32.max) else { throw Failure.limit }
                out.append(8); number(UInt64(fields.count), 4)
                for key in fields.keys.sorted() {
                    if names, let index = symbols.firstIndex(of: key) { number(UInt64(index), 2) }
                    else { number(65535, 2); try text(key) }
                    try write(fields[key]!, depth - 1)
                }
            }
        }
        try write(value, 512)
        return out
    }
    /// The shared Foundation bridge; it never interprets operation or provider names.
    public static func value(_ object: Any) throws -> Value {
        func read(_ object: Any, _ depth: Int) throws -> Value {
            guard depth > 0 else { throw Failure.limit }
            if object is NSNull { return .null }
            if let data = object as? Data { return .bytes(data) }
            if let number = object as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
                let kind = String(cString: number.objCType)
                if kind == "f" || kind == "d" {
                    guard number.doubleValue.isFinite else { throw Failure.invalid }
                    return .real(number.doubleValue)
                }
                return number.int64Value < 0 && kind != "Q"
                    ? .signed(number.int64Value) : .unsigned(number.uint64Value)
            }
            if let text = object as? String { return .string(text) }
            if let items = object as? [Any] {
                return .array(try items.map { try read($0, depth - 1) })
            }
            if let fields = object as? [String: Any] {
                return .object(try fields.mapValues { try read($0, depth - 1) })
            }
            throw Failure.invalid
        }
        return try read(object, 512)
    }
    /// Convert to Foundation values for the existing provider-independent client records.
    public static func foundation(_ value: Value) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return NSNumber(value: value)
        case .unsigned(let value): return NSNumber(value: value)
        case .signed(let value): return NSNumber(value: value)
        case .real(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .bytes(let value): return value
        case .array(let value): return value.map(foundation)
        case .object(let value): return value.mapValues(foundation)
        }
    }
    public enum Failure: Error { case invalid, schema, limit }
    /// The most values one body builds. Its length bounds them only at one per byte, each tens of bytes in memory: a
    /// hostile helper's 12 MB frame (or longer chunked reply) built about 12 million. Real replies stay far below a
    /// million (the largest recorded, a long chat session: about 14,000); a million costs about what one connection
    /// may already buffer (4 frames).
    public static let nodes = 1 << 20
    public static func decode(_ data: Data, schema names: Bool = true) throws -> Value {
        let bytes = [UInt8](data)
        var at = 0, budget = nodes
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - at else { throw Failure.invalid }
            defer { at += count }
            return bytes[at..<(at + count)]
        }
        func number(_ count: Int) throws -> UInt64 {
            // Little-endian bytes into a zeroed word at once (a per-byte reduce dominated Debug decoding).
            var value: UInt64 = 0
            try take(count).withUnsafeBytes { bytes in withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: bytes) } }
            return UInt64(littleEndian: value)
        }
        func text() throws -> String {
            let count = try number(4)
            guard count <= UInt64(Int.max),
                let value = String(bytes: try take(Int(count)), encoding: .utf8)
            else { throw Failure.invalid }
            return value
        }
        func symbol(_ index: UInt64) throws -> String {
            guard names, index < UInt64(symbols.count) else { throw Failure.invalid }
            return symbols[Int(index)]
        }
        func read(_ depth: Int) throws -> Value {
            guard depth > 0, budget > 0 else { throw Failure.limit }
            budget -= 1
            switch try number(1) {
            case 0: return .null
            case 1: return .bool(false)
            case 2: return .bool(true)
            case 3: return .unsigned(try number(8))
            case 4: return .signed(Int64(bitPattern: try number(8)))
            case 5:
                let value = Double(bitPattern: try number(8))
                guard value.isFinite else { throw Failure.invalid }
                return .real(value)
            case 6: return .string(try text())
            case 11:
                let count = try number(4)
                guard count <= UInt64(bytes.count - at) else { throw Failure.invalid }
                return .bytes(Data(try take(Int(count))))
            case 9: return .string(try symbol(number(2)))
            case 10:
                let index = try number(2)
                guard names, index < UInt64(records.count) else { throw Failure.invalid }
                let names = records[Int(index)]
                guard names.count <= bytes.count - at else { throw Failure.invalid }
                var fields: [String: Value] = [:]
                for name in names { fields[name] = try read(depth - 1) }
                return .object(fields)
            case 7, 8:
                let tag = bytes[at - 1]
                let count = try number(4)
                guard count <= UInt64((bytes.count - at) / (tag == 7 ? 1 : 3))
                else { throw Failure.invalid }
                // Each item is a value: more than the budget has left never fits (nor is an array reserved for them).
                guard count <= UInt64(budget) else { throw Failure.limit }
                if tag == 7 {
                    return .array(try (0..<Int(count)).map { _ in try read(depth - 1) })
                }
                var fields: [String: Value] = [:]
                for _ in 0..<Int(count) {
                    let index = try number(2)
                    let key = try index == 65535 ? text() : symbol(index)
                    guard fields[key] == nil else { throw Failure.invalid }
                    fields[key] = try read(depth - 1)
                }
                return .object(fields)
            default: throw Failure.invalid
            }
        }
        if names { guard Array(try take(schema.count)) == schema else { throw Failure.schema } }
        let value = try read(512)
        guard at == bytes.count else { throw Failure.invalid }
        return value
    }

    /// Codable values as value trees, with no JSON between: Data is bytes, a non-negative integer is
    /// unsigned (as the helper writes it), URL is its absolute string (as JSONEncoder wrote it).
    public static func value<T: Encodable>(encoding item: T) throws -> Value {
        let slot = Slot()
        try slot.put(item, [])
        return slot.resolved
    }
    public static func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
        try Reading(value: value, codingPath: []).read(type)
    }

    public struct Reply {
        public let kind: UInt8
        public let id: UInt64
        public let value: Value
        public let binary: Data?
    }
    public struct Collector {
        public let limit: Int
        public let chunkKind: UInt8
        public let chunkLimit: Int
        private var pending: [UInt64: (UInt64, Data)] = [:]
        private var total = 0
        public init(limit: Int, chunkKind: UInt8, chunkLimit: Int) {
            self.limit = limit; self.chunkKind = chunkKind; self.chunkLimit = chunkLimit
        }
        public mutating func push(kind: UInt8, id: UInt64, body: Data) throws -> Reply? {
            if kind == chunkKind {
                guard body.count > 8, body.count - 8 <= chunkLimit else { throw Failure.invalid }
                let sequence = body.prefix(8).enumerated().reduce(UInt64(0)) {
                    $0 | UInt64($1.element) << ($1.offset * 8)
                }
                var item = pending[id] ?? (0, Data())
                let count = body.count - 8
                guard sequence == item.0, limit >= 0, total <= limit, count <= limit - total,
                    item.0 < UInt64.max else { throw Failure.limit }
                item.1.append(body.dropFirst(8)); item.0 += 1; total += count
                pending[id] = item
                return nil
            }
            guard kind == 2 || kind == 3 else { throw Failure.invalid }
            let envelope = try decode(body)
            let item = pending.removeValue(forKey: id) ?? (0, Data())
            total -= item.1.count
            guard case .object(let fields) = envelope else { throw Failure.invalid }
            guard let stream = fields["stream"] else {
                guard item.0 == 0, body.count <= limit else { throw Failure.limit }
                return Reply(kind: kind, id: id, value: envelope, binary: nil)
            }
            guard case .object(let totals) = stream,
                totals["chunks"] == .unsigned(item.0),
                totals["bytes"] == .unsigned(UInt64(item.1.count))
            else { throw Failure.invalid }
            if fields["error"] != nil {
                return Reply(kind: kind, id: id, value: envelope, binary: nil)
            }
            switch totals["encoding"] {
            case .string("value"):
                return Reply(kind: kind, id: id, value: try decode(item.1), binary: nil)
            case .string("binary"):
                guard let result = fields["result"] else { throw Failure.invalid }
                return Reply(kind: kind, id: id, value: result, binary: item.1)
            default: throw Failure.invalid
            }
        }
        public mutating func cancel(_ id: UInt64) {
            if let item = pending.removeValue(forKey: id) { total -= item.1.count }
        }
        public func finish() throws {
            guard pending.isEmpty else { throw Failure.invalid }
        }
    }
}

private final class Slot {
    var value: HelperBinary.Value = .null
    var fields: [String: Slot]?
    var items: [Slot]?
    var resolved: HelperBinary.Value {
        if let fields { return .object(fields.mapValues(\.resolved)) }
        if let items { return .array(items.map(\.resolved)) }
        return value
    }
    func put<T: Encodable>(_ item: T, _ path: [any CodingKey]) throws {
        func integer<I: BinaryInteger>(_ value: I) -> HelperBinary.Value {
            value >= 0 ? .unsigned(UInt64(value)) : .signed(Int64(value))
        }
        func real(_ value: Double) throws -> HelperBinary.Value {
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(codingPath: path, debugDescription: "Non-finite number"))
            }
            return .real(value)
        }
        switch item {
        case let item as Data: value = .bytes(item)
        case let item as Bool: value = .bool(item)
        case let item as String: value = .string(item)
        case let item as URL: value = .string(item.absoluteString)
        case let item as Int: value = integer(item)
        case let item as Int8: value = integer(item)
        case let item as Int16: value = integer(item)
        case let item as Int32: value = integer(item)
        case let item as Int64: value = integer(item)
        case let item as UInt: value = integer(item)
        case let item as UInt8: value = integer(item)
        case let item as UInt16: value = integer(item)
        case let item as UInt32: value = integer(item)
        case let item as UInt64: value = integer(item)
        case let item as Double: value = try real(item)
        case let item as Float: value = try real(Double(item))
        default: try item.encode(to: Writing(slot: self, codingPath: path))
        }
    }
    func child(_ key: String) -> Slot {
        let slot = Slot()
        fields = fields ?? [:]
        fields![key] = slot
        return slot
    }
    func append() -> Slot {
        let slot = Slot()
        items = items ?? []
        items!.append(slot)
        return slot
    }
}

private struct Writing: Encoder {
    let slot: Slot
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        slot.fields = slot.fields ?? [:]
        return KeyedEncodingContainer(Keyed(slot: slot, codingPath: codingPath))
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        slot.items = slot.items ?? []
        return Unkeyed(slot: slot, codingPath: codingPath)
    }
    func singleValueContainer() -> any SingleValueEncodingContainer { Single(slot: slot, codingPath: codingPath) }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let slot: Slot
        let codingPath: [any CodingKey]
        mutating func encodeNil(forKey key: Key) throws { slot.child(key.stringValue).value = .null }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try slot.child(key.stringValue).put(value, codingPath + [key])
        }
        mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) -> KeyedEncodingContainer<N> {
            Writing(slot: slot.child(key.stringValue), codingPath: codingPath + [key]).container(keyedBy: type)
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            Writing(slot: slot.child(key.stringValue), codingPath: codingPath + [key]).unkeyedContainer()
        }
        mutating func superEncoder() -> any Encoder { Writing(slot: slot.child("super"), codingPath: codingPath) }
        mutating func superEncoder(forKey key: Key) -> any Encoder {
            Writing(slot: slot.child(key.stringValue), codingPath: codingPath + [key])
        }
    }
    struct Unkeyed: UnkeyedEncodingContainer {
        let slot: Slot
        let codingPath: [any CodingKey]
        var count: Int { slot.items?.count ?? 0 }
        mutating func encodeNil() throws { slot.append().value = .null }
        mutating func encode<T: Encodable>(_ value: T) throws { try slot.append().put(value, codingPath) }
        mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type) -> KeyedEncodingContainer<N> {
            Writing(slot: slot.append(), codingPath: codingPath).container(keyedBy: type)
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
            Writing(slot: slot.append(), codingPath: codingPath).unkeyedContainer()
        }
        mutating func superEncoder() -> any Encoder { Writing(slot: slot.append(), codingPath: codingPath) }
    }
    struct Single: SingleValueEncodingContainer {
        let slot: Slot
        let codingPath: [any CodingKey]
        mutating func encodeNil() throws { slot.value = .null }
        mutating func encode<T: Encodable>(_ value: T) throws { try slot.put(value, codingPath) }
    }
}

/// A value the app keeps as it arrived (a harness's usage or goal): the binary decoder hands it over as is.
extension HelperBinary.Value: Decodable {
    public init(from decoder: any Decoder) throws {
        guard let reading = decoder as? Reading else {
            throw DecodingError.typeMismatch(HelperBinary.Value.self, .init(codingPath: decoder.codingPath,
                debugDescription: "Only the binary decoder reads a raw value"))
        }
        self = reading.value
    }
}

private struct Reading: Decoder {
    let value: HelperBinary.Value
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func mismatch<T>(_ type: T.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Found \(value)"))
    }
    func read<T: Decodable>(_ type: T.Type) throws -> T {
        func integer<I: FixedWidthInteger>(_ type: I.Type) throws -> I {
            switch value {
            case .unsigned(let value): if let result = I(exactly: value) { return result }
            case .signed(let value): if let result = I(exactly: value) { return result }
            case .real(let value): if let result = I(exactly: value) { return result }
            default: break
            }
            throw mismatch(type)
        }
        func real() throws -> Double {
            switch value {
            case .real(let value): return value
            case .unsigned(let value): return Double(value)
            case .signed(let value): return Double(value)
            default: throw mismatch(type)
            }
        }
        switch type {
        case is Data.Type: if case .bytes(let value) = value { return value as! T }
        case is Bool.Type: if case .bool(let value) = value { return value as! T }
        case is String.Type: if case .string(let value) = value { return value as! T }
        case is URL.Type: if case .string(let text) = value, let url = URL(string: text) { return url as! T }
        case is Int.Type: return try integer(Int.self) as! T
        case is Int8.Type: return try integer(Int8.self) as! T
        case is Int16.Type: return try integer(Int16.self) as! T
        case is Int32.Type: return try integer(Int32.self) as! T
        case is Int64.Type: return try integer(Int64.self) as! T
        case is UInt.Type: return try integer(UInt.self) as! T
        case is UInt8.Type: return try integer(UInt8.self) as! T
        case is UInt16.Type: return try integer(UInt16.self) as! T
        case is UInt32.Type: return try integer(UInt32.self) as! T
        case is UInt64.Type: return try integer(UInt64.self) as! T
        case is Double.Type: return try real() as! T
        case is Float.Type: return Float(try real()) as! T
        default: return try T(from: self)
        }
        throw mismatch(type)
    }
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let fields) = value else { throw mismatch([String: HelperBinary.Value].self) }
        return KeyedDecodingContainer(Keyed(fields: fields, codingPath: codingPath))
    }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let items) = value else { throw mismatch([HelperBinary.Value].self) }
        return Unkeyed(items: items, codingPath: codingPath)
    }
    func singleValueContainer() throws -> any SingleValueDecodingContainer { Single(reading: self) }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let fields: [String: HelperBinary.Value]
        let codingPath: [any CodingKey]
        var allKeys: [Key] { fields.keys.compactMap { Key(stringValue: $0) } }
        func contains(_ key: Key) -> Bool { fields[key.stringValue] != nil }
        func reading(_ key: Key) throws -> Reading {
            guard let value = fields[key.stringValue] else {
                throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing key"))
            }
            return Reading(value: value, codingPath: codingPath + [key])
        }
        func decodeNil(forKey key: Key) throws -> Bool { try reading(key).value == .null }
        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try reading(key).read(type) }
        func nestedContainer<N: CodingKey>(keyedBy type: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> {
            try reading(key).container(keyedBy: type)
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
            try reading(key).unkeyedContainer()
        }
        func superDecoder() throws -> any Decoder {
            Reading(value: fields["super"] ?? .null, codingPath: codingPath)
        }
        func superDecoder(forKey key: Key) throws -> any Decoder { try reading(key) }
    }
    struct Unkeyed: UnkeyedDecodingContainer {
        let items: [HelperBinary.Value]
        let codingPath: [any CodingKey]
        var currentIndex = 0
        var count: Int? { items.count }
        var isAtEnd: Bool { currentIndex >= items.count }
        mutating func next() throws -> Reading {
            guard !isAtEnd else {
                throw DecodingError.valueNotFound(HelperBinary.Value.self,
                    .init(codingPath: codingPath, debugDescription: "No more items"))
            }
            defer { currentIndex += 1 }
            return Reading(value: items[currentIndex], codingPath: codingPath)
        }
        mutating func decodeNil() throws -> Bool {
            guard !isAtEnd, items[currentIndex] == .null else { return false }
            currentIndex += 1
            return true
        }
        mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().read(type) }
        mutating func nestedContainer<N: CodingKey>(keyedBy type: N.Type) throws -> KeyedDecodingContainer<N> {
            try next().container(keyedBy: type)
        }
        mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer { try next().unkeyedContainer() }
        mutating func superDecoder() throws -> any Decoder { try next() }
    }
    struct Single: SingleValueDecodingContainer {
        let reading: Reading
        var codingPath: [any CodingKey] { reading.codingPath }
        func decodeNil() -> Bool { reading.value == .null }
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try reading.read(type) }
    }
}
