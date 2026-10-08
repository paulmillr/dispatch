import Foundation

enum HelperWire {
  // The frame's representable body length: the codec's default bound.
  static let maximum = Int(UInt32.max) - 9
  /// The helper's frame body limit (helper wire::LIMIT: 2 MB of text whose every byte may be a
  /// six-byte escape, plus the result envelope). A remote helper is untrusted, so connections
  /// never accept or send a larger frame, whatever its hello advertises.
  static let limit = 12_000_013

  enum Kind: UInt8, Sendable {
    case request = 1, response, notify, cancel, chunk
  }

  struct Message: Equatable, Sendable {
    let kind: Kind
    let id: UInt64
    let body: Data
  }

  enum Failure: Error, Equatable {
    case length, kind, limit, truncated, failed, sequence
  }

  struct Content: Sendable {
    let json: Data
    let bytes: Data?
  }


  static func encode(_ message: Message, limit: Int = maximum) throws -> Data {
    guard message.body.count <= limit else { throw Failure.limit }
    var bytes = Data()
    var length = UInt32(message.body.count + 9).littleEndian
    var id = message.id.littleEndian
    withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
    bytes.append(message.kind.rawValue)
    withUnsafeBytes(of: &id) { bytes.append(contentsOf: $0) }
    bytes.append(message.body)
    return bytes
  }

  struct Decoder {
    var limit = maximum
    private var header = Data()
    private var body = Data()
    private var message: (Kind, UInt64, Int)?
    private var failed = false

    init(limit: Int = maximum) {
      self.limit = limit
    }

    mutating func feed(_ bytes: Data, emit: (Message) throws -> Void) throws {
      guard !failed else { throw Failure.failed }
      do {
        var offset = bytes.startIndex
        for _ in 0...bytes.count {
          if let (kind, id, length) = message {
            let count = min(length - body.count, bytes.endIndex - offset)
            body.append(bytes[offset..<offset + count])
            offset += count
            if body.count == length {
              let value = Message(kind: kind, id: id, body: body)
              body = Data()
              message = nil
              try emit(value)
            }
          } else {
            let count = min(13 - header.count, bytes.endIndex - offset)
            header.append(bytes[offset..<offset + count])
            offset += count
            if header.count == 13 {
              let length = header.prefix(4).reversed().reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
              }
              guard length >= 9 else { throw Failure.length }
              guard let kind = Kind(rawValue: header[4]) else { throw Failure.kind }
              guard length - 9 <= limit else { throw Failure.limit }
              let id = header.dropFirst(5).reversed().reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
              }
              message = (kind, id, Int(length - 9))
              header.removeAll(keepingCapacity: true)
            }
          }
          if offset == bytes.endIndex && (message == nil || message!.2 != body.count) {
            break
          }
        }
      } catch {
        failed = true
        throw error
      }
    }

    func finish() throws {
      guard !failed else { throw Failure.failed }
      guard header.isEmpty && message == nil else { throw Failure.truncated }
    }
  }
}
