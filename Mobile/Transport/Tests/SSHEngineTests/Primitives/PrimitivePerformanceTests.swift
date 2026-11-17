import CryptoKit
import XCTest
@testable import SSHEngine

/// Throughput figures, printed; run only with `SSHENGINE_PRIMITIVE_BENCH=1` (and `-c release` for meaningful numbers).
/// No thresholds except bcrypt's: ssh-keygen's 24 rounds must stay under a second in a release build.
final class PrimitivePerformanceTests: XCTestCase {
  private static let size = 32 << 20

  override func setUpWithError() throws {
    guard PrimitiveTestSupport.benchmarks else { throw XCTSkip("set SSHENGINE_PRIMITIVE_BENCH=1 to measure") }
  }

  func testChaCha20Throughput() throws {
    let cipher = try ChaCha20(key: [UInt8](repeating: 7, count: 32), nonce: [UInt8](repeating: 1, count: 8))
    var buffer = [UInt8](repeating: 0, count: Self.size)
    let seconds = Self.time { cipher.xor(&buffer, counter: 1) }
    Self.report("ChaCha20 xor, one 32 MiB buffer", seconds)
    // SSH-sized pieces: 32 KiB packets, each from counter 1 as the SSH cipher does.
    let packet = 32 << 10
    let packets = buffer.withUnsafeMutableBytes { bytes in
      Self.time {
        var offset = 0
        while offset < bytes.count {
          cipher.xor(UnsafeMutableRawBufferPointer(rebasing: bytes[offset..<(offset + packet)]), counter: 1)
          offset += packet
        }
      }
    }
    Self.report("ChaCha20 xor, 32 KiB packets", packets)
  }

  func testPoly1305Throughput() {
    let buffer = [UInt8](repeating: 0x5c, count: Self.size)
    let key = [UInt8](repeating: 0x33, count: 32)
    var tag: [UInt8] = []
    let seconds = Self.time { tag = Poly1305.authenticate(buffer, key: key) }
    XCTAssertEqual(tag.count, 16)
    Self.report("Poly1305, one 32 MiB message", seconds)
  }

  /// The assembled AEAD next to CryptoKit's, for scale.
  func testAEADAgainstCryptoKit() throws {
    let key = [UInt8](repeating: 9, count: 32)
    let nonce = [UInt8](repeating: 2, count: 12)
    let plaintext = [UInt8](repeating: 0x41, count: Self.size)
    let ours = try Self.time { _ = try AssembledAEAD.seal(key: key, nonce: nonce, aad: [], plaintext: plaintext) }
    Self.report("ChaCha20-Poly1305 (ours, assembled)", ours)
    let theirs = try Self.time {
      _ = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce))
    }
    Self.report("ChaCha20-Poly1305 (CryptoKit)", theirs)
  }

  /// What opening an ssh-keygen key costs: 48 bytes (aes256-ctr's key and IV) at 16 and 24 rounds, and at the
  /// most a file may ask for (`Limits.keyFileBcryptRounds`, what a hostile file can make the user wait).
  func testBcryptPBKDFAtSSHKeygenRounds() throws {
    for rounds in [16, 24, Limits.keyFileBcryptRounds] {
      let seconds = try Self.time {
        _ = try BcryptPBKDF.derive(password: Array("fictional passphrase".utf8), salt: [UInt8](repeating: 0x2a, count: 16),
                                   rounds: rounds, count: 48)
      }
      print("PrimitivePerformanceTests: bcrypt_pbkdf \(rounds) rounds, 48 bytes: " + String(format: "%.3f s", seconds))
      #if !DEBUG
      if rounds <= 24 { XCTAssertLessThan(seconds, 1) }
      #endif
    }
  }

  private static func time<R>(_ body: () throws -> R) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    _ = try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
  }

  private static func report(_ what: String, _ seconds: Double) {
    print("PrimitivePerformanceTests: \(what): " + String(format: "%.1f MB/s (%.3f s)", Double(size) / seconds / 1e6, seconds))
  }
}
