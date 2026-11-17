/// The algorithms the engine implements, by wire name. Nothing else is ever offered or accepted: no finite-field
/// Diffie-Hellman, no `ssh-rsa` (SHA-1) signatures, no DSA, no certificates, no CBC, no SHA-1 MACs, no compression.
/// The order offered is `AlgorithmPolicy`'s.

/// Key exchange methods. Each hashes with SHA-256 except the NIST curves above P-256.
public enum KeyExchangeAlgorithm: String, Sendable, Hashable, CaseIterable {
  /// ML-KEM-768 with X25519 (draft-ietf-sshm-mlkem-hybrid-kex). CryptoKit's ML-KEM needs iOS 26 / macOS 26.
  case mlkem768x25519 = "mlkem768x25519-sha256"
  case curve25519 = "curve25519-sha256"
  /// The same method under its pre-RFC 8731 name.
  case curve25519LibSSH = "curve25519-sha256@libssh.org"
  case ecdhP256 = "ecdh-sha2-nistp256"
  case ecdhP384 = "ecdh-sha2-nistp384"
  case ecdhP521 = "ecdh-sha2-nistp521"

  /// The exchange hash and key derivation hash (RFC 5656 §6.2.1, RFC 8731 §3).
  public var hash: HashAlgorithm {
    switch self {
    case .mlkem768x25519, .curve25519, .curve25519LibSSH, .ecdhP256: .sha256
    case .ecdhP384: .sha384
    case .ecdhP521: .sha512
    }
  }
}

public enum HashAlgorithm: Sendable, Hashable {
  case sha256, sha384, sha512

  public var digestBytes: Int {
    switch self {
    case .sha256: 32
    case .sha384: 48
    case .sha512: 64
    }
  }
}

/// Signature algorithms, for host keys (the KEXINIT host key list) and user keys alike. The name is what KEXINIT,
/// a signature blob and a publickey USERAUTH_REQUEST carry; `keyType` is the blob's type (RSA's is `ssh-rsa`).
public enum SignatureAlgorithm: String, Sendable, Hashable, CaseIterable {
  case ed25519 = "ssh-ed25519"
  case ecdsaP256 = "ecdsa-sha2-nistp256"
  case ecdsaP384 = "ecdsa-sha2-nistp384"
  case ecdsaP521 = "ecdsa-sha2-nistp521"
  case rsaSHA512 = "rsa-sha2-512"
  case rsaSHA256 = "rsa-sha2-256"

  /// The type name of the public key blob this algorithm signs with.
  public var keyType: String {
    switch self {
    case .ed25519: "ssh-ed25519"
    case .ecdsaP256: ECDSACurve.p256.keyType
    case .ecdsaP384: ECDSACurve.p384.keyType
    case .ecdsaP521: ECDSACurve.p521.keyType
    case .rsaSHA512, .rsaSHA256: "ssh-rsa"
    }
  }

  /// The algorithms that sign with keys of `blob`'s type: an RSA key has two (SHA-512 first), others one.
  public static func algorithms(for blob: PublicKeyBlob) -> [SignatureAlgorithm] {
    allCases.filter { $0.keyType == blob.keyType }
  }
}

/// Ciphers. The three families protect the packet length differently (`PacketOpener`): AES-GCM authenticates it in
/// the clear as associated data; ChaCha20-Poly1305 encrypts it under a key of its own; AES-CTR encrypts it with the
/// packet (encrypt-and-MAC) or leaves it in the clear inside the MAC (`-etm` MACs).
public enum CipherAlgorithm: String, Sendable, Hashable, CaseIterable {
  case aes256GCM = "aes256-gcm@openssh.com"
  case aes128GCM = "aes128-gcm@openssh.com"
  case chacha20Poly1305 = "chacha20-poly1305@openssh.com"
  case aes256CTR = "aes256-ctr"
  case aes192CTR = "aes192-ctr"
  case aes128CTR = "aes128-ctr"

  /// An AEAD cipher carries its own tag: the MAC list is not negotiated for it (as OpenSSH does).
  public var isAEAD: Bool {
    switch self {
    case .aes256GCM, .aes128GCM, .chacha20Poly1305: true
    case .aes256CTR, .aes192CTR, .aes128CTR: false
    }
  }

  public var isAESGCM: Bool { self == .aes256GCM || self == .aes128GCM }

  /// Key bytes derived for the cipher (ChaCha20-Poly1305: two 32-byte keys, the length key second).
  public var keyBytes: Int {
    switch self {
    case .aes256GCM, .aes256CTR: 32
    case .aes192CTR: 24
    case .aes128GCM, .aes128CTR: 16
    case .chacha20Poly1305: 64
    }
  }

  /// IV bytes derived for the cipher (GCM: the 12-byte nonce; CTR: the 16-byte counter block; ChaCha: none, the
  /// sequence number is the nonce).
  public var ivBytes: Int {
    switch self {
    case .aes256GCM, .aes128GCM: 12
    case .aes256CTR, .aes192CTR, .aes128CTR: 16
    case .chacha20Poly1305: 0
    }
  }

  /// The alignment of a packet (RFC 4253 §6: at least 8).
  public var blockBytes: Int { self == .chacha20Poly1305 ? 8 : 16 }

  /// The AEAD tag; 0 for CTR (its MAC's length applies).
  public var tagBytes: Int { isAEAD ? 16 : 0 }
}

/// MACs, for the CTR ciphers only.
public enum MACAlgorithm: String, Sendable, Hashable, CaseIterable {
  case hmacSHA256ETM = "hmac-sha2-256-etm@openssh.com"
  case hmacSHA512ETM = "hmac-sha2-512-etm@openssh.com"
  case hmacSHA256 = "hmac-sha2-256"
  case hmacSHA512 = "hmac-sha2-512"

  /// Encrypt-then-MAC: the length stays in the clear and the MAC covers the ciphertext.
  public var isEncryptThenMAC: Bool { self == .hmacSHA256ETM || self == .hmacSHA512ETM }
  /// Key bytes and tag bytes (RFC 6668: the full digest).
  public var keyBytes: Int { tagBytes }
  public var tagBytes: Int { self == .hmacSHA256ETM || self == .hmacSHA256 ? 32 : 64 }
}

/// Pseudo-algorithms in the KEXINIT key exchange list: signals, never negotiated as a method.
public enum KexSignal {
  /// The client takes EXT_INFO (RFC 8308).
  public static let extInfoClient = "ext-info-c"
  /// The server sends EXT_INFO.
  public static let extInfoServer = "ext-info-s"
  /// Strict key exchange (OpenSSH PROTOCOL, the Terrapin countermeasure).
  public static let strictClient = "kex-strict-c-v00@openssh.com"
  public static let strictServer = "kex-strict-s-v00@openssh.com"
}

/// What a key exchange settled on, for one direction pair. `mac` is nil for an AEAD cipher.
public struct NegotiatedAlgorithms: Sendable, Hashable {
  public var keyExchange: KeyExchangeAlgorithm
  public var hostKey: SignatureAlgorithm
  public var clientToServer: Direction
  public var serverToClient: Direction
  /// Both KEXINITs carried the strict key exchange signal.
  public var strictKex: Bool
  /// The server's KEXINIT carried `ext-info-s`.
  public var serverSendsExtInfo: Bool

  public struct Direction: Sendable, Hashable {
    public var cipher: CipherAlgorithm
    public var mac: MACAlgorithm?

    public init(cipher: CipherAlgorithm, mac: MACAlgorithm?) {
      self.cipher = cipher
      self.mac = mac
    }
  }

  public init(keyExchange: KeyExchangeAlgorithm, hostKey: SignatureAlgorithm, clientToServer: Direction,
              serverToClient: Direction, strictKex: Bool, serverSendsExtInfo: Bool) {
    self.keyExchange = keyExchange
    self.hostKey = hostKey
    self.clientToServer = clientToServer
    self.serverToClient = serverToClient
    self.strictKex = strictKex
    self.serverSendsExtInfo = serverSendsExtInfo
  }
}
