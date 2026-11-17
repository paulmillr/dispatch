/// The text layer of a key file: PEM-style armor (RFC 7468, plus RFC 1421's header lines) around base64, as
/// ssh-keygen and OpenSSL write it. One armored block per file: whitespace may surround it, nothing else. Lines may
/// end in CR LF and carry surrounding blanks. The base64 is strict (RFC 4648: padded, no characters outside the
/// alphabet, zero trailing bits) and is decoded straight into wiped memory; the copy of the characters made on the
/// way is wiped too.
enum Armor {
  struct Block {
    /// The label between `-----BEGIN ` and `-----`: `OPENSSH PRIVATE KEY`, `RSA PRIVATE KEY`, ...
    let label: String
    /// RFC 1421 header lines came before the base64 (`Proc-Type`, `DEK-Info`, `Comment`).
    let hasHeaders: Bool
    /// One of them was `Proc-Type: 4,ENCRYPTED` (legacy PEM encryption). The body is then not decoded.
    let legacyEncrypted: Bool
    /// The decoded base64; nil when `legacyEncrypted`.
    let body: SecretBytes?
  }

  /// The longest label taken (the known ones are at most 26 characters).
  private static let labelLimit = 64

  /// The block `text` holds; nil when its first non-blank line is no BEGIN line (not armored at all).
  static func parse(_ text: UnsafeRawBufferPointer) throws(SSHError) -> Block? {
    let lines = self.lines(text)
    var index = 0
    while index < lines.count, lines[index].isEmpty { index += 1 }
    guard index < lines.count, let label = beginLabel(text, lines[index]) else { return nil }
    index += 1

    var hasHeaders = false, legacyEncrypted = false
    while index < lines.count, text[lines[index]].contains(UInt8(ascii: ":")) {
      hasHeaders = true
      let line = String(decoding: text[lines[index]], as: UTF8.self)
      if line.hasPrefix("Proc-Type:"), line.contains("ENCRYPTED") { legacyEncrypted = true }
      index += 1
    }
    if hasHeaders, index < lines.count, lines[index].isEmpty { index += 1 }

    let end = Array("-----END \(label)-----".utf8)
    var body: [Range<Int>] = []
    while true {
      guard index < lines.count else { throw KeyFileProblem.damaged.error }
      let line = lines[index]
      index += 1
      if text[line].starts(with: "-----END ".utf8) {
        guard text[line].elementsEqual(end) else { throw KeyFileProblem.damaged.error }
        break
      }
      guard !line.isEmpty, text[line].allSatisfy(isBase64Character) else { throw KeyFileProblem.damaged.error }
      body.append(line)
    }
    for line in lines[index...] where !line.isEmpty {
      if text[line].starts(with: "-----BEGIN ".utf8) { throw KeyFileProblem.moreThanOneKey.error }
      throw KeyFileProblem.damaged.error
    }
    let decoded = legacyEncrypted ? nil : try decodeBase64(text, lines: body)
    return Block(label: label, hasHeaders: hasHeaders, legacyEncrypted: legacyEncrypted, body: decoded)
  }

  /// Each line's range with its line break and surrounding blanks (space, tab, CR) removed. At most one range per
  /// byte of a file within `Limits.keyFileBytes`.
  static func lines(_ text: UnsafeRawBufferPointer) -> [Range<Int>] {
    var lines: [Range<Int>] = []
    var start = 0
    var index = 0
    while index <= text.count {
      if index == text.count || text[index] == UInt8(ascii: "\n") {
        var low = start, high = index
        while low < high, isBlank(text[low]) { low += 1 }
        while high > low, isBlank(text[high - 1]) { high -= 1 }
        lines.append(low..<high)
        start = index + 1
      }
      index += 1
    }
    return lines
  }

  private static func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D }

  /// `-----BEGIN <label>-----` with a label of capital letters, digits and single spaces.
  private static func beginLabel(_ text: UnsafeRawBufferPointer, _ line: Range<Int>) -> String? {
    let bytes = text[line]
    let prefix = "-----BEGIN ".utf8, suffix = "-----".utf8
    guard bytes.count > prefix.count + suffix.count, bytes.starts(with: prefix),
      bytes.suffix(suffix.count).elementsEqual(suffix)
    else { return nil }
    let label = bytes.dropFirst(prefix.count).dropLast(suffix.count)
    guard label.count <= labelLimit, label.first != 0x20, label.last != 0x20,
      label.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x20 || $0 == 0x23 })
    else { return nil }
    return String(decoding: label, as: UTF8.self)
  }

  // MARK: Base64

  static func isBase64Character(_ byte: UInt8) -> Bool { value(byte) != nil || byte == UInt8(ascii: "=") }

  private static func value(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x41...0x5A: UInt32(byte - 0x41)
    case 0x61...0x7A: UInt32(byte - 0x61 + 26)
    case 0x30...0x39: UInt32(byte - 0x30 + 52)
    case UInt8(ascii: "+"): 62
    case UInt8(ascii: "/"): 63
    default: nil
    }
  }

  /// The base64 of `lines` (already checked to hold only base64 characters) decoded into wiped memory.
  static func decodeBase64(_ text: UnsafeRawBufferPointer, lines: [Range<Int>]) throws(SSHError) -> SecretBytes {
    let total = lines.reduce(0) { $0 + $1.count }
    guard total > 0, total % 4 == 0 else { throw KeyFileProblem.damaged.error }
    let characters = UnsafeMutableRawBufferPointer.allocate(byteCount: total, alignment: 1)
    defer {
      SecretBytes.wipe(characters)
      characters.deallocate()
    }
    var at = 0
    for line in lines {
      UnsafeMutableRawBufferPointer(rebasing: characters[at..<(at + line.count)])
        .copyMemory(from: UnsafeRawBufferPointer(rebasing: text[line]))
      at += line.count
    }
    let equals = UInt8(ascii: "=")
    let padding = characters[total - 1] != equals ? 0 : characters[total - 2] != equals ? 1 : 2
    for index in 0..<(total - padding) where value(characters[index]) == nil { throw KeyFileProblem.damaged.error }
    let count = total / 4 * 3 - padding

    // A throw from inside the initializer leaves the buffer to SecretBytes' deinit, which wipes and frees it.
    return try SecretBytes(count: count) { (output: UnsafeMutableRawBufferPointer) throws(SSHError) in
      var word: UInt32 = 0
      var written = 0
      var index = 0
      while index < total {
        word = 0
        for offset in 0..<4 { word = word << 6 | (value(characters[index + offset]) ?? 0) }
        // Only the last quantum is short (by its padding).
        var shift: UInt32 = 16
        while written < count {
          output[written] = UInt8(truncatingIfNeeded: word >> shift)
          written += 1
          if shift == 0 { break }
          shift -= 8
        }
        index += 4
      }
      // Canonical: the bits the padding leaves over are zero.
      let leftover: UInt32 = padding == 1 ? word & 0xFF : padding == 2 ? word & 0xFFFF : 0
      word = 0
      guard leftover == 0, written == count else { throw KeyFileProblem.damaged.error }
    }
  }
}
