# iPhone helper spike: `dispatch-helper --remote --stdio` on a plain exec channel

Status: Phase 0, plan items 2, 4 and 5 and helper change 1, 2026-10-18, on this Mac
(macOS 27.0, arm64) over a loopback sshd, and on Linux: the Lima VM `dispatch-rust-ssh-validation`
(Ubuntu 26.04 arm64, 1 CPU, 947 MB, system tmux 3.6, herdr 0.9.3) over its forwarded SSH port.
Branch `mobile-streams/helper-stdio`.

The iPhone has no shell. Per host it opens one SSH connection and runs the helper on a non-PTY exec
channel: no `login` wrapper, no `connect` bridge, no login shell, no `TERM`. Terminals are tmux windows
or herdr tabs the helper attaches to. The helper dies with the connection and reattaches next time.

Result: this mode works for hello, host identity, stats, tmux, herdr, terminal streaming, Claude
approvals and queue, Codex, Pi, and reattach after a dropped connection, once the six helper fixes below
are in. Several things must be done by the client; they are listed under "What the client must do".

## The command line, environment and grant

The phone runs this on an exec channel. Do not request a PTY (no `pty-req`), do not send `env` requests:

```sh
exec "$HOME/.dispatch/bin/versions/<sha256>/dispatch-helper" --remote --capabilities agent.events,agent.inspect,agent.pi,agent.pi.configure,agent.queue,agent.side,agent.submit,agent.version,backend.register,cancel,events,file.read,file.text,herdr.rpc,herdr.start,herdr.terminal,hooks.configure,host.identity,input.window,shell.lifecycle,stats.ping,stats.processes,stats.sample,tmux.pane --stdio
```

- `<sha256>` is the bundled helper's digest, as `SSHBootstrap.install` uploads it today.
- The capabilities are the Mac's full profile with hooks on (`SSHIntegrationGrant.capabilities(.full, hooks: true)`),
  sorted. `--hooks` is not needed because `hooks.configure` is in the list.
- The remote user's shell runs the command with `-c` (sshd's rule). `"$HOME/…"` works in sh, bash, zsh,
  fish and csh. `exec` keeps the helper as the direct child of sshd.
- Environment: none. The helper needs only what sshd sets (`HOME`, `USER`, `LOGNAME`, `SHELL`,
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin` on macOS). It asks the login shell for the real `PATH` itself
  (fix 2). `TERM` is not needed: the helper sets `TERM=xterm-256color` for the shells it starts, and
  tmux and herdr set it in their panes.
- Frames are the existing wire (`helper/PROTOCOL.md`) on the channel's stdin and stdout. `hello.version`
  equals `HelperBinary.version` (`13472849151989474303` at this commit), the same number as
  `build/helper-rust/bin/protocol-version`.

## The hello the phone sends

```
hello {features: ["interaction.options", "chat.list", "projects.recent", "multiplexers.versions", "terminals.coalesce", "launch.names", "stdio.liveness"]}
```

The reply adds `features` (the accepted names) and lists `chat.list` and `projects.recent` in `ops`.
Its `account` also carries `login_home` when the login shell's `$HOME` differs from the passwd home (the phone shortens paths to `~` with it).
A hello without `features` (the Mac app) gets exactly the reply it always got, and every behaviour
below stays off for that connection, even when the phone and the Mac share one helper.

| Feature | What the phone gets |
| --- | --- |
| `interaction.options` | Claude approvals offer a fourth choice, id `Session`, label "This session" (detail: "Allow Bash(python3 -c:*) until Claude exits"), when Claude's `permission_suggestions` hold allow rules; answering its index allows and adds those rules with destination `session`. Codex 0.162 rejects `updatedPermissions` in PermissionRequest hooks ("fail closed"), so Codex offers no session choice; Pi has no approvals in this path. |
| `chat.list` | `chat.list {}`: one row per agent-bound terminal (terminal, session, binding, key, label, name, cwd, busy, attention, activity, title, preview, time_ms, errors). 2 to 4 ms for two agents. |
| `projects.recent` | `projects.recent {limit?}`: `[{path, time_ms, agents, exists}]`, newest first, from Claude `projects/`, Codex `sessions/Y/M/D` and Pi `sessions/` under their config roots. Under 1 ms on the fixture. |
| `multiplexers.versions` | `multiplexers.list` rows add `installed`, `version` ("3.7", "3.6", "0.9.3"), for tmux `paste_state` (false before 3.7: show the older-tmux warning), and `running`: whether that server runs for this user, probed without starting one (tmux `-N list-sessions`, `herdr status server`). Check it before `backends.open` for herdr, which starts a herdr server. |
| `launch.names` | A `terminals.create` with `launch` names its new tmux window (`new-window -n`, so tmux no longer renames it "dispatch-helper") or herdr tab (`tab.rename`) `claude`, `codex` or `pi`, for the window's life. Splits keep their window's name. Verified on both multiplexers, macOS and Linux. |
| `stdio.liveness` | A `--remote --stdio` helper ends when this client has sent nothing for 45 s, so a connection whose close never arrives (seen on Lima: a VM-side helper alive for minutes after the phone's side died) never leaves two helpers serving one phone. **The phone sends `echo` (its latency ping) at least every 15 s while connected.** Helpers in other modes drop the feature from the accepted list. With a 3 s test limit both macOS and Linux helpers exited 2.0 s after the last ping. |
| `terminals.coalesce` | A stream's `terminal.output` is joined for at most 4 ms and 60 000 bytes. |

`terminals.coalesce`, 50 MB of `yes` through a tmux window over ssh:

| Host | Without | With |
| --- | --- | --- |
| macOS 27 (tmux 3.7) | 2.86 to 3.07 M frames, 270 to 284 MB on the wire, 22.3 to 23.7 s | 5 024 to 6 085 frames, 79 MB, 20.2 to 27.4 s |
| Ubuntu 26.04 VM (tmux 3.6) | 28 810 frames, 80.6 MB, 8.4 s | 1 561 frames, 78.8 MB, 7.3 s |

Throughput stays bound by tmux itself (22.7 s with no client at all on macOS); the frame count, the
phone's decode work and the macOS wire overhead (3.4x to 0.4 %) drop.

`host.identity` stays ungated: the Mac's helper captures record the `host.identity` native job's
output, and a replay answers that job with the recorded bytes, so hello replays unchanged; new
recordings simply carry `os_version`/`os_label`, which the Mac's decoder ignores. No `identity.os`
feature was added.

## The harness

`test/helper-stdio.py` runs the helper exactly as the phone does and asserts each step:

```sh
# build (what scripts/build-ssh-helper.py does for one macOS target)
cd helper && PATH=$PWD/../build/rust/bin:$PATH CARGO_HOME=$PWD/../build/cargo MACOSX_DEPLOYMENT_TARGET=14.0 \
  cargo build --offline --frozen --profile local -p dispatch-helper --target aarch64-apple-darwin --target-dir ../build/hs-target
# run (codec cases only without --live)
python3 test/helper-stdio.py --live [--helper PATH] [-k test_7] [--keep]
```

- Without `--live` (or `DISPATCH_HELPER_STDIO_LIVE=1`) only the codec case runs. The default helper is
  `build/hs-target/aarch64-apple-darwin/local/dispatch-helper`, then `build/helper-rust/bin/darwin-universal`.
- Fixture root: `/tmp/hs-<pid>` with its own `HOME`, a user-owned sshd on a free loopback port
  (`UsePAM no`, `StrictModes no`, keys under the root, `SetEnv` only for isolation:
  `HOME`, `SHELL=/bin/bash`, `TMUX_TMPDIR`, `HERDR_SOCKET_PATH`, `XDG_CONFIG_HOME`, `DISPATCH_TEST_ROOT`),
  the helper copied to `~/.dispatch/bin/versions/<sha>/dispatch-helper`, and tmux, herdr, claude, codex
  and pi from `build/test-tools/bin` linked into `~/.local/bin`, which only `~/.bash_profile` names.
- Safety: every tmux command the script runs carries `-S <root>/…` and runs without `TMUX`; herdr is
  reached only through the root's socket; teardown kills only pids it recorded, after checking their
  command lines. It is safe to run from inside the user's tmux. `--keep` leaves everything running and
  prints how to stop it.
- Codec: a Python binary value codec reading the generated names from `Dispatch/Helper/HelperBinary.swift`.
- Screens: Chat input needs a published screen (see below). The harness publishes the visible screen,
  cursor and faint tail about ten times a second, from `tmux capture-pane` for tmux and from a small VT
  model fed by the attach stream for herdr, standing in for the phone's Term surface.
- Not classified in `test/suites.json`: that manifest holds only XCTest identifiers and
  `test/selection.py` rejects anything else as stale.

Full run on this Mac: 10 cases, all pass, 72 to 85 s with the local build and 93 s with the Mac build's
`build/helper-rust/bin/darwin-universal` (Debug, capture feature).

### On a Linux host (`--remote`)

```sh
python3 test/helper-stdio.py --live --lima dispatch-rust-ssh-validation            # or --remote user@host:port --identity KEY
python3 test/helper-stdio.py --live --lima dispatch-rust-ssh-validation --prepend /opt/dispatch-test-tools/tmux/bin -k test_2   # tmux 3.7c
```

`--remote` runs every case on the SSH destination: the same private root (`/tmp/hs-<pid>` on the host,
with its own HOME, `DISPATCH_TEST_ROOT`, tmux `-S` socket, herdr socket and XDG folder), the Linux helper
from `build/helper-rust/bin/linux-<arch>` uploaded to `~/.dispatch/bin/versions/<sha256>/` under that
HOME (size and SHA-256 checked), and the five fixture scripts copied next to it. The host's own sshd is
not configured, so the isolation variables come from `env` in the exec command
(`cd <home> && exec env -u TMUX HOME=… SHELL=/bin/bash TMUX_TMPDIR=… HERDR_SOCKET_PATH=… XDG_CONFIG_HOME=… DISPATCH_TEST_ROOT=… <helper> --remote --capabilities … --stdio`).
The fixture's own commands use one private ControlMaster; helper sessions use fresh connections.
Agents are the host's (`/usr/local/bin/claude`, `codex`, `pi`). Teardown stops the root's tmux and
herdr, kills the pids it recorded (after checking their command lines) and removes the root on both
sides. `--lima NAME` reads the destination, user and port from `limactl list --json`.

Full run on the VM: 10 cases, all pass, 56 s; 11 cases with the feature work, 67 s (macOS: 11, 93 s). The 1 GB VM cannot run all agents at once, so each case
ends the agents it started.

## Results per item

| Item | Result | Numbers |
| --- | --- | --- |
| Build (plan 5.1) | pass | local profile, one target: 10.5 s cold in this worktree, 2 to 6 s incremental; 6.1 MB arm64. Mac app Debug build (all four helper targets, schema check): BUILD SUCCEEDED, `HelperBinary.swift` unchanged |
| `hello` over pipes and over ssh | pass | spawn to hello reply: 255 ms over pipes, 73 ms over ssh (both include the login-shell PATH probe; ssh varies 70 to 110 ms between runs) |
| `host.identity` OS string | pass after fix 1 | `os_label: "macOS 27.0"`, `os_version: "27.0"`; Linux gives `"Ubuntu 24.04"` from NAME and VERSION_ID (unit-tested parser; no live Linux run, see open issues) |
| latency (`stats.ping`) | pass | the Mac's ping is an `echo` round trip (`HelperStatistics.ping`); median of 20: 0.16 ms over loopback ssh, 0.09 ms over pipes. `stats.sample {plugin:"stats"}` answers |
| `multiplexers.list` | pass | tmux mux 0, native 1, herdr 2; tmux and herdr `external: true` |
| `backends.list` | pass after fix 2 | tmux was missing with sshd's PATH (Homebrew, `~/.local/bin`); herdr already had its own login-shell lookup |
| `backends.create` tmux, no server | pass after fix 3 | starts `tmux new-session -d`, then opens: 41 ms. `backends.open` alone still fails with no server, by design |
| `backends.create`/`open` herdr | pass | starts `herdr server` (detached, stdio on /dev/null): 280 ms |
| `terminals.create` with cwd | pass | tmux window / herdr tab in the first space, cwd as given: 30 ms |
| `terminals.attach` + `observe`, `printf` output | pass | output arrives as `terminal.output` notifications on the attach id; `terminal.input_window` grants 1 MiB input credit |
| `terminals.input` | pass | `bytes` must be raw bytes (tag 11); a base64 string or an integer array is refused with `invalid_input` |
| `terminals.resize` | pass | tmux window becomes 100x30; herdr reports the new viewport |
| `terminals.scroll` | tmux: `scrollback_app_owned` (by design); herdr: pass | tmux: the client scrolls its own Term; the attach stream replays the whole pane history on every (re)attach (500 lines arrive in 3.2 KB), and `terminals.seek` is unsupported. herdr scrolls server side and sends `terminal.scroll {offset, max, viewport}` |
| `close.request` idle check | pass after fix 4 | idle shell: `{closed:false, confirmation:false}`; then `policy:prompt` closes the window/tab. Before the fix, every window the helper created counted as busy (macOS bash 3.2 startup) |
| tmux and herdr outlive the helper session | pass | servers keep running; their stdio is not the channel, so ssh does not hang on exit |
| observe throughput, `yes \| head -c 50M` (plan 5.1) | pass | tmux: 23 to 31 s, 1.7 to 2.3 MB/s; 78.6 MB of terminal bytes in 2.9 M frames, 271 MB on the wire. herdr: 24.7 s, 2.1 MB/s, 2 frames, 178 KB on the wire. The same `yes` in a tmux pane with no client at all takes 22.7 s: tmux's own emulator is the bound, not the helper or ssh. See change list item 1d |
| Claude, tmux window and herdr tab: launch with `launch` + `environment` | pass after fixes 5 and 6 | launch to agent binding: 0.6 s (tmux), 0.25 to 1.1 s (herdr); hooks land in the agent's own `CLAUDE_CONFIG_DIR/settings.json` |
| approval arrives as `interaction.opened`, `interactions.answer` | pass | send to `interaction.opened`: 45 to 85 ms; option 0 allows (marker file written), option 1 denies; the fixture reports the tool result |
| `queue.add/list/update/reorder/remove/start/hold`, Claude | pass | helper-held queue (Claude has no native queue): hold, add three, edit, reorder, remove, start one, release hold, drains in order |
| Codex (`scripts/codex_fixture.py`) | pass, with a native trust step | `launch codex` + `CODEX_HOME`; Codex shows "Hooks need review" on first start and only runs Dispatch's hooks after "Trust all" in its TUI; the conversation id appears with the first prompt (binding session `""` then the thread id); approval through the PermissionRequest hook works; native queue: `queue.add` accepted (consumed at once while idle), `queue.hold` is `unsupported` |
| Pi (`scripts/pi_fixture.py`) | pass | needs `installation.install {launch: pi, enabled: true}` on the same connection before the launch; extension lands in `PI_CODING_AGENT_DIR`; chat reply; helper-held queue (`native_queue: false`) with `follow_up` mode |
| Survival: SIGKILL the ssh client, and separately SIGKILL the helper, with Claude running in a tmux window and a herdr tab | pass | helper gone 35 to 70 ms after the drop; both agents alive; new connection to hello: 71 to 113 ms; to both backends open + both chats open + both `chat.page`: 212 to 290 ms; same conversation ids and pids; all earlier records present; a new approval after reattach routes to the new helper |
| Helper queue across a drop | fails by design | items held by the helper (`queue.add` while held) are gone after the drop: `queue.list` is `[]`. Codex's native queue lives in its app-server, which the launcher owns inside the tmux window, so it survives |

Linux (Ubuntu 26.04 arm64 VM, same cases; macOS numbers above for comparison):

| Item | Linux result | Linux numbers (macOS) |
| --- | --- | --- |
| `hello` over ssh | pass | spawn to hello: 85 to 133 ms (73 to 113 ms) |
| `host.identity` | pass | `os_label: "Ubuntu 26.04"`, `os_version: "26.04"`, `os_name: "Ubuntu 26.04 LTS"`, `distribution: "ubuntu"` |
| echo median | pass | 0.2 to 1.2 ms through Lima's port forward (0.16 ms) |
| `backends.list` | pass | tmux, herdr found on sshd's own PATH (`/usr/local/bin:/usr/bin:…:/snap/bin`); the profile's folder is still added |
| tmux `backends.create` + open, no server | pass | 28 to 40 ms (41 ms) |
| herdr create + open | pass | 270 to 580 ms (280 ms) |
| tmux before 3.7 | observed | Ubuntu 26.04 ships tmux 3.6: `#{bracket_paste_flag}` is empty (3.7c reports `0`/`1`). The helper then types into a bound agent without paste-readiness verification (Claude send, approvals and queue all passed on 3.6) and refuses typing into anything else ("This tmux server cannot report bracketed-paste state. Use the terminal to send input.", tmux `ops.rs`) |
| observe throughput, tmux | pass | 3.6: 7.2 to 8.6 s, 6.1 to 7.3 MB/s, 28.8 k frames, 80.6 MB on the wire (2.5 % overhead); 3.7c: 6.7 s, 7.8 MB/s. macOS: 23 to 31 s, 2.9 M frames, 3.4x overhead: macOS ptys hand tmux one line per read |
| observe throughput, herdr | pass | 1.8 to 3.2 s, 16 to 29 MB/s (24.7 s) |
| Claude in tmux / herdr | pass | launch to binding 0.46 to 0.85 s; send to `interaction.opened` 60 to 720 ms on the 1-CPU VM (45 to 85 ms) |
| Codex, Pi | pass | launch to binding: Codex 0.6 to 1.8 s, Pi 1.0 s; Codex's hook trust step is the same |
| Survival | pass | ssh client killed: helper gone after 1.8 s (the loss reaches the guest's sshd through Lima's port forward late; 35 to 80 ms on macOS); helper killed: 26 to 41 ms; reconnect to hello 109 to 225 ms; to both chats paged 259 to 612 ms (212 to 290 ms) |
| Helper queue across a drop | fails by design, as on macOS | `queue.list` is `[]` after the drop |

What each harness fixture supports in this mode: Claude: launch, hooks, approvals (allow/deny), helper
queue, history, reattach. Codex: launch, approvals after the native hook trust, native queue, history
after the thread binding. Pi: launch with the optional extension, chat, helper queue. Questions
(`AskUserQuestion`), side chats and Nanocodex were not exercised.

## Helper fixes on this branch

1. `host.identity` adds `os_version` and `os_label` (macOS `kern.osproductversion` as "macOS 26.1";
   Linux NAME and VERSION_ID as "Ubuntu 24.04", else PRETTY_NAME or NAME). Existing fields unchanged.
   Commit 884ccb13; tests `system::inspect::identity::tests`.
2. A `--remote --stdio` helper without the login wrapper asks the login shell for its PATH once at
   startup (`$SHELL -lc 'printf … "$PATH"'`, stdin `/dev/null`, own process group, killed after 3 s),
   puts its entries first, keeps sshd's, and appends existing well-known folders (`/opt/homebrew/bin`,
   `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, `~/bin`, Nix and Linuxbrew paths). It is set before
   any thread starts, so tmux, herdr, their servers and agent launches inherit it. Skipped for the Mac's
   greeting probe (`--capabilities ''`) and under replay. Commit 6c1ac854; tests `system::search::tests`.
3. `backends.create` goes through a new `Multiplexer::start` (default: `open`). tmux starts its server
   with one detached session when none runs (`tmux -u [-S key] new-session -d`, outside any enclosing
   tmux), then opens it. `backends.open` still never creates work. Commit 25c24e49; tests
   `mux::start_tests` (tmux crate).
4. The idle check accepts the helper's own bash startup (`sh --noprofile -il`, used for bash before 4.2,
   i.e. macOS `/bin/bash`), so Close tab terminates idle windows the helper created. This also affects
   the Mac. Commit aa1c72d8; tests `system::inspect::tests`.
5. Launch setup treats a `--remote` helper as remote even without the login wrapper, so hooks go into
   the launched agent's own config root (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `PI_CODING_AGENT_DIR`)
   instead of the account default. Commit fe732b95; covered by the live Claude, Codex and Pi cases.
6. A launcher's setup asks its named helper (`DISPATCH_HELPER_ENDPOINT`) again for up to 3 s while that
   helper is alive but does not yet claim the process: herdr reports a new pane's tty asynchronously, and
   the launcher could otherwise start Claude without hooks (seen once in three herdr launches). Hooks
   never wait. This also affects the Mac. Commit 2cf12515; tests `system::sender::tests`.

Schema: none of these change the wire schema; `HelperBinary.version` is unchanged and the Mac build's
codec check passed. `helper/PROTOCOL.md` says it is generated by `helper/protocol.py`, which is not in
the repository; its `backends.create` row was edited by hand.

Rust tests (module-filtered, each well under a minute):

```sh
cd helper && PATH=$PWD/../build/rust/bin:$PATH CARGO_HOME=$PWD/../build/cargo
cargo test --offline --frozen -p dispatch-helper-core --lib     # 30 passed
cargo test --offline --frozen -p dispatch-helper-tmux --lib     # 8 passed
```

The crates have no `main` test target (`autotests = false`, no `[[test]]`); tests are `--lib` unit tests.

## What the client must do

- Publish screens. Chat input (`chat.send`, `queue.start`, typed answers) is verified against the
  screen the client publishes with `terminals.publish {mux, terminal, text, cursor, faint_tail}`, as the
  Mac's `TerminalBackend.publishScreen` does (visible text, cursor cell, whether the text after the
  cursor is faint), throttled to about 30 a second. Without it `chat.send` fails with
  `terminal_unavailable` ("The terminal shows no screen to act on"). So the phone keeps a Term surface
  per agent terminal it chats with, attached with `terminals.attach`, even when only the Chat view shows.
- Reattach by key, not id. Node ids are per helper process. After reconnecting, `backends.open` and find
  terminals by their topology `key` (tmux `…:%<pane>`, herdr `term_…`), then `chat.open` and
  `terminals.attach` again.
- Follow binding changes. A Codex conversation starts with an empty session and gets its thread id with
  the first prompt; Chat updates are scoped to the session, so reopen `chat.open` when the topology or
  `agent.changed` shows a new binding.
- `chat.open` answers with a `chat.history` notification on its request id, and `backends.open` with
  `backend.opened`; neither sends a response frame while the observer is open.
- Enable optional integrations on every connection. The helper keeps `installation.install` state in
  memory: Pi's extension needs `installation.install {launch, enabled: true}` on the same connection
  before a launch.
- Surface native trust steps. Codex shows "Hooks need review" on first start after the helper installs
  its hooks; until the user picks "Trust all" in the terminal, Codex approvals stay in its TUI. Claude
  installs need no step; whether Claude shows its auto-mode opt-in dialog depends on the user's settings
  (the fixture disables it).
- Keep the outbox until delivery. The helper's queue does not survive the connection (it dies with the
  helper). For Claude and Pi the device must keep queued messages and re-add them after reconnecting;
  only Codex's native queue survives.
- Expect `input` refusals right after an agent starts: Claude's prompt can show "for shortcuts" before
  it accepts input, and `chat.send` then fails with `input` ("current prompt or session does not allow
  input"). Nothing was typed; sending again shortly after succeeds (the harness retries every 0.5 s).
- Send `terminals.input` bytes as raw bytes (binary tag 11).
- Linux hosts: check that tmux and herdr servers outlive the SSH session. With systemd-logind's
  `KillUserProcesses=yes` they die at logout unless the user runs `loginctl enable-linger $USER`; say so
  in the no-multiplexer / host hint. Ubuntu's default (`no`) and the test VM (`Linger=yes`) keep them.
- Linux hosts with tmux before 3.7 (Ubuntu 26.04: 3.6): Chat to a bound agent works, but typing the
  helper cannot attribute to the bound agent is refused; show the Mac's tmux 3.7 warning in host detail.
- Expect the connection loss to reach the host late through NAT or forwarders (1.8 s through Lima), so
  a reconnect can meet the old helper still alive. The harness waits for it to exit; reconnecting while
  it lives (two helpers on one tmux/herdr server) is not exercised yet.
- tmux scrollback is the client's: keep Term's scrollback from the attach replay. herdr scrollback is
  the server's: send `terminals.scroll`, render `terminal.scroll`.

## Amended helper change list (plan section 5)

1. Verify `--stdio` client mode without `login`: done on this branch (fixes 1 to 6). Remaining, in order
   of value:
   a. Done: Linux live run with `--remote`/`--lima` (above); x86-64 Linux and other distributions
      are still untested.
   b. Persist the helper-held queue per conversation under `~/.dispatch/state` so it survives a drop,
      or document the device outbox as the only durable queue (the plan assumed the helper queue
      survives the phone disconnecting; it does not survive the helper).
   c. Optional helper-side screens for tmux (from `capture-pane`) so a Chat-only client can send without
      keeping a Term surface attached.
   d. Coalesce `terminal.output` per terminal per reactor turn: tmux control mode yields one frame per
      `%output` line (29 bytes of payload on average, 3.4x wire overhead for line-heavy output). herdr
      already sends rendered frames.
   e. Persist optional integration choices (Pi) across connections, or let `hello` report them.
   f. Expose Codex's hook trust state (`Install.trust`) so the phone can tell the user before the first
      approval goes missing.
   g. Linux sessions with `KillUserProcesses=yes` (systemd-logind) kill tmux and herdr servers started
      from an SSH session when it ends; the host hint should mention `loginctl enable-linger`. Not
      reproduced: the test VM has `Linger=yes` and Ubuntu's default `KillUserProcesses=no`, and the VM
      may not be reconfigured.
   h. With tmux before 3.7 (Ubuntu 26.04 still ships 3.6) the helper should report the missing
      bracketed-paste state (e.g. a `hello` or backend field) so the client can show the Mac's
      "readiness can't be verified" warning; today the client only sees the refusal text.
   d. and h. Done: `terminals.coalesce` and `multiplexers.versions` (above).
2. "This session" approval: done for Claude (`interaction.options`); Codex waits for hook support of
   `updatedPermissions` or for routing its app-server approvals (`acceptForSession`) through the helper.
3. `chat.list`: done.
4. `projects.recent`: done.
5. Revert a hunk: unchanged, future work.

## What the Mac's replay corpus sees

Every new behaviour is behind a feature the Mac never names, and nothing new reads the clock or
starts jobs for a client without features, so recorded Mac sessions replay as before. The fixes merged
earlier, checked against the same rule:

| Fix | Changes what the Mac records? |
| --- | --- |
| `host.identity` `os_version`/`os_label` | No replay divergence: the native job's output is recorded and replayed. New recordings contain the two fields; re-record nothing. |
| Login-shell PATH | No: only `--remote --stdio` without the login wrapper and with a spawning grant; the Mac runs `login`, local `--stdio`, or the greeting probe with `--capabilities ''`. |
| tmux `backends.create` starts a server | No: the Mac never sends `backends.create` (`HelperClient.create(_ route:)` has no caller). |
| Idle check accepts `sh --noprofile -il` | Not in replay (the `idle` native job is recorded). Live, on a Mac whose test shell is macOS `/bin/bash` 3.2, Close tab now terminates an idle helper-created tmux window or herdr tab instead of detaching it: re-record close-tab tests recorded with bash, if any (zsh shells are unaffected). |
| `--remote` launch setup | No: the Mac's launches run in login or local helpers, whose behaviour is unchanged. |
| Launch setup asks a live named helper again (herdr tty race) | Only a launcher capture that recorded the race (named helper alive, not yet owning the pane) diverges: replay now sees a second ownership ask. Such a recording ran its agent without hooks; re-record those launches if `capture` reports a launcher capture failing at `exchange`. |

## herdr release assets

Neither `helper/multiplexers/herdr/src/availability.rs` nor `docs/integrations.md` names a release
asset: the helper only looks for an installed `herdr` (PATH, then the login shell's PATH). The pinned
assets in `scripts/test-tools.lock.json` are
`https://github.com/herdrdev/herdr/releases/download/v0.9.3/herdr-macos-aarch64` and
`herdr-macos-x86_64`; the Linux binary on the test VM (sha256 `4de7aa3e…`, installed by
`scripts/ssh-vm.py` from a local file named `herdr-0.9.3-linux-aarch64`) follows the same scheme, so
the Linux assets are `herdr-linux-aarch64` and `herdr-linux-x86_64`. `herdr-linux-$(uname -m)` is
right on Linux (`uname -m` prints `aarch64` or `x86_64`). On macOS `uname -m` prints `arm64`, which
must become `aarch64` (`herdr-macos-aarch64`). Not verified against the release page (no network).

## Open issues

- Linux is covered on one arm64 Ubuntu VM only. No run against a real remote Mac with a Homebrew tmux
  on sshd's PATH-less channel; the fixture reproduces it with `~/.local/bin`.
- The login-shell probe costs one shell start per connection (part of the 70 to 250 ms to hello here); a
  slow profile adds up to 3 s before hello on the first request.
- The throughput number is tmux-bound on this Mac; the phone's decoder cost for 2.9 M small frames is
  untested.
