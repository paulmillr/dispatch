import CommonCrypto
import CryptoKit
import Foundation

/// The ciphers ssh-keygen writes `openssh-key-v1` private sections with (`-Z`; OpenSSH cipher.c), all keyed from
/// bcrypt_pbkdf's output: key, then IV. AES-CTR and AES-CBC through CommonCrypto; AES-GCM through CryptoKit (12-byte
/// IV, no associated data, the tag after the section); ChaCha20-Poly1305 as OpenSSH's packet construction with
/// sequence number 0 and no length (the engine's own `ChaCha20` and `Poly1305`: the first 32 key bytes are the main
/// key, the tag covers the section). 3des-cbc, which ssh-keygen still accepts, is refused.
enum KeyFileCipher: String, CaseIterable {
  case aes128CTR = "aes128-ctr"
  case aes192CTR = "aes192-ctr"
  case aes256CTR = "aes256-ctr"
  case aes128CBC = "aes128-cbc"
  case aes192CBC = "aes192-cbc"
  case aes256CBC = "aes256-cbc"
  case aes128GCM = "aes128-gcm@openssh.com"
  case aes256GCM = "aes256-gcm@openssh.com"
  case chacha20Poly1305 = "chacha20-poly1305@openssh.com"

  var keyBytes: Int {
    switch self {
    case .aes128CTR, .aes128CBC, .aes128GCM: 16
    case .aes192CTR, .aes192CBC: 24
    case .aes256CTR, .aes256CBC, .aes256GCM: 32
    case .chacha20Poly1305: 64
    }
  }

  var ivBytes: Int {
    switch self {
    case .aes128GCM, .aes256GCM: 12
    case .chacha20Poly1305: 0
    default: 16
    }
  }

  /// The section's length is a multiple of this.
  var blockBytes: Int { self == .chacha20Poly1305 ? 8 : 16 }

  /// The tag that follows the section (outside its string).
  var tagBytes: Int {
    switch self {
    case .aes128GCM, .aes256GCM, .chacha20Poly1305: 16
    default: 0
    }
  }

  /// The private section decrypted into wiped memory. `keyAndIV` is `keyBytes + ivBytes` bytes. A tag that does not
  /// verify is `SSHError.wrongPassphrase` (for CTR and CBC the check integers decide that later).
  func decrypt(_ section: SecretBytes, tag: [UInt8], keyAndIV: UnsafeRawBufferPointer) throws(SSHError) -> SecretBytes {
    guard keyAndIV.count == keyBytes + ivBytes, tag.count == tagBytes, section.count % blockBytes == 0 else {
      throw KeyFileProblem.damaged.error
    }
    let key = UnsafeRawBufferPointer(rebasing: keyAndIV[0..<keyBytes])
    let iv = UnsafeRawBufferPointer(rebasing: keyAndIV[keyBytes...])
    switch self {
    case .aes128CTR, .aes192CTR, .aes256CTR: return try commonCrypto(section, mode: kCCModeCTR, key: key, iv: iv)
    case .aes128CBC, .aes192CBC, .aes256CBC: return try commonCrypto(section, mode: kCCModeCBC, key: key, iv: iv)
    case .aes128GCM, .aes256GCM: return try gcm(section, tag: tag, key: key, iv: iv)
    case .chacha20Poly1305: return try chachaPoly(section, tag: tag, key: key)
    }
  }

  private func commonCrypto(_ section: SecretBytes, mode: Int, key: UnsafeRawBufferPointer,
                            iv: UnsafeRawBufferPointer) throws(SSHError) -> SecretBytes {
    var cryptor: CCCryptorRef?
    let status = CCCryptorCreateWithMode(
      CCOperation(kCCDecrypt), CCMode(mode), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), iv.baseAddress,
      key.baseAddress, key.count, nil, 0, 0, CCModeOptions(0), &cryptor)
    guard status == kCCSuccess, let cryptor else { throw KeyFileProblem.damaged.error }
    defer { CCCryptorRelease(cryptor) }
    // A throw from inside the initializer leaves the buffer to SecretBytes' deinit, which wipes and frees it.
    return try SecretBytes(count: section.count) { (output: UnsafeMutableRawBufferPointer) throws(SSHError) in
      var moved = 0, finished = 0
      let updated = section.withUnsafeBytes { input in
        CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
      }
      guard updated == kCCSuccess, moved <= output.count else { throw KeyFileProblem.damaged.error }
      let final = CCCryptorFinal(cryptor, output.baseAddress.map { $0 + moved }, output.count - moved, &finished)
      guard final == kCCSuccess, moved + finished == output.count else { throw KeyFileProblem.damaged.error }
    }
  }

  private func gcm(_ section: SecretBytes, tag: [UInt8], key: UnsafeRawBufferPointer,
                   iv: UnsafeRawBufferPointer) throws(SSHError) -> SecretBytes {
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: section.withUnsafeBytes { Data($0) },
                                  tag: tag)
    } catch {
      throw KeyFileProblem.damaged.error
    }
    var plain: Data
    do { plain = try AES.GCM.open(box, using: SymmetricKey(data: key)) } catch { throw SSHError.wrongPassphrase }
    defer { wipe(&plain) }
    return SecretBytes(copying: plain)
  }

  private func chachaPoly(_ section: SecretBytes, tag: [UInt8], key: UnsafeRawBufferPointer) throws(SSHError) -> SecretBytes {
    var cipher: ChaCha20
    do { cipher = try ChaCha20(key: UnsafeRawBufferPointer(rebasing: key[0..<32]), nonce: [UInt8](repeating: 0, count: 8)) } catch {
      throw KeyFileProblem.damaged.error
    }
    defer { cipher.wipe() }
    // Block 0's first 32 bytes are the Poly1305 key; the section is encrypted from block 1 on.
    var block = cipher.block(counter: 0)
    defer { wipe(&block) }
    let expected = block.withUnsafeBytes { block in
      section.withUnsafeBytes { Poly1305.authenticate($0, key: UnsafeRawBufferPointer(rebasing: block[0..<32])) }
    }
    guard Poly1305.tagsEqual(expected, tag) else { throw .wrongPassphrase }
    return SecretBytes(count: section.count) { (output: UnsafeMutableRawBufferPointer) in
      section.withUnsafeBytes { output.copyMemory(from: $0) }
      cipher.xor(output, counter: 1)
    }
  }
}
