# VM testing and profiling

Test selection and runner options are in [test/README.md](../test/README.md). This doc covers the machines those runners need.

**Agent rules:** never stop the test VM unless asked or recovering. Never use `dispatch-manual-ssh` (it's the user's). Never download replacements for missing pinned archives; fail instead. Keep captures and diagnostics under ignored `tmp/` or `build/`, and commit only reviewed, anonymized synthetic fixtures.

## macOS VM

A dedicated Tart VM (default `dispatch-tests`; override with `--vm NAME` before the subcommand, `DISPATCH_VM`, or [local inventory](#existing-local-test-resources)) runs desktop, focus, keyboard, and screenshot tests. Keep the host awake and leave the guest alone during runs. Each VM accepts one runner at a time. The runner syncs uncommitted source into `/Users/admin/dispatch-tests/workspace`, and keeps guest DerivedData.

### Prepare a new host

The host needs Apple Silicon, Xcode 26 with first launch completed, Homebrew in `/opt/homebrew`, `brew install openai/tools/tart`, and `bash scripts/setup.sh`. The image download is about 69 GB, plus disk and build products. The guest gets 4 CPUs, 8 GB of RAM, and a 1920×1080 pt Retina display.

`test/vm.py` copies two host binaries from **fixed paths** (finding them on `PATH` isn't enough):
- herdr 0.9.0 at `/opt/homebrew/bin/herdr`. Re-run setup after changing it.
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

### Parallel VM shards

`python3 test/vm.py clone-shard` creates `dispatch-tests-2`. `--shards auto` (the default) uses both VMs only if the lighter half has at least 180 s of recorded work and every VM's full allocation fits in RAM, after reserving the larger of RAM/4 and 8 GB for macOS. Whole classes are split by recorded duration, and Linux-paired classes stay on the primary VM. Merged results go to `build/vm-tests/<run>/`. Guest tool changes (`setup`, `rust`, `linux`) must be applied to both VMs, or the shard re-cloned.

### Results and recovery

Results are in `build/vm-tests/<run>/` (`test.log`, `TestSummary.json`, xcresults); timing history is in `tmp/profiling/test-runs/`. Runner self-tests: `python3 test/vm-runner.py`.

| Failure | Fix |
| --- | --- |
| Locked desktop / guest-agent timeout | `python3 test/vm.py stop; tart run dispatch-tests`, log in as `admin`/`admin`, enable auto-login, and disable idle lock. Agent log: guest `/tmp/tart-guest-agent.log`; restart it with `launchctl kickstart -k "gui/$(id -u)/org.cirruslabs.tart-guest-agent"`. Boot log: `build/vm-tests/dispatch-tests-boot.log`. |
| Stale guest test lock | Confirm nothing is running, then stop the VM and retry. |
| Missing Rust | `bash scripts/setup.sh`, then `python3 test/vm.py rust`. |
| Wrong display | Stop the VM and set 1920×1080 or 1280×832 pt at 2×. |
| Missing Claude/Pi | Install them, or select only suites whose dependencies are ready. |

## Linux SSH

Linux servers are small Lima VMs (Lima ≥ 2.0.0; 1 CPU, 1 GiB RAM, 8 GiB disk, no mounts), created only via `python3 scripts/ssh-vm.py NAME` with a distinct name.

### Prepare the Linux inventory

`~/VM-Archives/dispatch/` must hold these preserved files. They are not downloadable; get them from the environment maintainer.

| File | SHA-256 |
| --- | --- |
| `ubuntu-26.04-arm64.raw` | `7efd5db211147e80053e3e998ab232845b3c10a5aa4e76b6f2c575a84608c863` |
| `herdr-0.9.0-linux-aarch64` | `9c8db20fb7e7427b138d5367113f1621ffd319f2f65d6f009e2594029115f0d2` |

`ssh-vm.py` installs herdr only if it's missing. It never provisions agent CLIs, system tmux, Python, or the supported tmux 3.7c fixture (normally `/opt/dispatch-test-tools/tmux/bin/tmux`). Prepare those explicitly, keep system tmux alongside, and record versions and source hashes under `tmp/profiling/`.

### Pair and validate

```sh
python3 test/vm.py linux --server dispatch-rust-ssh-validation --codex /guest/path/codex --tmux /guest/path/tmux
python3 test/vm.py test SSHLinuxIntegrationTests SSHHostIsolationIntegrationTests HostLinuxIntegrationTests
```

`--agent claude|pi` with `--claude`/`--pi PATH` pairs another agent. Pairing installs only the client's test key, pins the host key, and relays through a temporary encrypted tunnel restricted to the client VM. Once paired, Linux classes join the full suite. Under QEMU emulation, three native-identity cases are excluded, so emulated runs do not establish native x86-64 coverage.

## Chat and UI fixtures

Fixtures run the real installed agent CLIs against a deterministic loopback model: no API key, inherited credentials removed, and personal config untouched. They are not a network firewall. Provenance: [Fixtures/README.md](../DispatchTests/Fixtures/README.md).

```sh
python3 test/codex-chat.py --keep /tmp/new-results          # empty dir; --codex PATH for another CLI
python3 scripts/codex_fixture.py serve --no-hooks --state /tmp/demo   # manual; run the printed launch command
python3 scripts/seed-codex-history.py --state /tmp/demo --turns 60   # then serve + launch --resume SESSION_ID
```

### Offline Codex scrolling fixture

`python3 scripts/offline-codex-demo.py serve`, then `... resume` in a Dispatch terminal after "History ready". The first run creates 120 real turns in `offline-chat-state/`. `--state`, `--turns`, and `--paragraphs` change the dataset, and size options apply only at creation. This exercises local rendering, not SSH. Profiling: [chat diagnostics](chat-diagnostics.md).

### Claude and Pi Messages fixture

```sh
python3 scripts/claude_fixture.py serve                # state /tmp/dispatch-claude-demo; --port, --delay
python3 scripts/claude_fixture.py launch [--integration] [--hooks] [--resume UUID]
python3 scripts/pi_fixture.py [--session ID] [--pi PATH]
```

Prompt keywords combine: `thinking`, `tool`, `permission tool`, `question`/`multiple questions`, `formatting`/`long`; anything else echoes. Claude runs with an isolated `CLAUDE_CONFIG_DIR`, and Pi with `STATE/pi-home` and only `bash`. Focused checks: `test/claude-chat.py [--endpoint-only]`, `test/pi-chat.py`, `test/pi-bridge.py`, each with a fresh `--keep tmp/profiling/...`. Pi RPC waits for `agent_settled`, not `agent_end`.

### Native Chat validation

Batch the relevant classes in one `vm.py test` run: Chat\* (discovery, drafts, queue, side, patch, presentation), Claude\*/HookTransport, Pi\*, and the SSH reconnect/recovery/lifetime classes. For remote Claude/Pi, pair with `--agent` and run `SSHClaudeIntegrationTests SSHLinuxClaudeIntegrationTests` or the Pi equivalents. Coverage is ARM64 only, so Intel macOS and Linux x86-64 agents are untested.

### Process statistics checks

The helper's `plugins/stats` tests (`cargo test` in `helper`) cover the native collectors. The live checks are `SSHProcessStatisticsIntegrationTests` (macOS cases in the VM). The Linux case reads `/tmp/dispatch-stats-linux.json` (`destination`, `options`) on the XCTest host and must not use a preconfigured ControlMaster.

### UI checks

For motion/layout changes, run `InterfaceMotionTests UIWalkthroughTests SplitSizingTests SettingsSynchronizationTests TerminalIntegrationTests`. Then check by hand: rapid sidebar reversal, divider restore, full screen, and Reduce Motion.

## Build profiling

Keep DerivedData. `python3 scripts/profile-build.py --label L [--clean] [--diagnostics] [--cache]` writes to `tmp/profiling/compilation/`, and `bash scripts/build.sh -showBuildTimingSummary` lists build tasks. Compiler caching (`COMPILATION_CACHE_ENABLE_CACHING=YES SWIFT_ENABLE_EXPLICIT_MODULES=YES`) speeds clean builds (about 55 s to 4 s once the cache is warm) but slows every edit (about +0.8 s for a body change, 15 s to 22 s for an interface change), so it's opt-in. Runtime benchmarks: [benchmarks](benchmarks.md).

## Existing local test resources

Ignored, host-local `build/test-environment.json` can rename VMs and move archives: `macos_vm`, `macos_shard_vm`, `manual_ssh_vm`, `linux_test_vm`, `linux_image`, `linux_herdr` (absolute paths; `~` isn't expanded). `--vm`/`DISPATCH_VM` take precedence. It never changes the fixed macOS herdr/Codex paths.
