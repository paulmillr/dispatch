import CryptoKit
import Foundation

/// The third-party vector files in `Primitives/Vectors` (the target's copied resource; `Vectors/README.md` gives each
/// file's origin and licence). Each is read only if its SHA-256 is the one pinned here, so a file that was edited,
/// truncated or replaced fails its test instead of quietly testing less.
enum VectorFiles {
  struct Mismatch: Error, CustomStringConvertible {
    let description: String
  }

  /// noble-ciphers' copy of StableLib's ChaCha20 streams: the original layout (8-byte nonce) from block 0.
  struct ChaChaStream: Decodable {
    let key: String
    let nonce: String
    let stream: String
  }

  /// noble-ciphers' copy of StableLib's Poly1305 vectors: the key is the field's first 32 bytes.
  struct PolyMAC: Decodable {
    let data: String
    let key: String
    let mac: String
  }

  /// noble-ciphers' copy of StableLib's ChaCha20-Poly1305 vectors: `result` is the ciphertext and the 16-byte tag;
  /// some have no `aad`.
  struct AEAD: Decodable {
    let key: String
    let nonce: String
    let aad: String?
    let msg: String
    let result: String
  }

  /// Wycheproof's `aead_test_schema_v1.json`, the fields these tests read.
  struct Wycheproof: Decodable {
    struct Group: Decodable {
      let ivSize: Int
      let keySize: Int
      let tagSize: Int
      let tests: [Test]
    }

    struct Test: Decodable {
      let tcId: Int
      let comment: String
      let flags: [String]
      let key: String
      let iv: String
      let aad: String
      let msg: String
      let ct: String
      let tag: String
      let result: String
    }

    let algorithm: String
    let numberOfTests: Int
    let testGroups: [Group]
  }

  static func stableLibChaCha20() throws -> [ChaChaStream] {
    try decode("stablelib_chacha20.json", sha256: "8dc3b66cb5b20d3247b6020866f1938a23bfb01d1aefaf74a58f31b0eedc3113")
  }

  static func stableLibPoly1305() throws -> [PolyMAC] {
    try decode("stablelib_poly1305.json", sha256: "d4d434d82ed36b4a4acc15485a14291cbecbf02aed67e5b3b013e648158041d6")
  }

  static func stableLibChaCha20Poly1305() throws -> [AEAD] {
    try decode("stablelib_chacha20poly1305.json",
               sha256: "5b9752192bb80df28929411be425cd01b38c7e392eeebc127f2eb26e6e26e228")
  }

  static func wycheproofChaCha20Poly1305() throws -> Wycheproof {
    try decode("chacha20_poly1305_test.json",
               sha256: "fe61d25f90e1bde4461d00eafe61049e5f29bd999f36b766df9cda90906ad53d")
  }

  private static func decode<T: Decodable>(_ name: String, sha256: String) throws -> T {
    guard let directory = Bundle.module.url(forResource: "Vectors", withExtension: nil) else {
      throw Mismatch(description: "the test bundle has no Vectors directory")
    }
    let data = try Data(contentsOf: directory.appendingPathComponent(name))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == sha256 else {
      throw Mismatch(description: "\(name): SHA-256 \(digest), pinned \(sha256) (Vectors/README.md)")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}
