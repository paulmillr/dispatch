# VM testing

Test selection and runner options are in [test/README.md](../test/README.md). This doc covers the machines those runners need.

**Agent rules:** never stop the test VM unless asked or recovering. Never use `dispatch-manual-ssh` (it's the user's). Never download replacements for missing pinned archives; fail instead. Keep captures and diagnostics under ignored `tmp/` or `build/`, and commit only reviewed, anonymized synthetic fixtures.

## macOS VM

A dedicated Tart VM (default `dispatch-tests`; override with `--vm NAME` before the subcommand, `DISPATCH_VM`, or [local inventory](#existing-local-test-resources)) runs desktop, focus, keyboard, and screenshot tests. Keep the host awake and leave the guest alone during runs. Each VM accepts one runner at a time. The runner syncs uncommitted source into `/Users/admin/dispatch-tests/workspace`, and keeps guest DerivedData.

### Prepare a new host

The host needs Apple Silicon, Xcode 26 with first launch completed, Homebrew in `/opt/homebrew`, `brew install openai/tools/tart`, and `bash scripts/setup.sh`. The image download is about 69 GB, plus disk and build products. The guest gets 4 CPUs, 8 GB of RAM, and a 1920×1080 pt Retina display.

`test/vm.py` copies two host binaries from **fixed paths** (finding them on `PATH` isn't enough):
- herdr 0.9.5 at `/opt/homebrew/bin/herdr`. Re-run setup after changing it.
- Native Codex from the global npm layout: `npm install --global --prefix /opt/homebrew @openai/codex`, giving `/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`. The runner copies the installed version and its `codex-code-mode-host` companion when present.

The full suite also needs Claude Code on `PATH` and the pinned Pi from `./run.sh --test`. Host binaries built for a newer macOS, or linked to host libraries, are rejected before copying.

```sh
python3 test/vm.py setup            # creates/reuses the VM from the digest-pinned image; copies host Rust + XcodeGen
python3 test/vm.py rust             # copy + verify host build/rust into the guest (no download)
python3 test/vm.py test ChatTests   # first validation: no Claude, Pi, or Linux needed
```

The guest must run commands as `admin` in a logged-in desktop, with passwordless sudo for the loopback sshd fixtures. In the guest, add `admin ALL=(ALL) NOPASSWD: ALL` via `visudo`; never do this on the host. Check:

```sh
tart exec dispatch-tests /usr/bin/stat -f %Su /dev/console   # admin
tart exec dispatch-tests /usr/bin/sudo -n /usr/bin/true      # exits 0
```

Custom images need the Tart guest agent as a LaunchAgent in admin's GUI session (`--run-agent`); a root LaunchDaemon doesn't work. Display settings apply only while the VM is stopped.

More VMs come from a prepared one: keep a base image with Xcode, auto-login `admin` and passwordless sudo (one per macOS release you test), then `tart clone <base> NAME` (an instant APFS clone) and `python3 test/vm.py --vm NAME setup` (about 3 minutes). Name them in `build/test-environment.json` ([below](#existing-local-test-resources)) or pass `--vm`. Back a base up with `tart export`; a clone is cheaper than restoring an export.

`setup` installs the host's `/opt/homebrew/bin/herdr` in the guest. If the host's Homebrew can't be upgraded (it belongs to another account), that copy can lag the pin in `scripts/test-tools.lock.json`: install the pinned `build/test-tools/bin/herdr` into the guest's `/opt/homebrew/bin/herdr` instead.

### Host build

`vm.py test` builds for testing on this Mac (test/xcode.py's fingerprinted build, skipped when inputs are unchanged) and copies the products (`Dispatch.app`, the Term frameworks, the `.xctestrun`) with a digest manifest (`build/test-tools/xcode-prebuilt.json`) into each guest. The guest's `xcode.py` (`DISPATCH_TEST_PREBUILT=1`) checks the digest and runs `test-without-building`; it never compiles. A host Xcode newer than the guest's is fine (Xcode 27.2 products run under the guest's Xcode 26.2), but such a run no longer exercises the guest's compiler: `--guest-build` restores the old per-guest build. An older guest Xcode can reject code the host's accepts (region isolation, "unable to type-check"), and the guests never test the host's Xcode either: after an Xcode update, also run the iPhone suites on the host (`test/run.sh --platform ios --suite exhaustive`, the live fixture and the `DispatchMobileUITests` scheme, [ios](ios.md#testing)).

### Parallel VM shards

`python3 test/vm.py clone-shard` creates `dispatch-tests-2`. `--shards auto` (the default) uses both VMs only if the lighter half has at least 180 s of recorded work and every VM's full allocation fits in RAM, after reserving the larger of RAM/4 and 8 GB for macOS. Allocated VM CPUs must also fit the host; booting VMs need their full memory allocation plus 4 GiB of currently available memory. Whole classes are split by recorded duration, and Linux-paired classes stay on the primary VM. Merged results go to `build/vm-tests/<run>/`. Guest tool changes (`setup`, `rust`, `linux`) must be applied to both VMs, or the shard re-cloned.

### Results and recovery

Results are in `build/vm-tests/<run>/` (`test.log`, `TestSummary.json`, xcresults); timing history is in `tmp/profiling/test-runs/`. Runner self-tests: `python3 test/vm-runner.py`.

| Failure | Fix |
| --- | --- |
| Locked desktop / guest-agent timeout | `python3 test/vm.py stop; tart run dispatch-tests`, log in as `admin`/`admin`, enable auto-login, and disable idle lock. Agent log: guest `/tmp/tart-guest-agent.log`; restart it with `launchctl kickstart -k "gui/$(id -u)/org.cirruslabs.tart-guest-agent"`. Boot log: `build/vm-tests/dispatch-tests-boot.log`. |
| Stale guest test lock | Confirm nothing is running, then stop the VM and retry. |
| Missing Rust | `bash scripts/setup.sh`, then `python3 test/vm.py rust`. |
| Wrong display | `python3 test/vm.py stop`: the next test run boots the VM at 1920×1080 pt, the size the recordings were made at (a 1280×832 pt guest stalls every replay whose windows follow the screen). Boot it while a Retina display is the host's main display, for 2×. |
| Replays stall or name unrecorded tool paths | The guest needs the corpus (`replays/`, synchronized when the host has it), the host's tool paths (`vm-guest.sh` links the VM's tools into `build/test-tools/bin`) and the unprivileged SSH fixture (`DISPATCH_UNPRIVILEGED_SSHD=1`, the default). `--live` runs everything live instead. |
| Missing Claude/Pi | Install them, or select only suites whose dependencies are ready. |
| A handful of SSH, tmux and herdr integration cases fail in a full run | Under load about ten fail and pass on rerun: `python3 test/vm.py test --failed <run>` before diagnosing. Several selectors kept in one zsh variable reach `vm.py` as one argument ("Invalid XCTest identifier"): use an array. |
| A VM will not start | Virtualization allows two macOS guests at a time: stop one (`python3 test/vm.py --vm NAME stop`). After a host reboot, guests start only once someone has logged in at the host's desktop; over SSH alone tart fails with `VZErrorDomain -9` ("Failed to get current host key"). |
| Every phase is slower than its recorded timings (OCR passes several times slower) | Check the host before the code: `notifyutil -g com.apple.system.thermalpressurelevel` above 0 at idle, or a sustained multithreaded CPU loop losing most of its speed within seconds, means the host is throttled. Guests have no Neural Engine, so their OCR runs on the CPU and shows it first. A full shutdown with the power unplugged has cleared spurious thermal pressure after an OS update. |
| `SwiftTerminalSessionTests/testKittySharedMemoryReadsOnlyTheRequestedRange` fails in the guest only | It fails with host-built products under the guest's older macOS and passes with `--guest-build` from the same sources. Confirm with `--guest-build` before treating it as a regression. |
| `TerminalPageMemoryTests/testClearedScrollbackLeavesTheFootprint` fails in the guest only ("module compiled with Swift 6.4.2 cannot be imported by the Swift 6.2.3 compiler") | It compiles a probe against the copied `Term.framework` with the guest's `swiftc`, which cannot import a module built by the host's newer Xcode. It passes with `--guest-build`. |
| Writing a file through `tart exec` gives 0 bytes | `tart exec` passes stdin only with `-i`. |

### A newer macOS guest

A guest on a newer macOS than the regular VMs reproduces layout bugs only that release has: `tart clone <base image> NAME`, `tart set NAME --display 1920x1080pt`, then `python3 test/vm.py --vm NAME setup`. Vision text recognition fails in a macOS 27 guest ("No available backends … ane"), so every OCR assertion fails or stalls there: use it for layout and pixel checks, and run OCR suites on the regular VMs.

### Checking a release by hand in a clean VM

To try the published app as a new user would (the cask, first launch, SSH to a clean Linux VM): clone a base image into
a throwaway VM and drive it over VNC (`tart run NAME --vnc-experimental`, then `vncdotool` from a scratch venv). VNC
input goes through virtual HID, so it works on Gatekeeper and privacy (TCC) dialogs, where CGEvent clicks and
`osascript` do not; `vncdo` drops Shift (send `key shift-c`), and its framebuffer is 2× the guest's points. Take
screenshots with `vncdo capture`, not guest `screencapture` under sudo (each call raises a new privacy prompt). Closing
the Screen Sharing window tart opens stops the VM.

- Never run `spctl --global-enable` in a guest: it lands in "App Store only", rejects every Developer ID app, and
  cannot be undone from the command line. Clone the base again instead.
- tart guests and Lima's vzNAT guests cannot reach each other: relay on the host from `192.168.64.1:<port>` to Lima's
  `127.0.0.1:<sshLocalPort>`. A tart guest's address changes on reboot (`tart ip NAME`).

### Updating the agent CLIs

`vm.py` takes Claude Code from the host's `PATH` (put a checkout's `build/test-tools/bin` first for the pinned one), Codex from the fixed Homebrew npm path above, and Pi always from the pin in `scripts/test-tools.lock.json`. A guest's tmux is its own Homebrew's: after a tmux pin change, `HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade tmux` in each guest (`tart exec NAME …`) once Homebrew's stable matches. To compare two versions, run `--live`: in replay the recorded tool I/O answers and the CLIs barely run. Compare the per-case failures of each run's `TestSummary.json` (`testFailures[].testIdentifierString`), then rerun their union under both versions, one VM each, swapping VMs for any case that differs. The Linux test VM's agents are separate: update them in the guest as well (with their publishers' SHA-256s) and pair it again (`vm.py linux … --claude/--pi/--codex PATH`).

## Linux SSH

Linux servers are small Lima VMs (Lima ≥ 2.0.0; 1 CPU, 1 GiB RAM, 8 GiB disk, no mounts), created only via `python3 scripts/ssh-vm.py NAME` with a distinct name.

### Prepare the Linux inventory

`~/VM-Archives/dispatch/` must hold these preserved files. They are not downloadable; get them from the environment maintainer.

| File | SHA-256 |
| --- | --- |
| `ubuntu-26.04-arm64.raw` | `7efd5db211147e80053e3e998ab232845b3c10a5aa4e76b6f2c575a84608c863` |
| `herdr-0.9.5-linux-aarch64` | `17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c` |

`ssh-vm.py` installs herdr only if it's missing. It never provisions agent CLIs, system tmux, Python, or the supported tmux fixture (normally `/opt/dispatch-test-tools/tmux/bin/tmux`). Prepare those explicitly and keep system tmux alongside. `python3 scripts/setup-linux-tmux.py` builds the fixture from the release and SHA-256 that `scripts/test-tools.lock.json` pins for macOS. Each agent CLI is the publisher's Linux arm64 build, checked against the publisher's SHA-256 (GitHub release asset digests; for Claude Code, the release's `manifest.json`), with its URL and digest in a `source.json` beside it.

### Pair and validate

```sh
python3 test/vm.py linux --server dispatch-rust-ssh-validation --codex /guest/path/codex --tmux /guest/path/tmux
python3 test/vm.py test SSHLinuxIntegrationTests SSHHostIsolationIntegrationTests HostLinuxIntegrationTests
```

With every agent installed in the Linux VM the usual way (CLIs in `/opt/dispatch-test-tools/<name>` linked from `/usr/local/bin`, the supported tmux in `/opt/dispatch-test-tools/tmux`):

```sh
python3 test/vm.py --vm NAME linux --server dispatch-rust-ssh-validation --codex /usr/local/bin/codex \
  --claude /usr/local/bin/claude --pi /usr/local/bin/pi --tmux /opt/dispatch-test-tools/tmux/bin/tmux
```

Lima forwards SSH on a port that changes at every start: read `sshLocalPort` from `limactl list --json` and update any host profile (`build/linux-ssh.json`, `build/host-linux-ssh.json`, their `known_hosts`) after a restart; a stale profile makes the Linux tests fail instead of skip. A VM listed as "Broken" ("vz driver is running but host agent is not") recovers with `limactl stop -f NAME` then `limactl start -y NAME`.

`--agent claude|pi` with `--claude`/`--pi PATH` pairs another agent. Pairing installs only the client's test key, pins the host key, and relays through a temporary encrypted tunnel restricted to the client VM. Once paired, Linux classes join the full suite. Under QEMU emulation, three native-identity cases are excluded, so emulated runs do not establish native x86-64 coverage.

## Existing local test resources

Ignored, host-local `build/test-environment.json` can rename VMs and move archives: `macos_vm`, `macos_shard_vm`, `manual_ssh_vm`, `linux_test_vm`, `linux_image`, `linux_herdr` (absolute paths; `~` isn't expanded). `--vm`/`DISPATCH_VM` take precedence. It never changes the fixed macOS herdr/Codex paths.
