/// RFC 4253 §7.2: the six keys of an exchange from K (as encoded for hashing), H and the session id.
///
///     K1 = HASH(K || H || X || session_id)          X = "A" ... "F"
///     Kn = HASH(K || H || K1 || ... || K(n-1))      until there are enough bytes; the key is the first ones
///
/// "A" and "B" are the client-to-server and server-to-client IVs, "C" and "D" the cipher keys, "E" and "F" the MAC
/// keys. Every key is written straight into wiped memory.
public enum KeyDerivation {
  /// `count` bytes of key `letter`.
  public static func derive(_ letter: Character, count: Int, sharedSecret: SecretBytes, exchangeHash: [UInt8],
                            sessionID: [UInt8], hash: HashAlgorithm) -> SecretBytes {
    let digestBytes = hash.digestBytes
    let letterByte = letter.asciiValue ?? 0
    return SecretBytes(count: max(0, count)) { (key: UnsafeMutableRawBufferPointer) in
      guard count > 0 else { return }
      // Whole digests go into a scratch buffer as long as the key, rounded up; the scratch is wiped after.
      let rounds = (count + digestBytes - 1) / digestBytes
      let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: rounds * digestBytes, alignment: 16)
      defer {
        SecretBytes.wipe(scratch)
        scratch.deallocate()
      }
      for round in 0..<rounds {
        var hasher = SSHHasher(hash)
        hasher.update(sharedSecret)
        hasher.update(exchangeHash)
        if round == 0 {
          withUnsafeBytes(of: letterByte) { hasher.update($0) }
          hasher.update(sessionID)
        } else {
          hasher.update(UnsafeRawBufferPointer(rebasing: scratch[0..<round * digestBytes]))
        }
        hasher.finalize(into: UnsafeMutableRawBufferPointer(rebasing: scratch[round * digestBytes..<(round + 1) * digestBytes]))
      }
      key.copyMemory(from: UnsafeRawBufferPointer(rebasing: scratch[0..<count]))
    }
  }

  /// Both directions' keys for `negotiated`, sized by its ciphers and MACs.
  public static func keys(for negotiated: NegotiatedAlgorithms, sharedSecret: SecretBytes, exchangeHash: [UInt8],
                          sessionID: [UInt8], hash: HashAlgorithm)
    -> (clientToServer: DirectionKeys, serverToClient: DirectionKeys)
  {
    func direction(_ algorithms: NegotiatedAlgorithms.Direction, iv: Character, key: Character, mac: Character) -> DirectionKeys {
      let cipher = algorithms.cipher
      return DirectionKeys(
        iv: derive(iv, count: cipher.ivBytes, sharedSecret: sharedSecret, exchangeHash: exchangeHash, sessionID: sessionID, hash: hash),
        key: derive(key, count: cipher.keyBytes, sharedSecret: sharedSecret, exchangeHash: exchangeHash, sessionID: sessionID, hash: hash),
        macKey: algorithms.mac.map {
          derive(mac, count: $0.keyBytes, sharedSecret: sharedSecret, exchangeHash: exchangeHash, sessionID: sessionID, hash: hash)
        })
    }
    return (direction(negotiated.clientToServer, iv: "A", key: "C", mac: "E"),
            direction(negotiated.serverToClient, iv: "B", key: "D", mac: "F"))
  }
}

/// The exchange hash every supported method computes (RFC 5656 §4, RFC 8731 §3.1, draft-ietf-sshm-mlkem-hybrid-kex
/// §2.4): `HASH(string V_C, string V_S, string I_C, string I_S, string K_S, string Q_C, string Q_S, K)`. The methods
/// differ only in what their two values are (an X25519 or EC point, or ML-KEM's concatenations) and in how K is encoded
/// (`KeyExchangeOutput.encodedSharedSecret`, already framed).
public enum ExchangeHash {
  public static func compute(_ hash: HashAlgorithm, transcript: KeyExchangeTranscript, hostKeyBlob: [UInt8],
                             clientValue: [UInt8], serverValue: [UInt8], encodedSharedSecret: SecretBytes) -> [UInt8] {
    var hasher = SSHHasher(hash)
    for field in [transcript.clientVersion, transcript.serverVersion, transcript.clientKexInit, transcript.serverKexInit,
                  hostKeyBlob, clientValue, serverValue] {
      var length = UInt32(truncatingIfNeeded: field.count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update($0) }
      hasher.update(field)
    }
    hasher.update(encodedSharedSecret)
    return hasher.finalize()
  }
}
