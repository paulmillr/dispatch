/// One key exchange method's client side (implemented in Crypto/): an ephemeral key, the server's reply, the shared
/// secret and the exchange hash. The transport runs everything around it: KEXINITs, negotiation, the policy, the host
/// key's signature and pin, key derivation, NEWKEYS. A method object serves one exchange; each re-exchange makes a new
/// one (fresh ephemeral keys). Its private key never leaves it and is wiped with it.
public protocol KeyExchangeMethod: AnyObject {
  var algorithm: KeyExchangeAlgorithm { get }

  /// The payload of the client's method message (number 30: KEX_ECDH_INIT, KEX_HYBRID_INIT) with a fresh ephemeral
  /// value from the core's `RandomSource`. Called once, first.
  func makeInit() throws(SSHError) -> [UInt8]

  /// Consumes the server's reply (number 31, the whole payload): parses it within `Limits` (host key blob,
  /// ephemeral value or ciphertext, signature blob), validates the server's value, computes the shared secret and
  /// hashes the exchange over `transcript` and the method's own fields. Called at most once, after `makeInit`.
  /// Throws `ProtocolViolation.keyExchange` (or `.malformed`) for a bad reply. Does not verify the signature.
  func receiveReply(_ payload: [UInt8], transcript: KeyExchangeTranscript) throws(SSHError) -> KeyExchangeOutput
}

/// What the transport contributes to the exchange hash (RFC 4253 §8): both identification lines and both KEXINIT
/// payloads, each hashed as a `string`.
public struct KeyExchangeTranscript: Sendable {
  /// The identification lines without CR LF (`V_C`, `V_S`).
  public let clientVersion: [UInt8]
  public let serverVersion: [UInt8]
  /// The KEXINIT payloads as sent and received, message number included (`I_C`, `I_S`).
  public let clientKexInit: [UInt8]
  public let serverKexInit: [UInt8]

  public init(clientVersion: [UInt8], serverVersion: [UInt8], clientKexInit: [UInt8], serverKexInit: [UInt8]) {
    self.clientVersion = clientVersion
    self.serverVersion = serverVersion
    self.clientKexInit = clientKexInit
    self.serverKexInit = serverKexInit
  }
}

/// The result of a reply, before the transport checks its signature.
public struct KeyExchangeOutput: Sendable {
  /// `K_S`, as received (`HostKey`, `HostKeyPin` take it from here).
  public let hostKeyBlob: [UInt8]
  /// The signature blob over `exchangeHash`, as received.
  public let signature: [UInt8]
  /// `H`. The first exchange's is the session id for the connection's life.
  public let exchangeHash: [UInt8]
  /// `K` exactly as it enters the exchange hash and the key derivation: an mpint's encoding for ECDH and
  /// curve25519, a string's for mlkem768x25519 (length prefix included either way).
  public let encodedSharedSecret: SecretBytes
  /// The method's hash, for the key derivation.
  public let hash: HashAlgorithm

  public init(hostKeyBlob: [UInt8], signature: [UInt8], exchangeHash: [UInt8], encodedSharedSecret: SecretBytes,
              hash: HashAlgorithm) {
    self.hostKeyBlob = hostKeyBlob
    self.signature = signature
    self.exchangeHash = exchangeHash
    self.encodedSharedSecret = encodedSharedSecret
    self.hash = hash
  }
}
