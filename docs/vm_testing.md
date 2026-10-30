# VM testing

Test selection and runner options are in [test/README.md](../test/README.md). This doc covers the machines those runners need.

**Agent rules:** never stop the test VM unless asked or recovering. Never use `dispatch-manual-ssh` (it's the user's). Never download replacements for missing pinned archives; fail instead. Keep captures and diagnostics under ignored `tmp/` or `build/`, and commit only reviewed, anonymized synthetic fixtures.

## macOS VM

A dedicated Tart VM (default `dispatch-tests`; override with `--vm NAME` before the subcommand, `DISPATCH_VM`, or [local inventory](#existing-local-test-resources)) runs desktop, focus, keyboard, and screenshot tests. Keep the host awake and leave the guest alone during runs. Each VM accepts one runner at a time. The runner syncs uncommitted source into `/Users/admin/dispatch-tests/workspace`, and keeps guest DerivedData.

### Prepare a new host

The host needs Apple Silicon, Xcode 26 with first launch completed, Homebrew in `/opt/homebrew`, `brew install openai/tools/tart`, and `bash scripts/setup.sh`. The image download is about 69 GB, plus disk and build products. The guest gets 4 CPUs, 8 GB of RAM, and a 1920×1080 pt Retina display.

`test/vm.py` copies two host binaries from **fixed paths** (finding them on `PATH` isn't enough):
- herdr 0.9.5 at `/opt/homebrew/bin/herdr`. Re-run setup after changing it.
- Native Codex from the global npm layout: `npm install --global --prefix /opt/homebrew @openai/codex`, giving `/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`. Any version works.

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

### Host build

`vm.py test` builds for testing on this Mac (test/xcode.py's fingerprinted build, skipped when inputs are unchanged) and copies the products (`Dispatch.app`, the Term frameworks, the `.xctestrun`) with a digest manifest (`build/test-tools/xcode-prebuilt.json`) into each guest. The guest's `xcode.py` (`DISPATCH_TEST_PREBUILT=1`) checks the digest and runs `test-without-building`; it never compiles. A host Xcode newer than the guest's is fine (Xcode 27.2 products run under the guest's Xcode 26.2), but such a run no longer exercises the guest's compiler: `--guest-build` restores the old per-guest build.

### Parallel VM shards

`python3 test/vm.py clone-shard` creates `dispatch-tests-2`. `--shards auto` (the default) uses both VMs only if the lighter half has at least 180 s of recorded work and every VM's full allocation fits in RAM, after reserving the larger of RAM/4 and 8 GB for macOS. Whole classes are split by recorded duration, and Linux-paired classes stay on the primary VM. Merged results go to `build/vm-tests/<run>/`. Guest tool changes (`setup`, `rust`, `linux`) must be applied to both VMs, or the shard re-cloned.

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

## Linux SSH

Linux servers are small Lima VMs (Lima ≥ 2.0.0; 1 CPU, 1 GiB RAM, 8 GiB disk, no mounts), created only via `python3 scripts/ssh-vm.py NAME` with a distinct name.

### Prepare the Linux inventory

`~/VM-Archives/dispatch/` must hold these preserved files. They are not downloadable; get them from the environment maintainer.

| File | SHA-256 |
| --- | --- |
| `ubuntu-26.04-arm64.raw` | `7efd5db211147e80053e3e998ab232845b3c10a5aa4e76b6f2c575a84608c863` |
| `herdr-0.9.5-linux-aarch64` | `17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c` |

`ssh-vm.py` installs herdr only if it's missing. It never provisions agent CLIs, system tmux, Python, or the supported tmux 3.7c fixture (normally `/opt/dispatch-test-tools/tmux/bin/tmux`). Prepare those explicitly, keep system tmux alongside, and record versions and source hashes under `tmp/profiling/`.

### Pair and validate

```sh
python3 test/vm.py linux --server dispatch-rust-ssh-validation --codex /guest/path/codex --tmux /guest/path/tmux
python3 test/vm.py test SSHLinuxIntegrationTests SSHHostIsolationIntegrationTests HostLinuxIntegrationTests
```

`--agent claude|pi` with `--claude`/`--pi PATH` pairs another agent. Pairing installs only the client's test key, pins the host key, and relays through a temporary encrypted tunnel restricted to the client VM. Once paired, Linux classes join the full suite. Under QEMU emulation, three native-identity cases are excluded, so emulated runs do not establish native x86-64 coverage.

## Existing local test resources

Ignored, host-local `build/test-environment.json` can rename VMs and move archives: `macos_vm`, `macos_shard_vm`, `manual_ssh_vm`, `linux_test_vm`, `linux_image`, `linux_herdr` (absolute paths; `~` isn't expanded). `--vm`/`DISPATCH_VM` take precedence. It never changes the fixed macOS herdr/Codex paths.
