import Foundation
import LocalAuthentication
import Security
import Synchronization

/// How a secret is guarded beyond the device being unlocked.
enum KeyProtection: Sendable, Equatable {
    /// Face ID (or the passcode's biometry set) unlocks each use: private keys on a device.
    case biometry
    /// Only `WhenUnlockedThisDeviceOnly`: passwords and passphrases, and every secret in tests (the simulator has
    /// no enrolled Face ID, so a biometry item cannot be read back there).
    case none

    /// The Keychain access control for this protection, never migrating to another device or a backup.
    func accessControl(privateKeyUsage: Bool = false) -> SecAccessControl? {
        var flags: SecAccessControlCreateFlags = privateKeyUsage ? [.privateKeyUsage] : []
        if self == .biometry { flags.insert(.biometryCurrentSet) }
        return SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil)
    }
}

enum SecretVaultError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case canceled
    /// The item needs Face ID, and the read was made where no prompt may show (background refresh).
    case interactionNotAllowed

    var errorDescription: String? {
        switch self {
        case .canceled: "Unlocking was canceled."
        case .interactionNotAllowed: "This key needs Face ID, which can't be asked for in the background."
        case .keychain(let status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }
}

/// Secrets by account name: private key material, passwords, passphrases. `KeychainVault` on the phone,
/// `MemoryVault` in tests and previews.
protocol SecretVault: Sendable {
    func set(_ secret: Data, for account: String, protection: KeyProtection) throws
    /// `reason` is what Face ID says when the item needs it. Blocks while the user authenticates: call it off the
    /// main actor. Not `interactive` (background refresh): an item behind Face ID fails at once
    /// (`SecretVaultError.interactionNotAllowed`) instead of attempting a prompt.
    func secret(for account: String, reason: String, interactive: Bool) throws -> Data?
    func remove(_ account: String) throws
    /// Every secret of this vault (Settings' Remove all data).
    func removeAll() throws
}

extension SecretVault {
    func secret(for account: String, reason: String) throws -> Data? {
        try secret(for: account, reason: reason, interactive: true)
    }
}

/// Generic passwords in the app's Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable.
struct KeychainVault: SecretVault {
    let service: String

    init(service: String = "yachts.dispatch.mobile.secrets") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func set(_ secret: Data, for account: String, protection: KeyProtection) throws {
        try remove(account)
        var item = query(account)
        item[kSecValueData as String] = secret
        if let control = protection.accessControl() {
            item[kSecAttrAccessControl as String] = control
        } else {
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretVaultError.keychain(status) }
    }

    func secret(for account: String, reason: String, interactive: Bool) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.localizedReason = reason
        // In the background no prompt can show: a Face ID item fails at once rather than waiting on one.
        context.interactionNotAllowed = !interactive
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled: throw SecretVaultError.canceled
        case errSecInteractionNotAllowed: throw SecretVaultError.interactionNotAllowed
        default: throw SecretVaultError.keychain(status)
        }
    }

    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretVaultError.keychain(status) }
    }

    func removeAll() throws {
        let all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrSynchronizable as String: false]
        let status = SecItemDelete(all as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretVaultError.keychain(status) }
    }
}

/// Secrets in memory, remembering each one's protection for tests.
final class MemoryVault: SecretVault {
    private let items = Mutex<[String: (Data, KeyProtection)]>([:])

    func set(_ secret: Data, for account: String, protection: KeyProtection) throws {
        items.withLock { $0[account] = (secret, protection) }
    }

    /// Like the Keychain: an item stored behind Face ID fails a read that may not prompt.
    func secret(for account: String, reason: String, interactive: Bool) throws -> Data? {
        try items.withLock { items in
            guard let (secret, protection) = items[account] else { return nil }
            if !interactive, protection == .biometry { throw SecretVaultError.interactionNotAllowed }
            return secret
        }
    }

    func protection(of account: String) -> KeyProtection? { items.withLock { $0[account]?.1 } }

    var accounts: Set<String> { items.withLock { Set($0.keys) } }

    func remove(_ account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }

    func removeAll() throws { items.withLock { $0.removeAll() } }
}
