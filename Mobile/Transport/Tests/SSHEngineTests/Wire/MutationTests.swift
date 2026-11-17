import XCTest
@testable import SSHEngine

/// "Never crashes": a deterministic mutation loop over valid encodings of what a server sends (KEXINIT, EXT_INFO,
/// USERAUTH_FAILURE, INFO_REQUEST, host key and signature blobs, ECDSA signatures), fed to every decoder and to the
/// message policy. A trap would stop the test process; reaching the end is the proof. On top of that, whatever
/// decodes must re-encode to exactly its input (the decoders are canonical), and every failure is a `WireError`.
final class MutationTests: XCTestCase {
  static let iterations = 20_000

  /// Valid server payloads, built by hand.
  static let seeds: [[UInt8]] = {
    let kexInit: [UInt8] = [20] + [UInt8](repeating: 0x42, count: 16)
      + Raw.string("mlkem768x25519-sha256,curve25519-sha256,ext-info-s,kex-strict-s-v00@openssh.com")
      + Raw.string("ssh-ed25519,rsa-sha2-512") + Raw.string("aes256-gcm@openssh.com") + Raw.string("aes256-gcm@openssh.com")
      + Raw.string("hmac-sha2-256-etm@openssh.com") + Raw.string("hmac-sha2-256-etm@openssh.com")
      + Raw.string("none") + Raw.string("none") + Raw.string("") + Raw.string("") + [0] + Raw.u32(0)
    let extInfo: [UInt8] = [7] + Raw.u32(2) + Raw.string("server-sig-algs") + Raw.string("ssh-ed25519,rsa-sha2-256")
      + Raw.string("ping@openssh.com") + Raw.string("0")
    let failure: [UInt8] = [51] + Raw.string("publickey,password,keyboard-interactive") + [0]
    // A Latin-1 prompt ("Kennwort für:"), as PAM on a Latin-1 system sends it.
    let infoRequest: [UInt8] = [60] + Raw.string("Login") + Raw.string("Two factors") + Raw.string("")
      + Raw.u32(2) + Raw.string([0x4B, 0x65, 0x6E, 0x6E, 0x77, 0x6F, 0x72, 0x74, 0x20, 0x66, 0xFC, 0x72, 0x3A]) + [0]
      + Raw.string("Code: ") + [1]
    let disconnect: [UInt8] = [1] + Raw.u32(11) + Raw.string("bye\u{1B}[2J") + Raw.string("")
    let signature = Raw.string("ecdsa-sha2-nistp256") + Raw.string(Raw.string([0x00, 0x80] + [UInt8](repeating: 1, count: 31))
      + Raw.string([UInt8](repeating: 2, count: 32)))
    return [kexInit, extInfo, failure, infoRequest, disconnect, signature, Fixture.ed25519Blob, Fixture.rsaBlob,
            Fixture.ecdsaBlob(.p521)]
  }()

  func testMutatedInputsNeverCrashTheDecoders() {
    let random = SeededRandom(seed: 0x5EED_0F_D15_EA5E)
    var decoded = 0
    for iteration in 0..<Self.iterations {
      let seed = Self.seeds[iteration % Self.seeds.count]
      let input = Self.mutate(seed, random)
      decoded += Self.decodeEverything(input)
      // The decoders also see each message's body without its number.
      decoded += Self.decodeEverything(Array(input.dropFirst()))
    }
    // Some mutations must leave valid encodings, or the loop tests only the first byte.
    XCTAssertGreaterThan(decoded, Self.iterations / 20)
  }

  func testTheUnmutatedSeedsDecode() {
    for seed in Self.seeds {
      XCTAssertGreaterThan(Self.decodeEverything(seed) + Self.decodeEverything(Array(seed.dropFirst())), 0, "\(seed.prefix(8))")
    }
  }

  /// One to four mutations: flip a bit, set a byte to a boundary value, truncate, insert a hostile length, repeat or
  /// delete a run.
  static func mutate(_ seed: [UInt8], _ random: SeededRandom) -> [UInt8] {
    var bytes = seed
    for _ in 0...random.below(4) {
      let position = random.below(max(1, bytes.count))
      switch random.below(7) {
      case 0 where !bytes.isEmpty:
        bytes[position] ^= UInt8(1) << UInt8(random.below(8))
      case 1 where !bytes.isEmpty:
        bytes[position] = [0x00, 0x01, 0x7F, 0x80, 0xFF, 0x2C][random.below(6)]
      case 2:
        bytes = Array(bytes.prefix(position))
      case 3:
        let length: UInt32 = [0, 1, 0x7FFF_FFFF, 0x8000_0000, .max, UInt32(Limits.packetLength), 64, 65][random.below(8)]
        bytes.insert(contentsOf: Raw.u32(length), at: min(position, bytes.count))
      case 4 where !bytes.isEmpty:
        let end = min(bytes.count, position + 1 + random.below(16))
        bytes.insert(contentsOf: bytes[position..<end], at: end)
      case 5 where !bytes.isEmpty:
        let end = min(bytes.count, position + 1 + random.below(8))
        bytes.removeSubrange(position..<end)
      default:
        bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: min(position, bytes.count))
      }
    }
    return bytes
  }

  /// Runs every decoder on `input`; returns how many accepted it. Asserts the canonical round trip of each that did.
  static func decodeEverything(_ input: [UInt8]) -> Int {
    var accepted = 0
    func attempt<T>(_ body: (inout WireReader) throws(WireError) -> T, check: (T) -> Void = { _ in }) {
      do throws(WireError) {
        check(try WireReader.decode(input, body))
        accepted += 1
      } catch {
        // Typed: anything but a WireError would not compile. Any case is fine; reaching here without a trap is.
      }
    }
    do throws(SSHError) {
      let kexInit = try KexInit(decoding: input)
      XCTAssertEqual(try? kexInit.encoded(), input, "KEXINIT round trip")
      accepted += 1
    } catch {}
    attempt { (reader: inout WireReader) throws(WireError) in
      _ = try reader.readMessageNumber()
      return try ClientTransport.extInfoEntries(&reader)
    }
    attempt { (reader: inout WireReader) throws(WireError) in
      (try reader.readMessageNumber(), try reader.readNameList(), try reader.readBoolean())
    }
    attempt { (reader: inout WireReader) throws(WireError) in
      _ = try reader.readMessageNumber()
      return try UserauthCore.challenge(&reader)
    }
    attempt { (reader: inout WireReader) throws(WireError) in
      (try reader.readMessageNumber(), try reader.readText(limit: Limits.authenticationTextBytes))
    }
    attempt { (reader: inout WireReader) throws(WireError) in
      (try reader.readMessageNumber(), try reader.readUInt32(), try reader.readDisplayText(limit: Limits.descriptionBytes),
       try reader.readDisplayText(limit: Limits.languageTagBytes))
    } check: { value in
      _ = DisplayText.sanitize(Array(value.2.utf8))
    }
    attempt { (reader: inout WireReader) throws(WireError) in
      (try reader.readMPInt(limit: 2049), try reader.readMPInt(limit: 2049))
    } check: { value in
      var writer = WireWriter()
      writer.writeMPInt(magnitude: value.0)
      writer.writeMPInt(magnitude: value.1)
      XCTAssertEqual(try? writer.finish(), input, "mpint round trip")
    }
    do throws(WireError) {
      let key = try PublicKeyBlob(decoding: input)
      XCTAssertEqual(key.encoded, input, "public key round trip")
      accepted += 1
    } catch {}
    do throws(WireError) {
      let blob = try SignatureBlob(decoding: input)
      XCTAssertEqual(try? blob.encoded(), input, "signature round trip")
      accepted += 1
      for curve in ECDSACurve.allCases {
        if let raw = try? ECDSASignature.raw(fromInner: blob.signature, curve: curve) {
          XCTAssertEqual(try? ECDSASignature.inner(fromRaw: raw, curve: curve), blob.signature, "ECDSA round trip")
        }
      }
    } catch {}
    if let message = InboundMessage(payload: input) {
      for context in MessagePolicyTests.contexts { _ = MessagePolicy.route(for: message.number, in: context) }
    }
    return accepted
  }
}
