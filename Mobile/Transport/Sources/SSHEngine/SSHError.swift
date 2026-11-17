/// Why an engine operation failed or a connection ended. Every public async call throws this type (typed throws), and
/// a session's end carries one. Cases hold no secret: no key, password, answer or signed bytes, and server text only
/// through `DisplayText`. `dmsCode` maps each case onto the result codes MobileTransport handles today
/// (`Core/include/dispatch_mobile_ssh.h`), so the adapter keeps its mapping to `SSHTransportError`.
///
/// A refusal is not an error: a refused login is `AuthOutcome.refused`, a refused exec is `ChannelExit.refused`.
public enum SSHError: Error, Sendable, Equatable, CustomStringConvertible {
  // MARK: Reaching the host (the stream connector)

  /// Name resolution found no address. DMS_HOST_NOT_FOUND.
  case hostNotFound
  /// Nothing accepted the TCP connection on the port. DMS_CONNECTION_REFUSED.
  case connectionRefused
  /// No route to the host from this network (on iOS also Local Network access denied). DMS_UNREACHABLE.
  case unreachable
  /// The host did not answer the TCP connection before the deadline. DMS_NO_ANSWER.
  case noAnswer
  /// Another socket failure, with the OS's text. DMS_NETWORK.
  case network(String)

  // MARK: Deadlines

  /// DMS_TIMEOUT.
  case timedOut(Deadline)

  // MARK: Host key

  /// The trust callback answered no. DMS_HOST_KEY_REJECTED.
  case hostKeyRejected
  /// A re-exchange presented another host key or algorithm than the first exchange: the connection ended before the
  /// new keys carried anything. DMS_HOST_KEY_CHANGED.
  case hostKeyChangedAtRekey(HostKeyChange)

  // MARK: Protocol

  /// The server broke the protocol, or offered nothing the engine accepts. DMS_PROTOCOL.
  case protocolViolation(ProtocolViolation)

  // MARK: The connection's end

  /// The connection is gone: closed by either side or lost. DMS_CLOSED.
  case closed(CloseReason)

  // MARK: Local outcomes

  /// A question was withdrawn or declined: a signer declined, a keyboard-interactive prompt was cancelled or answered
  /// with the wrong number of answers, the operation's task was cancelled. DMS_CANCELLED.
  case cancelled
  /// A key file or key the engine cannot use. The reason is a fixed phrase, never derived from key bytes.
  /// DMS_INVALID_KEY.
  case invalidKey(String)
  /// The key file is encrypted and the passphrase is missing or wrong. DMS_WRONG_PASSPHRASE.
  case wrongPassphrase
  /// A key type or method the engine does not support (a fixed phrase or a validated name). DMS_UNSUPPORTED.
  case unsupported(String)
  /// The server refused to open a channel, with its reason and description (display text, `readDisplayText` within
  /// `Limits.channelMessageBytes`, then `DisplayText.sanitize`). DMS_REFUSED.
  case channelOpenFailed(ChannelOpenFailureReason, description: String)
  /// The server refused a shell channel's `pty-req` or `shell` request (a refused exec is `ChannelExit.refused`).
  /// DMS_REFUSED.
  case requestRefused(ChannelRequestKind)
  /// The caller used the API out of order. DMS_PROTOCOL, as the C ABI's invalid arguments are.
  case usage(UsageError)

  /// Which deadline passed.
  public enum Deadline: Sendable, Equatable {
    /// Name resolution did not finish within the handshake deadline.
    case lookup
    /// Version exchange and key exchange did not finish within the handshake deadline (the time the host key
    /// decision took does not count).
    case handshake
    /// A keepalive fell due while `keepaliveCountMax` were already unanswered (`ConnectOptions.keepaliveCountMax`).
    case keepalive
    /// A direct public key request got no answer within `ConnectOptions.directAnswer` (the engine closed the
    /// connection).
    case directAnswer
  }

  /// How a re-exchange's host key differed from the first exchange's.
  public enum HostKeyChange: Sendable, Equatable {
    /// The same algorithm, another key (or a blob that is not a key the engine accepts).
    case differentKey
    /// Another signature algorithm, whatever the key (stricter than OpenSSH: rsa-sha2-256 after rsa-sha2-512 is a
    /// change).
    case differentAlgorithm(trusted: SignatureAlgorithm, presented: SignatureAlgorithm)
  }

  /// Why a connection ended.
  public enum CloseReason: Sendable, Equatable {
    /// The client closed it (`SSHSession.close`).
    case byClient
    /// The server sent DISCONNECT. `description` is the server's text: display text (`readDisplayText` within
    /// `Limits.descriptionBytes`, never refused for its encoding), then `DisplayText.sanitize`.
    case byServer(DisconnectReason, description: String)
    /// The stream ended or was reset without a DISCONNECT.
    case connectionLost
    /// An operation was asked of a session that had already ended for another reason (that reason is `ended()`'s).
    case alreadyEnded
    /// The server closed a channel before it was ready (a shell whose `pty-req` or `shell` was not yet confirmed);
    /// the connection stays up.
    case channelClosed
  }

  /// The channel requests whose refusal is an error.
  public enum ChannelRequestKind: String, Sendable, Equatable {
    case ptyRequest = "pty-req"
    case shell
  }

  /// API misuse. These are the caller's bugs; the session stays as it was.
  public enum UsageError: Sendable, Equatable {
    /// Channels need a successful login first.
    case notAuthenticated
    /// The session is already logged in.
    case alreadyAuthenticated
    /// Another login attempt is in progress; attempts run one at a time.
    case authenticationInProgress
    /// `Limits.channels` channels are open.
    case tooManyChannels
    /// An argument out of range (a keepalive count above `Limits.keepaliveCountMax`, a port of 0).
    case invalidArgument(String)
    /// The channel's input was already finished, or the channel closed (a write, a resize).
    case channelClosed
  }

  /// The C ABI's result code for this error (DMS_* in dispatch_mobile_ssh.h).
  public var dmsCode: Int32 {
    switch self {
    case .hostNotFound: -11
    case .connectionRefused: -12
    case .unreachable: -13
    case .noAnswer: -14
    case .network: -1
    case .timedOut: -2
    case .hostKeyRejected: -3
    case .hostKeyChangedAtRekey: -15
    case .protocolViolation, .usage: -4
    case .closed: -9
    case .cancelled: -7
    case .invalidKey: -5
    case .wrongPassphrase: -6
    case .unsupported: -8
    case .channelOpenFailed, .requestRefused: -10
    }
  }

  public var description: String {
    switch self {
    case .hostNotFound: "no address for the host"
    case .connectionRefused: "the connection was refused"
    case .unreachable: "no route to the host"
    case .noAnswer: "no answer"
    case .network(let text): text
    case .timedOut(let deadline):
      switch deadline {
      case .lookup: "looking up the host's address"
      case .handshake: "the SSH handshake"
      case .keepalive: "the host stopped answering"
      case .directAnswer: "the login"
      }
    case .hostKeyRejected: "the host key was not trusted"
    case .hostKeyChangedAtRekey(.differentKey): "the server presented a different host key at a key re-exchange"
    case .hostKeyChangedAtRekey(.differentAlgorithm(let trusted, let presented)):
      "the host key algorithm changed at a key re-exchange (\(trusted.rawValue), now \(presented.rawValue))"
    case .protocolViolation(let violation): violation.description
    case .closed(.byClient): "closed"
    case .closed(.byServer(_, let text)): "disconnected by the server: \(text)"
    case .closed(.connectionLost): "the connection was reset"
    case .closed(.alreadyEnded): "the connection is closed"
    case .closed(.channelClosed): "the server closed the channel"
    case .cancelled: "cancelled"
    case .invalidKey(let reason): reason
    case .wrongPassphrase: "the passphrase is wrong"
    case .unsupported(let what): what
    case .channelOpenFailed(let reason, let text): text.isEmpty ? "the server refused the channel (\(reason))"
      : "the server refused the channel (\(reason)): \(text)"
    case .requestRefused(.ptyRequest): "the server refused the terminal (pty-req)"
    case .requestRefused(.shell): "the server refused the shell request"
    case .usage(let error): "\(error)"
    }
  }
}

/// How the server broke the protocol. Each case is a fixed condition; add cases (never repurpose one) when a layer
/// needs a new one. Descriptions are fixed English phrases plus numbers and validated names.
public enum ProtocolViolation: Sendable, Equatable, CustomStringConvertible {
  /// The identification exchange (RFC 4253 §4.2).
  case version(VersionProblem)
  /// Packet framing or protection (RFC 4253 §6).
  case packet(PacketProblem)
  /// A message the current phase does not accept (`MessagePolicy`).
  case unexpectedMessage(MessageNumber, MessagePolicy.Context)
  /// A message whose fields did not decode.
  case malformed(MessageNumber, WireError)
  /// Algorithm negotiation (RFC 4253 §7.1) or the engine's algorithm policy.
  case negotiation(NegotiationProblem)
  /// The key exchange itself.
  case keyExchange(KeyExchangeProblem)
  /// Strict key exchange (`kex-strict-s-v00@openssh.com`): the server's KEXINIT was not the first packet.
  case strictKeyExchange
  /// A third EXT_INFO (`Limits.extInfoMessages`).
  case tooManyExtInfo
  /// The userauth service: a SERVICE_ACCEPT for another service, a PK_OK for another key.
  case authentication(AuthenticationProblem)
  /// The connection protocol (RFC 4254).
  case channel(ChannelProblem)
  /// UNIMPLEMENTED for a message the engine needs answered (its sequence number).
  case unimplemented(sequence: UInt32)

  public enum VersionProblem: Sendable, Equatable {
    case lineTooLong, tooManyLines
    /// The identification line is neither `SSH-2.0-` nor `SSH-1.99-` (RFC 4253 §5.1: 1.99 means a server that also
    /// speaks 2.0, and is accepted as 2.0).
    case notSSH2
    case malformedLine
  }

  public enum PacketProblem: Sendable, Equatable {
    /// `packet_length` above `Limits.packetLength` or below the minimum.
    case lengthOutOfRange
    /// The packet does not fill whole cipher blocks.
    case misaligned
    /// `padding_length` below `Limits.minimumPadding` or past the packet.
    case invalidPadding
    /// The MAC or AEAD tag did not verify.
    case integrity
    /// A sequence number would wrap (`Limits.rekeyPackets` makes this unreachable when rekeys work).
    case sequenceExhausted
    /// Bytes past one packet beyond `Limits.inboundBufferBytes` were buffered.
    case bufferOverflow
  }

  public enum NegotiationProblem: Sendable, Equatable {
    /// No algorithm of this category is on both lists.
    case noCommonAlgorithm(AlgorithmCategory)
    /// The negotiated cipher (ChaCha20-Poly1305) is open to prefix truncation and strict key exchange was not
    /// negotiated (`AlgorithmPolicy.truncatableModesRequireStrictKex`).
    case cipherRequiresStrictKex(CipherAlgorithm)
    /// AES-CTR with an encrypt-then-MAC MAC, open to prefix truncation, without strict key exchange
    /// (`AlgorithmPolicy.truncatableModesRequireStrictKex`).
    case encryptThenMACRequiresStrictKex(CipherAlgorithm, MACAlgorithm)
    /// The server set `first_kex_packet_follows`: no supported method lets a server guess first.
    case firstKexPacketFollows
  }

  public enum AlgorithmCategory: String, Sendable, Equatable {
    case keyExchange = "key exchange"
    case hostKey = "host key"
    case cipher
    case mac = "MAC"
    case compression
  }

  public enum KeyExchangeProblem: Sendable, Equatable {
    /// The server's ephemeral value or ciphertext is not valid for the method (wrong size, not on the curve).
    case invalidServerValue
    /// The shared secret is degenerate (X25519's all-zero output).
    case invalidSharedSecret
    /// The host key blob is not a key of the negotiated algorithm's type, or not one the engine accepts.
    case hostKeyTypeMismatch
    /// The host key is a certificate (refused, as the russh engine did).
    case hostKeyCertificate
    /// The signature over the exchange hash did not verify.
    case invalidSignature
  }

  public enum AuthenticationProblem: Sendable, Equatable {
    case unexpectedService
    case pkOKMismatch
    /// More keyboard-interactive rounds than `Limits.keyboardInteractiveRounds`.
    case tooManyRounds
  }

  public enum ChannelProblem: Sendable, Equatable {
    /// A message for a channel number the engine did not open (or already freed).
    case unknownChannel(UInt32)
    /// A message the channel's state does not allow (data after EOF, a reply with no request pending).
    case unexpectedInState(MessageNumber)
    /// A window adjust that would take the window past 2^32 - 1.
    case windowOverflow
    /// Data beyond the window the engine granted.
    case windowExceeded
    /// Data larger than the maximum packet size the engine announced.
    case packetTooLarge
    /// The server announced a maximum packet size below `Limits.peerMinimumPacket`.
    case maximumPacketTooSmall
    /// Extended data of a type other than stderr.
    case unknownExtendedDataType
    /// A REQUEST_SUCCESS or REQUEST_FAILURE with no global request pending.
    case unexpectedGlobalReply
  }

  public var description: String {
    switch self {
    case .version(let problem): "the server's identification line: \(problem)"
    case .packet(let problem): "packet: \(problem)"
    case .unexpectedMessage(let number, let context): "unexpected \(number) (\(context))"
    case .malformed(let number, let error): "malformed \(number): \(error)"
    case .negotiation(.noCommonAlgorithm(let category)): "no common \(category.rawValue) algorithm"
    case .negotiation(.cipherRequiresStrictKex(let cipher)):
      "\(cipher.rawValue) needs strict key exchange, which the server did not offer"
    case .negotiation(.encryptThenMACRequiresStrictKex(let cipher, let mac)):
      "\(cipher.rawValue) with \(mac.rawValue) needs strict key exchange, which the server did not offer"
    case .negotiation(.firstKexPacketFollows): "the server guessed the key exchange (first_kex_packet_follows)"
    case .keyExchange(let problem): "key exchange: \(problem)"
    case .strictKeyExchange: "strict key exchange: KEXINIT was not the server's first packet"
    case .tooManyExtInfo: "more than \(Limits.extInfoMessages) EXT_INFO messages"
    case .authentication(let problem): "authentication: \(problem)"
    case .channel(let problem): "channel: \(problem)"
    case .unimplemented(let sequence): "the server did not implement message \(sequence)"
    }
  }
}
