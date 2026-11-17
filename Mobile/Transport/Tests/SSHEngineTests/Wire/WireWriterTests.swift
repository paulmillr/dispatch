import SSHEngine
import XCTest

final class WireWriterTests: XCTestCase {
  func testValuesMatchTheRFCEncodings() throws {
    var writer = WireWriter(.serviceRequest)
    writer.writeString("ssh-userauth")
    writer.writeBoolean(true)
    writer.writeBoolean(false)
    writer.writeUInt32(0x0102_0304)
    writer.writeUInt64(0x0A0B_0C0D_0E0F_1011)
    writer.writeByte(0xFE)
    writer.writeBytes([9, 9])
    writer.writeNameList(["a", "b-c@example.org"])
    writer.writeNameList([])
    let expected = [5] + Raw.string("ssh-userauth") + [1, 0, 1, 2, 3, 4, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11]
      + [0xFE, 9, 9] + Raw.string("a,b-c@example.org") + Raw.u32(0)
    XCTAssertEqual(try writer.finish(), expected)
  }

  func testMPIntsAreMinimal() throws {
    let cases: [([UInt8], [UInt8])] = [
      ([], Raw.u32(0)),
      ([0, 0, 0], Raw.u32(0)),
      ([0x80], Raw.u32(2) + [0, 0x80]),
      ([0, 0, 0x7F], Raw.u32(1) + [0x7F]),
      (Raw.hex("09 a3 78 f9 b2 e3 32 a7"), Raw.u32(8) + Raw.hex("09 a3 78 f9 b2 e3 32 a7")),
    ]
    for (magnitude, wire) in cases {
      var writer = WireWriter()
      writer.writeMPInt(magnitude: magnitude)
      XCTAssertEqual(try writer.finish(), wire)
      // And the reader takes it back.
      var reader = WireReader(wire)
      XCTAssertEqual(try reader.readMPInt(limit: 16), Array(magnitude.drop { $0 == 0 }))
    }
  }

  func testInvalidNamesFailTheWriter() {
    for names in [[""], ["a,b"], ["sp ace"], ["ok", "caf\u{E9}"], [String(repeating: "n", count: Limits.nameLength + 1)]] {
      var writer = WireWriter()
      writer.writeNameList(names)
      XCTAssertThrows(WireError.unencodable) { () throws(WireError) in try writer.finish() }
    }
    var writer = WireWriter()
    writer.writeName("with,comma")
    writer.writeUInt32(1)
    XCTAssertThrows(WireError.unencodable) { () throws(WireError) in try writer.finish() }
  }

  func testSecretPayloadsAreMovedAndWiped() throws {
    let password = SecretBytes(utf8: "correct horse")
    var writer = WireWriter(.userauthRequest, capacity: 128)
    writer.writeString("phone")
    writer.writeString(password)
    let payload = try writer.finishSecret()
    XCTAssertEqual(payload.withUnsafeBytes { Array($0) }, [50] + Raw.string("phone") + Raw.string("correct horse"))
    XCTAssertEqual(writer.count, 0)
    XCTAssertThrows(WireError.unencodable) { () throws(WireError) in
      var failed = WireWriter()
      failed.writeName("")
      return try failed.finishSecret()
    }
  }

  func testSecretBytes() throws {
    let a = SecretBytes(copying: [1, 2, 3]), b = SecretBytes(copying: [1, 2, 3]), c = SecretBytes(copying: [1, 2, 4])
    XCTAssertTrue(a.constantTimeEquals(b))
    XCTAssertFalse(a.constantTimeEquals(c))
    XCTAssertFalse(a.constantTimeEquals(SecretBytes(copying: [1, 2])))
    XCTAssertEqual("\(a)", "SecretBytes(3 bytes)")
    struct Refused: Error, Equatable {}
    XCTAssertThrows(Refused()) { () throws(Refused) in
      try SecretBytes(count: 8) { (_: UnsafeMutableRawBufferPointer) throws(Refused) in throw Refused() }
    }
    var buffer: [UInt8] = [1, 2, 3]
    buffer.withUnsafeMutableBytes { SecretBytes.wipe($0) }
    XCTAssertEqual(buffer, [0, 0, 0])
  }
}
