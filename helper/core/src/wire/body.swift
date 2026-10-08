    public indirect enum Value: Equatable, Sendable {
        case null
        case bool(Bool)
        case unsigned(UInt64)
        case signed(Int64)
        case real(Double)
        case string(String)
        case array([Value])
        case object([String: Value])
    }
    public static func encode(_ value: Value) throws -> Data {
        var out = Data(schema)
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
                if let index = symbols.firstIndex(of: value) {
                    out.append(9); number(UInt64(index), 2)
                } else { out.append(6); try text(value) }
            case .array(let items):
                guard items.count <= Int(UInt32.max) else { throw Failure.limit }
                out.append(7); number(UInt64(items.count), 4)
                for item in items { try write(item, depth - 1) }
            case .object(let fields):
                guard fields.count <= Int(UInt32.max) else { throw Failure.limit }
                out.append(8); number(UInt64(fields.count), 4)
                for key in fields.keys.sorted() {
                    if let index = symbols.firstIndex(of: key) { number(UInt64(index), 2) }
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
        case .array(let value): return value.map(foundation)
        case .object(let value): return value.mapValues(foundation)
        }
    }
    public enum Failure: Error { case invalid, schema, limit }
    public static func decode(_ data: Data) throws -> Value {
        let bytes = [UInt8](data)
        var at = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - at else { throw Failure.invalid }
            defer { at += count }
            return bytes[at..<(at + count)]
        }
        func number(_ count: Int) throws -> UInt64 {
            try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        func text() throws -> String {
            let count = try number(4)
            guard count <= UInt64(Int.max),
                let value = String(bytes: try take(Int(count)), encoding: .utf8)
            else { throw Failure.invalid }
            return value
        }
        func symbol(_ index: UInt64) throws -> String {
            guard index < UInt64(symbols.count) else { throw Failure.invalid }
            return symbols[Int(index)]
        }
        func read(_ depth: Int) throws -> Value {
            guard depth > 0 else { throw Failure.limit }
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
            case 9: return .string(try symbol(number(2)))
            case 10:
                let index = try number(2)
                guard index < UInt64(records.count) else { throw Failure.invalid }
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
        guard Array(try take(schema.count)) == schema else { throw Failure.schema }
        let value = try read(512)
        guard at == bytes.count else { throw Failure.invalid }
        return value
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
                guard sequence == item.0, body.count - 8 <= limit - item.1.count,
                    item.0 < UInt64.max else { throw Failure.limit }
                item.1.append(body.dropFirst(8)); item.0 += 1
                pending[id] = item
                return nil
            }
            guard kind == 2 || kind == 3 else { throw Failure.invalid }
            let envelope = try decode(body)
            let item = pending.removeValue(forKey: id) ?? (0, Data())
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
        public mutating func cancel(_ id: UInt64) { pending.removeValue(forKey: id) }
        public func finish() throws {
            guard pending.isEmpty else { throw Failure.invalid }
        }
    }
}
