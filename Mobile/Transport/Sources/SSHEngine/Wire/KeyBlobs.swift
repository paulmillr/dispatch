/// The NIST curves of `ecdsa-sha2-*` keys (RFC 5656).
public enum ECDSACurve: String, Sendable, Hashable, CaseIterable {
  case p256 = "nistp256"
  case p384 = "nistp384"
  case p521 = "nistp521"

  /// The key type and signature algorithm name, `ecdsa-sha2-<curve>`.
  public var keyType: String { "ecdsa-sha2-" + rawValue }
  /// Bytes of one coordinate or scalar: r and s of a raw signature each take this many.
  public var scalarBytes: Int {
    switch self {
    case .p256: 32
    case .p384: 48
    case .p521: 66
    }
  }
  /// An uncompressed SEC1 point: 0x04, then X and Y.
  public var pointBytes: Int { 1 + 2 * scalarBytes }
}

/// A public key blob (RFC 4253 §6.6, RFC 5656 §3.1, RFC 8709 §4): the host key the server presents, a user key's
/// public half. Decoding is canonical: it refuses anything `encoded` would not reproduce byte for byte (trailing
/// bytes, non-minimal mpints), so comparing blobs compares keys. Only the structure is checked here (sizes, the
/// point's form, the RSA bounds of `Limits`); whether an ECDSA point is on its curve is CryptoKit's check when the
/// key is made. Certificates and every other type are refused by name (`WireError.unsupportedType`). A value built
/// by hand rather than decoded must hold the sizes `init(decoding:)` checks; `encoded` does not check them again.
public enum PublicKeyBlob: Sendable, Hashable {
  /// The 32-byte Ed25519 public key.
  case ed25519([UInt8])
  /// An uncompressed SEC1 point (`ECDSACurve.pointBytes`).
  case ecdsa(ECDSACurve, point: [UInt8])
  /// Minimal big-endian magnitudes (no leading zero byte).
  case rsa(exponent: [UInt8], modulus: [UInt8])

  /// The suffix of every OpenSSH certificate type: never decoded, always refused.
  public static let certificateSuffix = "-cert-v01@openssh.com"

  public init(decoding blob: [UInt8]) throws(WireError) {
    guard blob.count <= Limits.publicKeyBlobBytes else { throw .tooLong(limit: Limits.publicKeyBlobBytes) }
    self = try WireReader.decode(blob) { (reader: inout WireReader) throws(WireError) -> PublicKeyBlob in
      let type = try reader.readName()
      switch type {
      case "ssh-ed25519":
        let key = try reader.readString(limit: 32)
        guard key.count == 32 else { throw .invalidValue }
        return .ed25519(key)
      case "ssh-rsa":
        // RFC 4253 §6.6: e, then n.
        let exponent = try reader.readMPInt(limit: 1 + Limits.rsaExponentBytes)
        let modulus = try reader.readMPInt(limit: 1 + Limits.rsaMaximumBits / 8)
        try Self.checkRSA(exponent: exponent, modulus: modulus)
        return .rsa(exponent: exponent, modulus: modulus)
      default:
        guard let curve = ECDSACurve.allCases.first(where: { $0.keyType == type }) else {
          throw .unsupportedType(type)
        }
        // RFC 5656 §3.1: the curve identifier repeats the type's curve.
        guard try reader.readName() == curve.rawValue else { throw .invalidValue }
        let point = try reader.readString(limit: curve.pointBytes)
        guard point.count == curve.pointBytes, point.first == 0x04 else { throw .invalidValue }
        return .ecdsa(curve, point: point)
      }
    }
  }

  /// The type name the blob starts with: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, ...
  public var keyType: String {
    switch self {
    case .ed25519: "ssh-ed25519"
    case .ecdsa(let curve, _): curve.keyType
    case .rsa: "ssh-rsa"
    }
  }

  /// The wire blob.
  public var encoded: [UInt8] {
    var writer = WireWriter(capacity: 128)
    writer.writeName(keyType)
    switch self {
    case .ed25519(let key):
      writer.writeString(key)
    case .ecdsa(let curve, let point):
      writer.writeName(curve.rawValue)
      writer.writeString(point)
    case .rsa(let exponent, let modulus):
      writer.writeMPInt(magnitude: exponent)
      writer.writeMPInt(magnitude: modulus)
    }
    // Every value here was validated or built by the engine: names are constants, sizes are bounded.
    return (try? writer.finish()) ?? []
  }

  /// The RSA modulus size in bits; nil for other types.
  public var rsaModulusBits: Int? {
    guard case .rsa(_, let modulus) = self else { return nil }
    return Self.bits(modulus)
  }

  /// RSA's bounds: an odd exponent of at least 3 within `Limits.rsaExponentBytes`, an odd modulus of
  /// `Limits.rsaMinimumBits` to `Limits.rsaMaximumBits`.
  public static func checkRSA(exponent: [UInt8], modulus: [UInt8]) throws(WireError) {
    guard let low = exponent.last, low & 1 == 1, exponent.count <= Limits.rsaExponentBytes,
      exponent.count > 1 || low >= 3
    else { throw .invalidValue }
    guard let modulusLow = modulus.last, modulusLow & 1 == 1,
      (Limits.rsaMinimumBits...Limits.rsaMaximumBits).contains(bits(modulus))
    else { throw .invalidValue }
  }

  /// Bits of a minimal big-endian magnitude.
  static func bits(_ magnitude: [UInt8]) -> Int {
    guard let first = magnitude.first else { return 0 }
    return (magnitude.count - 1) * 8 + (8 - first.leadingZeroBitCount)
  }
}

/// A signature blob (RFC 4253 §6.6): the algorithm name, then the algorithm's signature bytes. What a host key's
/// signature over the exchange hash and a user key's USERAUTH_REQUEST signature both are. Only the framing is
/// checked here; the bytes' size and meaning are the verifier's (`ECDSASignature` for ECDSA's inner encoding).
public struct SignatureBlob: Sendable, Hashable {
  public let algorithm: String
  public let signature: [UInt8]

  public init(algorithm: String, signature: [UInt8]) {
    self.algorithm = algorithm
    self.signature = signature
  }

  public init(decoding blob: [UInt8]) throws(WireError) {
    guard blob.count <= Limits.signatureBlobBytes else { throw .tooLong(limit: Limits.signatureBlobBytes) }
    (algorithm, signature) = try WireReader.decode(blob) { (reader: inout WireReader) throws(WireError) in
      (try reader.readName(), try reader.readString(limit: Limits.signatureBlobBytes))
    }
  }

  /// The wire blob; `WireError.unencodable` for an invalid algorithm name.
  public func encoded() throws(WireError) -> [UInt8] {
    var writer = WireWriter(capacity: 16 + algorithm.utf8.count + signature.count)
    writer.writeName(algorithm)
    writer.writeString(signature)
    return try writer.finish()
  }
}

/// ECDSA's signature inside a signature blob (RFC 5656 §3.1.2: mpint r, mpint s) and the fixed-width r‖s that
/// CryptoKit (`rawRepresentation`) and the app's signers (Secure Enclave) use.
public enum ECDSASignature {
  /// r‖s, each `curve.scalarBytes` wide, from the blob's inner signature. r and s must be non-zero and fit.
  public static func raw(fromInner inner: [UInt8], curve: ECDSACurve) throws(WireError) -> [UInt8] {
    let width = curve.scalarBytes
    let (r, s) = try WireReader.decode(inner) { (reader: inout WireReader) throws(WireError) in
      (try reader.readMPInt(limit: width + 1), try reader.readMPInt(limit: width + 1))
    }
    guard !r.isEmpty, !s.isEmpty, r.count <= width, s.count <= width else { throw .invalidValue }
    return [UInt8](repeating: 0, count: width - r.count) + r + [UInt8](repeating: 0, count: width - s.count) + s
  }

  /// The blob's inner signature from r‖s (exactly `2 * curve.scalarBytes` bytes, neither half zero).
  public static func inner(fromRaw raw: [UInt8], curve: ECDSACurve) throws(WireError) -> [UInt8] {
    let width = curve.scalarBytes
    guard raw.count == 2 * width else { throw .invalidValue }
    let r = raw[..<width], s = raw[width...]
    guard r.contains(where: { $0 != 0 }), s.contains(where: { $0 != 0 }) else { throw .invalidValue }
    var writer = WireWriter(capacity: 2 * width + 10)
    writer.writeMPInt(magnitude: r)
    writer.writeMPInt(magnitude: s)
    return try writer.finish()
  }
}
