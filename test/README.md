# Test commands

Run examples from the repository root unless a guest directory is explicitly shown.
Test entry points live here; build/setup tools and shared agent fixtures remain in
`scripts/`. See [VM setup and troubleshooting](../docs/vm_testing.md) and the
[performance benchmark guide](../docs/benchmarks.md) for longer workflows.

Desktop tests need an unlocked desktop and take keyboard/window focus. Prefer the
dedicated test VM while using the host. `./run.sh --test` prepares local build and test
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
python3 test/vm.py test ChatTests     # XCTest in the dedicated macOS VM
bash test/run.sh ChatTests           # XCTest on the current desktop
```

## XCTest on the current Mac

Use `./run.sh --test [options]` for first-time setup and test execution. It asks before
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
./run.sh --test                          # Prepare tools, then fast checks
./run.sh --test --suite full             # Full correctness coverage
./run.sh --test ClaudeChatIntegrationTests
./run.sh --test --suite exhaustive --list # Read-only selection, no setup
```

Setup does not change permissions, sudo policy, or system settings. Desktop tests
still require an unlocked desktop and Screen Recording permission; isolated SSH
fixtures need no sudo by default: test runs on this Mac set `DISPATCH_UNPRIVILEGED_SSHD=1`,
which builds the Debug helper without the root sshd monitor check (release helpers keep it)
and runs the fixture's sshd as the current user. The VM runner sets `0` to keep testing that
check behind a root sshd; set `0` here only with passwordless sudo. External Linux-host tests
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
`test/suites.json`; new unclassified cases remain in full and exhaustive.
Full uses detailed plain-local agent behavior and focused Codex/Claude/Pi transport
checks; exhaustive also retains the original detailed live matrix and 20-cycle
reconnect stress repetition. Security, reattachment, host-isolation and platform
regressions remain full. The case-level selections are recorded in [suites.json](suites.json).

Accepts short class/case names, fully qualified identifiers, repeatable `--skip`,
and `--recheck`. `--list` prints the selected suite, count, cases, and exclusions
without starting dependencies or tests. Explicit selectors and `--failed` cannot
be combined with `--suite`.

```sh
bash test/run.sh                    # Fast checks only
bash test/run.sh --suite full
bash test/run.sh --suite exhaustive --list
bash test/run.sh ChatTests TmuxProtocolTests
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

### Focused shell wrappers

These forward extra arguments to `run.sh`. `--recheck` forces a build check, and
additional selectors add tests to the wrapper's built-in selection.

- `chat-discovery.sh`: discovery, routing, end-to-end chat, and presentation.
- `chat-history.sh`: history, performance, tool grouping, discovery, and end-to-end chat.
- `chat-formatting.sh`: formatting, tool grouping, performance, and end-to-end chat.
- `tmux.sh`: protocol, output filtering, sessions, edge cases, chat, and integration.

```sh
bash test/chat-discovery.sh
bash test/chat-history.sh --recheck
bash test/chat-formatting.sh ChatPresentationTests
bash test/tmux.sh --recheck
```

### `ui-motion.sh`

Runs its fixed motion, mockup, terminal, chat presentation/performance/history selection
directly through a Debug Xcode build. It does not forward arguments or use `xcode.py`'s
build-reuse logic.

```sh
bash test/ui-motion.sh
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
- `test`: defaults to fast checks; accepts `--suite fast|full|exhaustive`, explicit classes/cases, `--list`, `--skip`, `--recheck`, `--failed`, and `--shards auto|1|2` (default `auto`: two VMs only when a shard VM exists, host memory allows it and it saves time; see [parallel VM shards](../docs/vm_testing.md#parallel-vm-shards)).
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

### `ssh-herdr-stream.py`

Standalone framed-controller regression probe. Run on the dedicated test machine;
requires existing herdr and already-built Rust `herdr-stream` example binaries.
`--herdr` and at least one `--controller` are required; repeat `--controller` for
additional runnable architectures. It does not accept unittest selectors.

```sh
python3 test/ssh-herdr-stream.py --herdr /absolute/path/to/herdr \
  --controller /absolute/path/to/examples/herdr-stream
```

## Agent chat fixtures

These commands use real installed agent CLIs and deterministic localhost model
fixtures, without a model API account. Use new or empty `--keep` directories; optional
CLI-path flags override PATH discovery. See the [shared fixture guide](../docs/vm_testing.md#claude-and-pi-messages-fixture)
and [native Chat validation](../docs/vm_testing.md#native-chat-validation).

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

## Capture and replay runs

Run the existing XCTest selection while preserving native helper lifetimes and the app journal:

```sh
python3 test/xcode.py --capture investigation-01 DispatchTests/ChatTests
python3 test/xcode.py --replay investigation-01 DispatchTests/ChatTests
python3 test/xcode.py --replay captures/
python3 test/xcode.py --tests-from build/replay/changed-tests.json --capture investigation-02
```

Capture and replay need a helper built with the `capture` Cargo feature. Debug builds and direct
`scripts/build-ssh-helper.py` runs include it; Xcode Release builds and archives leave it out, and
their helpers ignore `DISPATCH_CAPTURE` and `DISPATCH_REPLAY`.

New recordings stage in ignored `build/captures/<run>/`, with `raw/`, `app/`, original
executables in `helpers/<sha256>`, and `manifest.json`. After indexing, every explicitly
passing variant is copied unchanged into `captures/<run>/`. Failed, skipped, and
unattributed recordings remain in staging for investigation and must not be committed.
Run names cannot be reused; a newer run does not replace earlier successful variants. `--tests-from`
requires a non-empty JSON array of XCTest selectors so an empty changed set cannot
accidentally run the full suite.

Every live XCTest run first builds its candidate helper and replay tools, then replays
**all retained native captures**. Any mismatch, incomplete replay, missing worker, or
nonpassing retained record blocks the run and prints its case and fixture path. There
is no bypass switch. Inspect the evidence before fixing the implementation or explicitly
removing an intentionally obsolete fixture; the runner never removes or blesses mismatches.
macOS runs locally; Linux defaults to the bundled x86-64 helper and `build/linux-ssh.json`.
Use `--replay-helper PLATFORM=PATH`, `--replay-tool PLATFORM=PATH`, and
`--replay-ssh PLATFORM=PATH` to select other platform binaries and workers.

App journals use `app/<Class.test>/<invocation>.jsonl`. Replaying a corpus visits
every variant, running multiple XCTest rounds when a case has several recordings.
Each round keeps its own results under `build/app-replay/<id>/`. Different recorded event orderings remain separate
replay cases, including versions from intermittently failing tests. A mismatch flags a
case for investigation; it does not by itself prove flakiness or a regression. App replay
does not require helper preflight, because it consumes recorded helper responses.

Each native batch keeps the first mismatch in a private per-capture directory and
links it from the report. Successful streams are not copied unless explicitly requested.
Completion receipts distinguish a helper return (with its status) from a native-program
handoff; handoff does not claim that the native program succeeded. Older empty receipts
remain supported without inferring a completion kind.

On the Mac, build the current helper and replay tools offline and verify every
retained passing capture with one command:

```sh
python3 test/replay.py --build
```

This uses `captures/` and the existing `build/linux-ssh.json` worker for Linux
recordings. It applies the same strict comparison as the XCTest preflight:
missing inputs, incomplete replay, and mismatches fail and print the affected
fixtures. Failed recordings stay under `build/captures/`, outside this corpus.
`--dry-run` prints build plans without building or verifying captures.

Compare explicitly supplied original and candidate helper artifacts:

```sh
python3 test/replay.py captures/ --helper macos=/path/to/candidate-helper \
  --tool macos=/path/to/replay-tool
python3 test/replay.py captures/ --helper macos=/path/to/candidate-helper \
  --tool macos=/path/to/replay-tool --helper linux=/path/to/linux-helper \
  --tool linux=/path/to/linux-replay-tool --ssh linux=build/linux-ssh.json --require-same
```

The helper comparison writes `report.json`, `changed-tests.json`,
`unverified-tests.json`, and `rerun-tests.json` under `build/replay/<timestamp>/`.
Pass `rerun-tests.json` to `--tests-from` with a new `--capture` name to capture
changed or unverified cases. `changed-tests.json` selects only confirmed changes;
unsupported or missing baselines remain explicitly unverified in the report.

`passing-changed.json` isolates captures from previously passing app tests that the
original helper replayed completely but the candidate cannot reproduce. `--require-same`
returns failure for every changed or unverified variant and writes `gate.json`. The report retains
every affected version and its replay evidence directory. `passing-changed-tests.json`
selects those cases for a targeted live run. Investigate their first mismatch and
relate it to the intended fix before accepting the change: it may be intentional,
or it may expose a regression in previously working behavior. A new passing UI run
does not replace the old capture or automatically explain its mismatch.

The per-case SSH collector downloads an archive, checks every file checksum, publishes
the snapshot, then separately acknowledges its hash. It **never deletes source files**:
a helper may still be writing after a failed test. Unchanged acknowledged bytes are
skipped on later collections; changed versions keep their own checksum directory and
original filename. Transfer, unpack, checksum, and conflicting-destination failures
remain in the manifest and fail capture coverage. Source cleanup is a separate
run-level action after producer lifetimes are known to have ended.

Import historical captures without rewriting their bytes:

```sh
python3 test/capture.py import --run historical-01 --source /path/to/captures \
  --helpers /path/to/original-helpers.json --source-commit ORIGINAL_COMMIT --dry-run
```

Inspect the dry run, then repeat without `--dry-run`. Helper mappings are an array of
`{platform, path, image}`: platform is `macos` or `linux`, path names the original
binary to preserve, and image is its original absolute execution path. Unknown
legacy identities remain unknown. `--bindings FILE` can supply verified baseline
attributions keyed by `raw/`-relative capture path, each with the capture `sha256`,
`helper_sha256`, `image`, `platform`, and `binding_proof: {path, sha256}`. The proof
report and original helper must match their hashes; raw capture bytes never change.
`--outcomes FILE` accepts the runner's array of `{identifier, outcome}` records.

Collection regression checks use an existing real native capture:

```sh
TMPDIR="$PWD/build/capture-tests" DISPATCH_CAPTURE_TEST_SOURCE=/path/to/native.jsonl \
  python3 test/capture.test.py
```

Create the project-local temporary directory first. No live helper or network is
needed for this transfer/index check.

## Earlier tooling verification

For this documentation update, all 29 Python files parsed, all seven shell scripts
passed `bash -n`, and `--help` succeeded for all 25 Python commands supporting it and
all five `vm.py` subcommands. The Linux guest controller's help check used an inert
helper path solely to satisfy its import-time environment requirement.

Executed `benchmark.py` (9 tests), `vm-runner.py` (20 tests), and a `profile.py` timing
example successfully. This verifies command wiring and runner behavior; desktop,
agent, Rust, and Linux workloads were not rerun. Placeholder executable/image/staging
paths in examples must be replaced with the existing resources for the test machine.

The full and exhaustive desktop suites also build and launch the hardened Release app outside XCTest. This checks that a window and a real terminal remain alive, then quits the owned app. Run it separately with `python3 -B test/release.py`; `--app path/to/Dispatch.app` checks an existing build. It uses a temporary project-local home and retains its log and result in `build/release-smoke/`. Use a disposable Mac with zsh as the login shell, as for the desktop fixtures.
