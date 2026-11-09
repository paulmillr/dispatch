# Test commands

Run examples from the repository root unless a guest directory is explicitly shown.
Test entry points live here; build/setup tools and shared agent fixtures remain in
`scripts/`. See [VM setup and troubleshooting](../docs/vm_testing.md) and the
[performance benchmark guide](../docs/benchmarks.md) for longer workflows.

Desktop tests need an unlocked desktop and take keyboard/window focus. Prefer the
dedicated test VM while using the host. `./build.sh --test` prepares local build and test
dependencies; `bash test/run.sh` keeps build setup offline. VM provisioning can download its pinned image
and install dependencies. Linux runners require the existing archived VM/tool inventory.
Use a dedicated Linux test instance, never `dispatch-manual-ssh`.

Most Python commands accept `--help`. The `unittest` scripts also accept `-v`, `-q`,
`-f` (stop on first failure), and a `ClassName.test_method` selector. Shell wrappers
have no independent help parser. `profile.py` does not support
`--help`; `environment.py` and `selection.py` are import-only modules.

## Start here

```sh
python3 test/benchmark.py             # Fast benchmark-runner regression tests
python3 test/vm-runner.py             # Fast test-runner/cache regression tests
python3 test/model-fixtures.py        # Local endpoint/shell barrier regressions
python3 test/terminal-shell.py        # Shell integration directory-name injection regressions
python3 test/shell-config-audit.py -v # Custom shell startup configurations (real Bash, Zsh, Fish)
python3 test/tmux-config-audit.py -v # Custom tmux configuration and prefix audit
python3 test/tmux-fuzz.py            # Randomized tmux configurations, sessions and operations
python3 test/vm.py test ChatTests     # XCTest in the dedicated macOS VM
bash test/run.sh ChatTests           # XCTest on the current desktop
```

`shell-config-audit.py` compiles the production Swift wrapper/launch generators and
Rust startup generator, then runs real shells with temporary homes and dummy
commands. It needs macOS, `swiftc`, and `rustc`; set `AUDIT_BASH` and `AUDIT_FISH` to
additional shell binaries, and `RUSTC` if the compiler is not on PATH. It does not
download tools. The audit's findings are ordinary regressions now (`AUDIT_STRICT=1`
only matters for a case marked `known_bug`): Apple Bash profiles read once, Fish
wrappers as autoload files and XDG path lists, Zsh startup quoting/aliases and unset
variables, and quoted custom Bash executable paths. It tests shell startup in
interactive mode with piped input; it does not exercise the app UI or live SSH.

`tmux-config-audit.py` builds the production Rust tmux multiplexer and Swift prefix
logic, and uses private tmux sockets for local and relayed control streams. Set
`AUDIT_TMUX` to choose a tmux version. It covers the session's own prefix table reaching
the app's key handler, refused bindings, server window indices, and new panes running
`default-command`/`default-shell`, and sessions started after a server was opened.
The default temporary build cache is `/private/tmp/dispatch-tmux-audit-build`
(`AUDIT_TMUX_BUILD` overrides it). macOS must permit Unix sockets and Swift compiler
macros. No desktop focus or existing tmux server is needed. The Swift fixture
uses model stubs and copies the actual app table-selection and index-selection
methods and the `backends.prefix` reply type verbatim, fed with the real helper's reply;
it does not launch the app UI (`TmuxPrefixTableTests` does).

`tmux-fuzz.py` drives the same Rust tmux multiplexer
(`helper/multiplexers/tmux/examples/fuzz.rs`) against private tmux servers with random
options, hooks and session names, interleaving Dispatch's operations with commands a user
types into tmux (new, killed, renamed, swapped, linked and joined sessions, windows and
panes, live `set-option`, raw `@dispatch-window` values). After each step the published
topology must follow the server within 3 s. The seed picks the connection: the server's
socket, a tab's own `tmux -CC` on a PTY, or an unverified relayed stream. With no arguments
it runs the regression set (seeds 1-24, 60 steps, about half a minute); `--runs`, `--steps`
and `--seed` explore further, and a failing seed repeats with `--seed N --runs 1` (failing
runs' logs are kept, `--keep` keeps all). It shares the audit's build cache and `AUDIT_TMUX`.
Not checked, as documented behavior: a relayed stream's view after it ended (kept for a
reconnect) and a session whose every pane the app detached (quiet until restored).

## XCTest on the current Mac

Use `./build.sh --test [options]` for first-time setup and test execution. It asks before
installing missing Codex, Claude Code, Pi, tmux, and herdr tools, pinned by version and
SHA-256 in [`scripts/test-tools.lock.json`](../scripts/test-tools.lock.json). Native CLI
packages are downloaded directly; tmux is built against pinned static libevent and
macOS ncurses using Xcode. Node, npm, and Homebrew are not needed. Binaries and caches
stay under `build/`, with executable links in `build/test-tools/bin`. Ordinary app
builds do not install these test tools. `DISPATCH_SETUP_OFFLINE=1` prohibits downloads.
`DISPATCH_TEST_ANY_TOOL_VERSION=1` lets an offline Mac test with the newest other installed build of a
tool whose pinned version is missing; setup names each substitute.
`python3 -B scripts/setup-test-tools.py --dry-run` shows the pinned downloads,
build commands, and local executable links without changing files.

```sh
./build.sh --test                          # Prepare tools, then fast checks
./build.sh --test --suite full             # Full correctness coverage
./build.sh --test ClaudeChatIntegrationTests
./build.sh --test --suite exhaustive --list # Read-only selection, no setup
```

Setup does not change permissions, sudo policy, or system settings. Desktop tests
still require an unlocked desktop and Screen Recording permission; isolated SSH
fixtures need no sudo by default: test runs set `DISPATCH_UNPRIVILEGED_SSHD=1`, the VM runner
too, and run the fixture's sshd as the current user. Recordings name that fixture, so `0` (a root
sshd through passwordless sudo) replays none of the SSH recordings. External Linux-host tests
need the configured test host. Missing prerequisites are not a passing full suite.
The test bundle pins the app's appearance to Dark, so the system appearance setting does not matter.
Animation checks also require Reduce Motion to be disabled in macOS Accessibility settings;
full and exhaustive runs check it first and stop with that message instead of timing out.
Disable crash-report dialogs on the test VM with
`defaults write com.apple.CrashReporter DialogType none`, and dismiss any already
queued crash reports. They can steal focus from the test app. Full and exhaustive
runs check this setting before starting; setup does not change it automatically.
After dismissing dialogs, activate another app: a windowless UserNotificationCenter
can still own focus and block the test app. Preflight also rejects that state or
any UserNotificationCenter windows and asks you to recheck.
The older VM provisioner remains available; native tests prefer the pinned local
tools and fall back to that VM's existing tool paths when local tools are absent.
Full, exhaustive, and explicit XCTest selections run the shared portable preflight
before building the app tests. This also prepares the native `test-interface` helper;
a missing or changed helper invalidates the cached pass. Fast checks omit this gate.
Short-lived Unix-socket fixtures use the Mac's private temporary directory when the
checkout path exceeds socket limits; their existing teardown removes these fixtures.
Codex fixtures disable the managed updater and stop their owned package processes
before removing downloaded package copies. Failure logs and session files stay available.
The XCTest runner audits fixture homes registered during that invocation and fails on
leftover managed processes or package directories; see `build/TestFixtureResources.json`.

### `run.sh`

Prepares dependencies offline, regenerates the Xcode project, and invokes `xcode.py`.
No test selectors means **fast checks only**. Use `--suite full` for full correctness
validation or `--suite exhaustive` for the complete live matrix. All three entry
points (`run.sh`, `xcode.py`, and `vm.py test`) share the case manifest in
`test/suites.json`; new unclassified cases remain in full and exhaustive. Cases marked
`disabled` there run in no suite, only when selected explicitly.
Full uses detailed plain-local agent behavior and focused Codex/Claude/Pi transport
checks; exhaustive also retains the original detailed live matrix and 20-cycle
reconnect stress repetition. Security, reattachment, host-isolation and platform
regressions remain full. The case-level selections are recorded in [suites.json](suites.json).

A case belongs in fast only if it needs no desktop focus, live agent or SSH host, and also does none of these:
reaches `SSHRustTestResources.protocolBinary()` or `localHelper()` (the debug Rust helper is built by the portable
preflight, which fast runs skip); creates `UserDefaults(suiteName:)` (it writes a plist into the real
`~/Library/Preferences`; the default stores are safe, since `DISPATCH_TESTING=1` makes `UserDefaults.app` nil and
`Home.url` a temporary folder); proves that something did *not* happen with a fixed sleep, or asserts inside a real
wall-clock window; calls `TerminalRuntime.shared.start()`. Local python3 fixture peers over pipes are fine.

Accepts short class/case names, fully qualified identifiers, repeatable `--skip`,
and `--recheck`. `--list` prints the selected suite, count, cases, and exclusions
without starting dependencies or tests. Explicit selectors and `--failed` cannot
be combined with `--suite`.

```sh
bash test/run.sh                    # Fast checks only
bash test/run.sh --suite full
bash test/run.sh --suite exhaustive --list
bash test/run.sh ChatTests TmuxIntegrationTests
bash test/run.sh ChatTests/testOptimisticFailureResetAndCommands --recheck
bash test/run.sh --skip DispatchTests/SSHLinuxIntegrationTests
```

`--skip` excludes only the named selection; it does not automatically exclude every
test requiring a Linux host. Use explicit classes or the VM runner's environment setup.

Benchmarks remain opt-in. `--benchmarks` (or `DISPATCH_TEST_BENCHMARKS=1`)
without a suite implies `full`; it cannot be combined with `--suite fast`.
An explicit class/case selector selects exactly those tests, including benchmarks;
`DispatchTests` explicitly selects the whole target. `scripts/benchmark.py` selects
measurement classes explicitly and is unaffected.

Native picker walkthroughs retain endpoint startup, SSH setup, agent readiness,
scenario, and awaited teardown timings in `build/chat-walkthrough-validation/`;
the VM runner collects these alongside `TestTimings.json`.

```sh
bash test/run.sh --benchmarks
bash test/run.sh UIBenchmarkTests
```

For Linux SSH tests driven from this Mac, place the connection profile in
`build/linux-ssh.json` (and `build/host-linux-ssh.json` for host-detection tests).
Each profile contains `destination`, an `options` array of SSH arguments, and the
existing absolute guest paths for `codex`, `claude`, `pi`, and `supportedTmux` as
needed by the selected tests. Use a dedicated test SSH target. The existing
`/Users/admin/dispatch-tests/` profiles remain the fallback for macOS VM runners.
Host-detection profiles can optionally specify `distribution` and `label` for a
different Linux distribution; the defaults remain `ubuntu` and `Ubuntu 26.04`.
For a user-level herdr installation, set `herdr` to its absolute executable path.
Report runs with these overrides separately from the Ubuntu VM coverage.

A profile for the Lima test VM (docs/vm_testing.md), reached through Lima's forwarded
port with Lima's own key, so nothing in the VM changes (the two files can be the same; Lima
names the guest account after yours):

```json
{"destination": "<your account>@dispatch-linux-test-server",
 "options": ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes",
             "-o", "UserKnownHostsFile=<checkout>/build/linux-ssh/known_hosts", "-i", "<home>/.lima/_config/user",
             "-p", "<sshLocalPort from limactl list --json>", "-o", "HostName=127.0.0.1",
             "-o", "HostKeyAlias=dispatch-linux-test-server", "-o", "ConnectTimeout=5"],
 "codex": "/usr/local/bin/codex", "claude": "/usr/local/bin/claude", "pi": "/usr/local/bin/pi",
 "supportedTmux": "/opt/dispatch-test-tools/tmux/bin/tmux"}
```

`build/linux-ssh/known_hosts` holds `dispatch-linux-test-server` followed by the VM's
`/etc/ssh/ssh_host_ed25519_key.pub`. Paths must be absolute. While a profile exists,
`test/scrub.py` also derives needles from that VM; delete the profiles when done (the
`replays/` pre-push hook reads them too, so keep them current while pushing).

### `xcode.py`

Lower-level runner for an already prepared project. Reuses a build only when input
and product fingerprints match; always executes XCTest and rejects failed, empty,
or unexpectedly skipped results. Writes `build/TestResults.xcresult`,
`build/TestSummary.json`, `build/TestProfile.json`, `build/TestCases.json`, and
`build/TestTimings.json`. The timing report retains per-case outcomes/durations,
selected and executed identifiers, fingerprints, tool versions, stages, slowest
cases/classes, and comparison with the saved baseline. Missing, unexpected, or
repeated cases fail validation even if the summary is green. Changed selections
are reported explicitly and do not demonstrate an unchanged-suite speedup.
VM runs requiring Linux include pairing and relay cleanup in `wall_seconds` and
retain `guest_workflow_seconds` for comparison with older reports that omitted
those outer phases.

```sh
python3 test/xcode.py ChatFormattingTests --recheck
python3 test/xcode.py --skip DispatchTests/HostLinuxIntegrationTests
```

### Focused selections

Pass class names to the shared runner. Add `--list` to inspect the selection without
building or `--recheck` to force a build check. For the dedicated desktop VM, pass
the same class names after `python3 test/vm.py test`.

```sh
# Chat discovery, routing and presentation
bash test/run.sh ChatDiscoveryTests ChatRoutingIntegrationTests \
  ChatEndToEndTests ChatPresentationTests

# Chat history
bash test/run.sh ChatHistoryTests ChatPerformanceTests ChatToolGroupingTests \
  ChatDiscoveryTests ChatEndToEndTests

# Chat formatting
bash test/run.sh ChatFormattingTests ChatToolGroupingTests \
  ChatPerformanceTests ChatEndToEndTests

# tmux protocol, sessions and integration
bash test/run.sh TmuxEdgeCaseTests TmuxChatIntegrationTests TmuxIntegrationTests

# Motion, layout and presentation
bash test/run.sh InterfaceMotionTests MainMockupPresentationTests TerminalIntegrationTests \
  ChatEndToEndTests ChatPresentationTests ChatPerformanceTests ChatHistoryTests ChatToolGroupingTests
```

### `release.py`

The full and exhaustive desktop suites also build and launch the hardened Release app outside XCTest. This checks that a window and a real terminal remain alive, then quits the owned app. It uses a temporary project-local home and keeps its log and result in `build/release-smoke/`.
Use a disposable Mac with zsh as the login shell, as for the desktop fixtures.

```sh
python3 -B test/release.py                          # --app path/to/Dispatch.app checks an existing build
```

## macOS VM orchestration

On a new machine, follow [host preparation and first VM validation](../docs/vm_testing.md#prepare-a-new-host)
before these commands. That guide includes the required host binary paths,
guest desktop/sudo checks and recovery steps. Start with `python3 test/vm.py test ChatTests`;
the full suite also requires installed Claude Code, Pi and Node. Linux tests need
the separate [archived Linux inventory](../docs/vm_testing.md#prepare-the-linux-inventory).

### `vm.py`

`--vm NAME` is a global option and goes **before** the subcommand. The default comes
from `DISPATCH_VM`, then local inventory, then `dispatch-tests`.

- `setup`: creates/reuses the VM and prepares its tools; `--image` overrides the image.
- `rust`: copies and verifies the prepared host Rust toolchain into an existing VM.
- `test`: defaults to fast checks; accepts `--suite fast|full|exhaustive`, explicit classes/cases, `--list`, `--skip`, `--recheck`, `--failed`, and `--shards auto|1|2` (default `auto`: two VMs only when a shard VM exists, host memory allows it and it saves time; see [parallel VM shards](../docs/vm_testing.md#parallel-vm-shards)). Tests run this Mac's Debug build-for-testing (built once per run, reused when unchanged) copied into each guest; `--guest-build` builds in each guest with its Xcode instead.
- `linux`: pairs an archived Linux SSH server with the macOS client.
- `clone-shard`: clones the prepared VM as the second VM for sharded tests (briefly stops the VM; refuses hosts without memory for both; `--shard-vm NAME` overrides `NAME-2`).
- `stop`: stops the VM and releases its resources.

```sh
python3 test/vm.py --vm dispatch-tests setup
python3 test/vm.py --vm dispatch-tests setup --image YOUR_PINNED_TART_IMAGE
python3 test/vm.py --vm dispatch-tests rust
python3 test/vm.py --vm dispatch-tests test                # Fast checks only
python3 test/vm.py --vm dispatch-tests test --suite full
python3 test/vm.py --vm dispatch-tests test SSHTransportTests --recheck
python3 test/vm.py --vm dispatch-tests test --failed RUN_ID
python3 test/vm.py --vm dispatch-tests stop
```

For an explicitly XCTest-only rerun, set `DISPATCH_TEST_SKIP_PREFLIGHT=1` to
skip the portable Rust, protocol, and tmux checks. This does not skip the build
or the desktop checks, and does not establish portable-helper coverage.

Replace `RUN_ID` with an existing run under `build/vm-tests/`; `--failed` also accepts
a run directory or `TestSummary.json`. It cannot be combined with explicit selectors or `--suite`.
Each run retains results under `build/vm-tests/<timestamp>/` and timing profiles under
`tmp/profiling/test-runs/`. The VM stays running after tests.

Linux pairing accepts `--server`, `--agent codex|claude|pi`, and existing absolute
guest executable paths via `--codex`, `--claude`, `--pi`, and `--tmux`. Substitute the
installed paths below. Pairing changes the dedicated test server's authorized keys
and the client's test connection configuration; it does not install agent tools.

```sh
python3 test/vm.py linux --server dispatch-rust-ssh-validation \
  --agent codex --codex /absolute/guest/path/to/codex --tmux /absolute/guest/path/to/tmux
python3 test/vm.py test SSHLinuxIntegrationTests
python3 test/vm.py linux --server dispatch-rust-ssh-validation \
  --agent pi --pi /absolute/guest/path/to/pi --tmux /absolute/guest/path/to/tmux
```

### `vm-guest.sh`

Internal macOS guest entry point, normally invoked by `vm.py`. Requires the prepared
`admin` desktop. Clears previous guest result/audit/validation artifacts, checks the
desktop for full/explicit runs, and forwards selection to `xcode.py`, which runs
the shared portable preflight outside fast coverage. Fast runs do not synchronize agent CLIs or
start Linux. Full/exhaustive Linux coverage requires a configured test server;
missing dependencies do not silently exclude selected cases.

```sh
# Inside the prepared macOS test VM only:
cd /Users/admin/dispatch-tests/workspace
bash test/vm-guest.sh ChatTests --recheck
```

### `host-linux.py`

Runs host-detection XCTest against a separate Linux SSH instance. Accepts `--vm`
(default `dispatch-tests`) and `--server` (default `dispatch-host-detection-tests`).
Prepares the test SSH connection and invokes the macOS runner.

```sh
python3 test/host-linux.py --vm dispatch-tests --server dispatch-host-detection-tests
```

## Portable helper and shell tests

### `contrast.swift`

Executes the production Oklab correction and bounded cache on a Metal GPU, with
an independent Double-precision color oracle. Checks contrast, hue, gamut, alpha,
unchanged readable colors, cache hits, saturation, and reset. No desktop focus
is needed; a Metal device is required. The algorithm and cache are documented in [`Shaders.swift`](../Vendor/Term/Sources/TermApple/Shaders.swift).

```sh
xcrun swift test/contrast.swift
```

## Agent chat fixtures

Fixtures run the real installed agent CLIs against a deterministic loopback model: no API key, inherited credentials removed, and personal config untouched. They are not a network firewall. Use new or empty `--keep` directories; optional CLI-path flags override PATH discovery. Provenance: [Fixtures/README.md](../DispatchTests/Fixtures/README.md).

```sh
python3 test/codex-chat.py --keep /tmp/new-results          # empty dir; --codex PATH for another CLI
python3 scripts/codex_fixture.py serve --no-hooks --state /tmp/demo   # manual; run the printed launch command
#   launch --codex-arg=-c --codex-arg='model="m"' ...   passes options on to the Codex TUI
python3 scripts/seed-codex-history.py --state /tmp/demo --turns 60   # then serve + launch --resume SESSION_ID
```

### Offline Codex scrolling fixture

`python3 scripts/offline-codex-demo.py serve`, then `... resume` in a Dispatch terminal after "History ready". The first run creates 120 real turns in `offline-chat-state/`. `--state`, `--turns`, and `--paragraphs` change the dataset, and size options apply only at creation. This exercises local rendering, not SSH. Profiling: [benchmarks](../docs/benchmarks.md#chat-rendering).

### Claude and Pi Messages fixture

```sh
python3 scripts/claude_fixture.py serve                # state /tmp/dispatch-claude-demo; --port, --delay
python3 scripts/claude_fixture.py launch [--integration] [--hooks] [--api-key-helper] [--resume UUID]
python3 scripts/pi_fixture.py [--session ID] [--pi PATH]
```

Prompt keywords combine: `thinking`, `tool`, `permission tool`, `question`/`multiple questions`, `formatting`/`long`; anything else echoes. Claude runs with an isolated `CLAUDE_CONFIG_DIR` (with `--api-key-helper`, its settings' `apiKeyHelper` prints the dummy key from `FIXTURE_CLAUDE_KEY` instead of `ANTHROPIC_API_KEY`, and `requests.jsonl` marks such requests `"auth": "helper"`), and Pi with `STATE/pi-home` and only `bash`. Focused checks: `test/claude-chat.py [--endpoint-only]`, `test/pi-chat.py`, `test/pi-bridge.py`, each with a fresh `--keep tmp/profiling/...`. Pi RPC waits for `agent_settled`, not `agent_end`.

### Native Chat validation

Batch the relevant classes in one `vm.py test` run: Chat\* (discovery, drafts, queue, side, patch, presentation), Claude\*/HookTransport, Pi\*, and the SSH reconnect/recovery/lifetime classes. For remote Claude/Pi, pair with `--agent` and run `SSHClaudeIntegrationTests SSHLinuxClaudeIntegrationTests` or the Pi equivalents. Coverage is ARM64 only, so Intel macOS and Linux x86-64 agents are untested.

### Process statistics checks

The helper's `plugins/stats` tests (`cargo test` in `helper`) cover the native collectors. The live checks are `SSHProcessStatisticsIntegrationTests` (macOS cases in the VM). The Linux case reads `/tmp/dispatch-stats-linux.json` (`destination`, `options`) on the XCTest host and must not use a preconfigured ControlMaster.

### UI checks

For motion/layout changes, run `InterfaceMotionTests UIWalkthroughTests SplitSizingTests SettingsSynchronizationTests TerminalIntegrationTests`. Then check by hand: rapid sidebar reversal, divider restore, full screen, and Reduce Motion.

### `model-fixtures.py`

Checks request-specific barriers for both local model endpoints: independent
releases, cancellation, disconnects, late release, timeouts, duplicate markers,
and graceful process shutdown. Also checks the shell FIFO readiness/release
barrier. Uses temporary localhost HTTP listeners and disposable files; no agent
CLI or desktop is required.

```sh
python3 test/model-fixtures.py -v
```

A prompt beginning with `FIXTURE_BARRIER_<32 lowercase hex digits>` waits for
`barriers/<id>/release` after publishing `accepted.json`. `completed.json` records
`delivered`, `cancelled`, `disconnected`, `timed_out`, or `failed`; `completions.jsonl`
retains request outcomes. Reusing an ID is an error. These endpoint records do not
prove application completion: the native revocation tests also observe the real
agent's completed turn and drain tracked app callbacks before checking delivery.

### `codex-chat.py`

Checks the real Codex CLI against the local Responses fixture. Options: `--codex`, `--keep`.

```sh
python3 test/codex-chat.py --codex /absolute/path/to/codex --keep tmp/codex-chat-example
```

### `claude-chat.py`

Checks fixture HTTP behavior and real Claude sessions. Options: `--claude`, `--keep`,
and `--endpoint-only` to run the fixture checks without Claude installed.

```sh
python3 test/claude-chat.py --endpoint-only
python3 test/claude-chat.py --claude /absolute/path/to/claude --keep tmp/claude-chat-example
```

### `pi-chat.py`

Checks real Pi JSON and RPC sessions. Options: `--pi`, `--keep`.

```sh
python3 test/pi-chat.py --pi /absolute/path/to/pi --keep tmp/pi-chat-example
```

### `pi-bridge.py`

Exercises the bundled bridge inside an isolated interactive Pi PTY. Accepts `--pi`;
`--keep` is required and retains the terminal transcript and fixture artifacts.

```sh
python3 test/pi-bridge.py --pi /absolute/path/to/pi --keep tmp/pi-bridge-example
```

## Runner checks and shared utilities

### `setup.py`

Offline tests for project-local build tools: pinned archive provisioning and reuse,
checksum rejection, interrupted download cleanup, archive containment, version and
override validation, offline refusal, one combined confirmation, decline/EOF
cancellation, and scoped child approval. Synthetic archives exercise the real
download verification and extraction paths; external downloads are mocked.
Rust tests reject altered manifests and
archives before extraction. These tests never contact upstream servers or build
the app.

Launcher checks also verify that Python does not write bytecode to an external
cache prefix.

Launcher checks cover production flag aliases, configuration overrides, compact
output and retained logs, visible setup prompts, failure handling, and cancellation
of build children without restarting the app.

```sh
python3 test/setup.py -v
```

### `benchmark.py`

Fast unit tests for benchmark reporting, comparison compatibility, and result adapters.
This is not the performance runner; actual measurements use `scripts/benchmark.py`.

```sh
python3 test/benchmark.py -v
```

### `vm-runner.py`

Fast unit tests for test selection, build/preflight caches, source synchronization,
and VM orchestration using temporary fixtures and mocked external commands. Does not
start a VM or build the app.

```sh
python3 test/vm-runner.py -v
```

### `quality-metrics.py`

Checks workspace-writer and collection counting, Swift initializer parsing, and Rust
byte-literal/test-module normalization. Requires Python and `lizard==1.24.0`; uses
temporary fixtures and does not build the app.

```sh
python3 test/quality-metrics.py -v
```

### `profile.py`

Timing wrapper: `python3 test/profile.py OUTPUT_JSON STAGE COMMAND [ARG ...]`.
Appends a stage to an existing timing report, records elapsed time/status, and propagates
a failed command's exit code. Also exposes the `Profile` class used by the runners.

```sh
python3 test/profile.py build/example-profile.json runner-check python3 test/benchmark.py
```

### `environment.py`

Import-only loader for optional `build/test-environment.json`, a local string-to-string
mapping. Supported consumers use `macos_vm`, `manual_ssh_vm`, `linux_test_vm`,
`linux_image`, and `linux_herdr`. The configuration stays ignored and off guests.

```sh
PYTHONPATH=test python3 -c 'from environment import load; print(load().get("macos_vm", "dispatch-tests"))'
```

### `selection.py`

Import-only helpers normalize XCTest identifiers, extract explicit failures,
discover case names, and resolve all suite/selector/exclusion decisions. The
case manifest controls classification; timings never promote a test to fast.

```sh
PYTHONPATH=test python3 -c 'from selection import normalize; print(normalize(["ChatTests", "DispatchTests/ChatTests"]))'
PYTHONPATH=test python3 -c 'from selection import failed_tests; print(failed_tests("build/TestSummary.json"))'
```

The second example requires an existing summary with failures; a passing or invalid
summary raises an error rather than selecting the entire suite.

## Writing tests

Replay rules (I/O through `System`, waits, ids, teardown) are in
[docs/replay.md](../docs/replay.md#writing-tests-that-replay). Besides those:

- **Test data is fictional.** No real names, emails, hosts, keys or GPG fingerprints, not even in comments: use
  "Sam Example <sam@example.com>", "Robin Example", `0123456789ABCDEF…`. Captures are scrubbed by needle, so a
  real value in a fixture is also a needle collision waiting to happen.
- **tmux always gets its own socket.** Shells started from an agent or a terminal inherit the user's `$TMUX`, and a
  tmux client uses the socket named there unless `-S`/`-L` is given: `TMUX_TMPDIR` is no isolation while `$TMUX` is
  set. Fixtures run `env -u TMUX tmux -S <private socket> …`. Never run a bare `tmux kill-server`, and never
  `pkill`/`killall` tmux, herdr, ssh or sshd: end only the pids the fixture started and recorded. The helper already
  strips `TMUX` and passes `-S` (`helper/multiplexers/tmux/src/backend.rs`).
- **Typing into an agent over SSH.** A command and its Return sent as one burst arrive as a paste, and agents do not
  submit a paste. Type the command, wait until the screen echoes it, then press Return.
- **Accessibility ids inside a chat bubble.** On the Mac a bubble's `chat-message-<row>` identifier is what every
  element inside it reports; an inner control's own identifier never shows in `accessibilityFrames`. Look controls up
  by the bubble id plus their label (`accessibilityFrames("chat-message-" + id, label: …, in:)`). A SwiftUI Button
  inside another Button's label merges into the outer one: put it beside.
- **Removed setting values.** When a setting loses a case (a font, a theme), don't add its old name to a migration
  test list: the decoder falls back to the default for any unknown value, so one made-up value ("Removed Font") covers
  it, and a list of real removed names reads as if they were still supported. Name an old value only when it maps to
  something other than the default.

## Worktrees

A second checkout (`git worktree add`) builds and tests like the main one once it has the main tree's tools. Link or
`cp -cR` `build/{rust,rust-downloads,cargo,tools,test-tools,downloads}` from the main tree; for the iPhone and Watch
apps also copy `build/mobile-ssh` (the XCFramework *and* its `target`; `Mobile/Transport/Frameworks` links there, and
without `target` the next simulator build recreates the framework with one slice). Keep worktrees outside `/tmp`: a
`/tmp` vs `/private/tmp` executable path fails SSH consent's origin check in every SSH-login test. A worktree has no
`replays/`, so it runs everything live and the build's corpus check only warns.

`test/xcode.py` always uses `/tmp/dt-journal` and points its `checkout` link at the tree that ran last, so two
checkouts running tests at once break each other ("…/dt-journal/checkout/… couldn't be opened"). Run one at a
time (for example `until mkdir /tmp/dispatch-main.lock 2>/dev/null; do sleep 15; done; …; rmdir /tmp/dispatch-main.lock`).
`test/vm.py` syncs the tree it runs from, uncommitted edits included, so hold the same lock around VM runs when
several checkouts share the VMs, and check another session's work from a worktree of HEAD plus only your files (its
uncommitted SSH changes fail SSH replays with `open.command lifetime` mismatches).

Baselines ("did this fail before my change?") are built in a worktree of the commit in question, never by reverting
files in a shared tree for a while: a commit made meanwhile would capture the reverted state. In scripts that set up a
scratch tree, `cd <tree> || exit 1` on its own line and use absolute paths for `rm`, `cp` and `mv`: a failed
`git worktree add` or `cd` otherwise retargets every relative path at the main tree (that once deleted `replays/`).

`git worktree remove` deletes the worktree's ignored `build/` too: copy screenshots and reports out first. Agents in parallel trees share the simulators' recording service, so `pkill -f recordVideo` from one cuts another's recording; stop only the pid you started.

Merging branches made in parallel worktrees: `Dispatch.xcodeproj/project.pbxproj` (and
`DispatchMobile.xcodeproj/project.pbxproj`) conflicts every time (take either side, then
`python3 scripts/generate-project.py`); `test/suites.json` conflicts on neighbouring additions (union the
`cases`, keeping the base order); two branches that each added the next replay migration need one renumbered (the
ledger keeps the first). A patch carried from a tree whose build appended to `helper/core/src/wire/registry.txt` must
include the regenerated `Dispatch/Helper/HelperBinary.swift`, or the other tree's build stops with "HelperBinary.swift
updated from the helper build".

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Build fails only at `CodeSign Dispatch.app`: "bundle format unrecognized … In subcomponent: …/PlugIns/DispatchTests.xctest" | An interrupted test run left an empty `DispatchTests.xctest` skeleton in the Debug app. Remove that folder (it holds no files) and build again. The full log is under `build/logs/`; it has no `error:` line. |
| Helper build reports missing items that `grep` finds in the source | Cargo fingerprints by mtime, and a tool restored old mtimes on the edited files. `git diff --name-only -- helper/ \| xargs touch`. |
| An OCR wait fails with `Fixture wait … checks=1` | One expensive check, not a stuck UI: a missed read runs a dozen Vision passes (~6 s), longer than the 5 s wait, and a capture taken right after a change can hold the previous frame. |
| Every UI case fails with `CancellationError`, or SCK error -3811 | Another test host is running (another session's run). `pgrep -fl "xcodebuild\|Dispatch.app/Contents/MacOS/Dispatch"`, then rerun. Keep screenshots in a uniquely named folder. |
| Focus asserts (`isKeyWindow`, full screen) time out on the host | Another app is frontmost and a background-launched test host cannot take focus. Run in the VM, or with someone at the desktop. Unattended, a loop beside the run can hand it focus: every 1.5 s find the test host by its derived-data path (`pgrep -f "<derived data>/Build/Products/Debug/Dispatch.app/Contents/MacOS/Dispatch"`, never a user's own Dispatch) and `osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is <pid>) to true'`; stop it afterwards (it steals focus). Wrap unattended host runs in `caffeinate -d -i`: a locked desktop skips walkthrough cases. |
| `--capture` prints "stored N new captures" but exits 1 | `build/captures` held an earlier capture, and that is what was stored. Move it away first; trust a capture only with exit 0 and the case listed as passed. |
| Exhaustive `--capture` runs out of ptys | `sudo sysctl kern.tty.ptmx_max=999`. |
| Codex fixtures exit at once (IsADirectoryError) | `TEST_RUNNER_DISPATCH_TEST_FIXTURES` names a ledger *file* the fixtures append to, not a folder. Leave it to `xcode.py`. |
| iPhone keyboard assertions fail while `app.keyboards.firstMatch` exists | An earlier `typeKey` made the simulator minimize the software keyboard (its frame sits below the window). `xcrun simctl spawn <udid> defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO`, then shut down and boot the simulator. |
| iPhone UI test starts from earlier choices | The app's settings persist in the simulator: terminate the app, then `xcrun simctl spawn <udid> defaults delete <data container>/Library/Preferences/yachts.dispatch.mobile <key>` (a full path without `.plist`). |
| `xcodebuild test` of `DispatchMobileUITests` never returns after the result | It hangs archiving logs: bound it (`perl -e 'alarm 595; exec @ARGV' xcodebuild …`); the test's own result line counts. The xcresult's attachments (`xcrun xcresulttool export attachments`) include a screen recording, more reliable than hierarchy dumps, which list views hidden under a sheet. |

## Capture and replay runs

Tests replay their recorded I/O by default and run live when nothing is recorded for them:

```sh
python3 test/xcode.py DispatchTests/ChatTests                      # replay where replays/ has a journal, live otherwise
python3 test/xcode.py --capture DispatchTests/ChatTests           # record live tests in build/captures, store the passed ones
python3 test/xcode.py --capture --live DispatchTests/ChatTests    # record every test
python3 test/xcode.py --replay DispatchTests/ChatTests            # replay only the journals in build/captures
```

The corpus in `replays/` is a separate git repository, ignored here; without it only `--live` runs.
The workflows, the corpus, the build's corpus check and the `capture` tool
(inspect, grep, check, store, prune) are in [docs/replay.md](../docs/replay.md).

Collection regression checks use an existing real native capture:

```sh
TMPDIR="$PWD/build/capture-tests" DISPATCH_CAPTURE_TEST_SOURCE=/path/to/helper-capture.rpl.zst \
  python3 test/capture.test.py
```

Create the project-local temporary directory first. No live helper or network is
needed for this transfer check.
