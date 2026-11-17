# MobileTransport

The SSH transport of Dispatch for iPhone: one SSH connection per host, the helper bootstrap over an exec channel,
the helper's `--stdio` session as a file handle for the unmodified `HelperTransport`, interactive PTY shells for
hosts without the helper (plain SSH), and the host connection state machine. Its API (`SSHConnection`, `SSHExec`,
`SSHShell`, `SSHKey`, `HostConnection`) runs on the Swift SSH engine behind one seam, and in a build with
`DISPATCH_RUSSH=1` also on the older Rust russh engine behind the same seam; no UIKit or AppKit. Design decisions and
limits: `docs/ios.md`, Transport; what each engine offers and refuses: `docs/security.md`, Dispatch for iPhone.

## Targets

- `MobileTransport`, the library the app links: the API, the seam (`Sources/MobileTransport/Engine.swift`) and the
  engines' adapters (russh's, `RusshEngine.swift`, compiles to nothing without `DISPATCH_RUSSH`).
  `Sources/MobileTransport/Shared/` links to the Mac's `Dispatch/SSH/SSHBootstrapScript.swift` (the install shell)
  and `Dispatch/SSH/GzipMember.swift`.
- `SSHEngine`: the Swift engine, Apple's frameworks only, no package dependency (`Sources/SSHEngine/README.md`, its
  spec).
- `DispatchMobileSSHCore`, only with `DISPATCH_RUSSH=1`: a binary target, the XCFramework of `Core/`, Rust russh
  behind the C ABI in `Core/include/dispatch_mobile_ssh.h` (The russh build, below).
- Test targets: `SSHEngineTests` (the Swift engine by layer, and the parity suite, which drives `MobileTransport`),
  `MobileTransportTests` (the API under private sshd daemons, the Swift engine's adapter) and `HelperBridgeTests`
  (the real helper over a channel).
- `Integration/` is not in the package: the app's sources that use it (`SSHHostSessionDriver`, `HostLogin`,
  `SSHShellOpener`, `MultiplexerFollower`, `HostLinkMapping`), built into the iPhone app.

Swift 6 language mode; macOS 26 (for `swift test`) and iOS 26, for CryptoKit's ML-KEM.

## The seam and the engines

`Engine.swift` is the seam: `EngineBackend` (connect, parse a key file), `EngineSession` (logins, exec, shell, close),
`EngineChannelEvents`, `EngineShell`, `EngineKey`. The wrappers talk only to it, and its doc comments are the
contract every engine keeps (callbacks exactly once and never on the caller's actor, questions answered exactly once,
the deadlines, the errors as `SSHTransportError`, the channel socket); it was written as russh does it, and "russh:"
there marks what that engine does where nothing above depends on it, so another may differ.

`SSHTransportEngine`'s cases are the engines the build has: `.swift` always, `.russh` only with `DISPATCH_RUSSH`, so
`allCases` is what an app can offer and `init(rawValue:)` refuses an engine the build lacks.
`SSHTransportEngine.preferred` picks the engine new connections and key files use, process-wide: `.standard`, the
Swift engine, unless set. Debug builds start from `DISPATCH_SSH_ENGINE` (`swift`, or `russh` in a russh build; any
other value stops the process; `TEST_RUNNER_DISPATCH_SSH_ENGINE` under xcodebuild); Release builds ignore it. The app
sets it at launch and, in a russh build, from Settings › Hosts › SSH engine, where the environment wins (docs/ios.md,
Transport). A connection keeps the engine it started with. A key file parsed by one engine fails a login on the other's connections (`invalidKey("the key was
parsed by another SSH engine")`); CryptoKit and Secure Enclave keys work with either.

- **Swift** (`SwiftEngine.swift` over `SSHClient.connector()`; `SwiftEngineChannels.swift`, `SwiftEngineSocket.swift`,
  `SwiftEngineErrors.swift`): the default. Every operation runs on a task of its own and ends with its one callback
  from there.
  `SwiftEngine`'s doc comment lists where it differs from russh, as the seam allows (docs/ios.md, Transport, repeats
  the list). Errors: `SSHError.transportError` gives the `SSHTransportError` case russh gives for the same condition,
  with the same text where the seam or russh fixes it (timeouts, a rekey's host key change, a refused PTY, shell or
  exec request) and the engine's own elsewhere (protocol errors, the OS's network errors); key files it refuses on
  purpose are `invalidKey` with a sentence that says what to do (`KeyFileRefusal.transportError`). A server that offers
  nothing the engine accepts is `incompatibleServer` with one too, final for the host: only modes that need strict key
  exchange it lacks ("The server's SSH is too old for a safe connection (it offers <mode> without strict key exchange);
  update the SSH server."), or no algorithm in common, which russh reports the same way (`RusshEngine.error` maps its
  "No common … algorithm" text). The server ending the connection
  at its attempt limit is `authenticationFailed(methods: [])`, final for the host, as with russh; any other end during
  a login stays `channelClosed`, which reconnects.
- **russh** (`RusshEngine.swift`, the only file that calls `dms_*`), only with `DISPATCH_RUSSH`. Callbacks come from
  its tokio runtime's two `dispatch-ssh` workers; logins, channel opens and `close` queue behind each other on the
  session's lock.

**The Swift engine's socket bridge.** A channel reaches the caller as one end of a socketpair, as the seam states it
(AF_UNIX stream, FD_CLOEXEC and SO_NOSIGPIPE on both ends, 1 MiB send and receive buffers, the caller's end blocking),
so `HelperTransport`, `FileHandle` and `Descriptor` drive it as they drive russh's. The engine's end is non-blocking,
driven by two dispatch sources (kqueue) that are armed only while a task waits, so a stalled caller parks no thread and
nothing polls (`SwiftEngineSocket`). Two tasks pump each channel (`SwiftEngineBridge`): input reads up to 256 KiB at a
time from the socket into the channel, which waits for the server's window; output writes what the channel delivers into
the socket, waiting while the caller's receive buffer is full. Each takes its next chunk only once the other side took
the last, so a caller that stops reading stops the channel's reads (whose window then stops the server), and a shut
window stops the socket's reads. The remote's EOF shuts the socket for writing (the caller reads end of file after the
data), and output the caller can no longer take (its end closed) closes the channel. Exec: stderr goes to
`events.stderr` as it comes, and the caller's end of input is sent as EOF. Shell: the caller's end of input closes the
channel. Once the channel closed, the socket is closed and `exited` called, last. `close()` wakes both directions,
cancels the sources and closes the number only once both cancellation handlers ran; every syscall on the number happens
under one lock after a check that it is still open, so none can reach a number the system has given to something else.
Window changes go through `SwiftEngineShellControl`: in call order, the latest size waiting while the shell opens,
dropped once it ended.

## Key logins

`SSHConnection.connect` tries `credentials` in order, each one whose method the server still allows, and says which
logged in (`credential`, its index). `.key` goes as SSH clients send a key: a query, then the signature after the
server's `PK_OK`. `.directKey(key, answered:)` sends the signed request at once (russh: `dms_auth_key`/`dms_auth_signer`
with `direct`; Swift: `Credential.publicKey(_, direct: true)`), as the connection's first request without waiting for
the service accept either: one round trip where `.key` takes three on a new connection (docs/ios.md, Transport).
`answered` hears once how it ended (`DirectKeyAnswer`: `loggedIn`; `refused`, a partial success too; `withdrawn` when
the signer declined or the login was cancelled; `unanswered`), not at all for an attempt that never started. A refused
direct attempt is an ordinary failure and the next credential goes on the same connection. One the server never answers
is the connection's end, never a failed login (which would be final for the host): the connect throws `channelClosed`
when the connection ended first, and `timedOut` when no answer came within 10 s of the request (russh:
`Session::set_direct_answer`; Swift: `Limits.directAnswer`; a signer's own time does not count), after which the engine
closes the connection. The app's driver puts `.directKey` first only for a key that logged in at that endpoint before
(`KeyLogins`, saved by the app: docs/ios.md, Connection).

## Shell channels

`SSHConnection.shell(term:columns:rows:)` opens a session channel with a PTY and starts the login shell
(`dms_shell_open` in the C ABI; the C names below are russh's, and the Swift engine behaves the same through its
adapter): `pty-req` with the given TERM and grid, no pixel size, no terminal modes (the server's defaults) and no `env`
requests, then `shell`. The returned `SSHShell` is an `AsyncSequence` of `Data` (the PTY merges stdout and stderr), with
`write`, `resize(columns:rows:)` (`window-change` through the engine's shell handle, `dms_shell`, since the pump owns
the channel) and `exitStatus()`: the status, 128 for a signal, or `SSHTransportError.channelClosed` when the channel or
connection went away first. A refused `pty-req` or `shell` request throws `commandFailed(status: -1, …)`, as a refused
exec's `exitStatus()` does. Exec and shell share the engine's socketpair pump; they differ in two things. A shell starts
once its requests are confirmed, an exec as soon as its request is sent (`dms_exec`): what the caller writes at once
follows the request on the channel as far as its window allows and output before the reply reads as usual, and a refused
request is the exec's end (`DMS_EXIT_REFUSED`, the engine closes the channel). With OpenSSH this saves no round trip:
its sshd opens a session channel with a window of zero and grants it only once the command started, so the first bytes
leave when the reply arrives, as they did (`LatencyTests`). And the end of input: an exec's is EOF, a shell's closes the
channel (a PTY has no end of file), so `close()` ends the shell at once and leaves the connection up. The engine then
ends the channel's read side itself (russh forgets a channel it closed and drops the server's reply), so `exitStatus()`
answers at once: a status that arrived before the close, else `channelClosed` (`.lost`). `resize` throws `channelClosed`
once the shell ended or was closed; the engine sends window changes in call order (the latest size wins; one asked
before the shell started is sent once it has) and drops them after its channel closed. Closing never frees the socket's
number while a read or write is in flight (shutdown at once, the last operation closes it), so a pending read cannot
land on the next socket that takes the number. Releasing the shell's handle (`dms_shell_free`) never closes the channel:
the fd decides the channel's lifetime. An exec whose socket the caller closed entirely closes its channel when the
command next writes, and reports what arrived before (usually `.lost`).

## The russh build

The package builds the Swift engine alone unless `DISPATCH_RUSSH=1` is in the environment of `swift`, `xcodebuild` or
Xcode (docs/ios.md, Building and running, has the Xcode app's way). With it, `Package.swift` adds the binary target
and the `DISPATCH_RUSSH` compilation condition for `MobileTransport` and the tests, which compiles `RusshEngine.swift`
and `SSHTransportEngine.russh`; the app's pre-build step builds the XCFramework, and its bundle gets the crates'
licences. Nothing else changes: the default engine stays the Swift one.

```sh
DISPATCH_RUSSH=1 bash scripts/setup.sh --mobile   # once: the pinned Rust 1.98.1 with the iOS targets, crates, build
python3 scripts/build-mobile-ssh.py --fetch       # or by hand: the locked crates into build/cargo (network), the build
python3 scripts/build-mobile-ssh.py               # offline: build/mobile-ssh/DispatchMobileSSHCore.xcframework
```

The XCFramework holds static libraries for iOS devices, the Apple Silicon simulator and macOS (for `swift test`).
`Frameworks` is a symlink to `build/mobile-ssh` (dangling in a checkout that never built it; only the russh build
reads it): the XCFramework must exist before SwiftPM or Xcode resolves the package with `DISPATCH_RUSSH=1`. Crates are
pinned in `Core/Cargo.lock`; licences: `THIRD_PARTY_NOTICES.md` and
`Core/ThirdPartyLicenses/MobileTransport/Dependencies.txt`, bundled only by a russh build (regenerate with
`python3 scripts/mobile-transport-licenses.py` after changing the lock file).

## Tests

```sh
cd Mobile/Transport && swift test --scratch-path ../../build/spm   # every Swift test, on the Swift engine; no Rust
# With russh (after DISPATCH_RUSSH=1 bash scripts/setup.sh --mobile):
DISPATCH_RUSSH=1 swift test --scratch-path ../../build/spm                           # the API on the Swift engine
DISPATCH_RUSSH=1 DISPATCH_SSH_ENGINE=russh swift test --scratch-path ../../build/spm  # the same, the API on russh
python3 scripts/vendor-russh.py --offline   # from the repository root: the patched russh in build/mobile-ssh/russh
cd Mobile/Transport/Core
PATH=$PWD/../../../build/rust/bin:$PATH CARGO_HOME=$PWD/../../../build/cargo cargo test --offline --frozen
```

**Which engine.** `swift test` runs the API's tests (`MobileTransportTests`, `HelperBridgeTests`, `Parity/`) on
`SSHTransportEngine.preferred`: the Swift engine, or russh when a russh build names it with `DISPATCH_SSH_ENGINE=russh`
(a Debug build reads it once, at the first use); `TEST_RUNNER_DISPATCH_SSH_ENGINE` does the same under xcodebuild.
The Swift engine's own tests (`SSHEngineTests` but `Parity/`) and the adapter's (`SwiftEngine*Tests`) do not depend
on it. Without `DISPATCH_RUSSH` everything runs on the Swift engine and nothing needs a russh artefact; the parts that
compare with russh are compiled only with it (`#if DISPATCH_RUSSH`): `SwiftEngineKeyTests` parsing the key files
`ssh-keygen` writes with both engines and comparing the results, `SwiftEngineErrorTests` holding each error against
russh's mapping (without russh, against the expected case and text alone), `OldServerTests` connecting russh to a
server the Swift engine refuses, `SpeedTests`' russh rows, and the interop tests' russh runs.

**The parity suite** (`Tests/SSHEngineTests/Parity/EngineParityTests.swift`) restates `Core/tests/engine.rs` against
the public API: each case connects with `SSHConnection.connect` to the scripted server (`ParityServer`, the Swift
engine's test server on a loopback port, scripted as `engine.rs`'s russh server is) and checks what the API shows and
what the server recorded; holds in the server's output replace the Rust tests' proxies. Run once per engine (in a
russh build), the same cases check both through the seam.

**Rust** (`cargo test` in `Core/`, for the russh build) runs an in-process russh server (keyboard-interactive, password, external
signer, exec (also one whose request is never answered, one whose output comes before its reply, and a refused one),
and a PTY shell that records its `pty-req`, `shell` and `window-change` requests and echoes input; a terminal named
`refused` is refused), rapid resizes arriving in order with the last winning, the C ABI's shell calls, and russh's
rekeys with the trusted key, and direct key logins: through a proxy that holds the server's answers, a direct request
(file key, RSA, external signer) reaches the server's signature check before the client heard anything, a queried one
does not; refused, declined and RSA's `server-sig-algs` cases. `tests/hostile.rs` runs a scripted server (X25519,
AES-256-GCM) that sends what russh's server cannot: a nested certificate as the host key, `EXT_INFO` floods, an
oversized packet, a zero maximum packet size, rekeys with the same key, another key, another algorithm, repeated and
while input streams, and a service accept held back: the signed direct request arrives before it (a queried one waits
for it), with `EXT_INFO` before or after it, a refusal, a connection that ends before the answer (`Closed`, not a
refusal) and a server that never answers the request (a timeout after the answer's deadline, counted from the
signature for a signer).
`DirectLoginTests` log in direct under the fixture sshd at `LogLevel VERBOSE`, whose "Postponed publickey" lines count
the queries (none for a direct login), with RSA following `PubkeyAcceptedAlgorithms`, a wrong remembered key and a
declined signature.
`ShellTests` drive the account's login shell under the fixture sshd: the prompt and TERM, `stty size` before and
after a resize, `exit 3`, the loss when the connection closes, `close()`, a closed shell never touching a socket
that reused its number, and `PermitTTY no` as a refusal; `DescriptorTests` hold an operation in flight across
`close()`. `CachedLaunchTests` start a cached helper straight from the cache and count the remote commands through a
fixture whose `ForceCommand` logs each one (`CommandLog`): one for a cached helper, whose first stdin line and
arguments arrive as `launchCommand` gives them; a miss, a damaged or wrong-size file, a home an ACL keeps from running
programs (moving to the runtime folder) and an unsupported platform (a `uname` on `PATH`) start nothing and the full
bootstrap then gives today's results. `HelperRootTests` check that the `.home` scripts are the Mac's byte for byte, the runtime folder's
scripts and probe, `launchFailure` and `fallbackRoot`, and, under the fixture sshd, an install and launch from the
runtime folder, a 126 at home moving there, and failed launch checks that keep stdout empty. The Swift tests start
private sshd daemons as the current user on loopback (`/tmp/st-<pid>-<run>-<n>`, keys in `/tmp/sk-<pid>-<run>`;
short roots because sun_path is 104 bytes) with their own HOME, helper test root and tmux/herdr socket paths, so
nothing touches the account's real home or servers. Each fixture stops only the sshd it started.

`HelperBridgeTests` compiles `Dispatch/Helper/{HelperWire,HelperBinary,HelperConnection,HelperTransport,AppReplay}.swift`
unmodified through symlinks and greets the real helper when the worktree has one
(`python3 scripts/build-ssh-helper.py --build-only` writes `build/helper-rust/bin`), also from the cache with the
`hello` written at once; otherwise those cases skip. `LatencyTests` times a reconnect to the real helper's `hello`
answer through `DelayRelay` (a loopback relay that holds every byte for half the round trip each way, and a new
connection for a whole one) at 0 to 400 ms, asked first with the full bootstrap and direct from the cache, and prints
the round trips each took: 13 and 7.

`ResourceLoopTests` run the Swift engine through the API in loops (connect, log in, exec, close; and connections reset
by `CutRelay` while the host key waits for trust, while the login signs, and with an exec and a shell open) and check
that descriptors come back to where they started and the heap does not grow; `DISPATCH_SSH_LOOPS=500` is the long
mode, which also waits out what closed connections free later (65 s) and compares the heap with its start
(`DISPATCH_SSH_LEAKS=1` adds `leaks`). `SpeedTests` (only with `DISPATCH_SSH_SPEED=1`, meant for `swift test -c release
-Xswiftc -enable-testing --scratch-path ../../build/spm-release`) set `SSHTransportEngine.preferred` themselves and time
the build's engines (russh too with `DISPATCH_RUSSH=1`) against sshd daemons restricted to one cipher or key exchange: 256 MiB each way per cipher, the time to a
logged-in session per key exchange (median of 30) and 100,000 round trips of 300 bytes over one exec's socket.

In the simulator (it shares the Mac's network), against an sshd on the Mac:

```sh
python3 scripts/mobile-ssh-fixture.py start /tmp/sim-1
TEST_RUNNER_DMS_FIXTURE=/tmp/sim-1/profile.json xcodebuild test -scheme MobileTransport \
  -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath ../../build/dd-mobile \
  -clonedSourcePackagesDirPath ../../build/spm-xcode
python3 scripts/mobile-ssh-fixture.py stop /tmp/sim-1
```

Measurements print as `MEASURE` lines.
