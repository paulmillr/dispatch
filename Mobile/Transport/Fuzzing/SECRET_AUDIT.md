# SSHEngine secret lifetime audit

Audited 2026-11-17. This follows the Swift engine's deliberate in-memory
representations. It cannot account for compiler-created stack/register spills or
copies inside CryptoKit, CommonCrypto, Security.framework, Foundation, or the
app's UI and Keychain implementations.

Path convention: `Contract/`, `Crypto/`, `Keys/`, `Transport/` and similar paths
are relative to `Mobile/Transport/Sources/SSHEngine`; paths beginning `Sources/`
or `Tests/` are relative to `Mobile/Transport`.

`SecretBytes` owns an allocation, never prints its contents, and uses
`memset_s` before freeing it (`Contract/SecretBytes.swift:10-55`). The array and
`Data` helpers also use `memset_s`, but are effective only for uniquely owned
storage (`Contract/SecretBytes.swift:58-65`).

## Lifetime traces

### Shared secret and derived traffic keys

1. Ephemeral private randomness starts in `SecretBytes`. X25519, NIST ECDH and
   ML-KEM then import it into framework private-key objects
   (`Crypto/KeyExchangeMethods.swift:76-80,162-190,251-263`).
2. The exchange object retains those private-key objects only until it processes
   the reply, then clears its property before deriving the shared value
   (`Crypto/KeyExchangeMethods.swift:122-129,200-223,271-290`).
3. CryptoKit's `SharedSecret`/`SymmetricKey` is copied directly into an encoded
   `SecretBytes` (`Crypto/KeyExchangeMethods.swift:84-96,209-223,281-290`).
4. Key derivation reads K directly, writes each result into `SecretBytes`, and
   wipes its raw digest scratch allocation (`Crypto/KeyDerivation.swift:10-55`).
5. The transport imports those direction keys into its ciphers and MACs
   (`Transport/ClientTransport.swift:532-559`). The `SecretBytes` values wipe on
   last release; CryptoKit/CommonCrypto retain their internal key schedules until
   the packet protectors are replaced at rekey or the connection is destroyed.

Copies that Swift cannot wipe are CryptoKit's private keys and shared-secret
objects (`Crypto/KeyExchangeMethods.swift:76-96,145-223,244-289`), ML-KEM's
private key and result (`Crypto/KeyExchangeMethods.swift:244-289`), CryptoKit
hash state/digests (`Crypto/Hashing.swift:4-5,23-59`), `SymmetricKey` traffic and
MAC keys (`Crypto/AESGCM.swift:38-45,73-80`, `Crypto/AESCTR.swift:47-55`), and
CommonCrypto's internal AES schedule until `CCCryptorRelease`
(`Crypto/AESCTR.swift:11-27`). Removing those copies would require replacing the
platform crypto implementations with primitives whose storage and optimizer
behavior the package controls.

### Private keys, key files, and passphrases

1. The public adapter accepts caller-owned key-file `Data` and either a `String`
   or caller-owned passphrase `Data` (`Sources/MobileTransport/SSHKey.swift:39-50`).
   Its temporary NUL-terminated C array is wiped after parsing
   (`Sources/MobileTransport/SSHKey.swift:51-56`). The Swift backend copies the
   file and passphrase into `SecretBytes`
   (`Sources/MobileTransport/SwiftEngine.swift:61-69`).
2. Armor base64 scratch is wiped and decoded DER/body bytes are returned as
   `SecretBytes` (`Sources/SSHEngine/Keys/Armor.swift:109-151`). PEM parsing uses
   a temporary full-DER array that is wiped on return
   (`Sources/SSHEngine/Keys/PEMKeyFile.swift:30-40`).
3. OpenSSH parsing keeps the encrypted section and decrypted plaintext in
   `SecretBytes`; bcrypt output is an array wiped on every exit, and the temporary
   full plaintext array is wiped on return
   (`Sources/SSHEngine/Keys/OpenSSHKeyFile.swift:28-56`). AES-GCM's `Data`
   plaintext is explicitly wiped (`Sources/SSHEngine/Keys/KeyFileCipher.swift:85-97`).
4. Ed25519 seeds, EC scalars and RSA private integers are extracted as
   `SecretBytes` (`Sources/SSHEngine/Keys/OpenSSHKeyFile.swift:132-173`,
   `Sources/SSHEngine/Keys/PEMKeyFile.swift:73-84,118-143`). Temporary PKCS#1
   import memory is wiped (`Sources/SSHEngine/Keys/RSAKeys.swift:12-25`).
5. After parsing, the returned `FileKey` retains only a CryptoKit private key or
   Security `SecKey` (`Sources/SSHEngine/Keys/FileKey.swift:5-23`). It lives until
   that `FileKey` and all references to it are released.

Copies not owned or wipeable by the engine are the input `Data` and passphrase
`String`/`Data` (`Sources/MobileTransport/SSHKey.swift:39-50`), CryptoKit private
keys (`Sources/SSHEngine/Keys/FileKey.swift:9-15`), and Security's internal copy
inside `SecKey` (`Sources/SSHEngine/Keys/RSAKeys.swift:4-6,22-25`). The bcrypt
implementation also uses CryptoKit SHA state/digest values that Swift cannot
wipe (`Sources/SSHEngine/Primitives/BcryptPBKDF.swift:18-20`). Avoiding the first
set requires a secret-owning app API and UI/Keychain integration; avoiding the
framework copies requires different crypto implementations.

### Passwords and keyboard-interactive answers

1. The public API receives a password `String` or answer `[String]`
   (`Sources/MobileTransport/SSHCredential.swift:28-30`). The backend immediately
   makes `SecretBytes`, but the original strings cannot be wiped
   (`Sources/MobileTransport/SwiftEngine.swift:99-102,112-124`).
2. A password remains in `SecretBytes` in both the driver credential and auth
   attempt until the attempt finishes (`Sources/SSHEngine/Client/ConnectionDriver.swift:185-207,265-270`,
   `Sources/SSHEngine/Auth/UserauthCore.swift:56-66,192-195,477-483`). Answers
   remain in `SecretBytes` through the synchronous response send
   (`Sources/SSHEngine/Auth/UserauthCore.swift:119-130`).
3. The wire writer reserves its final capacity, turns its buffer into
   `SecretBytes`, and wipes the writer array
   (`Sources/SSHEngine/Wire/WireWriter.swift:27-36`). Authentication always uses
   that path (`Sources/SSHEngine/Auth/UserauthCore.swift:416-447`).
4. During key exchange, a secret payload may remain as `Held.secret`; otherwise
   it is sealed immediately (`Sources/SSHEngine/Transport/ClientTransport.swift:73-86,304-329`).
   The padded plaintext packet is wiped after sealing
   (`Sources/SSHEngine/Transport/Framer.swift:117-136`).

The non-wipeable copies are the app-facing strings and any UI/framework copies
that created them. The driver deliberately retains the password until the server
answers because the `Credential` represents the in-flight attempt. Shortening
that lifetime would require separating the responder/signer retained by the
driver from the password value, plus changing the public API to accept a
wipeable secret type.

### Plaintext packets and channel data

The inbound framer wipes the authenticated full-packet plaintext after making
the payload (`Sources/SSHEngine/Transport/Framer.swift:78-88`). AES-GCM now also
wipes its temporary `Data` plaintext (`Sources/SSHEngine/Crypto/AESGCM.swift:56-70`),
and AES-CTR encrypt-and-MAC now wipes its full temporary plaintext on both success
and failure (`Sources/SSHEngine/Crypto/AESCTR.swift:139-155`). The outbound
framer wipes its padded plaintext packet (`Sources/SSHEngine/Transport/Framer.swift:117-136`).

The following plaintext copies are ordinary arrays and are not wiped:

- the payload copy returned by the framer and retained by `InboundMessage`
  (`Sources/SSHEngine/Transport/Framer.swift:88`,
  `Sources/SSHEngine/Contract/Transport.swift:42-53`);
- decoded channel output, early output, and queued events
  (`Sources/SSHEngine/Connection/ConnectionCore.swift:285-312,415-438,600-610`);
- driver output queues returned to the application
  (`Sources/SSHEngine/Client/ConnectionDriver.swift:287-334`);
- application input, pending driver writes, the connection core's input queue,
  normal `WireWriter` payloads, and transport rekey backlog
  (`Sources/SSHEngine/Client/ConnectionDriver.swift:275-284,306-307`,
  `Sources/SSHEngine/Connection/ConnectionCore.swift:60-80,433-438,500-519`,
  `Sources/SSHEngine/Transport/ClientTransport.swift:73-86,297-335`);
- exec commands and terminal names, which are `String`
  (`Sources/SSHEngine/Connection/ConnectionCore.swift:399-402`).

Wiping those safely is not a local change: Swift array copy-on-write means a
wipe may only clear a newly made copy while another owner retains the original.
It would require secret-aware, move/borrow-style byte buffers through the public
channel API, decoder, event queues and transport. That is a protocol-neutral but
source/API-level redesign, so it was not attempted here.

## Errors and logs

`SecretBytes.description` prints only its byte count
(`Contract/SecretBytes.swift:49`). Production SSHEngine has no logger or print
calls. Protocol errors contain bounded server display/description text or fixed
reasons, never a formatted secret; the robustness suite checks candidate secret
texts against error descriptions
(`Tests/SSHEngineTests/Robustness/SessionReplayTests.swift:242-251,392-398`). OS
network errors may contain OS-provided text (`Sources/SSHEngine/Client/NetworkStream.swift:61-68,145`),
not SSH plaintext. Fuzz-only `preconditionFailure` messages interpolate typed
setup errors but use only fictional constant credentials
(`Sources/SSHEngine/FuzzingSupport.swift:18-74`).

## Changes made during this audit

- Wipe AES-GCM's successful-open `Data` scratch before it is released
  (`Sources/SSHEngine/Crypto/AESGCM.swift:58-69`).
- Wipe AES-CTR encrypt-and-MAC's full plaintext scratch on successful opens as
  well as failed authentication (`Sources/SSHEngine/Crypto/AESCTR.swift:139-155`).

Both preserve the existing packet-cipher and protocol behavior.
