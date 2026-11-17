/// Keys that sign outside the engine: the app's Keychain Ed25519 keys and Secure Enclave P-256 keys, whose private
/// half never enters the engine. The signer returns the raw signature, in the form MobileTransport's `SSHKey.Signer`
/// has always returned (and the russh engine's `signature_blob` took): Ed25519's 64 bytes, or ECDSA's fixed-width
/// r‖s, which is CryptoKit's `ECDSASignature.rawRepresentation` (`SSHKey(p256:)` and `SSHKey(secureEnclave:)` return
/// exactly that). DER (X9.62, what `SecKeyCreateSignature` gives for ECDSA) is not accepted: its length never equals
/// r‖s's, so it fails the length check. RSA keys are not taken, as the russh engine did not take them.
public enum ExternalSignature {
  /// The signature blob for a raw signature under `algorithm`. Wrong lengths, and an r or s of zero, are
  /// `SSHError.invalidKey` with the russh engine's texts.
  public static func blob(raw: [UInt8], algorithm: SignatureAlgorithm) throws(SSHError) -> [UInt8] {
    let inner: [UInt8]
    switch algorithm {
    case .ed25519:
      guard raw.count == 64 else { throw .invalidKey("Ed25519 signatures are 64 bytes") }
      inner = raw
    case .ecdsaP256, .ecdsaP384, .ecdsaP521:
      let curve: ECDSACurve = algorithm == .ecdsaP256 ? .p256 : algorithm == .ecdsaP384 ? .p384 : .p521
      do { inner = try ECDSASignature.inner(fromRaw: raw, curve: curve) } catch {
        throw .invalidKey("ECDSA signature has the wrong length")
      }
    case .rsaSHA512, .rsaSHA256:
      throw unsupportedRSA
    }
    do { return try SignatureBlob(algorithm: algorithm.rawValue, signature: inner).encoded() } catch {
      throw .invalidKey("the signature could not be encoded")
    }
  }

  static let unsupportedRSA = SSHError.unsupported("external signing for ssh-rsa is unsupported")
}

/// A `UserKey` whose signing is a raw signer's (`ExternalSignature`). Each signature is checked against the public
/// key before it is handed to the auth layer, so a signer that signs with another key fails here
/// (`SSHError.invalidKey`) instead of as a server refusal.
public struct ExternalSignerKey: UserKey {
  /// Signs the RFC 4252 §7 bytes and returns the raw signature; throws `SSHError.cancelled` when the user declines.
  public typealias RawSigner = @Sendable ([UInt8]) async throws(SSHError) -> [UInt8]

  public let publicKey: PublicKeyBlob
  public let publicKeyBlob: [UInt8]
  private let signer: RawSigner

  /// `publicKeyBlob`: the key's SSH wire blob, Ed25519 or ECDSA. An undecodable blob is `invalidKey`, an RSA one
  /// `unsupported`.
  public init(publicKeyBlob: [UInt8], sign: @escaping RawSigner) throws(SSHError) {
    let key: PublicKeyBlob
    do { key = try PublicKeyBlob(decoding: publicKeyBlob) } catch {
      throw .invalidKey("the signer's public key blob is not a key the engine takes")
    }
    if case .rsa = key { throw ExternalSignature.unsupportedRSA }
    publicKey = key
    self.publicKeyBlob = publicKeyBlob
    signer = sign
  }

  public var keyType: String { publicKey.keyType }

  /// The `authorized_keys` line (no comment) and the SHA256 fingerprint.
  public var authorizedKeysLine: String { PublicKeyText.line(blob: publicKeyBlob, key: publicKey, comment: "") }
  public var fingerprint: String { PublicKeyText.fingerprint(blob: publicKeyBlob, key: publicKey) }

  public func sign(_ data: [UInt8], algorithm: SignatureAlgorithm) async throws(SSHError) -> [UInt8] {
    guard SignatureAlgorithm.algorithms(for: publicKey).contains(algorithm) else {
      throw .usage(.invalidArgument("a \(keyType) key cannot sign \(algorithm.rawValue)"))
    }
    let raw = try await signer(data)
    let blob = try ExternalSignature.blob(raw: raw, algorithm: algorithm)
    guard SSHSignatureVerifier.isValid(signatureBlob: blob, over: data, key: publicKey, algorithm: algorithm) else {
      throw .invalidKey("the signer's signature does not verify with its public key")
    }
    return blob
  }
}
