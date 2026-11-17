import CryptoKit
import Foundation

/// The client side of every supported key exchange method (`KeyExchangeMethod`). Each sends one value in message 30
/// and reads the server's reply in 31, laid out the same way for all of them:
///
///     byte    31
///     string  K_S, the host key blob
///     string  the server's value (Q_S, or mlkem768x25519's S_REPLY)
///     string  the signature over H
///
/// Ephemeral keys are made from the injected `RandomSource`'s bytes (`rawRepresentation`, `seedRepresentation`), so a
/// seeded source gives the same exchange every time. CryptoKit holds the private keys and wipes them when the method
/// object goes.
public enum KeyExchangeMethods {
  public static func make(_ algorithm: KeyExchangeAlgorithm, random: any RandomSource) -> any KeyExchangeMethod {
    switch algorithm {
    case .curve25519, .curve25519LibSSH: Curve25519Exchange(algorithm: algorithm, random: random)
    case .ecdhP256: ECDHExchange(curve: .p256, random: random)
    case .ecdhP384: ECDHExchange(curve: .p384, random: random)
    case .ecdhP521: ECDHExchange(curve: .p521, random: random)
    case .mlkem768x25519: MLKEMHybridExchange(random: random)
    }
  }
}

/// The reply's three fields, within `Limits`.
struct KeyExchangeReply {
  let hostKeyBlob: [UInt8]
  let serverValue: [UInt8]
  let signature: [UInt8]

  init(_ payload: [UInt8]) throws(SSHError) {
    do {
      (hostKeyBlob, serverValue, signature) = try WireReader.decode(payload) {
        (reader: inout WireReader) throws(WireError) -> ([UInt8], [UInt8], [UInt8]) in
        guard try reader.readMessageNumber() == .kexECDHReply else { throw .invalidValue }
        return (try reader.readString(limit: Limits.publicKeyBlobBytes),
                try reader.readString(limit: Limits.keyExchangeValueBytes),
                try reader.readString(limit: Limits.signatureBlobBytes))
      }
    } catch {
      throw .protocolViolation(.malformed(.kexECDHReply, error))
    }
  }

  /// The exchange's output: H over the transcript, K_S, both values and K (`encoded`, framed as it is hashed).
  func output(_ algorithm: KeyExchangeAlgorithm, transcript: KeyExchangeTranscript, clientValue: [UInt8],
              encoded: SecretBytes) -> KeyExchangeOutput {
    let hash = ExchangeHash.compute(algorithm.hash, transcript: transcript, hostKeyBlob: hostKeyBlob,
                                    clientValue: clientValue, serverValue: serverValue, encodedSharedSecret: encoded)
    return KeyExchangeOutput(hostKeyBlob: hostKeyBlob, signature: signature, exchangeHash: hash,
                             encodedSharedSecret: encoded, hash: algorithm.hash)
  }
}

/// Message 30 with the client's value as its one string.
func keyExchangeInit(_ value: [UInt8]) throws(SSHError) -> [UInt8] {
  var writer = WireWriter(.kexECDHInit, capacity: 5 + value.count)
  writer.writeString(value)
  do { return try writer.finish() } catch { throw .protocolViolation(.malformed(.kexECDHInit, error)) }
}

/// The method's life: `makeInit` once, then `receiveReply` at most once.
enum ExchangeStep {
  case fresh, initSent, done

  static let outOfOrder = SSHError.usage(.invalidArgument("a key exchange method used out of order"))
}

/// X25519 (RFC 8731) and the reply's shared secret check. K is the 32 output bytes read as a big-endian unsigned
/// number, encoded as an mpint; an all-zero output (a low-order point) is refused.
enum X25519 {
  static let keyBytes = 32

  static func privateKey(_ random: any RandomSource) throws(SSHError) -> Curve25519.KeyAgreement.PrivateKey {
    let seed = try random.secret(keyBytes)
    do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed) } catch {
      throw .unsupported("the X25519 key could not be made")
    }
  }

  /// The shared secret's 32 bytes in wiped memory, or the reply's problem.
  static func shared(_ privateKey: Curve25519.KeyAgreement.PrivateKey, server: ArraySlice<UInt8>) throws(SSHError) -> SecretBytes {
    guard server.count == keyBytes else { throw .protocolViolation(.keyExchange(.invalidServerValue)) }
    let secret: SharedSecret
    do {
      secret = try privateKey.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: server))
    } catch {
      throw .protocolViolation(.keyExchange(.invalidSharedSecret))
    }
    let bytes = secret.withUnsafeBytes { SecretBytes(copying: $0) }
    guard bytes.count == keyBytes, !bytes.withUnsafeBytes({ ConstantTime.isZero($0) }) else {
      throw .protocolViolation(.keyExchange(.invalidSharedSecret))
    }
    return bytes
  }
}

/// `curve25519-sha256` and `curve25519-sha256@libssh.org` (RFC 8731): Q_C and Q_S are 32-byte X25519 public keys.
final class Curve25519Exchange: KeyExchangeMethod {
  let algorithm: KeyExchangeAlgorithm
  private let random: any RandomSource
  private var privateKey: Curve25519.KeyAgreement.PrivateKey?
  private var clientValue: [UInt8] = []
  private var step = ExchangeStep.fresh

  init(algorithm: KeyExchangeAlgorithm, random: any RandomSource) {
    self.algorithm = algorithm
    self.random = random
  }

  func makeInit() throws(SSHError) -> [UInt8] {
    guard step == .fresh else { throw ExchangeStep.outOfOrder }
    let key = try X25519.privateKey(random)
    privateKey = key
    clientValue = Array(key.publicKey.rawRepresentation)
    step = .initSent
    return try keyExchangeInit(clientValue)
  }

  func receiveReply(_ payload: [UInt8], transcript: KeyExchangeTranscript) throws(SSHError) -> KeyExchangeOutput {
    guard step == .initSent, let privateKey else { throw ExchangeStep.outOfOrder }
    step = .done
    self.privateKey = nil
    let reply = try KeyExchangeReply(payload)
    let shared = try X25519.shared(privateKey, server: reply.serverValue[...])
    let encoded = shared.withUnsafeBytes { SecretBytes.mpint(magnitude: $0) }
    return reply.output(algorithm, transcript: transcript, clientValue: clientValue, encoded: encoded)
  }
}

/// `ecdh-sha2-nistp256/384/521` (RFC 5656 §4): Q_C and Q_S are uncompressed SEC1 points; the server's must be exactly
/// that form and on the curve (CryptoKit checks it when it makes the key). K is the shared point's x coordinate as an
/// mpint.
final class ECDHExchange: KeyExchangeMethod {
  private enum PrivateKey {
    case p256(P256.KeyAgreement.PrivateKey)
    case p384(P384.KeyAgreement.PrivateKey)
    case p521(P521.KeyAgreement.PrivateKey)
  }

  let curve: ECDSACurve
  private let random: any RandomSource
  private var privateKey: PrivateKey?
  private var clientValue: [UInt8] = []
  private var step = ExchangeStep.fresh

  init(curve: ECDSACurve, random: any RandomSource) {
    self.curve = curve
    self.random = random
  }

  var algorithm: KeyExchangeAlgorithm {
    switch curve {
    case .p256: .ecdhP256
    case .p384: .ecdhP384
    case .p521: .ecdhP521
    }
  }

  func makeInit() throws(SSHError) -> [UInt8] {
    guard step == .fresh else { throw ExchangeStep.outOfOrder }
    // A scalar from random bytes; CryptoKit refuses 0 and values past the group order, so a refused draw is redrawn
    // (P-256 refuses about one in 2^32; P-521's top 7 bits are cleared first, leaving it below 2^521).
    for _ in 0..<16 {
      let scalar = try random.secret(curve.scalarBytes)
      let masked = curve == .p521
        ? scalar.withUnsafeBytes { raw in
          SecretBytes(count: raw.count) { (out: UnsafeMutableRawBufferPointer) in
            out.copyMemory(from: raw)
            out[0] &= 0x01
          }
        }
        : scalar
      do {
        switch curve {
        case .p256:
          let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: masked)
          privateKey = .p256(key)
          clientValue = Array(key.publicKey.x963Representation)
        case .p384:
          let key = try P384.KeyAgreement.PrivateKey(rawRepresentation: masked)
          privateKey = .p384(key)
          clientValue = Array(key.publicKey.x963Representation)
        case .p521:
          let key = try P521.KeyAgreement.PrivateKey(rawRepresentation: masked)
          privateKey = .p521(key)
          clientValue = Array(key.publicKey.x963Representation)
        }
        step = .initSent
        return try keyExchangeInit(clientValue)
      } catch {
        continue
      }
    }
    throw .unsupported("the ECDH key could not be made")
  }

  func receiveReply(_ payload: [UInt8], transcript: KeyExchangeTranscript) throws(SSHError) -> KeyExchangeOutput {
    guard step == .initSent, let privateKey else { throw ExchangeStep.outOfOrder }
    step = .done
    self.privateKey = nil
    let reply = try KeyExchangeReply(payload)
    let point = reply.serverValue
    guard point.count == curve.pointBytes, point.first == 0x04 else {
      throw .protocolViolation(.keyExchange(.invalidServerValue))
    }
    let secret: SharedSecret
    do {
      switch privateKey {
      case .p256(let key): secret = try key.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: point))
      case .p384(let key): secret = try key.sharedSecretFromKeyAgreement(with: try P384.KeyAgreement.PublicKey(x963Representation: point))
      case .p521(let key): secret = try key.sharedSecretFromKeyAgreement(with: try P521.KeyAgreement.PublicKey(x963Representation: point))
      }
    } catch {
      throw .protocolViolation(.keyExchange(.invalidServerValue))
    }
    let encoded = secret.withUnsafeBytes { raw -> SecretBytes? in
      raw.count == curve.scalarBytes ? SecretBytes.mpint(magnitude: raw) : nil
    }
    guard let encoded else { throw .protocolViolation(.keyExchange(.invalidSharedSecret)) }
    return reply.output(algorithm, transcript: transcript, clientValue: clientValue, encoded: encoded)
  }
}

/// `mlkem768x25519-sha256` (draft-ietf-sshm-mlkem-hybrid-kex, as OpenSSH 10 implements it):
///
///     C_INIT  = C_PK2 ‖ C_PK1         ML-KEM-768 encapsulation key (1184) ‖ X25519 public key (32)
///     S_REPLY = S_CT2 ‖ S_PK1         ML-KEM-768 ciphertext (1088) ‖ X25519 public key (32)
///     K       = SHA-256(K_PQ ‖ K_CL)  ML-KEM shared secret ‖ X25519 shared secret, hashed and exchanged as a string
///
/// C_INIT and S_REPLY enter the exchange hash as strings, as Q_C and Q_S do. The X25519 half is refused as in
/// curve25519 (an all-zero output); ML-KEM's decapsulation never fails for a well-sized ciphertext (implicit
/// rejection gives a key the server cannot know, so the signature check fails instead).
final class MLKEMHybridExchange: KeyExchangeMethod {
  static let encapsulationKeyBytes = 1184
  static let ciphertextBytes = 1088
  /// ML-KEM's seed: d ‖ z (FIPS 203 §7.1).
  static let seedBytes = 64

  let algorithm = KeyExchangeAlgorithm.mlkem768x25519
  private let random: any RandomSource
  private var kemKey: MLKEM768.PrivateKey?
  private var curveKey: Curve25519.KeyAgreement.PrivateKey?
  private var clientValue: [UInt8] = []
  private var step = ExchangeStep.fresh

  init(random: any RandomSource) { self.random = random }

  func makeInit() throws(SSHError) -> [UInt8] {
    guard step == .fresh else { throw ExchangeStep.outOfOrder }
    let seed = try random.secret(Self.seedBytes)
    let kem: MLKEM768.PrivateKey
    do {
      kem = try seed.withUnsafeBytes { try MLKEM768.PrivateKey(seedRepresentation: $0, publicKey: nil) }
    } catch {
      throw .unsupported("the ML-KEM key could not be made")
    }
    let curve = try X25519.privateKey(random)
    kemKey = kem
    curveKey = curve
    clientValue = Array(kem.publicKey.rawRepresentation) + Array(curve.publicKey.rawRepresentation)
    guard clientValue.count == Self.encapsulationKeyBytes + X25519.keyBytes else {
      throw .unsupported("the ML-KEM key could not be made")
    }
    step = .initSent
    return try keyExchangeInit(clientValue)
  }

  func receiveReply(_ payload: [UInt8], transcript: KeyExchangeTranscript) throws(SSHError) -> KeyExchangeOutput {
    guard step == .initSent, let kemKey, let curveKey else { throw ExchangeStep.outOfOrder }
    step = .done
    self.kemKey = nil
    self.curveKey = nil
    let reply = try KeyExchangeReply(payload)
    let value = reply.serverValue
    guard value.count == Self.ciphertextBytes + X25519.keyBytes else {
      throw .protocolViolation(.keyExchange(.invalidServerValue))
    }
    let quantum: SymmetricKey
    do { quantum = try kemKey.decapsulate(value[0..<Self.ciphertextBytes]) } catch {
      throw .protocolViolation(.keyExchange(.invalidServerValue))
    }
    let classical = try X25519.shared(curveKey, server: value[Self.ciphertextBytes...])
    var hasher = SHA256()
    quantum.withUnsafeBytes { hasher.update(bufferPointer: $0) }
    classical.withUnsafeBytes { hasher.update(bufferPointer: $0) }
    let encoded = hasher.finalize().withUnsafeBytes { SecretBytes.string($0) }
    return reply.output(algorithm, transcript: transcript, clientValue: clientValue, encoded: encoded)
  }
}
