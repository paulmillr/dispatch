# MobileTransport

The SSH transport of Dispatch for iPhone: one SSH connection per host, the helper bootstrap over an exec channel,
the helper's `--stdio` session as a file handle for the unmodified `HelperTransport`, interactive PTY shells for
hosts without the helper (plain SSH), and the host connection state machine. The SSH engine is Rust (`Core/`:
russh behind the C ABI in `Core/include/dispatch_mobile_ssh.h`); this package is its Swift API (Foundation and
CryptoKit only, no UIKit or AppKit). Design decisions and limits: `docs/ios.md`, Transport.

## Shell channels

`SSHConnection.shell(term:columns:rows:)` opens a session channel with a PTY and starts the login shell
(`dms_shell_open` in the C ABI): `pty-req` with the given TERM and grid, no pixel size, no terminal modes (the
server's defaults) and no `env` requests, then `shell`. The returned `SSHShell` is an `AsyncSequence` of `Data`
(the PTY merges stdout and stderr), with `write`, `resize(columns:rows:)` (`window-change` through the engine's
`dms_shell` handle, since the pump owns the channel) and `exitStatus()`: the status, 128 for a signal, or
`SSHTransportError.channelClosed` when the channel or connection went away first. A refused `pty-req` or `shell`
request throws `commandFailed(status: -1, …)`, as a refused exec does. Exec and shell share the engine's
socketpair pump; the one difference is the end of input: an exec's is EOF, a shell's closes the channel (a PTY has
no end of file), so `close()` ends the shell at once and leaves the connection up. The engine then ends the
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
cd Mobile/Transport/Core
PATH=$PWD/../../../build/rust/bin:$PATH CARGO_HOME=$PWD/../../../build/cargo cargo test --offline --frozen
cd .. && swift test --scratch-path ../../build/spm
```

The engine tests run an in-process russh server (keyboard-interactive, password, external signer, exec, and a PTY
shell that records its `pty-req`, `shell` and `window-change` requests and echoes input; a terminal named
`refused` is refused), rapid resizes arriving in order with the last winning, and the C ABI's shell calls.
`ShellTests` drive the account's login shell under the fixture sshd: the prompt and TERM, `stty size` before and
after a resize, `exit 3`, the loss when the connection closes, `close()`, a closed shell never touching a socket
that reused its number, and `PermitTTY no` as a refusal; `DescriptorTests` hold an operation in flight across
`close()`. `HelperRootTests` check that the `.home` scripts are the Mac's byte for byte, the runtime folder's
scripts and probe, `launchFailure` and `fallbackRoot`, and, under the fixture sshd, an install and launch from the
runtime folder, a 126 at home moving there, and failed launch checks that keep stdout empty. The Swift tests start
private sshd daemons as the current user on loopback (`/tmp/st-<pid>-<run>-<n>`, keys in `/tmp/sk-<pid>-<run>`;
short roots because sun_path is 104 bytes) with their own HOME, helper test root and tmux/herdr socket paths, so
nothing touches the account's real home or servers. Each fixture stops only the sshd it started.

`HelperBridgeTests` compiles `Dispatch/Helper/{HelperWire,HelperBinary,HelperConnection,HelperTransport,AppReplay}.swift`
unmodified through symlinks and greets the real helper when the worktree has one
(`python3 scripts/build-ssh-helper.py --build-only` writes `build/helper-rust/bin`); otherwise that case skips.
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
