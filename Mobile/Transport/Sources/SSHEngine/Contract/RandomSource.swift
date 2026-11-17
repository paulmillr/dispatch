import Security

/// Where the sans-I/O core gets random bytes: packet padding, the KEXINIT cookie, ephemeral key exchange keys
/// (CryptoKit keys made from these bytes with `rawRepresentation` / seed initializers). Injected so tests are
/// deterministic; the app uses `SystemRandom`. Owned by one core, like the rest of its state.
public protocol RandomSource: AnyObject {
  /// Fills `buffer` completely, or throws: never returns partly filled or predictable bytes.
  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(SSHError)
}

extension RandomSource {
  /// `count` random bytes.
  public func bytes(_ count: Int) throws(SSHError) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: max(0, count))
    // withUnsafeMutableBytes rethrows untyped: carry the typed error out by hand.
    var failure: SSHError?
    result.withUnsafeMutableBytes { buffer in
      do throws(SSHError) { try fill(buffer) } catch { failure = error }
    }
    if let failure { throw failure }
    return result
  }

  /// `count` random bytes in wiped memory (an ephemeral private key's seed).
  public func secret(_ count: Int) throws(SSHError) -> SecretBytes {
    try SecretBytes(count: count) { (buffer: UnsafeMutableRawBufferPointer) throws(SSHError) in try fill(buffer) }
  }
}

/// The system's cryptographically secure generator (`SecRandomCopyBytes`).
public final class SystemRandom: RandomSource {
  public init() {}

  public func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(SSHError) {
    guard let base = buffer.baseAddress, buffer.count > 0 else { return }
    guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, base) == errSecSuccess else {
      SecretBytes.wipe(buffer)
      throw .unsupported("the system random number generator failed")
    }
  }
}
