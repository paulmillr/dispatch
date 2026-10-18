# MobileTransport

The SSH transport of Dispatch for iPhone: one SSH connection per host, the helper bootstrap over an exec
channel, the helper's `--stdio` session as a file handle for the unmodified `HelperTransport`, and the host
connection state machine. The SSH engine is Rust (`Core/`: russh behind the C ABI in
`Core/include/dispatch_mobile_ssh.h`); this package is its Swift API (Foundation and CryptoKit only, no
UIKit or AppKit). Design decisions and limits: `docs/ios.md`, Transport.

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

The engine tests run an in-process russh server (keyboard-interactive, password, external signer, exec). The
Swift tests start private sshd daemons as the current user on loopback (`/tmp/st-<pid>-<run>-<n>`, keys in
`/tmp/sk-<pid>-<run>`; short roots because sun_path is 104 bytes) with their own HOME, helper test root and
tmux/herdr socket paths, so nothing touches the account's real home or servers. Each fixture stops only the
sshd it started.

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
