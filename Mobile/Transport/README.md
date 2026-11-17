# MobileTransport

The SSH transport of Dispatch for iPhone: one SSH connection per host, the helper bootstrap over an exec channel,
the helper's `--stdio` session as a file handle for the unmodified `HelperTransport`, interactive PTY shells for
hosts without the helper (plain SSH), and the host connection state machine. The SSH engine is Rust (`Core/`:
russh behind the C ABI in `Core/include/dispatch_mobile_ssh.h`); this package is its Swift API (Foundation and
CryptoKit only, no UIKit or AppKit). Design decisions and limits: `docs/ios.md`, Transport.

## Key logins

`SSHConnection.connect` tries `credentials` in order, each one whose method the server still allows, and says which
logged in (`credential`, its index). `.key` goes as SSH clients send a key: a query, then the signature after the
server's `PK_OK`. `.directKey(key, answered:)` sends the signed request at once (`dms_auth_key`/`dms_auth_signer` with
`direct`), as the connection's first request without waiting for the service accept either: one round trip where `.key`
takes three on a new connection (docs/ios.md, Transport). `answered` hears once how it ended (`DirectKeyAnswer`:
`loggedIn`; `refused`, a partial success too; `withdrawn` when the signer declined or the login was cancelled;
`unanswered`), not at all for an attempt that never started. A refused direct attempt is an ordinary failure and the
next credential goes on the same connection. One the server never answers is the connection's end, never a failed
login (which would be final for the host): the connect throws `channelClosed` when the connection ended first, and
`timedOut` when no answer came within 10 s of the request (`Session::set_direct_answer`; a signer's own time does not
count), after which the engine closes the connection. The app's driver puts `.directKey` first only for a key that
logged in at that endpoint before (`KeyLogins`, saved by the app: docs/ios.md, Connection).

## Shell channels

`SSHConnection.shell(term:columns:rows:)` opens a session channel with a PTY and starts the login shell
(`dms_shell_open` in the C ABI): `pty-req` with the given TERM and grid, no pixel size, no terminal modes (the
server's defaults) and no `env` requests, then `shell`. The returned `SSHShell` is an `AsyncSequence` of `Data`
(the PTY merges stdout and stderr), with `write`, `resize(columns:rows:)` (`window-change` through the engine's
`dms_shell` handle, since the pump owns the channel) and `exitStatus()`: the status, 128 for a signal, or
`SSHTransportError.channelClosed` when the channel or connection went away first. A refused `pty-req` or `shell`
request throws `commandFailed(status: -1, …)`, as a refused exec's `exitStatus()` does. Exec and shell share the
engine's socketpair pump; they differ in two things. A shell starts once its requests are confirmed, an exec as soon
as its request is sent (`dms_exec`): what the caller writes at once follows the request on the channel as far as its
window allows and output before the reply reads as usual, and a refused request is the exec's end
(`DMS_EXIT_REFUSED`, the engine closes the channel). With OpenSSH this saves no round trip: its sshd opens a session
channel with a window of zero and grants it only once the command started, so the first bytes leave when the reply
arrives, as they did (`LatencyTests`). And the end of input: an exec's is EOF, a shell's closes the channel (a PTY has no end of file), so `close()` ends the shell at once and leaves the connection up. The engine then ends the
channel's read side itself (russh forgets a channel it closed and drops the server's reply), so `exitStatus()`
answers at once: a status that arrived before the close, else `channelClosed` (`Lost`). `resize` throws
`channelClosed` once the shell ended or was closed; the engine sends window changes in order from one task per
shell (the latest size wins; one asked before the shell started is sent once it has) and drops them after its
channel closed. Closing never frees the socket's number while a read or write is in flight (shutdown at once, the
last operation closes it), so a pending read cannot land on the next socket that takes the number.
`dms_shell_free` releases the handle only: the fd decides the channel's lifetime. An exec whose socket the caller
closed entirely closes its channel when the command next writes, and reports what arrived before (usually `Lost`).

## Building the engine

```sh
python3 scripts/setup-ssh-rust.py                 # the pinned Rust 1.98.1 with the iOS targets
python3 scripts/build-mobile-ssh.py --fetch       # once: the locked crates into build/cargo (network)
python3 scripts/build-mobile-ssh.py               # offline: build/mobile-ssh/DispatchMobileSSHCore.xcframework
```

The XCFramework holds static libraries for iOS devices, the Apple Silicon simulator and macOS (for `swift test`).
`Frameworks` is a symlink to `build/mobile-ssh`: the XCFramework must exist before SwiftPM or Xcode resolves the
package. Crates are pinned in `Core/Cargo.lock`; licences: `THIRD_PARTY_NOTICES.md` and
`Mobile/ThirdPartyLicenses/MobileTransport/Dependencies.txt` (regenerate with
`python3 scripts/mobile-transport-licenses.py` after changing the lock file).

## Tests

```sh
python3 scripts/vendor-russh.py --offline   # from the repository root: the patched russh in build/mobile-ssh/russh
cd Mobile/Transport/Core
PATH=$PWD/../../../build/rust/bin:$PATH CARGO_HOME=$PWD/../../../build/cargo cargo test --offline --frozen
cd .. && swift test --scratch-path ../../build/spm
```

The engine tests run an in-process russh server (keyboard-interactive, password, external signer, exec (also one
whose request is never answered, one whose output comes before its reply, and a refused one), and a PTY
shell that records its `pty-req`, `shell` and `window-change` requests and echoes input; a terminal named
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
`Sources/MobileTransport/Shared/SSHBootstrapScript.swift` links to `Dispatch/SSH/SSHBootstrapScript.swift`, the
install shell the Mac app uses.

In the simulator (it shares the Mac's network), against an sshd on the Mac:

```sh
python3 scripts/mobile-ssh-fixture.py start /tmp/sim-1
TEST_RUNNER_DMS_FIXTURE=/tmp/sim-1/profile.json xcodebuild test -scheme MobileTransport \
  -destination 'platform=iOS Simulator,name=<device>' -derivedDataPath ../../build/dd-mobile \
  -clonedSourcePackagesDirPath ../../build/spm-xcode
python3 scripts/mobile-ssh-fixture.py stop /tmp/sim-1
```

Measurements print as `MEASURE` lines.
