/// Why `KeyFile.parse` failed. Three kinds, as the C ABI and MobileTransport distinguish them:
///
/// - `SSHError.wrongPassphrase`: the file is encrypted and the passphrase is missing (nil or empty) or wrong. The
///   file's structure was sound up to the decryption.
/// - `SSHError.unsupported(<KeyFileRefusal>)`: a readable file the engine refuses on purpose (a format, key type or
///   parameter it does not take). Each refusal has its own fixed text, so the app can say what to do about it.
/// - `SSHError.invalidKey(<KeyFileProblem>)`: anything else: not a key file, damaged, inconsistent.
///
/// Every text is a fixed phrase: nothing in an error comes from the file's bytes.

/// Key files refused on purpose, thrown as `SSHError.unsupported(rawValue)`.
public enum KeyFileRefusal: String, Sendable, CaseIterable {
  /// A PuTTY `.ppk` file (PuTTYgen exports keys in OpenSSH format).
  case puttyKey = "PuTTY key files (.ppk) are not supported"
  /// Legacy PEM encryption (`Proc-Type: 4,ENCRYPTED`; `ssh-keygen -p` rewrites the file in OpenSSH format).
  case encryptedPEM = "encrypted PEM key files are not supported"
  /// `ENCRYPTED PRIVATE KEY` (PKCS#8 with PBES2).
  case encryptedPKCS8 = "encrypted PKCS#8 key files are not supported"
  /// `ssh-dss` and `DSA PRIVATE KEY`.
  case dsa = "DSA keys are not supported"
  /// `sk-ssh-ed25519@openssh.com`, `sk-ecdsa-sha2-nistp256@openssh.com`: the key needs its hardware token.
  case securityKey = "security key (FIDO) keys are not supported"
  /// A certificate (`*-cert-v01@openssh.com`, or an X.509 `CERTIFICATE`) instead of a private key.
  case certificate = "certificates are not supported: choose the private key file"
  /// A public key (an `authorized_keys` line, `PUBLIC KEY`) instead of a private key.
  case publicKey = "this is a public key: choose the private key file"
  /// Another vendor's private key format (`SSH2 ENCRYPTED PRIVATE KEY`, ssh.com).
  case foreignFormat = "this key file format is not supported"
  /// A key type other than Ed25519, ECDSA P-256/384/521 and RSA (secp256k1, X25519, Ed448, RSA-PSS, ...).
  case keyType = "this key type is not supported"
  /// An `openssh-key-v1` cipher ssh-keygen no longer writes (3des-cbc) or no implementation knows.
  case cipher = "the key file's cipher is not supported"
  /// An `openssh-key-v1` KDF other than bcrypt.
  case kdf = "the key file's key derivation is not supported"
  /// More bcrypt rounds than `Limits.keyFileBcryptRounds`.
  case bcryptRounds = "the key file asks for more bcrypt rounds than allowed"
  /// An RSA modulus outside `Limits.rsaMinimumBits...Limits.rsaMaximumBits`.
  case rsaKeySize = "RSA keys must have 2048 to 16384 bits"

  public var error: SSHError { .unsupported(rawValue) }

  /// The refusal an error carries, if it is one.
  public init?(_ error: SSHError) {
    guard case .unsupported(let text) = error else { return nil }
    self.init(rawValue: text)
  }
}

/// Unreadable key files, thrown as `SSHError.invalidKey(rawValue)`.
public enum KeyFileProblem: String, Sendable, CaseIterable {
  /// Bytes that are not text (the russh engine's text).
  case notText = "not a text key file"
  /// Text that holds no private key armor the engine knows.
  case notAKey = "not a private key file"
  /// Larger than `Limits.keyFileBytes`.
  case tooLarge = "the key file is too large"
  /// Malformed: truncated, a length past its limit or the end, bad base64 or DER, wrong check integers or padding in
  /// an unencrypted file, trailing data.
  case damaged = "the key file is damaged"
  /// More than one key in one file (an `openssh-key-v1` count above 1, or two armored blocks).
  case moreThanOneKey = "the key file holds more than one key"
  /// The private half does not belong to the public half the file carries (or the key fails its signing check).
  case mismatchedHalves = "the private key does not match the public key in the file"

  public var error: SSHError { .invalidKey(rawValue) }

  /// The problem an error carries, if it is one.
  public init?(_ error: SSHError) {
    guard case .invalidKey(let text) = error else { return nil }
    self.init(rawValue: text)
  }
}

/// Runs a wire decode, reporting any failure as a damaged file.
func damagedUnlessDecoded<T>(_ body: () throws(WireError) -> T) throws(SSHError) -> T {
  do { return try body() } catch { throw KeyFileProblem.damaged.error }
}
