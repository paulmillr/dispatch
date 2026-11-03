import CryptoKit
import Foundation
import Observation
import os

/// A key's private half as the transport signs with it.
enum KeyMaterial: @unchecked Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case secureEnclaveP256(SecureEnclave.P256.Signing.PrivateKey)
    /// An imported file the built-in parser could not read the private half of (RSA, ECDSA, encrypted files): the
    /// transport's parser loads it. Both are wiped when the material goes (`SecretBytes`).
    case openSSH(file: SecretBytes, passphrase: SecretBytes?)
}

/// The keys and login secrets on this phone (plan 3.6). Key records are in `keys.json`; every secret is in the
/// Keychain (`SecretVault`), `AfterFirstUnlockThisDeviceOnly` and never synced: software private keys (ED25519 and
/// imported files), their passphrases, passwords and Secure Enclave handles, so connecting, reconnecting, a watch
/// request or background refresh logs in without a prompt, also while the phone is locked. Face ID guards only Secure
/// Enclave P-256 keys, where the enclave enforces it at each signature (`keyProtection`), so they never sign
/// unattended. Software keys older builds kept behind Face ID (`biometryCurrentSet`) move once, at their first use in
/// the foreground, with one Face ID prompt for all of them (`moveFaceIDKeys`).
@MainActor @Observable
final class KeyStore {
    private struct Document: Codable {
        var version = 1
        var keys: [KeyRecord]
    }

    private(set) var keys: [KeyRecord]
    /// The last save's failure, if it failed: the keys stay in memory (their secrets are in the Keychain already) and
    /// Spaces says so with a retry.
    private(set) var saveError: String?
    /// Keys made, imported or renamed since the last save that reached the disk.
    private(set) var unsaved: Set<UUID> = []
    @ObservationIgnored let url: URL?
    @ObservationIgnored let vault: any SecretVault
    /// Whether a new Secure Enclave key asks Face ID at each signature (`.biometry`; `.none` in tests). Software keys
    /// are stored without it whatever this says.
    @ObservationIgnored let keyProtection: KeyProtection
    @ObservationIgnored let parser: any OpenSSHPrivateKeyParsing
    /// The simulator and some devices have none; New key then offers ED25519 only.
    @ObservationIgnored let secureEnclaveAvailable: Bool

    /// `keyProtection` is `.none` in tests: biometry can't be exercised on a simulator (docs/ios.md lists the
    /// device checks).
    init(url: URL? = MobileFiles.keys, vault: any SecretVault = KeychainVault(), keyProtection: KeyProtection = .biometry,
         parser: any OpenSSHPrivateKeyParsing = BuiltInOpenSSHKeyParser(),
         secureEnclaveAvailable: Bool = SecureEnclave.isAvailable) {
        self.url = url
        self.vault = vault
        self.keyProtection = keyProtection
        self.parser = parser
        self.secureEnclaveAvailable = secureEnclaveAvailable
        keys = url.flatMap { MobileFiles.read(Document.self, from: $0, version: 1)?.keys } ?? []
    }

    func key(_ id: UUID) -> KeyRecord? { keys.first { $0.id == id } }

    /// A new ED25519 key; its seed goes to the Keychain after first unlock, so it signs without a prompt.
    @discardableResult
    func generateED25519(label: String) throws -> KeyRecord {
        let key = Curve25519.Signing.PrivateKey()
        let record = KeyRecord(label: label, kind: .ed25519, blob: SSHKeyEncoding.ed25519Blob(key.publicKey))
        try vault.set(key.rawRepresentation, for: Self.privateAccount(record.id), protection: .none)
        return add(record)
    }

    /// A new P-256 key in the Secure Enclave, used with Face ID; the Keychain keeps the enclave's handle to it.
    @discardableResult
    func generateSecureEnclaveP256(label: String) throws -> KeyRecord {
        guard secureEnclaveAvailable else { throw OpenSSHKeyError.unsupported("This \(MobileDevice.name) has no Secure Enclave available.") }
        var error: Unmanaged<CFError>?
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if keyProtection == .biometry { flags.insert(.biometryCurrentSet) }
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? SecretVaultError.keychain(errSecParam)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: control)
        let record = KeyRecord(label: label, kind: .secureEnclaveP256, blob: SSHKeyEncoding.p256Blob(key.publicKey))
        // The handle is useless off this device's enclave, which enforces Face ID itself.
        try vault.set(key.dataRepresentation, for: Self.privateAccount(record.id), protection: .none)
        return add(record)
    }

    /// Imports an OpenSSH private key file. Throws `OpenSSHKeyError.passphraseRequired` for an encrypted file without
    /// `passphrase`; ask for it and call again.
    @discardableResult
    func importKey(_ file: Data, label: String?, passphrase: String? = nil) throws -> KeyRecord {
        let parsed = try parser.parse(file, passphrase: passphrase)
        if let existing = keys.first(where: { $0.blob == parsed.publicKeyBlob }) { return existing }
        let label = [label, parsed.comment].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? Self.defaultLabel(parsed.algorithm)
        let record: KeyRecord
        if let seed = parsed.ed25519Seed {
            record = KeyRecord(label: label, kind: .ed25519, blob: parsed.publicKeyBlob)
            try vault.set(seed, for: Self.privateAccount(record.id), protection: .none)
        } else {
            record = KeyRecord(label: label, kind: .imported(parsed.algorithm), blob: parsed.publicKeyBlob)
            try vault.set(file, for: Self.privateAccount(record.id), protection: .none)
            if parsed.encrypted, let passphrase {
                try vault.set(Data(passphrase.utf8), for: Self.passphraseAccount(record.id), protection: .none)
            }
        }
        return add(record)
    }

    func rename(_ id: UUID, to label: String) {
        guard let index = keys.firstIndex(where: { $0.id == id }), !label.isEmpty, keys[index].label != label else { return }
        keys[index].label = label
        save(changed: [id])
    }

    /// Removes the key and its secrets. Hosts that used it ask for another key at their next connection.
    func delete(_ id: UUID) {
        try? vault.remove(Self.privateAccount(id))
        try? vault.remove(Self.passphraseAccount(id))
        // A copy left by a move out of Face ID that was cut short: it would bring the key back at the next move.
        try? vault.remove(Self.movingPrefix + Self.privateAccount(id))
        guard keys.contains(where: { $0.id == id }) else { return }
        keys.removeAll { $0.id == id }
        unsaved.remove(id)
        save()
    }

    /// The private key for signing, read from the Keychain off the main actor without a prompt; a Secure Enclave key
    /// asks Face ID at its signature. A software key an older build kept behind Face ID is moved first, in the
    /// foreground (`moveFaceIDKeys`: one prompt for all such keys, the last one they ever ask). Not `interactive`
    /// (background refresh): a key behind Face ID fails at once (`SecretVaultError.interactionNotAllowed`).
    func material(for id: UUID, interactive: Bool = true) async throws -> KeyMaterial? {
        guard let record = key(id) else { return nil }
        let vault = vault, label = record.label
        let reason = "Unlock the key “\(label)” to connect."
        if interactive, record.kind != .secureEnclaveP256 {
            do { try await moveFaceIDKeys(reason: reason) } catch let error as SecretVaultError where error.endsTheAttempt {
                // The one prompt this connect gets was dismissed or cannot succeed: no second one for the read.
                throw error
            } catch {
                // The key is read as it is stored; a key still behind Face ID asks for it there.
                Self.log.error("Keychain: moving keys out of Face ID failed: \(error.localizedDescription)")
            }
        }
        return try await Task.detached {
            // The Keychain's buffer is copied into one the app wipes, and released here.
            guard let secret = try vault.secret(for: Self.privateAccount(id), reason: reason, interactive: interactive)
                .map(SecretBytes.init(copying:)) else {
                return nil
            }
            switch record.kind {
            case .ed25519:
                // CryptoKit keeps (and zeroes) its own copy; ours is wiped when `secret` goes.
                return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret.data))
            case .secureEnclaveP256:
                // The handle reads unattended, but the enclave would ask Face ID at the first signature, where no
                // prompt can show: refuse now, as a key behind Face ID does.
                guard interactive else { throw SecretVaultError.interactionNotAllowed }
                return .secureEnclaveP256(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret.data))
            case .imported:
                // The passphrase stays bytes (never a String) until the engine has parsed the file.
                let passphrase = try vault.secret(for: Self.passphraseAccount(id), reason: reason, interactive: interactive)
                    .map(SecretBytes.init(copying:))
                return .openSSH(file: secret, passphrase: passphrase)
            }
        }.value
    }

    func setPassword(_ password: String, for host: UUID) throws {
        try vault.set(Data(password.utf8), for: Self.passwordAccount(host), protection: .none)
    }

    func password(for host: UUID, interactive: Bool = true) async throws -> String? {
        let vault = vault
        return try await Task.detached {
            try vault.secret(for: Self.passwordAccount(host), reason: "Log in", interactive: interactive)
                .flatMap { String(data: $0, encoding: .utf8) }
        }.value
    }

    func removePassword(for host: UUID) { try? vault.remove(Self.passwordAccount(host)) }

    /// Moves the secrets older builds kept `WhenUnlockedThisDeviceOnly` without Face ID (passwords, passphrases, Secure
    /// Enclave handles, and keys where `keyProtection` is `.none`) to `KeyProtection.none`'s after-first-unlock class.
    /// Accounts are chosen by what this store wrote, never by reading an item's access control (which has no public
    /// reader): a key behind Face ID is never named, so never touched. Nothing records that it ran: listing the
    /// service's few items' attributes is cheap and a second run moves nothing. Nil without the Keychain (tests'
    /// `MemoryVault`) or when listing failed (the phone locked: the next launch tries again).
    @discardableResult
    func migrateSecrets() async -> KeychainVault.Migration? {
        guard let vault = vault as? KeychainVault else { return nil }
        let plain = Set(keys.filter { $0.kind == .secureEnclaveP256 || keyProtection == .none }.map { Self.privateAccount($0.id) })
        return await Task.detached(priority: .utility) {
            do {
                let migration = try vault.migrate { account in
                    account.hasPrefix(Self.passwordPrefix) || account.hasPrefix(Self.passphrasePrefix) || plain.contains(account)
                }
                if migration != KeychainVault.Migration() {
                    Self.log.notice("Keychain: \(migration.moved) moved to after first unlock, \(migration.failed) failed")
                }
                return migration
            } catch {
                Self.log.error("Keychain: listing for the move to after first unlock failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    /// Software keys still behind Face ID were looked for and none is left (once a launch).
    @ObservationIgnored private var faceIDKeysMoved = false
    /// The move under way: hosts connecting at the same moment wait for it, so there is one prompt, not one each.
    @ObservationIgnored private var movingFaceIDKeys: Task<Int, Error>?

    /// Moves the software keys older builds kept behind Face ID (`KeyProtection.biometry`: ED25519 and imported keys)
    /// to after first unlock, keeping their secrets: one Face ID prompt (`reason`) for all of them, then every later
    /// connect and reconnect reads them without one. Each is copied to `moving:<account>` before it is rewritten, and the
    /// copy removed after, so a move cut short loses nothing: the next run puts a missing key back from its copy. Secure
    /// Enclave handles are never touched (the enclave asks Face ID itself). Runs once a launch until nothing is left;
    /// throws `SecretVaultError.canceled` when the prompt is dismissed.
    func moveFaceIDKeys(reason: String) async throws {
        guard !faceIDKeysMoved else { return }
        if let movingFaceIDKeys {
            _ = try await movingFaceIDKeys.value
            return
        }
        let vault = vault
        let software = Set(keys.filter { $0.kind != .secureEnclaveP256 }.map { Self.privateAccount($0.id) })
        let task = Task.detached { try await Self.moveFaceIDKeys(vault, software: software, reason: reason) }
        movingFaceIDKeys = task
        defer { movingFaceIDKeys = nil }
        let moved = try await task.value
        if moved > 0 { Self.log.notice("Keychain: \(moved) keys moved out of Face ID") }
        faceIDKeysMoved = true
    }

    /// `moveFaceIDKeys`' work in `vault`: the number of keys moved.
    nonisolated static func moveFaceIDKeys(_ vault: any SecretVault, software: Set<String>, reason: String) async throws -> Int {
        let listing = try vault.listing()
        // A move cut short: a key whose rewrite did not land comes back from its copy (after first unlock, no prompt);
        // the copy of a key no longer listed is dropped.
        for (account, _) in listing where account.hasPrefix(movingPrefix) {
            let original = String(account.dropFirst(movingPrefix.count))
            if software.contains(original), listing[original] == nil,
               let copy = try vault.secret(for: account, reason: reason, interactive: false) {
                try vault.set(copy, for: original, protection: .none)
            }
            try vault.remove(account)
        }
        let behind = listing.filter { software.contains($0.key) && $0.value == .whenUnlocked }.map(\.key).sorted()
        guard !behind.isEmpty else { return 0 }
        let unlocked = try await vault.authenticated(reason: reason)
        var moved = 0
        for account in behind {
            guard let secret = try unlocked.secret(for: account, reason: reason, interactive: true) else { continue }
            try vault.set(secret, for: movingPrefix + account, protection: .none)
            try vault.set(secret, for: account, protection: .none)
            try vault.remove(movingPrefix + account)
            moved += 1
        }
        return moved
    }

    private nonisolated static let log = Logger(subsystem: "yachts.dispatch.mobile", category: "Keys")
    /// A key's copy while it moves out of Face ID (`moveFaceIDKeys`).
    nonisolated static let movingPrefix = "moving:"
    private nonisolated static let passwordPrefix = "password:"
    private nonisolated static let passphrasePrefix = "passphrase:"

    nonisolated static func privateAccount(_ id: UUID) -> String { "key:" + id.uuidString }
    nonisolated static func passphraseAccount(_ id: UUID) -> String { passphrasePrefix + id.uuidString }
    nonisolated static func passwordAccount(_ host: UUID) -> String { passwordPrefix + host.uuidString }

    nonisolated static func defaultLabel(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "id_ed25519"
        case "ssh-rsa": "id_rsa"
        case let other where other.hasPrefix("ecdsa-"): "id_ecdsa"
        default: "key"
        }
    }

    private func add(_ record: KeyRecord) -> KeyRecord {
        keys.append(record)
        save(changed: [record.id])
        added?(record)
        return record
    }

    /// Called with every key made or imported (Debug test runs authorize new keys on a fixture host with it).
    @ObservationIgnored var added: ((KeyRecord) -> Void)?

    /// Writes the list again after a failed save (the notice's Retry).
    func retrySave() { save() }

    private func save(changed: Set<UUID> = []) {
        guard let url else { return }
        do {
            try MobileFiles.write(Document(keys: keys), to: url)
            if saveError != nil { saveError = nil }
            if !unsaved.isEmpty { unsaved = [] }
        } catch {
            saveError = error.localizedDescription
            unsaved.formUnion(changed)
        }
    }
}
