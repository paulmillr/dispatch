/// Private key files, as the app imports them: the one entry point of Keys/.
///
/// Read: OpenSSH (`openssh-key-v1`; plain, or passphrase-protected with bcrypt and any cipher `KeyFileCipher` names),
/// and unencrypted PEM (`RSA PRIVATE KEY`, `EC PRIVATE KEY`, `PRIVATE KEY`), each holding one Ed25519, ECDSA
/// P-256/384/521 or RSA (2048 to 16384 bits) key. Refused (`KeyFileRefusal`): PuTTY files, encrypted PEM and PKCS#8,
/// DSA, security keys, certificates, public keys, other formats and key types, bcrypt rounds above the limit.
///
/// Order of checks: the size (`Limits.keyFileBytes`); a PuTTY header; text (tab, line feed, carriage return and
/// printable ASCII only, after an optional UTF-8 byte order mark); a public key line or RFC 4716 armor; the armor and
/// its label; the format's own checks. A passphrase is asked for (`wrongPassphrase` when missing) only once the file's structure up
/// to the encrypted section is sound and its key type is one the engine takes. A passphrase given for an unencrypted
/// file is ignored; an empty one counts as none.
///
/// Secrets: the file and passphrase stay the caller's (`SecretBytes`); every copy made here (decoded base64, the
/// decrypted section, derived keys, DER for Security) is wiped before `parse` returns. The private key then lives
/// only in the returned key's CryptoKit or Security object.
public enum KeyFile {
  public static func parse(_ file: SecretBytes, passphrase: SecretBytes? = nil) throws(SSHError) -> FileKey {
    try parse(file, passphrase: passphrase, maximumRounds: Limits.keyFileBcryptRounds)
  }

  /// `maximumRounds` lower than the limit, for tests that must bound bcrypt's cost.
  static func parse(_ file: SecretBytes, passphrase: SecretBytes?, maximumRounds: Int) throws(SSHError) -> FileKey {
    guard file.count <= Limits.keyFileBytes else { throw KeyFileProblem.tooLarge.error }
    let passphrase = passphrase.flatMap { $0.isEmpty ? nil : $0 }
    let block = try file.withBytes { (text) throws(SSHError) -> Armor.Block in
      let start = text.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
      let content = UnsafeRawBufferPointer(rebasing: text[start...])
      let firstLine = content.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
      if firstLine.starts(with: "PuTTY-User-Key-File-".utf8) { throw KeyFileRefusal.puttyKey.error }
      guard content.allSatisfy({ $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || (0x20...0x7E).contains($0) }) else {
        throw KeyFileProblem.notText.error
      }
      if let refusal = publicKeyLine(firstLine) { throw refusal.error }
      // RFC 4716's armor (four dashes): ssh-keygen -e's public keys, and ssh.com's private key files.
      if firstLine.starts(with: "---- BEGIN SSH2 ".utf8) {
        let line = String(decoding: firstLine.prefix { $0 != 0x0A && $0 != 0x0D }, as: UTF8.self)
        throw line.contains("PUBLIC KEY") ? KeyFileRefusal.publicKey.error : KeyFileRefusal.foreignFormat.error
      }
      guard let block = try Armor.parse(content) else { throw KeyFileProblem.notAKey.error }
      return block
    }

    switch block.label {
    case "OPENSSH PRIVATE KEY":
      guard !block.hasHeaders, let body = block.body else { throw KeyFileProblem.damaged.error }
      return try OpenSSHKeyFile.parse(body, passphrase: passphrase, maximumRounds: maximumRounds)
    case "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY":
      if block.legacyEncrypted { throw KeyFileRefusal.encryptedPEM.error }
      guard !block.hasHeaders, let body = block.body else { throw KeyFileProblem.damaged.error }
      return try PEMKeyFile.parse(label: block.label, body: body)
    case "DSA PRIVATE KEY":
      throw KeyFileRefusal.dsa.error
    case "ENCRYPTED PRIVATE KEY":
      throw KeyFileRefusal.encryptedPKCS8.error
    case "SSH2 ENCRYPTED PRIVATE KEY", "SSH2 PRIVATE KEY":
      throw KeyFileRefusal.foreignFormat.error
    case "PUBLIC KEY", "RSA PUBLIC KEY", "SSH2 PUBLIC KEY", "EC PUBLIC KEY":
      throw KeyFileRefusal.publicKey.error
    case "CERTIFICATE", "TRUSTED CERTIFICATE":
      throw KeyFileRefusal.certificate.error
    default:
      throw KeyFileProblem.notAKey.error
    }
  }

  /// A public key or certificate line (`ssh-ed25519 AAAA... comment`, as in a `.pub` or `-cert.pub` file):
  /// `<type> <base64 starting AAAA>`, the type a name starting `ssh-`, `ecdsa-`, `rsa-` or `sk-`.
  private static func publicKeyLine(_ text: some Collection<UInt8>) -> KeyFileRefusal? {
    let line = text.prefix { $0 != 0x0A && $0 != 0x0D }
    let words = line.split(separator: 0x20, maxSplits: 2, omittingEmptySubsequences: true)
    guard words.count >= 2, words[1].starts(with: "AAAA".utf8),
      let type = WireReader.name(ArraySlice(words[0])),
      ["ssh-", "ecdsa-", "rsa-", "sk-"].contains(where: { type.hasPrefix($0) })
    else { return nil }
    return type.hasSuffix(PublicKeyBlob.certificateSuffix) ? .certificate : .publicKey
  }
}
