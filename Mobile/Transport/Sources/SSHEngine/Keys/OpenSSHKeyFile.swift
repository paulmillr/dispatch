import CryptoKit
import Foundation

/// `openssh-key-v1` (OpenSSH PROTOCOL.key), the format ssh-keygen writes by default:
///
///     "openssh-key-v1\0" | string cipher | string kdf | string kdf options | uint32 count (1)
///     | string public key blob | string private section [| tag, for AEAD ciphers]
///
/// The private section, decrypted: uint32 check | uint32 check | the key's private fields | string comment | padding
/// 1, 2, 3, ... to the cipher's block size. Checked here: one key per file; cipher `none` with KDF `none` and no
/// options, or a known cipher with `bcrypt` (salt within `Limits.keyFileSaltBytes`, 1 to `maximumRounds` rounds); the
/// section a whole number of blocks; equal check integers (unequal after decryption: the passphrase is wrong, as
/// OpenSSH reports it); the private fields' public parts equal to the public blob, and the private key's own public
/// key equal to it too; the padding; no trailing bytes anywhere. The public blob is examined first, so a refused type
/// (DSA, a security key, a certificate) is reported without asking for the passphrase.
enum OpenSSHKeyFile {
  static let magic = Array("openssh-key-v1\u{0}".utf8)

  private struct Envelope {
    var cipher: KeyFileCipher?
    var salt: [UInt8] = []
    var rounds = 0
    var publicBlob: [UInt8] = []
    var section: SecretBytes
    var tag: [UInt8] = []
  }

  static func parse(_ body: SecretBytes, passphrase: SecretBytes?, maximumRounds: Int) throws(SSHError) -> FileKey {
    let envelope = try body.withTemporaryArray { (bytes) throws(SSHError) in
      try readEnvelope(bytes, maximumRounds: maximumRounds)
    }
    let publicKey = try decodePublicKey(envelope.publicBlob)

    var plain = envelope.section
    if let cipher = envelope.cipher {
      guard let passphrase, !passphrase.isEmpty else { throw .wrongPassphrase }
      guard envelope.section.count % cipher.blockBytes == 0 else { throw KeyFileProblem.damaged.error }
      var derived: [UInt8]
      do {
        derived = try passphrase.withUnsafeBytes { password in
          try envelope.salt.withUnsafeBytes { salt in
            try BcryptPBKDF.derive(password: password, salt: salt, rounds: envelope.rounds,
                                   count: cipher.keyBytes + cipher.ivBytes)
          }
        }
      } catch {
        throw KeyFileProblem.damaged.error
      }
      defer { wipe(&derived) }
      plain = try withTypedBytes(of: derived) { (keyAndIV) throws(SSHError) in
        try cipher.decrypt(envelope.section, tag: envelope.tag, keyAndIV: keyAndIV)
      }
    } else {
      guard envelope.section.count % 8 == 0 else { throw KeyFileProblem.damaged.error }
    }
    let encrypted = envelope.cipher != nil
    let blockBytes = envelope.cipher?.blockBytes ?? 8
    return try plain.withTemporaryArray { (bytes) throws(SSHError) in
      try readPrivateSection(bytes, publicKey: publicKey, encrypted: encrypted, blockBytes: blockBytes)
    }
  }

  /// Everything outside the private section.
  private static func readEnvelope(_ bytes: [UInt8], maximumRounds: Int) throws(SSHError) -> Envelope {
    var reader = WireReader(bytes)
    let (cipherName, kdfName, options, count) = try damagedUnlessDecoded { () throws(WireError) in
      guard try reader.readBytes(count: magic.count) == magic else { throw .invalidValue }
      return (try reader.readName(), try reader.readName(), try reader.readString(limit: 8 + Limits.keyFileSaltBytes),
              try reader.readUInt32())
    }
    guard count == 1 else { throw count == 0 ? KeyFileProblem.damaged.error : KeyFileProblem.moreThanOneKey.error }

    var envelope = Envelope(section: SecretBytes(copying: []))
    if cipherName == "none" {
      guard kdfName == "none", options.isEmpty else { throw KeyFileProblem.damaged.error }
    } else {
      guard let cipher = KeyFileCipher(rawValue: cipherName) else { throw KeyFileRefusal.cipher.error }
      guard kdfName == "bcrypt" else {
        throw kdfName == "none" ? KeyFileProblem.damaged.error : KeyFileRefusal.kdf.error
      }
      let (salt, rounds) = try damagedUnlessDecoded { () throws(WireError) in
        try WireReader.decode(options) { (options: inout WireReader) throws(WireError) in
          (try options.readString(limit: Limits.keyFileSaltBytes), try options.readUInt32())
        }
      }
      guard !salt.isEmpty, rounds >= 1 else { throw KeyFileProblem.damaged.error }
      guard let rounds = Int(exactly: rounds), rounds <= maximumRounds else { throw KeyFileRefusal.bcryptRounds.error }
      envelope.cipher = cipher
      envelope.salt = salt
      envelope.rounds = rounds
    }
    let tagBytes = envelope.cipher?.tagBytes ?? 0
    (envelope.publicBlob, envelope.section, envelope.tag) = try damagedUnlessDecoded { () throws(WireError) in
      let blob = try reader.readString(limit: Limits.publicKeyBlobBytes)
      let section = try reader.readSecretString(limit: Limits.keyFileBytes)
      let tag = try reader.readBytes(count: tagBytes)
      try reader.expectEnd()
      return (blob, section, tag)
    }
    return envelope
  }

  /// The file's public key, with the refusals its type name decides.
  private static func decodePublicKey(_ blob: [UInt8]) throws(SSHError) -> PublicKeyBlob {
    var reader = WireReader(blob)
    let type = try damagedUnlessDecoded { () throws(WireError) in try reader.readName() }
    if type.hasSuffix(PublicKeyBlob.certificateSuffix) { throw KeyFileRefusal.certificate.error }
    if type == "ssh-dss" { throw KeyFileRefusal.dsa.error }
    if type.hasPrefix("sk-") { throw KeyFileRefusal.securityKey.error }
    if type == "ssh-rsa" {
      // The size refusal before the blob's own bounds (which would only say invalid).
      let (exponent, modulus) = try damagedUnlessDecoded { () throws(WireError) in
        (try reader.readMPInt(limit: Limits.publicKeyBlobBytes), try reader.readMPInt(limit: Limits.publicKeyBlobBytes))
      }
      try PEMKeyFile.checkRSASize(exponent: exponent, modulus: modulus)
    }
    do {
      return try PublicKeyBlob(decoding: blob)
    } catch .unsupportedType {
      throw KeyFileRefusal.keyType.error
    } catch {
      throw KeyFileProblem.damaged.error
    }
  }

  private static func readPrivateSection(_ bytes: [UInt8], publicKey: PublicKeyBlob, encrypted: Bool,
                                         blockBytes: Int) throws(SSHError) -> FileKey {
    var reader = WireReader(bytes)
    let (check1, check2) = try damagedUnlessDecoded { () throws(WireError) in
      (try reader.readUInt32(), try reader.readUInt32())
    }
    guard check1 == check2 else { throw encrypted ? .wrongPassphrase : KeyFileProblem.damaged.error }
    let type = try damagedUnlessDecoded { () throws(WireError) in try reader.readName() }
    guard type == publicKey.keyType else { throw KeyFileProblem.mismatchedHalves.error }

    let material: FileKey.Material
    switch publicKey {
    case .ed25519(let point):
      // string public key (32) | string seed ‖ public key (64)
      let (key, secret) = try damagedUnlessDecoded { () throws(WireError) in
        (try reader.readString(limit: 32), try reader.readSecretString(limit: 64))
      }
      guard key == point else { throw KeyFileProblem.mismatchedHalves.error }
      guard secret.count == 64 else { throw KeyFileProblem.damaged.error }
      guard secret.withUnsafeBytes({ $0[32...].elementsEqual(point) }) else {
        throw KeyFileProblem.mismatchedHalves.error
      }
      let signing: Curve25519.Signing.PrivateKey
      do { signing = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.slice(0..<32)) } catch {
        throw KeyFileProblem.damaged.error
      }
      guard signing.publicKey.rawRepresentation.elementsEqual(point) else { throw KeyFileProblem.mismatchedHalves.error }
      material = .ed25519(signing)

    case .ecdsa(let curve, let point):
      // string curve | string Q | mpint d
      let (name, q, scalar) = try damagedUnlessDecoded { () throws(WireError) in
        (try reader.readName(), try reader.readString(limit: curve.pointBytes),
         try reader.readSecretMPInt(limit: curve.scalarBytes + 1))
      }
      guard name == curve.rawValue, q == point else { throw KeyFileProblem.mismatchedHalves.error }
      let (key, derived) = try ECKeys.privateKey(curve: curve, scalar: scalar)
      guard derived == point else { throw KeyFileProblem.mismatchedHalves.error }
      material = key

    case .rsa(let exponent, let modulus):
      // mpint n | mpint e | mpint d | mpint iqmp | mpint p | mpint q
      let limit = modulus.count + 1
      let (n, e, d, iqmp, p, q) = try damagedUnlessDecoded { () throws(WireError) in
        (try reader.readMPInt(limit: limit), try reader.readMPInt(limit: Limits.rsaExponentBytes + 1),
         try reader.readSecretMPInt(limit: limit), try reader.readSecretMPInt(limit: limit),
         try reader.readSecretMPInt(limit: limit), try reader.readSecretMPInt(limit: limit))
      }
      guard n == modulus, e == exponent else { throw KeyFileProblem.mismatchedHalves.error }
      let key = try RSAKeys.privateKey(modulus: n, exponent: e, d: d, iqmp: iqmp, p: p, q: q)
      try RSAKeys.checkPair(key, exponent: e, modulus: n)
      material = .rsa(key)
    }

    let (comment, padding) = try damagedUnlessDecoded { () throws(WireError) in
      (try reader.readString(limit: Limits.keyFileCommentBytes), reader.readRemaining())
    }
    // 1, 2, 3, ... up to (not including) the block size: what OpenSSH and other writers produce.
    guard bytes.count % blockBytes == 0, padding.count < max(blockBytes, 16),
      padding.elementsEqual((0..<padding.count).lazy.map { UInt8(truncatingIfNeeded: $0 + 1) })
    else { throw KeyFileProblem.damaged.error }
    return FileKey(material: material, publicKey: publicKey, comment: String(decoding: comment, as: UTF8.self))
  }
}
