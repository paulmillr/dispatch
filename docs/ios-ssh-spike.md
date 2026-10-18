Decision (2026-10-18, orchestrator): the first round failed requirement 2 (with swift-nio-ssh plus Citadel, RSA keys cannot log in to a default OpenSSH and keyboard-interactive does not exist), so per the plan the transport engine is Rust `russh` 0.64.1 behind a C ABI. Citadel's swift-nio-ssh fork is out (it lacks Apple's July 2026 pre-auth ECDSA parsing fix), and Apple's own swift-nio-ssh has neither RSA user keys nor keyboard-interactive. With russh every requirement below passes.

# iPhone SSH transport spike (Phase 0, item 1 and the transport half of item 2)

Date: 2026-10-18. Branch `mobile-streams/ssh-spike`. Code: `Mobile/Transport` (Swift package
`MobileTransport`, the public API) and `Mobile/Transport/Core` (Rust crate `dispatch-mobile-ssh`, the engine).
Numbers come from `swift test` on an Apple Silicon Mac against a loopback OpenSSH 10.3 sshd (LibreSSL 3.3.6)
running as the current user, with its default algorithm policy, plus `xcodebuild test` in an iOS 27 simulator
against the same kind of sshd on the Mac. Loopback numbers are CPU-bound upper limits.

## Results (russh engine)

| # | Requirement | Result | Evidence | Numbers |
| --- | --- | --- | --- | --- |
| 1 | Connect; host key through a delegate with algorithm, key blob and `ssh-keygen -lf` fingerprint; trust on first use; a mismatch rejects | Pass | `HostKeyTests` (3); Rust `host_key_reports_keygen_fingerprint`, `rejected_host_key_fails_connect_without_disconnect` | |
| 2a | ED25519, ECDSA P-256/384/521 and RSA keys from OpenSSH files (`Data`), plain and passphrase-encrypted, parsed in Rust | Pass | `AuthenticationTests.testED25519`, `testECDSA`, `testRSA`, `testWrongOrMissingPassphrase`; Rust `key_files_of_every_type`, `wrong_or_missing_passphrase` | |
| 2b | RSA signs rsa-sha2-512/256 only, never ssh-rsa, under OpenSSH 10.3's default policy | Pass | `testRSA` (default policy), `testRSANeverSignsSHA1` (a server accepting only ssh-rsa refuses us) | |
| 2c | Password | Pass | Rust `password` and `keyboard_interactive_and_password_through_the_c_abi` (in-process russh server); `testCredentialsFallThrough` (OpenSSH refuses it, the next credential is tried) | A user-owned sshd cannot check passwords (no PAM, no root) |
| 2d | Keyboard-interactive with a prompt callback (name, instruction, prompts with echo flags → responses) | Pass | Rust `keyboard_interactive_two_rounds`, `keyboard_interactive_cancel`, `…_through_the_c_abi` (two rounds: hidden password, echoed code) | Same PAM limit for OpenSSH; `testCredentialsFallThrough` covers the refusal path |
| 2e | External signer: CryptoKit and Secure Enclave keys sign in Swift; private keys never cross the FFI | Pass | `testCryptoKitKeys` (P-256, Ed25519), `testSecureEnclaveP256` (real enclave on this Mac), `testSignerFailureIsCancelled`; Rust `external_signer` (Ed25519, P-256, P-384) | |
| 3 | Exec channel: socketpair fd with backpressure and EOF/close both ways, stderr, exit status; `uname`; 50 MiB each way | Pass | `ExecTests` (3), `MeasurementTests`, Rust `exec_over_socketpair` | Upload 50 MiB into `cat > file` (SHA-256 checked): 462 to 478 MB/s. Download `yes \| head -c 50M`: 438 to 509 MB/s. A reader paused 1 s with 50 MB pending: +2.7 to +3.3 MB resident |
| 4 | Bootstrap over an exec channel (shared `SSHBootstrapScript` shell, size and SHA-256 checked on the host) | Pass | `BootstrapTests` (4), real helper | Real 16.1 MB helper: upload 0.15 s, cached check 56 to 59 ms |
| 5 | Helper `--stdio` channel consumed by the unmodified `HelperConnection`/`HelperTransport` | Pass, real helper | `HelperBridgeTests` (3): `hello` with the full iPhone profile (65 ops), `multiplexers.list` (tmux, native, herdr), EOF shutdown with status 0 | Open + hello 226 to 406 ms (includes re-hashing the 16 MB file); `cat` echo 24 MiB both ways at once: 229 to 234 MB/s per direction |
| 6 | `HostConnection` state machine, `SSHReconnect` backoff, retry hook, cancellation, fake clock | Pass | `HostConnectionTests` (9) | Reconnect after a drop 1.05 to 1.09 s (1 s policy delay) |
| 6b | Keepalives; a dead connection surfaces as a disconnect | Pass | `KeepaliveTests` (server processes frozen with SIGSTOP: socket open, silent) | Detected after 2.9 s with keepalive 1 s × 2 |
| 7 | Swift 6 strict concurrency; public types Sendable or actors | Pass | Swift 6 language mode; `ConcurrencyTests` | |
| 8 | Connect + auth latency; idle connection memory | Measured | `MeasurementTests.testConnectLatencyAndIdleMemory` | ED25519, 20 runs: median 28 to 39 ms (handshake 12 to 14 ms, auth 16 to 25 ms). Idle connection: 127 KB heap, 122 KB resident each |
| iOS | The iPhone build: package in the simulator against the Mac's sshd; `DispatchMobile` linked | Pass | `SimulatorTests`, `SimulatorHelperTests` (iOS 27 simulator, `scripts/mobile-ssh-fixture.py`); `xcodebuild build -scheme DispatchMobile` for the simulator | Simulator: connect + auth median 45.7 ms, `cat` echo 32 MiB both ways 186 MB/s per direction, helper bootstrap + hello pass |

Test counts: `swift test` 37 tests, 0 failures, 0 skipped (MobileTransportTests 34 in 11.6 s, HelperBridgeTests 3
in 1.7 s; 17.4 s wall). `cargo test` (Core) 10 tests in 3.5 s. Simulator: 11 tests (the platform-neutral ones
plus the two simulator cases), 0 failures.

Compared with the first round (swift-nio-ssh): throughput is about the same (NIO 460 to 680 MB/s debug),
connect + auth is 5 to 15 ms slower (auth 16 to 25 ms against 7 to 9 ms), and an idle connection costs about
10 times the memory (127 KB against 12 KB heap). Neither matters for a handful of hosts. The auth gap is not
investigated; it is constant per connect.

## The engine

`Mobile/Transport/Core`: its own cargo workspace (crate `dispatch-mobile-ssh`, staticlib plus rlib for tests),
outside `helper/`. `helper/Cargo.lock` has 11 packages, all the helper's own (no `source =` entries): the helper
stays free of third-party crates, and third-party Rust enters only here.

- russh 0.64.1 with `default-features = false, features = ["ring", "rsa"]`. ring rather than aws-lc-rs:
  no cmake; ring's C and assembly cross-compile for iOS with Xcode's clang through `cc` (an explicit SDK per
  target). 125 crates ship (`cargo tree -e normal --target aarch64-apple-ios`), pinned in `Cargo.lock`. Two are
  release candidates that russh pins exactly: `ssh-key 0.7.0-rc.11`, `rsa 0.10.0-rc.18`.
- One tokio runtime, two workers, for every session.
- Toolchain: the pinned Rust 1.98.1 (`scripts/setup-ssh-rust.py`), whose TARGETS now include
  `aarch64-apple-ios` and `aarch64-apple-ios-sim` (same pinned manifest, SHA-256 verified; 55 MB more). Every
  checkout must run `python3 scripts/setup-ssh-rust.py` once after this lands, or the helper build's offline
  toolchain check fails on the missing iOS targets.
- Crates: `python3 scripts/build-mobile-ssh.py --fetch` downloads them into `build/cargo` once (the network
  step); every build is `cargo build --offline --frozen`.
- `scripts/build-mobile-ssh.py` builds release static libraries for `aarch64-apple-ios` (iOS 26),
  `aarch64-apple-ios-sim` and `aarch64-apple-darwin` (macOS 14, for `swift test`), about 45 s cold and 40 MB
  each (unstripped archives), and wraps them with the checked-in header and module map into
  `build/mobile-ssh/DispatchMobileSSHCore.xcframework`. It runs in a minimal environment so Xcode's build
  settings cannot leak into ring's C build (that is what broke the first Xcode build). There is no x86_64
  simulator or Intel Mac slice.
- The Swift package uses it as a binary target through the committed symlink `Mobile/Transport/Frameworks` →
  `build/mobile-ssh`, so the XCFramework must exist before SwiftPM or Xcode resolves the package (a setup step).
  No system frameworks are needed at link time.

### C ABI (`Core/include/dispatch_mobile_ssh.h`, hand-written)

Opaque handles (`dms_session`, `dms_key`, `dms_reply`), and a context pointer on every callback. Each operation
documents its last callback, after which the context is never used again; Swift passes retained boxes and
releases them there.

- `dms_connect(options, {context, host_key, disconnected}, context, connected)`: the host key callback receives
  algorithm, blob, SHA256 fingerprint and OpenSSH line, and is answered later through `dms_reply_bool`, so the
  trust-on-first-use sheet can take as long as the user needs (the handshake deadline pauses meanwhile).
  `disconnected` fires exactly once for a connected session (lost, keepalive timeout, remote disconnect,
  close); it is triggered by russh dropping the handler, so no ending is missed.
- Auth, each with one `done(code, remaining_methods, partial)`: `dms_auth_password`; `dms_auth_key` with a
  `dms_key` from `dms_key_parse(data, passphrase)` (OpenSSH or PEM files; RSA signs rsa-sha2-512, or -256 when
  that is all the server lists, never ssh-rsa); `dms_auth_keyboard_interactive` with a prompt callback answered
  by `dms_reply_strings` or `dms_reply_cancel`; `dms_auth_signer` with the SSH public key blob and a sign
  callback answered with the raw signature (Ed25519 64 bytes, ECDSA r‖s), which Rust encodes.
- `dms_exec(session, command, context, started(fd), stderr(bytes), exited(kind, status, signal))`: `fd` is the
  caller's end of a socketpair (stdin writes, stdout reads; 1 MiB socket buffers; `SO_NOSIGPIPE`). Rust pumps
  channel ↔ socket: it reads the socket only as fast as the SSH window allows and the channel only as fast as
  the socket drains; `shutdown(SHUT_WR)` sends EOF, the remote's EOF half-closes the socket, and closing the
  socket closes the channel once the remote writes again.
- Keepalives: `keepalive_interval_ms` and `keepalive_max` in the options (Swift defaults: 15 s × 3).

### Swift API (same shape as the first round)

`SSHConnection`, `SSHEndpoint`, `SSHCredential` (`.key`, `.password`, `.keyboardInteractive`, which now works),
`SSHKey` (`openSSH(_:passphrase:)`, `init(ed25519:)`, `init(p256:)`, `init(secureEnclave:)`, and
`init(kind:publicKeyBlob:hardwareBacked:sign:)` for any Keychain-held key; kinds now include P-384 and P-521),
`HostKeyInfo`, `HostKeyTrust`, `TrustOnFirstUse`, `SSHExec`, `SSHCommandResult`, `HelperBootstrap`,
`HelperChannel`, `SSHHostSession`, `HostConnection` and its state, `SSHTransportError` (new cases: `cancelled`,
`network`, `protocolError`). Changes: `SSHConnection.Timings` is `handshake` + `authentication`; `connect`
takes `keepalive` and `keepaliveMax`; `SSHConnection.endReason` says why a connection ended;
`SSHExec.takeFileDescriptor()` hands the socket over; `HelperChannel.read` and `.write` are one `FileHandle`
(HelperTransport already accepts one descriptor for both directions). The package has no package dependencies
any more (CryptoKit only).

### Helper channel

`HelperChannel.open` runs the helper's command through `dms_exec` and hands the socket to
`HelperConnection(read:write:)`. There are no pipes and no NIO bridge any more: the engine's pump is the bridge.
HelperTransport closing the socket reaches the helper as stdin EOF (its orderly shutdown); the helper's exit
ends the socket after its last bytes. The shared helper sources still need `System.polling` (a three-line stub
here, the `mobile` branch's iOS stand-in there) and `AppReplay`'s `Process` initializer behind
`#if canImport(AppKit)` (the same two-line guard as on `mobile`, applied here identically).

### Bootstrap

Unchanged from the first round: `Dispatch/SSH/SSHBootstrapScript.swift` holds the install shell byte for byte
(the Mac compiles it; the package through a symlink): probe, cache check, upload into a private staging
directory, size and SHA-256 checked on the host, rename. Scripts run as `exec /bin/sh -c '…'` like the Mac's,
because macOS logins run zsh, which reads `0700` as decimal.

## Integration with `DispatchMobile` and the Hosts stream

This branch forks from `mobile` before the `DispatchMobile` target existed, so it does not carry the project
change. It was verified in a throwaway checkout of `mobile` (79d1f1f8) with this branch applied: the change
below, `python3 scripts/generate-project.py`, then `xcodebuild build -scheme DispatchMobile -destination
'platform=iOS Simulator,…'` succeeds, and the app links the engine (19 `dms_*` symbols in
`DispatchMobile.debug.dylib`). The `Dispatch.xcodeproj` conflict between the branches resolves by regenerating.

```yaml
# top level, before targets:
packages:
  MobileTransport:
    path: Mobile/Transport
# DispatchMobile preBuildScripts, first entry:
      - name: Build SSH engine
        script: python3 "$SRCROOT/scripts/build-mobile-ssh.py"
        basedOnDependencyAnalysis: false
# DispatchMobile dependencies, first entry:
      - package: MobileTransport
```

Setup must run `python3 scripts/setup-ssh-rust.py` and `python3 scripts/build-mobile-ssh.py --fetch` before the
first Xcode build: SwiftPM resolves the binary target before the pre-build script runs.

For `docs/ios-contracts.md`'s `HostSessionDriver`: `HostConnection<SSHHostSession>` produces the `HostLink`
states one to one (`HostConnectionState` has the same cases), `SSHHostSession.establish` reports the phases and
returns the connection plus the helper channel, and the driver wraps `helper.read`/`helper.write` in
`HelperConnection` and `HelperClient`, runs `hello` (`HelperSession.Info`) and `multiplexers.list`, and maps
`stats.ping` to latency. Keepalive losses arrive as `closed()` returning, which `HostConnection` already turns
into `reconnecting`.

## What the fallback cannot do, or does differently, compared with the plan

- Host certificates (`@cert-authority`) are refused; user certificates are not wired (russh supports both).
- No x86_64 simulator or Intel Mac slice; agent forwarding, port forwarding and SFTP are not exposed.
- The app carries a second crypto stack (ring and RustCrypto) next to CryptoKit; the size impact on the final
  app is not measured yet (40 MB archives per slice before dead-stripping).
- The engine is a release-built static library even in Debug app builds, and Rust panics abort
  (`panic = "abort"`).
- russh's in-process test server sometimes stalls when echoing more than one SSH window in both directions at
  once (about one run in three at 8 MB); against OpenSSH the same pattern (24 to 32 MiB both ways) never failed.
  The Rust test stays at 1 MB; worth watching if the helper ever streams both ways at full speed.
- Unchanged device-only work: Face ID prompts for Secure Enclave keys during a signature (the engine waits on
  the sign reply, so the handshake carries on afterwards), Keychain persistence, Local Network permission,
  background socket loss (`retryNow()` on foregrounding), and whether to move from BSD sockets to
  Network.framework (russh's `connect_stream` takes any stream, so a Network.framework socket can be passed in
  later).

## First round: why not swift-nio-ssh plus Citadel

Kept for the record; that implementation is removed. Citadel 0.12.0 depends on `Joannis/swift-nio-ssh` 0.3.x, a
fork whose merge base with Apple is April 2022, and the two cannot share a package graph. The fork lacks Apple's
swift-nio-ssh 0.14.1 fix (July 2026) for an out-of-bounds stack write when parsing an ECDSA signature, reachable
before authentication. Citadel's RSA signs ssh-rsa (SHA-1) only, which OpenSSH 8.8 and later refuse by default,
and the fork cannot name rsa-sha2-* without patches. No swift-nio-ssh variant implements keyboard-interactive.
Citadel parses no ECDSA key files and has no known-hosts helpers. That round measured 460 to 680 MB/s, connect
+ auth 20 to 25 ms and 12 KB per idle connection.

## Verification commands

```sh
python3 scripts/setup-ssh-rust.py                       # once: adds the iOS targets
python3 scripts/build-mobile-ssh.py --fetch             # once: crates into build/cargo; then builds
cd Mobile/Transport/Core && PATH=$PWD/../../../build/rust/bin:$PATH CARGO_HOME=$PWD/../../../build/cargo \
  cargo test --offline --frozen                         # 10 engine tests
cd Mobile/Transport && swift test --scratch-path ../../build/spm   # 37 tests
python3 scripts/mobile-ssh-fixture.py start /tmp/sim-1
TEST_RUNNER_DMS_FIXTURE=/tmp/sim-1/profile.json xcodebuild test -scheme MobileTransport \
  -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath ../../build/dd-mobile \
  -clonedSourcePackagesDirPath ../../build/spm-xcode    # in Mobile/Transport
python3 scripts/mobile-ssh-fixture.py stop /tmp/sim-1
```

The real-helper cases need `python3 scripts/build-ssh-helper.py --build-only` (`build/helper-rust/bin`).
