/// The inbound half of the binary packet protocol (RFC 4253 §6): a buffer of the stream's bytes, the direction's
/// `PacketOpener`, and the sequence number. For each packet it reads the length (decrypting what the family needs),
/// checks it against `Limits.packetLength`, the minimum and the alignment before waiting for more, then opens the whole
/// packet (tag first) and checks the padding. Sequence numbers count every packet and wrap nowhere: the packet after
/// number 2^32 - 1 is refused (`.sequenceExhausted`); strict key exchange sets them back to 0 at NEWKEYS.
struct InboundFramer {
  private(set) var opener: any PacketOpener = PlaintextOpener()
  /// The next packet's sequence number; above `UInt32.max` once exhausted.
  private(set) var nextSequence: UInt64 = 0
  private var buffer: [UInt8] = []
  private var start = 0
  /// The head packet's `packet_length`, once read (the encrypt-and-MAC opener decrypts its first block for it).
  private var pendingLength: Int?

  /// Bytes received and not yet consumed.
  var buffered: Int { buffer.count - start }

  mutating func append(_ bytes: [UInt8]) {
    if start > 0 && start >= buffer.count / 2 {
      buffer.removeSubrange(0..<start)
      start = 0
    }
    buffer.append(contentsOf: bytes)
  }

  /// The unconsumed bytes (the version exchange reads its lines from here).
  var unconsumed: ArraySlice<UInt8> { buffer[start...] }

  mutating func consume(_ count: Int) {
    start = min(buffer.count, start + max(0, count))
  }

  /// Installs the next keys (at NEWKEYS, between two packets).
  mutating func install(_ opener: any PacketOpener) {
    self.opener = opener
    pendingLength = nil
  }

  mutating func resetSequence() { nextSequence = 0 }

  /// Tests only: moves the sequence number (to reach the wrap without 2^32 packets).
  mutating func setSequence(_ next: UInt64) { nextSequence = next }

  /// One decoded packet.
  struct Packet {
    let payload: [UInt8]
    let sequence: UInt32
    /// The bytes it took on the wire, tag included.
    let wireBytes: Int
  }

  /// The next whole packet, or nil until enough bytes are buffered.
  mutating func next() throws(SSHError) -> Packet? {
    // Exhausted only once a next packet starts to arrive (number 2^32 - 1 itself is fine).
    guard buffered > 0 else { return nil }
    guard let sequence = UInt32(exactly: nextSequence) else { throw .protocolViolation(.packet(.sequenceExhausted)) }
    let length: Int
    if let pendingLength {
      length = pendingLength
    } else {
      guard buffered >= opener.lengthPrefixBytes else { return nil }
      let prefix = Array(buffer[start..<start + opener.lengthPrefixBytes])
      let field = try opener.packetLength(prefix, sequence: sequence)
      // padding_length and at least the minimum padding; the length prefix must not reach into the next packet.
      let minimum = max(1 + Limits.minimumPadding, opener.lengthPrefixBytes - 4)
      guard let value = Int(exactly: field), value >= minimum, value <= Limits.packetLength else {
        throw .protocolViolation(.packet(.lengthOutOfRange))
      }
      let aligned = opener.lengthIsAligned ? 4 + value : value
      guard aligned % opener.blockBytes == 0 else { throw .protocolViolation(.packet(.misaligned)) }
      pendingLength = value
      length = value
    }
    let total = 4 + length + opener.tagBytes
    guard buffered >= total else { return nil }
    let wire = Array(buffer[start..<start + total])
    start += total
    pendingLength = nil
    var plaintext = try opener.open(wire, sequence: sequence)
    defer { wipeBytes(&plaintext) }
    guard plaintext.count == length else { throw .protocolViolation(.packet(.integrity)) }
    let padding = Int(plaintext[0])
    // At least the minimum padding, and a payload of at least its message number.
    guard padding >= Limits.minimumPadding, 1 + padding < length else { throw .protocolViolation(.packet(.invalidPadding)) }
    nextSequence += 1
    return Packet(payload: Array(plaintext[1..<length - padding]), sequence: sequence, wireBytes: total)
  }
}

/// The outbound half: pads each payload to the sealer's alignment with random bytes (at least
/// `Limits.minimumPadding`), seals it under the current sequence number, and appends the wire bytes to `output`. The
/// plaintext packet it builds is wiped once sealed (what `send(secret:)` relies on).
struct OutboundFramer {
  private(set) var sealer: any PacketSealer = PlaintextSealer()
  private(set) var nextSequence: UInt64 = 0
  /// Sealed bytes the driver has not taken yet.
  var output: [UInt8] = []

  mutating func install(_ sealer: any PacketSealer) { self.sealer = sealer }

  mutating func resetSequence() { nextSequence = 0 }

  /// Tests only: moves the sequence number (to reach the wrap without 2^32 packets).
  mutating func setSequence(_ next: UInt64) { nextSequence = next }

  /// The padded packet's size for a payload of `count` bytes under the current sealer.
  func packetBytes(payload count: Int) -> (length: Int, padding: Int) {
    let block = sealer.blockBytes
    let unpadded = (sealer.lengthIsAligned ? 4 : 0) + 1 + count
    var padding = block - unpadded % block
    if padding < Limits.minimumPadding { padding += block }
    return (1 + count + padding, padding)
  }

  /// Seals one payload (read from `payload` without copying it anywhere but the packet). Returns its sequence number
  /// and the bytes it took on the wire.
  mutating func seal(_ payload: UnsafeRawBufferPointer, random: any RandomSource) throws(SSHError) -> (UInt32, Int) {
    guard let sequence = UInt32(exactly: nextSequence) else { throw .protocolViolation(.packet(.sequenceExhausted)) }
    let (length, padding) = packetBytes(payload: payload.count)
    guard let field = UInt32(exactly: length) else { throw .usage(.invalidArgument("a payload too large for a packet")) }
    var packet = [UInt8](repeating: 0, count: 4 + length)
    defer { wipeBytes(&packet) }
    var failure: SSHError?
    packet.withUnsafeMutableBytes { raw in
      raw.storeBytes(of: field.bigEndian, toByteOffset: 0, as: UInt32.self)
      raw[4] = UInt8(padding)
      if let source = payload.baseAddress, let target = raw.baseAddress, payload.count > 0 {
        (target + 5).copyMemory(from: source, byteCount: payload.count)
      }
      do throws(SSHError) {
        try random.fill(UnsafeMutableRawBufferPointer(rebasing: raw[(5 + payload.count)...]))
      } catch {
        failure = error
      }
    }
    if let failure { throw failure }
    let wire = try sealer.seal(packet, sequence: sequence)
    output.append(contentsOf: wire)
    nextSequence += 1
    return (sequence, wire.count)
  }

  mutating func seal(_ payload: [UInt8], random: any RandomSource) throws(SSHError) -> (UInt32, Int) {
    var result: Result<(UInt32, Int), SSHError> = .failure(.closed(.alreadyEnded))
    payload.withUnsafeBytes { raw in
      do throws(SSHError) { result = .success(try seal(raw, random: random)) } catch { result = .failure(error) }
    }
    return try result.get()
  }
}
