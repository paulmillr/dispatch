import Foundation

/// Bytes that are a secret (a password, a keyboard-interactive answer, a shared secret, derived keys before they go
/// into CryptoKit key types, a decrypted private key's fields), in memory of their own that is zeroed (`memset_s`,
/// which the optimizer keeps) when the last reference goes. The contents never change after `init`, so a value can be
/// shared across tasks. Never printed: `description` says only the size.
///
/// What it cannot cover: copies made before the bytes got here (a `String` from a text field, the Keychain's `Data`),
/// and copies a caller makes with `withUnsafeBytes`. Prefer passing `SecretBytes` along over copying out of it.
public final class SecretBytes: @unchecked Sendable, ContiguousBytes, CustomStringConvertible {
  // Immutable after init until deinit wipes it: no data race is possible, hence @unchecked Sendable.
  private let storage: UnsafeMutableRawBufferPointer

  /// `count` bytes, written once by `initialize`. If it throws, the buffer is wiped and freed: by `deinit`, which
  /// Swift runs for an object whose stored properties were all set before the throw (freeing it here as well would
  /// free it twice).
  public init<E: Error>(count: Int, initialize: (UnsafeMutableRawBufferPointer) throws(E) -> Void) throws(E) {
    storage = .allocate(byteCount: max(0, count), alignment: 16)
    storage.initializeMemory(as: UInt8.self, repeating: 0)
    try initialize(storage)
  }

  /// A copy of `bytes`. The source is the caller's to wipe.
  public convenience init(copying bytes: some Collection<UInt8>) {
    self.init(count: bytes.count) { (buffer: UnsafeMutableRawBufferPointer) in
      _ = buffer.initializeMemory(as: UInt8.self, from: bytes)
    }
  }

  /// The UTF-8 bytes of `text`. The `String` itself cannot be wiped; use this only where the text already exists
  /// (a typed password).
  public convenience init(utf8 text: String) {
    self.init(copying: text.utf8)
  }

  deinit {
    Self.wipe(storage)
    storage.deallocate()
  }

  public var count: Int { storage.count }
  public var isEmpty: Bool { storage.isEmpty }

  /// ContiguousBytes, so CryptoKit takes it directly (`SymmetricKey(data:)`). The pointer must not escape `body`.
  public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try body(UnsafeRawBufferPointer(storage))
  }

  public var description: String { "SecretBytes(\(count) bytes)" }

  /// Zeroes `buffer` in a way the optimizer keeps.
  public static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
    guard let base = buffer.baseAddress, buffer.count > 0 else { return }
    _ = memset_s(base, buffer.count, 0, buffer.count)
  }
}

/// Zeroes an array's bytes in place (a plaintext packet, a decrypted block, a derived key) in a way the optimizer
/// keeps. The array's own storage: call it where the array is uniquely referenced.
func wipeBytes(_ bytes: inout [UInt8]) {
  bytes.withUnsafeMutableBytes { SecretBytes.wipe($0) }
}

func wipeBytes(_ data: inout Data) {
  data.withUnsafeMutableBytes { SecretBytes.wipe($0) }
}
