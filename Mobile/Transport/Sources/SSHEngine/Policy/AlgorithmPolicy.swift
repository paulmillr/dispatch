/// The engine's algorithm policy: what it offers, in which order, and which negotiated sets it refuses. The one
/// decision that may need flipping is a single constant.
public enum AlgorithmPolicy {
  /// Without strict key exchange, a connection whose packets use a mode open to Terrapin's prefix truncation
  /// (CVE-2023-48795) in either direction is refused: ChaCha20-Poly1305, and AES-CTR with an encrypt-then-MAC MAC
  /// (`-etm@openssh.com`). AES-GCM and AES-CTR with an encrypt-and-MAC MAC (`hmac-sha2-256`, `hmac-sha2-512`) are
  /// allowed. Sources: Bäumer, Brinkmann, Schwenk, "Terrapin Attack: Breaking SSH Channel Integrity By Sequence Number
  /// Manipulation" (USENIX Security 2024, arXiv:2312.12422v2), §4.4 and Table 1: ChaCha20-Poly1305 affected (perfect
  /// truncation), CBC-EtM and CTR-EtM affected (CTR-EtM's exploitability low), CBC-EaM, CTR-EaM and GCM not affected;
  /// terrapin-attack.com, "What about other cipher modes?": GCM does not use the sequence number, and the original
  /// encrypt-and-MAC "protects the integrity of the plaintext, thus thwarting our attack". Strict key exchange (OpenSSH
  /// 9.6 release notes; OpenSSH's PROTOCOL) is the countermeasure that makes every mode safe.
  public static let truncatableModesRequireStrictKex = true

  /// The client's preference lists, as its KEXINIT sends them.
  public struct Preferences: Sendable, Hashable {
    public var keyExchange: [KeyExchangeAlgorithm]
    public var hostKey: [SignatureAlgorithm]
    public var cipher: [CipherAlgorithm]
    public var mac: [MACAlgorithm]

    public init(keyExchange: [KeyExchangeAlgorithm], hostKey: [SignatureAlgorithm], cipher: [CipherAlgorithm],
                mac: [MACAlgorithm]) {
      self.keyExchange = keyExchange
      self.hostKey = hostKey
      self.cipher = cipher
      self.mac = mac
    }

    /// Every supported algorithm, in the engine's order. SSH negotiates the client's first choice the server also
    /// has, so the order alone makes a server without strict key exchange land on a mode `check` allows whenever it
    /// has one, without waiting for its KEXINIT: AES-GCM first (hardware AES, never truncatable), then AES-CTR with
    /// the encrypt-and-MAC MACs before the encrypt-then-MAC ones, and ChaCha20-Poly1305 last, negotiated only with a
    /// server that has neither AES mode (and refused then unless strict).
    public static let standard = Preferences(
      keyExchange: [.mlkem768x25519, .curve25519, .curve25519LibSSH, .ecdhP256, .ecdhP384, .ecdhP521],
      hostKey: [.ed25519, .ecdsaP256, .ecdsaP384, .ecdsaP521, .rsaSHA512, .rsaSHA256],
      cipher: [.aes256GCM, .aes128GCM, .aes256CTR, .aes192CTR, .aes128CTR, .chacha20Poly1305],
      mac: [.hmacSHA256, .hmacSHA512, .hmacSHA256ETM, .hmacSHA512ETM])

    /// The KEXINIT key exchange name-list: the methods, then `ext-info-c` and the strict signal.
    public var keyExchangeNames: [String] {
      keyExchange.map(\.rawValue) + [KexSignal.extInfoClient, KexSignal.strictClient]
    }

    /// The compression name-list, both directions: `none` only.
    public static let compressionNames = ["none"]
  }

  /// Whether one direction's mode is open to prefix truncation (`truncatableModesRequireStrictKex`).
  public static func isTruncatable(_ direction: NegotiatedAlgorithms.Direction) -> Bool {
    switch direction.cipher {
    case .chacha20Poly1305: true
    case .aes256GCM, .aes128GCM: false
    case .aes256CTR, .aes192CTR, .aes128CTR: direction.mac?.isEncryptThenMAC ?? false
    }
  }

  /// Refuses a negotiated set the policy does not allow (`truncatableModesRequireStrictKex`). Run once both KEXINITs
  /// are known, at every exchange, before the method's first message is sent.
  public static func check(_ negotiated: NegotiatedAlgorithms) throws(SSHError) {
    guard truncatableModesRequireStrictKex, !negotiated.strictKex else { return }
    for direction in [negotiated.clientToServer, negotiated.serverToClient] where isTruncatable(direction) {
      if let mac = direction.mac {
        throw .protocolViolation(.negotiation(.encryptThenMACRequiresStrictKex(direction.cipher, mac)))
      }
      throw .protocolViolation(.negotiation(.cipherRequiresStrictKex(direction.cipher)))
    }
  }
}
