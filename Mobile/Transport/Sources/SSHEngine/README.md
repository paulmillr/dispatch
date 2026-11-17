# SSHEngine

The Swift SSH client engine of Dispatch for iPhone (docs/ios.md, Transport): MobileTransport's engine, the default
and, unless the app is built with `DISPATCH_RUSSH=1`, the only one; such a build also has russh (`Core/`), the engine of
earlier versions, as a choice (Settings › Hosts › SSH engine, or `DISPATCH_SSH_ENGINE` in Debug builds). MobileTransport
runs on it when `SSHTransportEngine.preferred` is `.swift`, as it is unless set otherwise, through its adapter
(`Sources/MobileTransport/SwiftEngine*.swift`, `Mobile/Transport/README.md`). Security is the goal, not speed or
features: no package dependencies, Apple's frameworks for the cryptography (CryptoKit; CommonCrypto for AES-CTR and
key files' AES-CBC; Security for RSA and randomness), written by hand only where they offer nothing (Hand-written
cryptography, below). This file is the engine's spec; the code in `Wire/`, `Contract/`, `Policy/`, `Limits.swift` and
`SSHError.swift` is the contract and its doc comments state the invariants.

## Layers

```
 MobileTransport adapter              SwiftEngine*.swift: the seam (Engine.swift) over the facade, sockets for channels
 ─────────────────────────────────────────────────────────────────────────────────────────
 Facade (Contract/Client.swift)       SSHConnector, SSHSession, ExecChannel, ShellChannel; SSHClient.connector()
 Driver (Client/)                     ConnectionDriver: one owner of all connection state; stream, timers, questions
 ───────────────────────── sans-I/O core: synchronous, deterministic ─────────────────────
 ClientCore (Client/ClientCore.swift) the three layers below composed; the upper layers' phase into every poll
 Connection                           session channels: exec, PTY shell, window-change, exit status/signal
 Auth                                 SERVICE_REQUEST, none/password/publickey (queried, direct)/keyboard-interactive
   ↕ TransportLink (Contract/Transport.swift): send, sessionID, hostKey, serverExtensions, outboundBacklog, end
 Transport                            version exchange, framing, MessagePolicy, KEXINIT/negotiation, key exchange,
   ↕ TransportCore (driving side)      host key trust and pin, key derivation, NEWKEYS, EXT_INFO, keepalive, rekey
 Crypto                               PacketOpener/PacketSealer, KeyExchangeMethod, exchange hash, key derivation
 Keys                                 key files (OpenSSH, PEM) as UserKey, external signers, SSHSignatureVerifier
 Primitives                           ChaCha20, Poly1305, bcrypt_pbkdf, Blowfish
 Wire                                 WireReader/Writer, message numbers, reason codes, key/signature blobs
 ─────────────────────────────────────────────────────────────────────────────────────────
 ByteStream (Contract/ByteStream.swift): Network.framework TCP in the app (Client/NetworkStream.swift), MemoryByteStream
 in tests
```

### The sans-I/O split and who owns state

Everything between `ByteStream` and the facade is synchronous state machines: bytes, timer firings and answers in;
events and bytes out. No sockets, clocks, tasks, locks or callbacks inside. This is what makes the engine testable
and fuzzable without a network.

- **The driver** (`ConnectionDriver`, an actor; Swift 6 strict concurrency) is the only owner of a connection's
  `ClientCore`. Its read loop feeds the stream to `receive` (and stops reading while `readsPaused`: the outbound
  backlog above twice `Limits.outboundBacklogBytes`), then drains `poll` one event at a time; its write loop writes
  `takeOutbound()`, one write in flight at a time. It runs the timers the core asks for (`TimerRequest` of a
  `CoreTimer`: `keepalive`, `rekey`, `directAnswer`; one per kind, `schedule` replaces; keepalive and rekey may fire
  up to a twentieth of their delay late, at most 1 s, so wake-ups coalesce; one more than 60 s away sleeps in 60 s
  slices, because a cancelled `Task.sleep` keeps its wake-up job in the runtime until its time, and every connection
  cancels an hour's rekey timer at its end) and the handshake deadline itself (it
  spans the TCP connect and pauses while `HostKeyTrust` decides); awaits the trust callback, signers and prompts and
  feeds their answers back. Once the connection ended it cancels every timer and question, lets the last bytes (a
  DISCONNECT) leave within 2 s, and closes the stream.
- **One event at a time.** `ClientCore` polls the transport with the upper layers' current phase before every packet:
  `poll(service:)` decodes at most one packet and checks it against that phase, because each delivered message can
  change it (SERVICE_ACCEPT, then USERAUTH_SUCCESS, then channel data can arrive in one read).
- **Core objects are not `Sendable`** (`ClientCore` and its layers; `TransportCore`, `PacketOpener`,
  `KeyExchangeMethod`, `RandomSource` are `AnyObject` protocols): the compiler keeps them inside their owner. The
  facade types are `Sendable`.
- Randomness comes in through `RandomSource` (`SystemRandom`, `SecRandomCopyBytes`, in the app; `SeededRandom` in
  tests), so a core's output is reproducible. Ephemeral CryptoKit keys are made from its bytes.
- Failures inside the core never throw out of the driving calls: they become `TransportEvent.ended(SSHError)`,
  exactly once and last (a DISCONNECT may still be in `takeOutbound`).

## Rules

1. **Fail closed.** Every phase accepts an explicit list of message numbers (`Policy/MessagePolicy.swift`); anything
   else ends the connection with `ProtocolViolation.unexpectedMessage`. The engine never answers UNIMPLEMENTED (a
   deliberate deviation from RFC 4253 §11.4). The only "ignore" paths are IGNORE and DEBUG (refused in a strict
   initial exchange), banners, and the server's global requests and channel opens, which are refused as RFC 4254
   requires.
2. **Hostile input never crashes.** No trap, no force unwrap, no unchecked arithmetic on a server's value. Every
   length, count and depth has a named limit (`Limits.swift`) checked before allocation or use. `WireReader` cannot
   read past its end; `readCount` cannot promise more elements than the remaining bytes hold. Converting a wire
   `UInt32` uses `Int(exactly:)`.
3. **Sans-I/O core**, as above.
4. **Secrets** live in CryptoKit key types, Security's `SecKey` or `SecretBytes` (wiped with `memset_s` on release;
   `description` shows the size only). Passwords and keyboard-interactive answers arrive as `SecretBytes`; payloads
   holding them are built with `WireWriter.finishSecret` and sent with `TransportLink.send(secret:)`, whose plaintext
   copies the transport wipes. Key file bytes, passphrases, decrypted private fields, shared secrets and derived keys
   are `SecretBytes` or wiped scratch too. Nothing secret goes into an error, a description or a log. What this
   cannot reach: copies made before the bytes arrive (a `String`, the Keychain's `Data`), CryptoKit's and Security's
   own state, and Swift's copies of values and register or stack temporaries.
5. **No package dependencies**: Foundation, CryptoKit, CommonCrypto, Security, Network. Two primitives are Swift
   ports of OpenBSD's C (Hand-written cryptography, below), with their notices; no third-party code is linked.

## Errors

- `WireError` (typed throws) from `WireReader`, the blob codecs and `WireWriter.finish`. It carries sizes and validated
  names only. The layer that decoded a message wraps it: `InboundMessage.decode` gives
  `ProtocolViolation.malformed(number, error)`; Keys maps it to `SSHError.invalidKey`.
- `SSHError` (typed throws) from everything else and as a session's end. One case per outcome MobileTransport
  distinguishes; `dmsCode` names the C ABI's `DMS_*` code of the same outcome, and the adapter
  (`SwiftEngineErrors.swift`) maps each case to the `SSHTransportError` russh gives for that code (a refused channel
  open excepted: russh reports it as a protocol error). `ProtocolViolation` enumerates fixed conditions: add cases,
  never repurpose one.
- Key files: `wrongPassphrase`, `unsupported(<KeyFileRefusal>)` for what is refused on purpose (each with a fixed
  text, which the adapter turns into one that says what to do), `invalidKey(<KeyFileProblem>)` for the rest. No text
  comes from the file's bytes.
- Refusals are not errors: `AuthOutcome.refused(remaining:partialSuccess:)`, `.passwordChangeRequested`;
  `ChannelExit.refused`.
- Server text (DISCONNECT and open-failure descriptions, exit-signal messages) only through `DisplayText.sanitize`.
- The client's DISCONNECT reason comes from `SSHError.disconnectReason`.

## Wire decisions

Strictness beyond RFC 4251, each refused as malformed: a boolean other than 0 or 1; a non-minimal or negative mpint
(no value the engine reads is negative); a name that is empty, longer than 64 bytes, or not printable US-ASCII
without a comma; an empty element in a name-list; trailing bytes after a message's or blob's last field.

Text comes in two kinds. Text the engine compares, acts on or echoes back is strict UTF-8 (`readText`; names are
`readName`), and invalid UTF-8 is malformed. Text a server sends only for display never ends the connection for its
encoding (real servers send Latin-1 banners and PAM prompts): `readDisplayText` replaces invalid sequences, is still
bounded by its limit, and is shown through `DisplayText.sanitize` (or the app's prompt display). Display text is:
the userauth banner; keyboard-interactive name, instruction and prompts; the PASSWD_CHANGEREQ prompt; DISCONNECT and
DEBUG descriptions; CHANNEL_OPEN_FAILURE descriptions; exit-signal error messages; and every language tag, which is
read (`Limits.languageTagBytes`) and ignored. `PublicKeyBlob` and `SignatureBlob` decode canonically (re-encoding
gives the input back; the mutation test checks it), so blobs compare as keys. A certificate type is refused by name;
no certificate is ever decoded, so there is no nesting to bound.

## Message policy

`MessagePolicy.route(for:in:)` per packet, `Context` = transport phase × service phase × "first packet after the
first NEWKEYS" × EXT_INFO count. Summary (the tests hold the full table):

| Phase | Accepted |
| --- | --- |
| before the server's first KEXINIT | 1, 2, 4, 20 (a strict KEXINIT must then be packet 0: `checkFirstKexInit`) |
| initial exchange, strict | 1, then 31, then 21 |
| initial exchange, not strict | 1, 2, 4, then 31, then 21 |
| re-exchange past both KEXINITs | 1, 2, 3, 4, then 31, then 21; nothing of the upper layers |
| established (or our rekey KEXINIT sent) | 1, 2, 3, 4, 20, 81, 82, plus the service phase's |
| service not requested / requested | 7 only as the first packet after NEWKEYS and the first EXT_INFO; 6 once requested |
| userauth, no request out | 53 |
| userauth, request out | 51, 52, 53, 7 (up to 2 in all); 60 for password, publickey query, keyboard-interactive |
| connection | 80, 90-100 |

Global requests (80-82) are the transport's: it sends `keepalive@openssh.com` (after the login only), takes 81, 82 or an
UNIMPLEMENTED for it as the answer (checking one is outstanding), and refuses the server's requests. Channel numbers, replies with
nothing pending and the second EXT_INFO's place before USERAUTH_SUCCESS are checked by the layer that handles them.
This is stricter than russh: two EXT_INFOs back to back after NEWKEYS end the connection at the second.

## Algorithms and policy

`Contract/Algorithms.swift` names everything implemented; nothing else is offered or accepted.
`Policy/AlgorithmPolicy.swift` holds the order and one flippable constant, `truncatableModesRequireStrictKex`: without
strict key exchange, a connection whose mode in either direction is open to Terrapin's prefix truncation
(CVE-2023-48795) is refused: ChaCha20-Poly1305, and AES-CTR with an `-etm@openssh.com` MAC. AES-GCM and AES-CTR with
`hmac-sha2-256` or `hmac-sha2-512` (encrypt-and-MAC) are not affected and connect (the paper's Table 1, §4.4, and
terrapin-attack.com, cited in the code). `check` runs at every exchange before the method's first message; the refusal
names the mode ("chacha20-poly1305@openssh.com needs strict key exchange, which the server did not offer", "aes256-ctr
with hmac-sha2-256-etm@openssh.com needs …"). The order alone, with no wait for the server's KEXINIT, makes a server
without strict key exchange land on an allowed mode whenever it has one: AES-GCM, then AES-CTR with the plain MACs,
ChaCha20-Poly1305 last. So OpenSSH with OpenSSL stays on AES-GCM, Dropbear (no AES-GCM by default, old or new) uses
AES-CTR with `hmac-sha2-256`, and the hand-written ChaCha20 and Poly1305 run only against a server that offers neither
AES mode. Offered, in order:

- Key exchange: `mlkem768x25519-sha256`, `curve25519-sha256`, `curve25519-sha256@libssh.org`,
  `ecdh-sha2-nistp256`, `-nistp384`, `-nistp521`; the first KEXINIT's list ends with `ext-info-c` and
  `kex-strict-c-v00@openssh.com` (a re-exchange's leaves both out).
- Host keys: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `-nistp384`, `-nistp521`, `rsa-sha2-512`, `rsa-sha2-256`.
- Ciphers: `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`, `aes256-ctr`, `aes192-ctr`, `aes128-ctr`,
  `chacha20-poly1305@openssh.com`. MACs, for CTR only: `hmac-sha2-256`, `hmac-sha2-512`,
  `hmac-sha2-256-etm@openssh.com`, `hmac-sha2-512-etm@openssh.com`. Compression: `none` only.
- Refused by `Negotiation`: no common algorithm in a category, compression other than `none`, and a server KEXINIT
  with `first_kex_packet_follows`.

Host keys: `HostKey(algorithm:blob:)` validates the blob against the negotiated algorithm (a certificate type is
refused); the transport verifies the exchange's signature with it before the trust callback sees it. `fingerprint`
and `openSSH` are what the trust sheet and known-hosts store use. `HostKeyPin.check(algorithm:blob:)` is the rekey
rule, run on the raw blob before decoding: another algorithm or another blob is `hostKeyChangedAtRekey`, with the
russh engine's texts; the signature is then verified with the trusted key.

## Hand-written cryptography

Each exists because no Apple framework offers it; each states its constant-time properties in its doc comment, as
properties of the source (Swift promises nothing about the machine code, and no compiled-code check is made).

- `Primitives/ChaCha20.swift` and `Primitives/Poly1305.swift` (RFC 8439; Poly1305's arithmetic ported from
  poly1305-donna's 32-bit form, 26-bit limbs, which its author offers as MIT or public domain): `chacha20-poly1305@openssh.com` (`Crypto/ChaChaPoly.swift`, OpenSSH's PROTOCOL.chacha20poly1305: a header
  key for the length, the original 64-bit nonce layout, Poly1305 over the encrypted length and ciphertext), which
  CryptoKit's RFC 8439 AEAD is not; and key files encrypted with that cipher. Constant time in the source: add, xor,
  rotate, masks, no data-dependent branch or index. Tested against RFC 8439's vectors; the original layout against
  StableLib's streams and libsodium's across the 2^32 counter boundary; Poly1305 against StableLib's vectors and a
  slow big-integer reference at the reduction's edges; the assembled RFC AEAD against StableLib's and Wycheproof's
  vectors (`testvectors_v1`, its nonce-size cases refused) and CryptoKit's `ChaChaPoly` (30,000 random cases per
  run); and the cipher against sshd. The third-party vectors (from noble-ciphers 2.4.0, and Wycheproof's file) are
  in `Tests/SSHEngineTests/Primitives/Vectors/`, unchanged, with their origins and licences.
- `Primitives/BcryptPBKDF.swift` and `Primitives/Blowfish.swift` (Swift ports of OpenBSD's `bcrypt_pbkdf.c`, ISC
  license, and of the cipher and key schedules of its libc `blowfish.c`, BSD 3-clause; their notices are in
  `THIRD_PARTY_NOTICES.md` and `Mobile/ThirdPartyLicenses/SSHEngine/`): the KDF of passphrase-protected `openssh-key-v1` files, run only on a file the user
  imports, on the device. Not constant time, by design (S-box lookups indexed by key-dependent bytes); never on
  network data. Rounds bounded by `Limits.keyFileBcryptRounds`. Tested against Eric Young's Blowfish vectors,
  pyca/bcrypt's `bcrypt_pbkdf` vectors and ssh-keygen as an oracle.
- `Keys/RSAArithmetic.swift`: x mod m by binary long division, for the d mod (p - 1) and d mod (q - 1) that
  Security's PKCS#1 import needs and `openssh-key-v1` does not carry. Only on an imported key file. Trip counts
  depend on the operands' lengths only, the conditional subtraction is a mask; every imported RSA key signs and
  verifies once (`RSAKeys.checkPair`). Tested against UInt128 arithmetic and against OpenSSL's values for real keys
  (`KeygenOracleTests`).
- Parsers, not cryptography, also by hand: the wire codec, PEM armor and base64, DER (`Keys/DER.swift`: no Apple API
  reads PKCS#8's envelope or SEC1 with explicit curve parameters).

## Limits

All in `Limits.swift`, each commented. Shared with the russh engine (docs/security.md): packet length 256 KiB checked
from the length field alone; at most 2 EXT_INFO; a channel whose server announces a maximum packet size of 0 fails to
open, and the connection ends with it (`peerMinimumPacket`); certificates refused (by name, so no nesting bound). The
engine's own: name 64 bytes, name-list 8 KiB / 128 names, EXT_INFO 64 extensions of at most 8 KiB each (russh took
10,000), key exchange values 2 KiB, host and user key blobs and signatures 4 KiB, RSA 2048 to 16384 bits with an
exponent of at most 8 bytes, version line 255 bytes after at most 64 other lines, keyboard-interactive 32 prompts and 32
rounds, banners, prompts and DISCONNECT and DEBUG descriptions 16 KiB, channel-open failure descriptions and
exit-signal messages 1 KiB (`channelMessageBytes`), language tags 256 bytes, 64 channels, 2 MiB window, 32 KiB
maximum packet, 256 KiB of unsent input per channel, 1 MiB outbound backlog, rekey after 1 GiB, 2^31 packets or an hour,
direct answer 10 s, a keepalive count of at most 100 (the connection ends when a keepalive falls due with that many
unanswered); key files 64 KiB, at most 1024 bcrypt rounds, salts of at most 64 bytes.

## Directories

| Directory | Scope |
| --- | --- |
| `Wire/`, `Contract/`, `Policy/`, `Limits.swift`, `SSHError.swift` | the contract: codecs, the facade's and the layers' protocols and types, the message and algorithm policies, the limits, the errors; changes are additive (an error case, a limit) |
| `Primitives/` | ChaCha20, Poly1305, bcrypt_pbkdf and its Blowfish |
| `Crypto/` | packet protection (AES-GCM, ChaCha20-Poly1305, AES-CTR with HMAC, the plaintext pair), key exchange methods, the exchange hash, key derivation |
| `Transport/` | version exchange, framing, KEXINIT and negotiation, `ClientTransport` (the `TransportCore`): exchanges, the pin, EXT_INFO, keepalive, rekey |
| `Keys/` | key files (`KeyFile.parse`: `openssh-key-v1`, passphrase via bcrypt_pbkdf; unencrypted PEM and PKCS#8; armor, DER, the files' ciphers), `FileKey`, fingerprints and `authorized_keys` lines for user keys, external signers (Ed25519 64 bytes, ECDSA r‖s, to signature blobs), RSA through Security, `SSHSignatureVerifier` (host key signatures) |
| `Auth/`, `Connection/` | userauth and channel state machines against `TransportLink`, tested with `FakeTransportLink` |
| `Client/` | `ClientCore` (the composed core), `ConnectionDriver`, the facade's implementation (`SSHClient.connector()`, `Session.swift`), Network.framework's `StreamConnector` (`NetworkStream.swift`) |

Tests mirror the directories under `Tests/SSHEngineTests/`, plus `Parity/` (below). `Support/` is shared:
`MemoryByteStream.pair()` and `MemoryConnector`, `SeededRandom`, `FakeTransportLink`, `Raw` (hand-built encodings),
`Fixture` (fictional key bytes), `XCTAssertThrows` for typed errors, `ScriptedServer` (an in-memory server built from
the engine's own transport pieces), `LoopbackServer` (it on a loopback port), `TransportHarness`, `LiveSSHD` (a
private `/usr/sbin/sshd`).

## Notes per layer

- **Transport.** The framer checks `packet_length` against `Limits.packetLength` and the alignment before reading
  more, and wipes a sealed packet's plaintext when it came from `send(secret:)`. Nothing is decoded while the trust
  callback decides, and NEWKEYS (ours) leaves only after `answerHostKey(trusted: true)`. Strict key exchange resets
  both sequence numbers at every NEWKEYS; any wrap ends the connection. A re-exchange offers the same lists, so a
  different negotiated host key algorithm is reported as a host key change (the pin), not a negotiation failure. Our
  re-exchanges (limits, the timer) wait for the connection phase (OpenSSH's sshd cannot take a KEXINIT before
  authentication); one the server starts is taken in any phase. `server-sig-algs`' value is the bare comma list, as
  OpenSSH sends it. `KeyExchangeOutput.encodedSharedSecret` is K as hashed: mpint for ECDH and X25519, string for
  mlkem768x25519. Keepalives start with the connection phase (after USERAUTH_SUCCESS; no keepalive timer before
  it): RFC 4252 §6 makes a message of 80 or more before authentication an error the server must disconnect for, and
  Dropbear does; russh and OpenSSH's client start them once logged in too. Before the login only the handshake
  deadline (to the first exchange) and a direct key's answer deadline bound a dead link. An UNIMPLEMENTED naming a
  keepalive's sequence number answers it. Keepalive timing is the russh engine's and OpenSSH's `ServerAliveCountMax`: a keepalive
  falls due after each interval of silence, and one falling due while `keepaliveCountMax` are already unanswered ends
  the connection instead, so a silent server is given up after (count + 1) × interval (60 s at 15 s × 3, up to the
  timers' tolerance later); any packet resets the count. A keepalive falling due with 100 outstanding (a server that
  talks but never answers them) ends it too. The identification line may be `SSH-2.0-` or `SSH-1.99-` (RFC 4253
  §5.1; 1.99 is taken as 2.0); anything else is `.version(.notSSH2)`.
- **Keys.** `PublicKeyBlob` decodes and encodes public blobs (the private section of `openssh-key-v1` has its own
  field order, RSA's n before e). Every type the engine signs is in `SignatureAlgorithm`; RSA signs rsa-sha2-512 or
  -256, never ssh-rsa. Key file bytes and passphrases arrive as `SecretBytes`; private fields are read with
  `readSecretString` and `readSecretMPInt` into wiped memory. An external signer's signature is checked against its
  public key before it is sent.
- **Auth.** The phase goes to the policy through `MessagePolicy.ServicePhase`/`UserauthWait` (`ClientCore` passes it
  to `poll`). A direct publickey request sends SERVICE_REQUEST and the signed USERAUTH_REQUEST back to back; for RSA
  it waits until `serverExtensions` is non-nil (the first packet after NEWKEYS, no round trip) to pick the hash.
  `.directAnswer` is scheduled when the direct request leaves (after the signature); on it,
  `end(.timedOut(.directAnswer))`. A connection that ends while a request is pending ends the attempt with the
  connection's error (`closed` when it closed), with one exception, the server's attempt limit: an asked-for request
  (password, keyboard-interactive answers, a key's query or signature; never a direct key) on the wire when the server
  ended the connection with a DISCONNECT, or closed it after refusing an earlier attempt on it, ends as
  `.refused(remaining: [])` (OpenSSH sends "Too many authentication failures", Dropbear just closes; the text stays in
  the connection's end). The app then shows a failed login instead of reconnecting to submit it again; a drop before
  any refusal stays `closed`. Global requests are the transport's. Banners,
  keyboard-interactive texts, the password-change prompt and exit-signal messages are display text
  (`readDisplayText`): a Latin-1 prompt shows replacement characters and the login goes on; the user name sent and
  anything compared stay strict.

## Not supported, deliberately

Server mode; more than one connection per session; compression; finite-field Diffie-Hellman; `ssh-rsa` (SHA-1)
signatures, DSA, security keys (`sk-*`); host and user certificates; CBC ciphers and SHA-1 MACs; port forwarding,
X11, agent forwarding, subsystems, `env` requests, terminal modes; password change; hostbased and GSSAPI logins;
PuTTY PPK, encrypted PEM and PKCS#8, and ssh.com key files; `3des-cbc` and KDFs other than bcrypt in `openssh-key-v1`
files; answering UNIMPLEMENTED; SSH-1.

## Tests

```sh
cd Mobile/Transport && swift test --scratch-path ../../build/spm --filter SSHEngineTests
```

Per directory: the wire codec against hand-built RFC encodings and hostile ones (truncations, lengths past the end or
the limit, `UInt32.max` counts, non-minimal and negative mpints, invalid names, strict and lenient UTF-8), key and
signature blobs and their bounds, and deterministic mutation loops (server payloads through every decoder and the
policy; everything a server sent in a recorded session; userauth messages in each phase: no trap, canonical round
trips); the policy as a full 256-number table per phase, including the direct-login orders of `Core/tests/hostile.rs`;
the algorithm policy; the primitives (above); packet protection, key exchange methods, the exchange hash and key
derivation recomputed from their definitions; the transport against the scripted server (every method, cipher and
MAC, strict or not, re-exchanges, keepalives, hostile servers); userauth and channels against `FakeTransportLink`
(exact bytes, flow control, hostile servers); key files built in-process and by `ssh-keygen` (every type, format and
cipher it writes, hostile files), signatures cross-checked with `ssh-keygen -Y` and openssl; the composed core and
the driver in memory; host key fingerprint and pin; error codes and texts; the in-memory stream's contract.

Against the macOS `/usr/sbin/sshd` (private instances on loopback, skipped when sshd cannot start):
`SSHDInteropTests` (every key exchange method, cipher, MAC and host key type, re-exchanges both ways while data
streams; `SSHENGINE_SSHD_FULL=1` for the full cross product) and `LiveClientTests` (the whole engine through
`SSHClient.connector()`: every user key kind, asked and direct, exec and shell, megabytes with slow readers, many
channels, re-exchanges under load, keepalives, a network cut or frozen by `LoopbackRelay`).

`Robustness/` replays whole sessions into `ClientCore` with seeded corruption: the scripted server's sessions
(`RobustScenarios`: every key exchange method and cipher family, each MAC with AES-CTR, every login method, exec,
shells, re-exchanges both ways, keepalives, strict and not) are recorded as what the server sealed, sealed again with
the payloads changed (bits, length fields, message numbers, cuts, duplicates, drops, moves, messages of other phases)
or the wire bytes changed (bits, bytes, length fields, insertions, deletions, packets duplicated, dropped, swapped,
truncation), and each case must end with one `.ended(SSHError)` within bounded steps and buffers, never report a host
key, an established session or a login unless the recorded exchange verified, act on nothing the integrity check did
not pass, and show no secret in an error (`SessionReplayTests`' comment has the bounds). 25,000 cases and every fifth
truncation offset by default; `SSHENGINE_ROBUST_CASES=1000000` is the long mode (every offset too),
`SSHENGINE_ROBUST_SEED` the master seed, `SSHENGINE_ROBUST_CASE=<seed>` replays one case.

`Parity/` drives MobileTransport's public API: `EngineParityTests` restate `Core/tests/engine.rs` against the
scripted server on a loopback port, on the engine `SSHTransportEngine.preferred` names (this one unless a
`DISPATCH_RUSSH=1` build names russh with `DISPATCH_SSH_ENGINE=russh`), so both engines pass the same cases; `ScriptedSessionTests` cover what the API cannot reach, chiefly a
re-exchange the client starts during a session.

`Interop/` runs the build's engines (this one; russh too with `DISPATCH_RUSSH=1`) against Dropbear and OpenSSH,
current and older releases, in a Linux VM
(`scripts/ssh-interop-vm.py`, docs/vm_testing.md, "Swift SSH interop servers") and skips without its profile. Against
servers without strict key exchange (OpenSSH 9.5p1 and 8.9p1 settle on AES-GCM, Dropbear 2022.83 on AES-CTR with
`hmac-sha2-256`) every case passes; a client constrained to ChaCha20-Poly1305 or CTR-EtM is refused. OpenSSH 7.9p1
built without OpenSSL fails its own AES-CTR (it closes the connection after the negotiation; OpenSSH's client gets the
same), and its ChaCha20-Poly1305 is refused, so the Swift engine cannot use it; the tests record that and the two
documented Dropbear 2022.83 bugs (`KnownServerBug`) instead of failing.
