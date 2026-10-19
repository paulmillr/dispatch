import CryptoKit
import XCTest
@testable import DispatchMobile

/// Key encodings against OpenSSH's own output: the vectors below were made with `ssh-keygen` (OpenSSH 10) and its
/// `ssh-keygen -l` fingerprints, plus RFC 8032's first Ed25519 test vector.
@MainActor
final class KeyStoreTests: XCTestCase {
    static let ed25519File = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACAj+Gf1IL3tFrgavF5xeU+nqdBgNYbTsASg2hBXL+UqHwAAAJhu0vrYbtL6
    2AAAAAtzc2gtZWQyNTUxOQAAACAj+Gf1IL3tFrgavF5xeU+nqdBgNYbTsASg2hBXL+UqHw
    AAAEBo03pLWHLr7Q0NakzhHyJt5ZtxIkmC3GfCPHwrtco+uiP4Z/Ugve0WuBq8XnF5T6ep
    0GA1htOwBKDaEFcv5SofAAAAD3ZlY3RvckBkaXNwYXRjaAECAwQFBg==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICP4Z/Ugve0WuBq8XnF5T6ep0GA1htOwBKDaEFcv5Sof vector@dispatch"
    static let ed25519Fingerprint = "SHA256:Fiiqmo23qQblDYq0AXfrYrqyjfHSB5vxJVpKj/stiYc"

    /// Passphrase "secret", aes256-ctr with bcrypt.
    static let encryptedFile = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABB+NVZ6P5
    +4v1UxWacpUTlSAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIJKT1Y1vehTH5xWg
    gf8pR3L7Lv0wxybgWLDOw0o60M/cAAAAkNR2N6AnR1tWkN2EOFgHshEXRtGHGleWCiqgcT
    PzP7u/VQG9hpq9lWCEfbKOrcYcQMWRbWnt1osOC1ILp9Fz8EcZMvBy8wDRPvDWIqyd3AzU
    SvQ2epGvKZrUNcHf9qZ48Sz36xdQLTCmhTo8Ikp922/ZphbB6WQ0TS7fyy5HqKN9QeF9zM
    qws3YZ+OefY/vGsQ==
    -----END OPENSSH PRIVATE KEY-----
    """
    static let encryptedFingerprint = "SHA256:L36MZZrFRHqSAdAeDc0OgIy00UonFSkBHu6+YiV8JA8"

    static let ecdsaFile = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRrWxS7vE3owJb6QFz3kuUF+FBkB77k
    QPgZK6XSM6ut96nz0xiSxs6RqR50U2WCHE0t9WN2x+WJHnyTf8Ice9OuAAAAoC4tCg0uLQ
    oNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGtbFLu8TejAlvpA
    XPeS5QX4UGQHvuRA+BkrpdIzq633qfPTGJLGzpGpHnRTZYIcTS31Y3bH5YkefJN/whx706
    4AAAAhAJkHxyI/cUv8mOVK8D/cjuG2horY0l/TGeWbtYnoWpe4AAAABHAyNTYBAgM=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let ecdsaFingerprint = "SHA256:qnWiqCp0vAWwJMWPcR2oBXswozb+OQRwZCDUAw3Hk2A"

    static let rsaPublic = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLSQwXoi1c3Ro9y3nHT0uJeocx/3XzLdO4BAGK/TGI1xhcUg9RdYoDr1j74mkJbP4Rue4FQ4T7eN1XY03W2hEvn9+aXprmuVofbiXcgr4/Dt9snD+1SI15jliAs1sWWomr3kUf+mFU+X0Q7v4/eIxBINkOCmrURvMMaa+8EBNY8duFz7mnMBV+JS6KQh5+fbOrPr/R+s8M9VzfD/8CyhcRO2q//OB25yGR4yPeTOwqG89tsLVTvlNmGTdZYBw9AlqeecyA/A5/McqZtSYiyrG8JCyfvt9abLNYvFpoM4qmo+TDmCBP89PIxl+8TIqujv18pkjYIXijbt63/tOPLKxDmub+R/lFAOctBBJqk+h7erSJ1mYzG06YP4RfzUGbylQMoQxHX4o5OMuH85cd4R9anHMsr5mfTf3xRVS2CdLH+WVXGk6ZRI1o1XMHlQlGF/URTSvzi9FCuZSiwo83bXVjmib3Uv4gYi4pIr58YjOYfpSqUpDjN8Ea6SxFp9SKbCE= rsa"
    static let rsaFingerprint = "SHA256:+dBD/IitJqniva8qv6VtwU11GIYsTZJgIFsPF6LOOIo"

    static let p256Public = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCgIZmoThJemKLs+SRh00p48kOju0R22mx21rxmrTMFSGtDn4/Gz3iKeRngRwDSKwJS3kzUsAzcaP2ccPPK2t+Q= p256"
    static let p256Fingerprint = "SHA256:RqjWAH3Y3E86PO87vHF3JAzt3VVuP6QphVDYJsjRSWE"

    private func hex(_ text: String) -> Data {
        Data(stride(from: 0, to: text.count, by: 2).map {
            UInt8(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }

    private func store(_ vault: MemoryVault = MemoryVault()) -> KeyStore {
        KeyStore(url: nil, vault: vault, keyProtection: .none, secureEnclaveAvailable: false)
    }

    func testFingerprintsMatchSSHKeygen() throws {
        for (line, fingerprint, type) in [(Self.ed25519Public, Self.ed25519Fingerprint, "ED25519"),
                                          (Self.rsaPublic, Self.rsaFingerprint, "RSA 3072"),
                                          (Self.p256Public, Self.p256Fingerprint, "ECDSA P-256")] {
            let blob = try XCTUnwrap(SSHKeyEncoding.blob(authorizedKey: line))
            XCTAssertEqual(SSHKeyEncoding.fingerprint(blob), fingerprint)
            XCTAssertFalse(SSHKeyEncoding.fingerprint(blob).hasSuffix("="), "OpenSSH drops the base64 padding")
            XCTAssertEqual(SSHKeyEncoding.typeLabel(blob), type)
        }
        XCTAssertNil(SSHKeyEncoding.blob(authorizedKey: "ssh-rsa " + Self.ed25519Public.split(separator: " ")[1]),
                     "The named algorithm must be the blob's")
    }

    /// RFC 8032 7.1 test 1: the seed derives the public key, and the blob is OpenSSH's `ssh-ed25519` form.
    func testEd25519EncodingFromTheRFCVector() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        XCTAssertEqual(key.publicKey.rawRepresentation, hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
        let blob = SSHKeyEncoding.ed25519Blob(key.publicKey)
        XCTAssertEqual(blob, hex("0000000b7373682d65643235353139" + "00000020" + "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
        let line = try XCTUnwrap(SSHKeyEncoding.authorizedKey(blob, comment: "phone"))
        XCTAssertEqual(line, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea phone")
    }

    /// The P-256 blob a Secure Enclave key is presented with: re-encoding OpenSSH's key gives OpenSSH's bytes.
    func testP256EncodingMatchesOpenSSH() throws {
        let blob = try XCTUnwrap(SSHKeyEncoding.blob(authorizedKey: Self.p256Public))
        let point = blob.suffix(65)
        let key = try P256.Signing.PublicKey(x963Representation: point)
        XCTAssertEqual(SSHKeyEncoding.p256Blob(key), blob)
    }

    func testBuiltInParserReadsAnUnencryptedEd25519File() throws {
        let parsed = try BuiltInOpenSSHKeyParser().parse(Data(Self.ed25519File.utf8), passphrase: nil)
        XCTAssertEqual(parsed.algorithm, "ssh-ed25519")
        XCTAssertEqual(parsed.comment, "vector@dispatch")
        XCTAssertEqual(SSHKeyEncoding.fingerprint(parsed.publicKeyBlob), Self.ed25519Fingerprint)
        let seed = try XCTUnwrap(parsed.ed25519Seed)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        XCTAssertEqual(SSHKeyEncoding.ed25519Blob(key.publicKey), parsed.publicKeyBlob)
        // Pasted text with CRLF and indentation reads the same.
        let pasted = "  " + Self.ed25519File.replacingOccurrences(of: "\n", with: "\r\n  ") + "\r\n"
        XCTAssertEqual(try BuiltInOpenSSHKeyParser().parse(Data(pasted.utf8), passphrase: nil), parsed)
    }

    func testBuiltInParserAsksForAPassphraseAndReadsOtherKeysPublicHalf() throws {
        let parser = BuiltInOpenSSHKeyParser()
        XCTAssertThrowsError(try parser.parse(Data(Self.encryptedFile.utf8), passphrase: nil)) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .passphraseRequired)
        }
        let encrypted = try parser.parse(Data(Self.encryptedFile.utf8), passphrase: "secret")
        XCTAssertTrue(encrypted.encrypted)
        XCTAssertFalse(encrypted.passphraseVerified)
        XCTAssertNil(encrypted.ed25519Seed)
        XCTAssertEqual(SSHKeyEncoding.fingerprint(encrypted.publicKeyBlob), Self.encryptedFingerprint)

        let ecdsa = try parser.parse(Data(Self.ecdsaFile.utf8), passphrase: nil)
        XCTAssertEqual(ecdsa.algorithm, "ecdsa-sha2-nistp256")
        XCTAssertNil(ecdsa.ed25519Seed)
        XCTAssertEqual(SSHKeyEncoding.fingerprint(ecdsa.publicKeyBlob), Self.ecdsaFingerprint)
    }

    func testBuiltInParserRefusesOtherFiles() {
        let parser = BuiltInOpenSSHKeyParser()
        XCTAssertThrowsError(try parser.parse(Data(Self.ed25519Public.utf8), passphrase: nil)) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .notOpenSSH)
        }
        XCTAssertThrowsError(try parser.parse(Data("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----".utf8),
                                              passphrase: nil)) {
            guard case .unsupported = $0 as? OpenSSHKeyError else { return XCTFail("\($0)") }
        }
        var damaged = Self.ed25519File
        damaged.replace("AAAAD3ZlY3Rvck", with: "AAAAD3ZlY3RvcL")
        XCTAssertThrowsError(try parser.parse(Data(damaged.utf8), passphrase: nil))
    }

    func testGeneratedEd25519KeyKeepsItsSeedInTheVault() async throws {
        let vault = MemoryVault()
        let keys = store(vault)
        let record = try keys.generateED25519(label: "iphone")
        XCTAssertEqual(record.kind, .ed25519)
        XCTAssertTrue(record.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(record.publicKey.hasSuffix(" iphone"))
        XCTAssertEqual(record.fingerprint, SSHKeyEncoding.fingerprint(try XCTUnwrap(record.blob)))
        XCTAssertEqual(record.typeLabel, "ED25519")
        XCTAssertEqual(vault.protection(of: KeyStore.privateAccount(record.id)), KeyProtection.none)
        guard case .ed25519(let key)? = try await keys.material(for: record.id) else { return XCTFail("No key") }
        XCTAssertEqual(SSHKeyEncoding.ed25519Blob(key.publicKey), record.blob)
        let signature = try key.signature(for: Data("challenge".utf8))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data("challenge".utf8)))

        keys.delete(record.id)
        XCTAssertTrue(keys.keys.isEmpty)
        XCTAssertTrue(vault.accounts.isEmpty)
    }

    /// The app's store puts private keys behind biometry; tests inject none (the simulator has no Face ID).
    func testPrivateKeysUseTheInjectedProtection() throws {
        let vault = MemoryVault()
        let keys = KeyStore(url: nil, vault: vault, keyProtection: .biometry, secureEnclaveAvailable: false)
        let record = try keys.generateED25519(label: "phone")
        XCTAssertEqual(vault.protection(of: KeyStore.privateAccount(record.id)), .biometry)
        try keys.setPassword("hunter2", for: UUID())
        XCTAssertEqual(vault.accounts.filter { $0.hasPrefix("password:") }.compactMap(vault.protection), [KeyProtection.none],
                       "Passwords are not behind Face ID")
        XCTAssertThrowsError(try keys.generateSecureEnclaveP256(label: "se"), "No enclave: no enclave key")
    }

    func testImportKeepsEd25519SeedsAndOtherFilesWithTheirPassphrase() async throws {
        let vault = MemoryVault()
        let keys = store(vault)
        let ed25519 = try keys.importKey(Data(Self.ed25519File.utf8), label: nil)
        XCTAssertEqual(ed25519.label, "vector@dispatch")
        XCTAssertEqual(ed25519.kind, .ed25519)
        XCTAssertEqual(ed25519.fingerprint, Self.ed25519Fingerprint)
        XCTAssertEqual(ed25519.publicKey, Self.ed25519Public)
        XCTAssertEqual(try keys.importKey(Data(Self.ed25519File.utf8), label: "again"), ed25519, "The same key twice is one key")

        XCTAssertThrowsError(try keys.importKey(Data(Self.encryptedFile.utf8), label: "work")) {
            XCTAssertEqual($0 as? OpenSSHKeyError, .passphraseRequired)
        }
        let encrypted = try keys.importKey(Data(Self.encryptedFile.utf8), label: "work", passphrase: "secret")
        XCTAssertEqual(encrypted.kind, .imported("ssh-ed25519"))
        XCTAssertEqual(encrypted.fingerprint, Self.encryptedFingerprint)
        guard case .openSSH(let file, let passphrase)? = try await keys.material(for: encrypted.id) else { return XCTFail() }
        XCTAssertEqual(file.data, Data(Self.encryptedFile.utf8))
        XCTAssertEqual(passphrase?.data, Data("secret".utf8), "bytes, never a String")
        // The driver wipes both once the engine has parsed the key.
        file.wipe()
        passphrase?.wipe()
        XCTAssertTrue(file.data.allSatisfy { $0 == 0 })
        XCTAssertEqual(file.data.count, Self.encryptedFile.utf8.count)
        XCTAssertEqual(passphrase?.data, Data(count: 6))

        let ecdsa = try keys.importKey(Data(Self.ecdsaFile.utf8), label: "")
        XCTAssertEqual(ecdsa.label, "id_ecdsa")
        XCTAssertEqual(ecdsa.typeLabel, "ECDSA P-256")
        XCTAssertEqual(keys.keys.map(\.id), [ed25519.id, encrypted.id, ecdsa.id])
    }

    /// A secret read from the Keychain lives in one buffer of the app's own: a `Data` passed on shares it (no copy of
    /// the bytes), and wiping zeroes that buffer.
    func testSecretBytesOwnOneBufferAndWipeIt() {
        // Larger than Data's inline storage (a key file is), so the buffer is on the heap and can be compared.
        let source = Data(repeating: 0x2a, count: 256)
        let secret = SecretBytes(copying: source)
        let shared = secret.data
        let address = { (data: Data) in data.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } }
        XCTAssertEqual(address(shared), address(secret.data), "passed on without copying the bytes")
        XCTAssertNotEqual(address(source), address(secret.data), "not the Keychain's buffer")
        secret.wipe()
        XCTAssertEqual(secret.data, Data(count: source.count))
        XCTAssertEqual(source, Data(repeating: 0x2a, count: 256), "the source is the caller's")
    }

    func testKeyRecordsRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyStoreTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("keys.json")
        let vault = MemoryVault()
        let keys = KeyStore(url: url, vault: vault, keyProtection: .none, secureEnclaveAvailable: false)
        try keys.generateED25519(label: "one")
        try keys.importKey(Data(Self.ecdsaFile.utf8), label: "two")
        keys.rename(keys.keys[0].id, to: "uno")
        XCTAssertEqual(KeyStore(url: url, vault: vault, keyProtection: .none, secureEnclaveAvailable: false).keys, keys.keys)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE"), "Key records never hold private keys")
    }

    /// The real Keychain on the simulator, without biometry: set, read, replace, remove.
    func testKeychainVaultRoundTrip() throws {
        let vault = KeychainVault(service: "yachts.dispatch.mobile.tests." + UUID().uuidString)
        defer { try? vault.remove("password:test") }
        XCTAssertNil(try vault.secret(for: "password:test", reason: "test"))
        try vault.set(Data("one".utf8), for: "password:test", protection: .none)
        try vault.set(Data("two".utf8), for: "password:test", protection: .none)
        XCTAssertEqual(try vault.secret(for: "password:test", reason: "test"), Data("two".utf8))
        try vault.remove("password:test")
        XCTAssertNil(try vault.secret(for: "password:test", reason: "test"))
    }

    /// Where the simulator offers a Secure Enclave, its key is presented as `ecdsa-sha2-nistp256` and signs.
    func testSecureEnclaveKeyWhenAvailable() async throws {
        try XCTSkipUnless(SecureEnclave.isAvailable, "No Secure Enclave on this simulator")
        let keys = KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none)
        let record = try keys.generateSecureEnclaveP256(label: "enclave")
        XCTAssertEqual(record.typeLabel, "ECDSA P-256")
        XCTAssertTrue(record.publicKey.hasPrefix("ecdsa-sha2-nistp256 "))
        guard case .secureEnclaveP256(let key)? = try await keys.material(for: record.id) else { return XCTFail() }
        XCTAssertEqual(SSHKeyEncoding.p256Blob(key.publicKey), record.blob)
    }
}
