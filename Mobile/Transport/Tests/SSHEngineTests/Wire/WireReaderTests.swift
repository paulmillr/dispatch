import SSHEngine
import XCTest

/// The reader against hand-built RFC 4251 encodings, including hostile ones: truncated values, lengths past the end
/// or over the limit, huge counts, non-minimal and negative mpints, invalid names and text.
final class WireReaderTests: XCTestCase {
  func testFixedSizeValues() throws {
    var reader = WireReader([0x07, 0x01, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 0x14])
    XCTAssertEqual(try reader.readByte(), 7)
    XCTAssertEqual(try reader.readBoolean(), true)
    XCTAssertEqual(try reader.readBoolean(), false)
    XCTAssertEqual(try reader.readUInt32(), 0xDEAD_BEEF)
    XCTAssertEqual(try reader.readUInt64(), 0x0102_0304_0506_0708)
    XCTAssertEqual(try reader.readMessageNumber(), .kexInit)
    XCTAssertTrue(reader.isAtEnd)
    XCTAssertThrows(WireError.truncated) { () throws(WireError) in try reader.readByte() }
  }

  func testTruncatedFixedValuesLeaveThePositionAlone() {
    for length in 0..<8 {
      var reader = WireReader([UInt8](repeating: 0xFF, count: length))
      if length < 4 { XCTAssertThrows(WireError.truncated) { () throws(WireError) in try reader.readUInt32() } }
      XCTAssertThrows(WireError.truncated) { () throws(WireError) in try reader.readUInt64() }
      XCTAssertEqual(reader.offset, 0)
    }
  }

  func testBooleansAreZeroOrOne() {
    for value in [UInt8(2), 0x80, 0xFF] {
      var reader = WireReader([value])
      XCTAssertThrows(WireError.invalidBoolean) { () throws(WireError) in try reader.readBoolean() }
      XCTAssertEqual(reader.offset, 0)
    }
  }

  func testStrings() throws {
    var reader = WireReader(Raw.string("ssh-userauth") + Raw.string([]) + Raw.string([0, 0xFF]))
    XCTAssertEqual(try reader.readString(limit: 64), Array("ssh-userauth".utf8))
    XCTAssertEqual(try reader.readString(limit: 0), [])
    XCTAssertEqual(try reader.readString(limit: 2), [0, 0xFF])
    XCTAssertTrue(reader.isAtEnd)
  }

  func testAStringLongerThanItsLimitFailsBeforeReading() {
    var reader = WireReader(Raw.string([UInt8](repeating: 0x41, count: 65)))
    XCTAssertThrows(WireError.tooLong(limit: 64)) { () throws(WireError) in try reader.readString(limit: 64) }
    XCTAssertEqual(reader.offset, 0)
  }

  func testALengthPastTheEndIsTruncated() {
    // Within the limit, more than the input holds.
    var reader = WireReader(Raw.u32(10) + [1, 2, 3])
    XCTAssertThrows(WireError.truncated) { () throws(WireError) in try reader.readString(limit: 100) }
    XCTAssertEqual(reader.offset, 0)
    // A length field cut short.
    var short = WireReader([0, 0, 1])
    XCTAssertThrows(WireError.truncated) { () throws(WireError) in try short.readString(limit: 100) }
  }

  func testAHugeLengthCostsNothing() {
    for length in [UInt32.max, 0x8000_0000, 0x7FFF_FFFF, UInt32(Limits.packetLength + 1)] {
      var reader = WireReader(Raw.u32(length) + [1])
      XCTAssertThrows(WireError.tooLong(limit: Limits.packetLength)) { () throws(WireError) in
        try reader.readString(limit: Limits.packetLength)
      }
    }
  }

  func testText() throws {
    var reader = WireReader(Raw.string("Pässwörd für ☃"))
    XCTAssertEqual(try reader.readText(limit: 100), "Pässwörd für ☃")
    // Overlong encoding of "/", a lone surrogate, a truncated sequence.
    for bad in [[UInt8]([0xC0, 0xAF]), [0xED, 0xA0, 0x80], [0xE2, 0x98]] {
      var invalid = WireReader(Raw.string(bad))
      XCTAssertThrows(WireError.invalidUTF8) { () throws(WireError) in try invalid.readText(limit: 100) }
      XCTAssertEqual(invalid.offset, 0)
    }
  }

  func testDisplayTextIsLenientButBounded() throws {
    // "Willkommen, Gäste!" in Latin-1: invalid UTF-8, which display text shows rather than refuses.
    let latin1: [UInt8] = Array("Willkommen, G".utf8) + [0xE4] + Array("ste!".utf8)
    var reader = WireReader(Raw.string(latin1) + Raw.string("en"))
    XCTAssertEqual(try reader.readDisplayText(limit: 64), "Willkommen, G\u{FFFD}ste!")
    XCTAssertEqual(try reader.readDisplayText(limit: Limits.languageTagBytes), "en")
    XCTAssertTrue(reader.isAtEnd)
    // The same bytes read strictly are refused: names and compared text stay strict.
    var strict = WireReader(Raw.string(latin1))
    XCTAssertThrows(WireError.invalidUTF8) { () throws(WireError) in try strict.readText(limit: 64) }
    // Valid UTF-8 passes unchanged, and the limit and the end still hold.
    var valid = WireReader(Raw.string("Pässwörd ☃"))
    XCTAssertEqual(try valid.readDisplayText(limit: 64), "Pässwörd ☃")
    var long = WireReader(Raw.string([UInt8](repeating: 0xFF, count: 65)))
    XCTAssertThrows(WireError.tooLong(limit: 64)) { () throws(WireError) in try long.readDisplayText(limit: 64) }
    XCTAssertEqual(long.offset, 0)
    var short = WireReader(Raw.u32(10) + [0xE4])
    XCTAssertThrows(WireError.truncated) { () throws(WireError) in try short.readDisplayText(limit: 64) }
    XCTAssertEqual(short.offset, 0)
  }

  func testALatin1PromptDecodesAsAChallenge() throws {
    // An INFO_REQUEST as a Latin-1 PAM sends it: name, instruction, language tag, one prompt "Kennwort für:".
    let prompt: [UInt8] = Array("Kennwort f".utf8) + [0xFC] + Array("r:".utf8)
    let message = InboundMessage(payload: [60] + Raw.string("") + Raw.string([0xC4, 0x6E]) + Raw.string("de-DE")
      + Raw.u32(1) + Raw.string(prompt) + [0])!
    let challenge = try message.decode { (reader: inout WireReader) throws(WireError) in
      let name = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
      let instruction = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
      _ = try reader.readDisplayText(limit: Limits.languageTagBytes)
      let count = try reader.readCount(limit: Limits.keyboardInteractivePrompts, elementBytes: 5)
      var prompts: [KeyboardInteractiveChallenge.Prompt] = []
      for _ in 0..<count {
        prompts.append(.init(text: try reader.readDisplayText(limit: Limits.authenticationTextBytes), echo: try reader.readBoolean()))
      }
      return KeyboardInteractiveChallenge(name: name, instruction: instruction, prompts: prompts)
    }
    XCTAssertEqual(challenge.instruction, "\u{FFFD}n")
    XCTAssertEqual(challenge.prompts, [.init(text: "Kennwort f\u{FFFD}r:", echo: false)])
    XCTAssertEqual(DisplayText.sanitize(Array(challenge.prompts[0].text.utf8)), "Kennwort f r:")
  }

  func testNames() throws {
    var reader = WireReader(Raw.string("keepalive@openssh.com"))
    XCTAssertEqual(try reader.readName(), "keepalive@openssh.com")
    for bad in ["", "a,b", "with space", "tab\t", "caf\u{E9}", "nul\u{0}"] {
      var invalid = WireReader(Raw.string(bad))
      XCTAssertThrows(WireError.invalidName) { () throws(WireError) in try invalid.readName() }
    }
    var long = WireReader(Raw.string(String(repeating: "x", count: Limits.nameLength + 1)))
    XCTAssertThrows(WireError.tooLong(limit: Limits.nameLength)) { () throws(WireError) in try long.readName() }
    var longest = WireReader(Raw.string(String(repeating: "x", count: Limits.nameLength)))
    XCTAssertEqual(try longest.readName().count, Limits.nameLength)
  }

  func testNameLists() throws {
    var reader = WireReader(Raw.string("curve25519-sha256,ext-info-c,kex-strict-c-v00@openssh.com") + Raw.string(""))
    XCTAssertEqual(try reader.readNameList(), ["curve25519-sha256", "ext-info-c", "kex-strict-c-v00@openssh.com"])
    XCTAssertEqual(try reader.readNameList(), [])
    for bad in [",", "a,", ",a", "a,,b", "a b", "a,\u{7F}"] {
      var invalid = WireReader(Raw.string(bad))
      XCTAssertThrows(WireError.invalidName) { () throws(WireError) in try invalid.readNameList() }
      XCTAssertEqual(invalid.offset, 0)
    }
  }

  func testNameListBounds() throws {
    let many = (0...Limits.nameListCount).map { "n\($0)" }.joined(separator: ",")
    var tooMany = WireReader(Raw.string(many))
    XCTAssertThrows(WireError.tooMany(limit: Limits.nameListCount)) { () throws(WireError) in try tooMany.readNameList() }
    var exactly = WireReader(Raw.string((1...Limits.nameListCount).map { "n\($0)" }.joined(separator: ",")))
    XCTAssertEqual(try exactly.readNameList().count, Limits.nameListCount)
    var long = WireReader(Raw.string(String(repeating: "a,", count: 5000) + "a"))
    XCTAssertThrows(WireError.tooLong(limit: Limits.nameListBytes)) { () throws(WireError) in try long.readNameList() }
  }

  func testMPInts() throws {
    let cases: [([UInt8], [UInt8])] = [
      // RFC 4251 §5's examples (the non-negative ones): 0, 9a378f9b2e332a7, 80.
      ([], []),
      (Raw.hex("09 a3 78 f9 b2 e3 32 a7"), Raw.hex("09 a3 78 f9 b2 e3 32 a7")),
      (Raw.hex("00 80"), [0x80]),
      ([0x7F], [0x7F]),
      ([0x00, 0xFF, 0x00], [0xFF, 0x00]),
    ]
    for (wire, magnitude) in cases {
      var reader = WireReader(Raw.string(wire))
      XCTAssertEqual(try reader.readMPInt(limit: 16), magnitude, "\(wire)")
    }
  }

  func testNonMinimalAndNegativeMPIntsAreRefused() {
    for wire in [[UInt8]([0x00]), [0x00, 0x00], [0x00, 0x7F], [0x00, 0x00, 0x80]] {
      var reader = WireReader(Raw.string(wire))
      XCTAssertThrows(WireError.nonMinimalMPInt) { () throws(WireError) in try reader.readMPInt(limit: 16) }
      XCTAssertEqual(reader.offset, 0)
    }
    // RFC 4251 §5's negative examples: -1234 (ed cc), -deadbeef (ff 21 52 41 11), and a bare ff.
    for wire in [Raw.hex("ed cc"), Raw.hex("ff 21 52 41 11"), [0xFF], [0x80]] {
      var reader = WireReader(Raw.string(wire))
      XCTAssertThrows(WireError.negativeMPInt) { () throws(WireError) in try reader.readMPInt(limit: 16) }
    }
    var long = WireReader(Raw.string([0x01] + [UInt8](repeating: 0, count: 16)))
    XCTAssertThrows(WireError.tooLong(limit: 16)) { () throws(WireError) in try long.readMPInt(limit: 16) }
  }

  func testCountsCannotReserveMoreThanTheInput() throws {
    // 3 strings take at least 12 bytes; 12 are there.
    var fits = WireReader(Raw.u32(3) + [UInt8](repeating: 0, count: 12))
    XCTAssertEqual(try fits.readCount(limit: 100, elementBytes: 4), 3)
    var short = WireReader(Raw.u32(4) + [UInt8](repeating: 0, count: 12))
    XCTAssertThrows(WireError.tooMany(limit: 100)) { () throws(WireError) in try short.readCount(limit: 100, elementBytes: 4) }
    XCTAssertEqual(short.offset, 0)
    var huge = WireReader(Raw.u32(.max))
    XCTAssertThrows(WireError.tooMany(limit: Limits.extInfoExtensions)) { () throws(WireError) in
      try huge.readCount(limit: Limits.extInfoExtensions, elementBytes: 8)
    }
    var overLimit = WireReader(Raw.u32(65) + [UInt8](repeating: 0, count: 1000))
    XCTAssertThrows(WireError.tooMany(limit: 64)) { () throws(WireError) in try overLimit.readCount(limit: 64, elementBytes: 8) }
  }

  func testBytesAndRemaining() throws {
    var reader = WireReader(Array(0..<20))
    XCTAssertEqual(try reader.readBytes(count: 16), Array(0..<16))
    XCTAssertThrows(WireError.truncated) { () throws(WireError) in try reader.readBytes(count: 5) }
    XCTAssertThrows(WireError.truncated) { () throws(WireError) in try reader.readBytes(count: -1) }
    XCTAssertEqual(reader.remaining, 4)
    XCTAssertEqual(reader.readRemaining(), [16, 17, 18, 19])
    XCTAssertEqual(reader.readRemaining(), [])
  }

  func testSecretStrings() throws {
    var reader = WireReader(Raw.string([1, 2, 3]) + Raw.u32(9) + [1])
    let secret = try reader.readSecretString(limit: 8)
    XCTAssertEqual(secret.withUnsafeBytes { Array($0) }, [1, 2, 3])
    XCTAssertEqual(secret.description, "SecretBytes(3 bytes)")
    XCTAssertThrows(WireError.tooLong(limit: 8)) { () throws(WireError) in try reader.readSecretString(limit: 8) }
  }

  func testDecodeRefusesTrailingBytes() throws {
    let value = try WireReader.decode(Raw.u32(5)) { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
    XCTAssertEqual(value, 5)
    XCTAssertThrows(WireError.trailingBytes) { () throws(WireError) in
      try WireReader.decode(Raw.u32(5) + [0]) { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
    }
  }

  func testInboundMessageDecodeNamesTheMessage() throws {
    let accept = InboundMessage(payload: [6] + Raw.string("ssh-userauth"))!
    XCTAssertEqual(accept.number, .serviceAccept)
    XCTAssertEqual(try accept.decode { (reader: inout WireReader) throws(WireError) in try reader.readName() }, "ssh-userauth")
    let trailing = InboundMessage(payload: [6] + Raw.string("ssh-userauth") + [0])!
    XCTAssertThrows(SSHError.protocolViolation(.malformed(.serviceAccept, .trailingBytes))) { () throws(SSHError) in
      try trailing.decode { (reader: inout WireReader) throws(WireError) in try reader.readName() }
    }
    XCTAssertNil(InboundMessage(payload: []))
  }
}
