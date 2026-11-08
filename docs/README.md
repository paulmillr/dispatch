# Dispatch: summary for humans, and humans with agents

Dispatch: a macOS terminal (Swift/SwiftUI), a dependency-free Rust helper (`helper/`) that runs locally and on SSH
hosts, an iPhone client (`Mobile/`) and a Watch companion (`Watch/`). The docs are the specs: read the one for an area
before changing it, and change it along with the behaviour.

| Area | Read |
| --- | --- |
| Build, run, release overview | `README.md`, `docs/releasing.md` |
| Ownership and invariants (app) | `docs/architecture.md` |
| tmux, herdr, SSH, agent chat lifecycles | `docs/integrations.md` |
| What runs, is read or written on each machine | `docs/security.md` |
| Helper wire protocol | `helper/PROTOCOL.md` |
| Tests: runners, suites, worktrees, troubleshooting | `test/README.md` |
| Recordings, replay, migrations, scrubbing | `docs/replay.md` |
| Test VMs (macOS, Linux) | `docs/vm_testing.md` |
| iPhone/iPad, Watch, dictation | `docs/ios.md`, `docs/watch.md`, `docs/dictation.md` |
| Benchmarks and profiling recipes | `docs/benchmarks.md` |

## Commands

```sh
./run.sh --just-build                      # Debug build (also replays the helper corpus, below)
python3 scripts/generate-project.py        # after adding/moving source files; commit both project.pbxproj
bash test/run.sh [Class[/testCase] ...]    # XCTest; no selector = fast suite
python3 test/xcode.py --capture DispatchTests/Class/testX   # record one test; then --replay it
python3 test/vm.py test Class              # desktop tests in the macOS VM (preferred over the host)
test/run.sh --platform ios [Class]         # iPhone tests in the simulator
cd helper && cargo test --offline --features dispatch-helper/capture
```

## Rules that are expensive to break

- **Debug builds validate the helper recordings in `replays/`** and fail on any mismatch. They apply pending replay
  migrations first and reuse a passing result only while its helper and corpus are unchanged. A missing corpus emits
  a warning and leaves the helper unchecked. Replay intentional changes before migrating or re-recording the affected
  cases ([replay](replay.md)); `replays/` is its own git repository.
- **Replay first, record last.** After a change, replay the affected classes; the failures are exactly what changed.
  Record again only tests you changed on purpose and understand. Never re-record everything to make failures go away.
- **`helper/core/src/wire/registry.txt` is append-only**: never reorder or delete lines.
- **All I/O and machine facts go through `System`** (`Dispatch/Helper/System.swift`), waits through
  `TestSupport.eventually`, ids from `System.uuid()`; `test/xcode.py` refuses direct environment, home and bundle reads.
- **tmux always gets `-S <private socket>`** under `env -u TMUX`: agent shells inherit the user's `$TMUX`. Never run a
  bare `tmux kill-server`, and never `pkill` tmux, herdr, ssh or sshd.
- **Test data is fictional**: no real names, emails, hosts or keys.
- **Chat composers stay `ChatCaretTextView`/`ChatEditorTextView`**, never a SwiftUI `TextField` (120 Hz performance).
- **Shared sources from `Dispatch/` also compile into the iPhone app**: `project-mobile.yml` lists them explicitly
  ([shared sources](ios.md#shared-sources)); guard Mac-only code with `#if canImport(AppKit)` and check with
  `python3 test/ios.py`.
- `build/` holds every tool and artifact, `tmp/` is scratch; setup never needs sudo or Homebrew.
