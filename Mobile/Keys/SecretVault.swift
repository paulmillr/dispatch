import Foundation
import LocalAuthentication
import Security
import Synchronization

/// How a secret is guarded. Neither class ever leaves this device or reaches a backup (`ThisDeviceOnly`).
enum KeyProtection: Sendable, Equatable {
    /// `WhenUnlockedThisDeviceOnly` behind `biometryCurrentSet`: Face ID unlocks each use, never with the phone locked
    /// or unattended. Private keys on a device.
    case biometry
    /// `AfterFirstUnlockThisDeviceOnly`: readable once the phone was unlocked since it started, also while it is locked,
    /// so a watch request or background refresh can log in with a password (docs/security.md, Dispatch for iPhone).
    /// Passwords, passphrases, Secure Enclave handles (the enclave's own access control asks Face ID), and every secret
    /// in tests (the simulator has no enrolled Face ID, so a biometry item cannot be read back there).
    case none

    /// The Keychain class.
    var accessible: CFString {
        self == .biometry ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    /// The Keychain access control for this protection.
    func accessControl(privateKeyUsage: Bool = false) -> SecAccessControl? {
        var flags: SecAccessControlCreateFlags = privateKeyUsage ? [.privateKeyUsage] : []
        if self == .biometry { flags.insert(.biometryCurrentSet) }
        return SecAccessControlCreateWithFlags(nil, accessible, flags, nil)
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
    /// Every secret but the accounts `keeping` accepts (Settings' Remove all data except SSH keys).
    func removeAll(keeping: (String) -> Bool) throws
}

extension SecretVault {
    func secret(for account: String, reason: String) throws -> Data? {
        try secret(for: account, reason: reason, interactive: true)
    }
}

/// Generic passwords in the app's Keychain, not synchronizable, of `KeyProtection.accessible`'s class:
/// `WhenUnlockedThisDeviceOnly` behind Face ID, else `AfterFirstUnlockThisDeviceOnly`.
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
            item[kSecAttrAccessible as String] = protection.accessible
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

    func removeAll(keeping: (String) -> Bool) throws {
        // Attributes only: listing never reads a secret, so no item behind Face ID prompts.
        var request: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecAttrSynchronizable as String: false]
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretVaultError.keychain(status) }
        let accounts = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        for account in accounts where !keeping(account) { try remove(account) }
    }

    /// What `migrate` did: items moved to after first unlock, items left as they were though `moving` named them.
    struct Migration: Equatable, Sendable {
        var moved = 0
        var failed = 0
    }

    /// Moves the items `moving` names from `WhenUnlockedThisDeviceOnly` (builds before passwords became readable while
    /// the phone is locked) to `KeyProtection.none`'s class, keeping their secret. Attributes only: no secret is read,
    /// so nothing prompts. Items already moved, and every item `moving` does not name, are left alone; nothing is
    /// deleted. Run while the phone is unlocked: a when-unlocked item cannot be listed or changed while it is locked.
    func migrate(moving: (String) -> Bool) throws -> Migration {
        var request: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecAttrSynchronizable as String: false]
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretVaultError.keychain(status) }
        let old = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        var migration = Migration()
        for attributes in result as? [[String: Any]] ?? [] {
            guard let account = attributes[kSecAttrAccount as String] as? String, moving(account),
                  attributes[kSecAttrAccessible as String] as? String == old,
                  let control = KeyProtection.none.accessControl() else { continue }
            let update = [kSecAttrAccessControl as String: control] as CFDictionary
            if SecItemUpdate(query(account) as CFDictionary, update) == errSecSuccess {
                migration.moved += 1
            } else {
                migration.failed += 1
            }
        }
        return migration
    }
}

/// Secrets in memory, remembering each one's protection for tests.
final class MemoryVault: SecretVault {
    private let items = Mutex<[String: (Data, KeyProtection)]>([:])
    private let lock = Mutex(false)

    /// The phone is locked: as the Keychain's classes go, a `.none` item (after first unlock) still reads, a
    /// `.biometry` one (when unlocked) does not.
    var locked: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    func set(_ secret: Data, for account: String, protection: KeyProtection) throws {
        items.withLock { $0[account] = (secret, protection) }
    }

    /// Like the Keychain: an item stored behind Face ID fails a read that may not prompt, or any read while locked.
    func secret(for account: String, reason: String, interactive: Bool) throws -> Data? {
        let locked = locked
        return try items.withLock { items in
            guard let (secret, protection) = items[account] else { return nil }
            if !interactive || locked, protection == .biometry { throw SecretVaultError.interactionNotAllowed }
            return secret
        }
    }

    func protection(of account: String) -> KeyProtection? { items.withLock { $0[account]?.1 } }

    var accounts: Set<String> { items.withLock { Set($0.keys) } }

    func remove(_ account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }

    func removeAll() throws { items.withLock { $0.removeAll() } }

    func removeAll(keeping: (String) -> Bool) throws { items.withLock { $0 = $0.filter { keeping($0.key) } } }
}
