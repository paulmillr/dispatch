import Foundation

/// A secret read from the Keychain (a key file, a passphrase) in a buffer of the app's own, overwritten with zeros
/// (`memset_s`) when the last reference goes. The Keychain's returned buffer is copied once and released at once;
/// pass `data` on without mutating it, so the bytes stay in this one buffer (docs/security.md, iPhone).
final class SecretBytes: @unchecked Sendable {
    private var storage: Data
    private let lock = NSLock()

    /// Copies `data` into a buffer only this object holds.
    init(copying data: Data) {
        var owned = Data(count: data.count)
        owned.withUnsafeMutableBytes { target in data.withUnsafeBytes { target.copyMemory(from: $0) } }
        storage = owned
    }

    /// The bytes, sharing this buffer (a `Data` value that is not mutated never copies them).
    var data: Data { lock.withLock { storage } }

    /// Overwrites the bytes with zeros now (they read as zeros afterwards).
    func wipe() {
        lock.withLock {
            storage.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress, bytes.count > 0 else { return }
                _ = memset_s(base, bytes.count, 0, bytes.count)
            }
        }
    }

    deinit { wipe() }
}
