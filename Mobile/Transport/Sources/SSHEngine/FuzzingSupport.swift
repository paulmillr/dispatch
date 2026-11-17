#if SSHENGINE_FUZZING
import Foundation

/// Entry points used only by the separate `Mobile/Transport/Fuzzing` package. The normal package never defines
/// `SSHENGINE_FUZZING`, so none of this harness is present in app, build, or test binaries.
public enum SSHEngineFuzzing {
  private static let readSize = 16 * 1024
  private static let fixedSeed: UInt64 = 0xC11E_0000

  /// Arbitrary server bytes from byte zero: identification, plaintext packet framing, negotiation and key exchange.
  public static func clientInitial(_ input: [UInt8]) {
    let core: ClientCore
    do throws(SSHError) {
      core = try ClientCore(
        options: ConnectOptions(host: "fuzzer.invalid", keepaliveInterval: nil),
        verifier: SSHSignatureVerifier(), random: FuzzRandom(seed: fixedSeed))
    } catch {
      preconditionFailure("constant fuzz options failed: \(error)")
    }
    core.start()
    var observation = Observation()
    settle(core, observation: &observation, trustHostKey: true)
    deliver(input, to: core, observation: &observation, trustHostKey: true)
    core.receiveEnd()
    settle(core, observation: &observation, trustHostKey: true)
    observation.checkEnded(core)
  }

  /// Arbitrary authenticated payload bytes after a fixed AES-128-GCM key exchange. The selector chooses a valid
  /// service state before the payload: service accept, password reply, authenticated connection, or channel phases.
  public static func clientPostKex(_ input: [UInt8]) {
    guard let selector = input.first else { return }
    let incoming = fixedKeys(iv: 0x11, key: 0x21)
    let outgoing = fixedKeys(iv: 0x12, key: 0x22)
    let core: ClientCore
    do throws(SSHError) {
      core = try ClientCore.fuzzEstablished(random: FuzzRandom(seed: fixedSeed), inboundKeys: incoming,
                                            outboundKeys: outgoing)
    } catch {
      preconditionFailure("constant fuzz state failed: \(error)")
    }
    var server = OutboundFramer()
    do throws(SSHError) {
      server.install(try PacketProtection.sealer(cipher: .aes128GCM, mac: nil,
                                                 keys: fixedKeys(iv: 0x11, key: 0x21)))
    } catch {
      preconditionFailure("constant fuzz keys failed: \(error)")
    }
    var observation = Observation()
    settle(core, observation: &observation, trustHostKey: false)

    // States mirror the valid phases exercised by Robustness/SessionReplayTests.
    let state = Int(selector % 7)
    do throws(SSHError) {
      if state == 6 {
        try core.authenticate(user: "phone", credential: .keyboardInteractive { _ in nil })
      } else {
        try core.authenticate(user: "phone", credential: .password(SecretBytes(utf8: "fictional-fuzz-password")))
      }
    } catch {
      preconditionFailure("constant fuzz login failed: \(error)")
    }
    settle(core, observation: &observation, trustHostKey: false)

    if state >= 1 {
      send([MessageNumber.serviceAccept.rawValue] + string("ssh-userauth"), through: &server, to: core,
           observation: &observation)
    }
    if (2...5).contains(state) {
      send([MessageNumber.userauthSuccess.rawValue], through: &server, to: core, observation: &observation)
    }
    if (3...5).contains(state), core.endedWith == nil {
      do throws(SSHError) { _ = try core.openExec("true") } catch {
        preconditionFailure("constant fuzz channel failed: \(error)")
      }
      settle(core, observation: &observation, trustHostKey: false)
    }
    if (4...5).contains(state), core.endedWith == nil {
      let confirmation = [MessageNumber.channelOpenConfirmation.rawValue] + u32(0) + u32(41)
        + u32(Limits.channelWindow) + u32(Limits.channelMaximumPacket)
      send(confirmation, through: &server, to: core, observation: &observation)
    }
    if state == 5, core.endedWith == nil {
      send([MessageNumber.channelSuccess.rawValue] + u32(0), through: &server, to: core,
           observation: &observation)
    }

    var payload = Array(input.dropFirst())
    if payload.isEmpty { payload = [selector] }
    if payload.count > Limits.packetLength { payload.removeSubrange(Limits.packetLength...) }
    if core.endedWith == nil { send(payload, through: &server, to: core, observation: &observation) }
    core.receiveEnd()
    settle(core, observation: &observation, trustHostKey: false)
    observation.checkEnded(core)
  }

  /// Every message-body decoder, independently of the state machine's phase checks.
  public static func messages(_ input: [UInt8]) {
    guard let message = InboundMessage(payload: input) else { return }
    do throws(SSHError) {
      switch message.number {
      case .disconnect:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readDisplayText(limit: Limits.descriptionBytes),
           try reader.readDisplayText(limit: Limits.languageTagBytes))
        }
      case .ignore:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          try reader.readString(limit: Limits.packetLength)
        }
      case .unimplemented:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
      case .debug:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readBoolean(), try reader.readDisplayText(limit: Limits.descriptionBytes),
           try reader.readDisplayText(limit: Limits.languageTagBytes))
        }
      case .serviceAccept:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readName() }
      case .extInfo:
        _ = try message.decode(ClientTransport.extInfoEntries)
      case .kexInit:
        let decoded = try KexInit(decoding: input)
        let encoded = try decoded.encoded()
        precondition(encoded == input, "a decoded KEXINIT was not canonical")
      case .kexECDHReply:
        _ = try KeyExchangeReply(input)
      case .newKeys, .userauthSuccess, .requestSuccess, .requestFailure, .channelEOF, .channelClose,
           .channelSuccess, .channelFailure:
        _ = try message.decode { (_: inout WireReader) throws(WireError) in }
      case .userauthFailure:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readNameList(), try reader.readBoolean())
        }
      case .userauthBanner:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readDisplayText(limit: Limits.authenticationTextBytes),
           try reader.readDisplayText(limit: Limits.languageTagBytes))
        }
      case MessageNumber(60):
        decodeMessage60(message)
      case .globalRequest:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readName(), try reader.readBoolean(), reader.readRemaining())
        }
      case .channelOpen:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readName(), try reader.readUInt32(), try reader.readUInt32(), try reader.readUInt32(),
           reader.readRemaining())
        }
      case .channelOpenConfirmation:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readUInt32(), try reader.readUInt32(), try reader.readUInt32(),
           reader.readRemaining())
        }
      case .channelOpenFailure:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readUInt32(),
           try reader.readDisplayText(limit: Limits.channelMessageBytes),
           try reader.readDisplayText(limit: Limits.languageTagBytes))
        }
      case .channelWindowAdjust:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readUInt32())
        }
      case .channelData:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readString(limit: Int(Limits.channelMaximumPacket)))
        }
      case .channelExtendedData:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readUInt32(),
           try reader.readString(limit: Int(Limits.channelMaximumPacket)))
        }
      case .channelRequest:
        _ = try message.decode { (reader: inout WireReader) throws(WireError) in
          (try reader.readUInt32(), try reader.readName(), try reader.readBoolean(), reader.readRemaining())
        }
      default:
        // Unknown numbers are a typed phase error in the real state machine; there is no body schema to run here.
        _ = MessagePolicy.route(for: message.number, in: .init(transport: .established))
      }
    } catch {
      // Typed SSHError is the decoder contract.
    }
  }

  public static func keyBlobs(_ input: [UInt8]) {
    do throws(WireError) {
      let key = try PublicKeyBlob(decoding: input)
      precondition(key.encoded == input, "a decoded public key blob was not canonical")
    } catch {}
  }

  public static func signatures(_ input: [UInt8]) {
    do throws(WireError) {
      let blob = try SignatureBlob(decoding: input)
      let encoded = try blob.encoded()
      precondition(encoded == input, "a decoded signature blob was not canonical")
      for curve in ECDSACurve.allCases {
        if let raw = try? ECDSASignature.raw(fromInner: blob.signature, curve: curve) {
          let inner = try ECDSASignature.inner(fromRaw: raw, curve: curve)
          precondition(inner == blob.signature,
                       "an ECDSA signature did not round-trip")
        }
      }
    } catch {}
    for curve in ECDSACurve.allCases {
      do throws(WireError) {
        let raw = try ECDSASignature.raw(fromInner: input, curve: curve)
        let inner = try ECDSASignature.inner(fromRaw: raw, curve: curve)
        precondition(inner == input,
                     "an ECDSA inner signature did not round-trip")
      } catch {}
    }
  }

  /// Selector 0 parses a whole armored file; 1/2/3 drive PKCS#8, PKCS#1 and SEC1 DER directly; 4 drives the binary
  /// OpenSSH format without a base64 barrier. Bcrypt is capped at four rounds in every OpenSSH path.
  public static func keyFiles(_ input: [UInt8]) {
    guard let selector = input.first else { return }
    let format = selector % 5
    // The whole-file entry point must see oversized inputs so it exercises its early limit check. The format-specific
    // entry points normally sit behind that check, so keep their direct fuzz inputs within the same production limit.
    let payload = input.dropFirst()
    let bytes = SecretBytes(copying: format == 0 ? payload : payload.prefix(Limits.keyFileBytes))
    let passphrase = SecretBytes(utf8: "fictional passphrase for a throwaway key")
    do throws(SSHError) {
      switch format {
      case 0: _ = try KeyFile.parse(bytes, passphrase: passphrase, maximumRounds: 4)
      case 1: _ = try PEMKeyFile.parse(label: "PRIVATE KEY", body: bytes)
      case 2: _ = try PEMKeyFile.parse(label: "RSA PRIVATE KEY", body: bytes)
      case 3: _ = try PEMKeyFile.parse(label: "EC PRIVATE KEY", body: bytes)
      default: _ = try OpenSSHKeyFile.parse(bytes, passphrase: passphrase, maximumRounds: 4)
      }
    } catch {
      // Typed SSHError is the key-file contract.
    }
  }

  private static func decodeMessage60(_ message: InboundMessage) {
    do throws(SSHError) {
      _ = try message.decode(UserauthCore.challenge)
    } catch {}
    do throws(SSHError) {
      _ = try message.decode { (reader: inout WireReader) throws(WireError) in
        (try reader.readDisplayText(limit: Limits.authenticationTextBytes),
         try reader.readDisplayText(limit: Limits.languageTagBytes))
      }
    } catch {}
    do throws(SSHError) {
      _ = try message.decode { (reader: inout WireReader) throws(WireError) in
        (try reader.readName(), try reader.readString(limit: Limits.publicKeyBlobBytes))
      }
    } catch {}
  }

  private static func fixedKeys(iv: UInt8, key: UInt8) -> DirectionKeys {
    DirectionKeys(iv: SecretBytes(copying: [UInt8](repeating: iv, count: CipherAlgorithm.aes128GCM.ivBytes)),
                  key: SecretBytes(copying: [UInt8](repeating: key, count: CipherAlgorithm.aes128GCM.keyBytes)),
                  macKey: nil)
  }

  private static func send(_ payload: [UInt8], through server: inout OutboundFramer, to core: ClientCore,
                           observation: inout Observation) {
    do throws(SSHError) {
      server.output = []
      _ = try server.seal(payload, random: FuzzRandom(seed: UInt64(server.nextSequence)))
    } catch {
      preconditionFailure("the fuzz server could not seal a bounded payload: \(error)")
    }
    deliver(server.output, to: core, observation: &observation, trustHostKey: false)
  }

  private static func deliver(_ bytes: [UInt8], to core: ClientCore, observation: inout Observation,
                              trustHostKey: Bool) {
    var offset = 0
    while offset < bytes.count, core.endedWith == nil {
      let end = min(bytes.count, offset + readSize)
      let chunk = Array(bytes[offset..<end])
      core.receive(chunk)
      settle(core, observation: &observation, trustHostKey: trustHostKey)
      precondition(core.inboundBuffered <= Limits.inboundBufferBytes + chunk.count,
                   "inbound buffering passed Limits.inboundBufferBytes")
      offset = end
    }
  }

  private static func settle(_ core: ClientCore, observation: inout Observation, trustHostKey: Bool) {
    for _ in 0..<1_000 {
      observation.drain(core, trustHostKey: trustHostKey)
      precondition(core.outboundBacklog <= 2 * Limits.outboundBacklogBytes + Limits.packetLength,
                   "outbound buffering passed its documented one-packet allowance")
      let bytes = core.takeOutbound()
      if bytes.isEmpty { return }
    }
    preconditionFailure("the core did not become quiescent")
  }

  private static func u32(_ value: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
     UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
  }

  private static func string(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    return u32(UInt32(bytes.count)) + bytes
  }

  private struct Observation {
    var events = 0
    var ends = 0
    var endedWasLast = false

    mutating func drain(_ core: ClientCore, trustHostKey: Bool) {
      var perInput = 0
      while let event = core.poll() {
        perInput += 1
        events += 1
        precondition(perInput <= 3 * (Limits.packetLength / 16 + 1) + Limits.channels + 16,
                     "one input produced an unbounded number of events")
        precondition(!endedWasLast, "an event followed the connection end")
        switch event {
        case .hostKeyNeedsTrust where trustHostKey:
          core.answerHostKey(trusted: true)
        case .prompt(let question, let challenge):
          core.answered(question, with: challenge.prompts.map { _ in SecretBytes(utf8: "fictional-answer") })
        case .ended(let error):
          _ = error.description  // The associated value is statically an SSHError; exercise its secret-safe text.
          ends += 1
          endedWasLast = true
        default:
          break
        }
      }
    }

    func checkEnded(_ core: ClientCore) {
      precondition(core.endedWith != nil, "EOF did not end the core")
      precondition(ends == 1 && endedWasLast, "the core did not emit one typed SSHError as its last event")
    }
  }

  /// SplitMix64, matching the deterministic source used by `Tests/SSHEngineTests/Robustness`.
  private final class FuzzRandom: RandomSource {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    private func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var value = state
      value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
      value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
      return value ^ (value >> 31)
    }

    func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(SSHError) {
      for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: next()) }
    }
  }
}
#endif
