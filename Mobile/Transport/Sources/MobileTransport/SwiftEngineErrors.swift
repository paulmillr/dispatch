import Foundation
import SSHEngine

// The Swift engine's errors as the package's. The reference is `RusshEngine.error` over the C ABI code each case names
// (`SSHError.dmsCode`), so both engines give the same `SSHTransportError` for the same condition. Where they cannot (the
// texts come from different code, or the conditions differ), the case says so in a comment.

extension SSHError {
  /// The package's error for this engine error.
  var transportError: SSHTransportError {
    switch self {
    // `SessionLink.explain` fills in the endpoint.
    case .hostNotFound: .connectFailed(.hostNotFound, host: "", port: 0)
    case .connectionRefused: .connectFailed(.refused, host: "", port: 0)
    case .unreachable: .connectFailed(.unreachable, host: "", port: 0)
    case .noAnswer: .connectFailed(.noAnswer, host: "", port: 0)
    // The OS's text; russh's comes from Rust's io::Error and may word the same errno differently.
    case .network(let text): .network(text)
    // "looking up the host's address", "the SSH handshake", "the host stopped answering", "the login": the seam's texts.
    case .timedOut: .timedOut(description)
    // russh's code for a rejected key has no mapping of its own: its text, which the wrappers replace from the app's
    // decision (`SessionLink.explain`).
    case .hostKeyRejected: .protocolError("Unknown server key")
    // The engine's two reasons are russh's texts.
    case .hostKeyChangedAtRekey: .hostKeyChangedAtRekey(description)
    // A server that offers nothing this engine accepts: final for the host, one sentence that says what to do
    // (`SSHTransportError.incompatibleServer`). Only truncatable modes without strict key exchange (OpenSSH before 9.6
    // without AES-GCM or plain-MAC AES-CTR; russh connects to it), or no common algorithm (russh: the same case, from
    // its "No common … algorithm" text, `RusshEngine.error`).
    case .protocolViolation(.negotiation(.cipherRequiresStrictKex(let cipher))): .tooOld(cipher.rawValue)
    case .protocolViolation(.negotiation(.encryptThenMACRequiresStrictKex(let cipher, let mac))):
      .tooOld("\(cipher.rawValue) with \(mac.rawValue)")
    case .protocolViolation(.negotiation(.noCommonAlgorithm(let category))): .noCommonAlgorithm(category.rawValue)
    // DMS_PROTOCOL. The texts are the engine's fixed phrases; russh's are its own error messages.
    case .protocolViolation, .usage: .protocolError(description)
    // Every end (by either side, lost, already ended): DMS_CLOSED.
    case .closed: .channelClosed
    case .cancelled: .cancelled
    case .invalidKey(let reason): .invalidKey(reason)
    case .wrongPassphrase: .wrongPassphrase
    case .unsupported(let what): .unsupportedAuthentication(what)
    // Not by `dmsCode` (DMS_REFUSED, which would be `commandFailed`): russh reports a refused channel open as a protocol
    // error ("Failed to open channel (ConnectFailed)"), which the seam names, so the case is that one (text differs).
    case .channelOpenFailed: .protocolError(description)
    // "the server refused the terminal (pty-req)", "the server refused the shell request": russh's texts.
    case .requestRefused: .commandFailed(status: -1, stderr: description)
    }
  }

  /// A key file's failure (`KeyFile.parse`) as the package's: a missing or wrong passphrase `wrongPassphrase`, an
  /// unreadable file `invalidKey`; what the engine refuses on purpose `invalidKey` with what to do instead
  /// (`KeyFileRefusal.transportError`).
  var keyFileError: SSHTransportError {
    KeyFileRefusal(self)?.transportError ?? transportError
  }
}

extension KeyFileRefusal {
  /// What the app shows ("Invalid private key: <reason>."), in one sentence: what is refused, then what to do about it.
  /// A file the engine could read in another form says how to get that form (ssh-keygen rewrites a file it can read
  /// with its own defaults); a key the engine cannot use at all says to make another. Unlike russh, which reports a key
  /// type it does not take as `unsupportedAuthentication` ("The … authentication method is not supported."), every
  /// refusal is `invalidKey`.
  var transportError: SSHTransportError {
    let convert = "run “ssh-keygen -p -f <file>” on it, which saves it"
    let newKey = "make a new key, such as with “ssh-keygen -t ed25519”, and add it to the host"
    return switch self {
    case .puttyKey:
      .invalidKey("PuTTY key files (.ppk) are not supported; in PuTTYgen, choose Conversions › Export OpenSSH key and import that file")
    case .encryptedPEM:
      .invalidKey("encrypted PEM key files are not supported; \(convert) in OpenSSH format, and import it again")
    case .encryptedPKCS8:
      .invalidKey("encrypted PKCS#8 key files are not supported; \(convert) in OpenSSH format, and import it again")
    case .cipher:
      .invalidKey("the key file’s cipher is not supported; \(convert) with ssh-keygen’s default cipher, and import it again")
    case .kdf:
      .invalidKey("the key file’s key derivation is not supported; \(convert) with bcrypt, and import it again")
    case .bcryptRounds:
      .invalidKey("the key file asks for more than \(Limits.keyFileBcryptRounds) bcrypt rounds; \(convert) with ssh-keygen’s default rounds, and import it again")
    case .rsaKeySize:
      .invalidKey("RSA keys must have \(Limits.rsaMinimumBits) to \(Limits.rsaMaximumBits) bits; \(newKey)")
    case .dsa:
      .invalidKey("DSA keys are not supported; \(newKey)")
    case .securityKey:
      .invalidKey("security key (FIDO) keys are not supported; \(newKey)")
    case .keyType:
      .invalidKey("this key type is not supported; \(newKey)")
    case .certificate, .publicKey, .foreignFormat:
      .invalidKey(rawValue)
    }
  }
}
