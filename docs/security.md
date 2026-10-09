# Security and privacy

Dispatch is a macOS terminal. It runs with your user account's full permissions: there is no App Sandbox. Anything a terminal program can do, Dispatch and its helpers can do too. This page lists everything Dispatch reads, writes, runs, or stores beyond drawing a terminal, both on your Mac and on SSH hosts. Defaults are given in parentheses.

## Summary

- **No network traffic of its own:** no telemetry, analytics, crash reporting, or update checks.
- **Agent hooks are installed automatically** into Codex and Claude config while Chat is on (default).
- **SSH hosts can get a helper** that, once granted, runs remote terminals, reads processes, metrics, readable files, and transcripts, and edits agent config. Any process running as your remote user can use it too.
- **Unsafe pastes are confirmed automatically**, so a multi-line paste can run commands immediately.
- **Builds are ad-hoc signed and not notarized.**

## Network

- The only outbound connections Dispatch makes are the system `ssh`, which you start, and an optional `ws://` WebSocket to a local Codex app-server.
- That WebSocket is only used if you launched Codex with `--remote ws(s)://` on a loopback address. It uses an ephemeral session, no proxy, and refuses redirects. If `--remote-auth-token-env` is set, Dispatch doesn't connect at all, because it never guesses credentials.
- Every other channel is a Unix socket, a pipe, or a file on the same machine.
- Dispatch itself makes no model API calls. Agents, including the side conversations below, talk to their own providers with their own credentials.

## Local shells

**Wrappers.** Every local terminal is set up so that `ssh`, `codex`, `herdr`, and `tmux` go through Dispatch first:

- Shell functions are defined for these commands, unless you already have a function or alias with the same name.
- Bash children also inherit `BASH_FUNC_ssh%%` and `BASH_FUNC_codex%%`, so scripts run from the terminal use the wrappers too.
- `/tmp/dispatch-herdr-<UUID>/bin` is put at the front of `PATH`. Its shims re-run the Dispatch app binary.
- There are no local `claude()` or `pi()` wrappers.
- Dispatch never edits your rc files. Instead it points `ZDOTDIR` (zsh), `ENV` (bash), or `XDG_DATA_DIRS` (fish) at private startup files, which source your real ones and then add the wrapper functions.

What each wrapper does:

- `ssh`: an interactive `ssh` (one with a terminal) may start the SSH integration described below. Anything else runs the real `ssh` unchanged.
- `codex`: for supported TUI invocations, Dispatch starts a private `codex app-server` on `/tmp/dispatch-codex-<UUID>/control.sock` (folder mode 0700). It runs the Codex TUI against that server with your full environment and stops the server when the TUI exits. Other TUI invocations, failed private-server starts, and failed capability probes fall back to `--no-daemon`, avoiding the user's shared background server and its persisted feature settings. Successfully probed older CLIs without that option retain their native behavior. Explicit remote connections and service commands run unchanged.
- `herdr` and `tmux` hand sessions to the native tmux/herdr integration.

**Environment.** Dispatch adds these variables to every local terminal, so every program started from it inherits them:

- `DISPATCH_CHAT_SOCKET` and `DISPATCH_CHAT_TOKEN`: the hook socket and a per-pane random token.
- `DISPATCH_HERDR_DIRECTORY`, `DISPATCH_HERDR_TAB`, and `DISPATCH_HERDR_TOKEN`: the launch mailbox, the tab ID, and a per-tab random token.
- `DISPATCH_EXECUTABLE` and `DISPATCH_TMUX_ENABLED_FILE`.

Any process running as you can read these values, but the tokens are not enough to impersonate an agent (see [Hook receiver](#hook-receiver)). The tmux bridge removes its own `DISPATCH_TMUX_*` tokens before starting the shell. A herdr server Dispatch starts gets your environment minus all `DISPATCH_*` and `GHOSTTY_*` variables.

**Temporary files.** All of these are owned by you, in folders with mode 0700, and removed when Dispatch quits:

| Path | Purpose |
| --- | --- |
| `/tmp/dispatch-herdr-<UUID>/` | Command shims, private startup files, integration on/off flags, and a file mailbox for launch, SSH consent, and reconnect requests. Each request must carry its tab's token and is used once. SSH consent requests must also come from a live Dispatch process. SSH ControlMaster sockets live in `s-<id>/master`. |
| `/tmp/dispatch-ghostty-<UUID>/` | Shell-integration scripts with the wrapper functions added. |
| `/tmp/dispatch-<UUID>/chat.sock` | The agent hook receiver (socket mode 0600). |
| `/tmp/dispatch-tmux-<UUID>/socket` | The tmux PTY bridge. |
| `$TMPDIR/dispatch-scroll-<UUID>/control` | The herdr scroll FIFO (mode 0600, ownership checked). |

## Terminal content, clipboard, and links

**Clipboard.**

- Programs can't read your clipboard: OSC 52 reads always get an empty reply, and kitty clipboard reads need a one-time grant from a real paste.
- Programs can write to your clipboard without asking, from local tabs and plain SSH tabs. This covers OSC 52, the kitty clipboard protocol, and tmux paste buffers up to 8 MiB.
- On SSH hosts with the Dispatch helper, clipboard writes are blocked unless **Remote programs can copy** is on (on).

**Paste.** The terminal detects unsafe pastes: text with newlines outside bracketed paste, or an embedded end-of-paste sequence. Dispatch confirms them automatically, so you never see a warning. There is no setting to turn this off.

**Links.**

- Cmd-click opens HTTP(S) URLs and existing paths with `/usr/bin/open`; other URL schemes ask first.
- OSC 8 hyperlinks are never opened by the Swift engine.
- In chat, links open only if they are `http(s)` with a host and no embedded credentials. File citations open in an in-app preview (regular UTF-8 files up to 2 MB, symlinks followed). Every other link is removed. Chat doesn't load remote images.

**Kitty graphics.** Kitty's terminal image protocol is off by default. Turning on **Kitty graphics** in Settings → Integrations lets terminal programs display images. Only trusted local tabs may ask the Swift engine to read a regular file or shared-memory object; remote tabs can send inline image bytes but cannot name resources on the Mac. File reads exclude `/proc`, `/sys`, and `/dev`. The Swift engine caps decoded image storage at 64 MiB per terminal, individual decoded images at 32 MiB, and placements at 1,024.

**Escape-sequence notifications.** OSC 9 and OSC 777 are parsed and then dropped; they never become desktop notifications.

**Replies to terminal queries.**

- Dispatch identifies itself as `ghostty <version>` (XTVERSION) and sets `TERM_PROGRAM=ghostty`.
- It answers size, color, terminfo-capability, and mode queries.
- The answerback (ENQ) is empty, and title reports are ignored.

**Screen reading.** To detect Claude's prompts and menus, Dispatch reads up to 64 KB of the visible screen of panes that run an agent. That text is kept in memory only.

The helper on an SSH host gets the visible screen of the tab running that SSH session, so it can detect the same prompts there. It gets only text the session wrote: whatever the tab showed before the session started stays blank in what it receives, even after later output moves that text around the screen, until a clear erases it. Sending stops when the session's shell exits, and a Stats-only grant gets none of it.

## Agent chat

Chat attaches to Codex, Claude Code, Pi, and Nanocodex sessions that are already running in a terminal.

**Discovery.** Every 0.35 s, Dispatch inspects the foreground process group of each terminal:

- It only looks at processes owned by you.
- It reads each process's path, full argument list, and working directory.
- From the environment it reads only `HOME`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `PI_CODING_AGENT_DIR`.
- For Codex, it lists the process's open files to find the session transcript and reads that file's first line. If it can't find the transcript, it runs `codex --version` once per executable, from a temporary folder.
- It reads agents' registration files, and only if they are owned by you and not readable by anyone else:
  - Claude: `~/.claude/sessions/<pid>.json`
  - Pi: `~/.pi/agent/dispatch/sessions/<pid>.json`
  - Nanocodex: `$CODEX_HOME/nanocodex/tui/instances/*.json`

**Transcripts.** Dispatch reads the agent's conversation file, newest pages first and older pages on demand. Transcript text is kept in memory only and never written to disk by Dispatch.

**Hooks Dispatch installs on your Mac.** When Chat is on (default), Dispatch installs its hooks for Codex and Claude at every launch, unless you turned off that agent's hooks in Settings. There is no consent dialog. The only notice is a line in Settings.

- Codex: `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`) gets session, prompt, tool, compaction, stop, and permission events. Codex then asks you to trust the hook in `/hooks`.
- Claude: `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude/settings.json`) gets `PermissionRequest` and `PreToolUse` for `AskUserQuestion`.
- How the edit is made: Dispatch only adds or removes entries whose command is its own. It refuses invalid JSON and aborts if the file changed while it was working. It rewrites the whole file pretty-printed with sorted keys, so your formatting changes. It doesn't make a backup and doesn't set the file mode.
- The hook command runs the helper's stable copy, `~/.dispatch/bin/dispatch-helper hook {codex,claude}`. It sends the hook's JSON — your prompts, tool inputs and outputs, and the agent's replies — to the running helper over a Unix socket in `~/.dispatch/run/*/` (folder 0700). It does nothing when no Dispatch helper is running.
- Turning Chat off removes Dispatch's Claude entries for the current helper path. It leaves the Codex entries in place, because Codex's trust is keyed by each hook's position. The hook script itself stays on disk.
- To remove every Dispatch hook, for both agents and from any helper version, run `~/.dispatch/bin/dispatch-helper uninstall-hooks` (add `--dry-run` to preview). It edits `$CLAUDE_CONFIG_DIR`/`~/.claude/settings.json` and `$CODEX_HOME`/`~/.codex/hooks.json`, keeps other handlers, settings, the file mode and symlinks, and drops matcher groups and events it leaves empty. Codex asks again in `/hooks` to trust any of your own hooks that sit after a removed one. Turn Chat off first, or Dispatch installs its hooks again at the next launch.
- Pi needs an explicit **Install** in Settings. That writes `~/.pi/agent/extensions/dispatch-chat.js` (0600) plus a checksum receipt, and refuses symlinked or foreign-owned folders. While Pi runs, the extension listens on `/tmp/dispatch-pi-<uid>/<pid>-<uuid>.sock` (0600, token required). Through that socket it serves Pi's state (including the current editor text), model list, prompt, steer, and abort. **Remove** deletes both files.

<a id="hook-receiver"></a>**Hook receiver.** Dispatch accepts a hook request only when all of these hold:

- The connecting process runs as your user.
- The hook process descends from that process, and a Codex or Claude process is among its ancestors.
- The request is well-formed: limited headers, a body of at most 4 MB, and at most 32 clients at once.

The token routes the request to a pane. If the token doesn't match any pane, Dispatch falls back to tmux foreground ownership. Approvals wait at most 45 s and questions at most 180 s. After that the agent shows its own prompt.

**Approvals and questions.**

- An approval card belongs to one live agent request. Before your decision is sent, Dispatch checks again that the process, conversation, and request still match. Subagent requests are never shown.
- Only **Allow once** and **Deny** decide a request. There is no auto-approve, no "always allow", and no saved decision.
- Expired or invalid requests get an empty reply, so the agent falls back to its own prompt.

**Sending prompts.**

- For local Codex and Claude, Dispatch types your text into the terminal as a bracketed paste, then presses Return. Before typing, it checks that exactly one matching agent is in the foreground, that the text has no control characters other than newline and tab, and (for Claude) that the agent is idle and its input is empty. Before pressing Return, it checks ownership again.
- Text starting with `/` or `!` is protected so the agent takes it literally.
- Pi and Nanocodex receive prompts over their local sockets. Nanocodex requires the auth token from its registration file and a matching peer process.
- If Dispatch can't tell whether a prompt was delivered, it never resends it automatically. The queue pauses instead.
- If Dispatch can no longer verify the agent, input is paused, but history and drafts stay.

**Side conversations (`/btw`, `/side`).** These start a separate agent process from the same executable and working directory, forked from the parent conversation:

- The child agent sends the parent conversation to its model provider again.
- Dispatch copies these values from the parent agent's environment into the child, in memory only:
  - Claude: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, and the telemetry opt-outs.
  - Codex: `OPENAI_API_KEY` and `OPENAI_BASE_URL`.
- `/btw` is read-only: no shell or network, no MCP servers or hooks, and every permission request is denied.
- `/side` has the agent's normal permissions. Dispatch shows one request at a time for you to decide, and denies a second concurrent request.
- Closing the sheet ends the child process.

## SSH integration

**Without the helper.** Plain SSH always works:

- OpenSSH handles passwords, keys, and host keys in the real terminal. Dispatch never sees them and does not parse `~/.ssh/config`.
- Dispatch never adds agent forwarding, `SendEnv`, or `SetEnv`. Port forwarding and `-A` pass through exactly as you typed them.
- Non-interactive commands, and any configuration of your own for ControlMaster, ControlPath, ControlPersist, or `RemoteCommand`, always get plain `ssh`.

**How a connection is made.**

- Dispatch runs `ssh -G` to resolve the destination and keeps only a SHA-256 fingerprint of the result.
- An enhanced connection opens a private ControlMaster at `/tmp/dispatch-herdr-<UUID>/s-<id>/master`, using your normal ssh configuration.
- Every helper command then reuses that master with `-F /dev/null`, `BatchMode=yes`, `ProxyCommand=/usr/bin/false`, and `ClearAllForwardings=yes`, so a missing master can never trigger a fresh login.
- The ssh process inherits the wrapper's whole environment, including the `DISPATCH_*` tokens. Those values reach the remote only if your own ssh config forwards them.
- The **New space** backend probe opens a separate connection (`BatchMode=yes`, `StrictHostKeyChecking=yes`) and runs a login shell to look for tmux and herdr.

**Consent.**

- **On new hosts** chooses what happens the first time you connect: **Ask** (default), **Full features**, or **Plain SSH**.
- The Ask sheet offers the helper upload, Stats, File access (which also covers Git), and Codex/Claude/Pi hooks. On a new host, every box is checked.
- Pressing **Don't connect** (Esc) or waiting 120 s aborts the `ssh`; Dispatch never silently falls back to plain SSH.
- With **Full features** there is no sheet: everything is granted, Codex and Claude hooks are on, and Pi hooks are off.
- A grant is tied to one ssh executable, destination, resolved-config fingerprint, and remote user. Aliases that differ in any of these never share a grant. Grouping hosts in the sidebar doesn't share permissions either.
- Grants are stored in UserDefaults (`SSHIntegrationPermissions.v2`). Removing a permission takes effect on live connections; adding one needs a new connection. **Reset** forgets the grants and revokes them on live connections.

**The helper on the remote host.**

- It is uploaded to `~/.dispatch/bin/versions/<sha256>/dispatch-helper`. Before running it, Dispatch requires private permissions (umask 077, folders 0700, owned by you, no symlinks, `$HOME` not writable by group or others) and a matching size and SHA-256.
- Its only verification is that hash; there is no code signature.
- It runs as a child of `sshd`, not as a daemon, and exits when the connection closes. If its login shell exits while other Dispatch connections to that host still use it, it keeps serving them until they disconnect or 24 hours pass without traffic from any of them.
- Its capabilities and session ID are visible in the remote process list. It has no credentials of its own: any process running as your remote user can connect to its socket and use everything the grant allows, including running commands. Only other users are kept out.
- Per-connection state lives in `~/.dispatch/sessions/<session>/` (the login hand-off, the login's bus socket, and its exit status) and `~/.dispatch/run/<random>/` (hook sockets, shell startup files). Folders are 0700, so only your user can connect.
- Each helper start removes what no running helper holds: run folders of exited helpers, and session folders and uploaded helper versions that are unlocked and unchanged for a day.

**What the helper reads**, depending on the grant:

- **Stats:** CPU, memory, swap, load, uptime, network counters, and disk space for `/` and your home folder. It also reads a process table (pid, name, CPU, memory). On Linux this table covers every user's processes. Stats are sampled every 15 s while connected and every 2 s while the stats view is open; latency is pinged every 60 s in the background. On the Mac, stats are kept in memory for up to an hour and never written to disk.
- **Host identity:** sent with every connection. It is the machine ID (`/etc/machine-id` or `kern.uuid`), boot ID, uid, home folder, hostname, and OS/distribution.
- **Processes**, for agent discovery: executable, full argument list, working directory, open files, and a short allowlist of environment variables. Agent processes are verified again (pid, start time, executable) before every operation.
- **Files** (granted by Files, Git, or Chat): any regular file your remote account can read, by absolute path, with symlinks followed and no folder allowlist. Text reads are capped at 2 MB; byte reads continue to the end of the file unless the request gives a length.
- **Agent sessions:** Codex rollout files and app-server socket, `~/.claude/sessions` and `~/.claude/projects` transcripts, Pi session records, and Nanocodex registrations.

**What the helper changes on the remote host.**

- **Agent hooks:**
  - It adds hooks to `$CODEX_HOME/hooks.json` and `~/.claude/settings.json`, in the config folder used by the live agent process.
  - The edit only appends, refuses invalid JSON, takes an exclusive lock, requires files owned by you that others can't write and that are at most 1 MiB, keeps the existing file mode, and replaces the file atomically. It makes no backup.
  - Turning hooks off stops routing but **leaves the entries in place**. A leftover hook does nothing once no Dispatch connection is live.
  - Hook events forward their full JSON to your Mac, up to 250 KB each, including prompts and tool input.
- **Helper copy:** `~/.dispatch/bin/dispatch-helper`, the stable path that hook entries and shell startup files run. Each helper refreshes it from its own executable.
- **Pi:** the extension `<pi agent dir>/extensions/dispatch-chat.js` is removed again when Pi hooks are turned off.
- **Shell startup:** when agent hooks are granted, the remote shell starts through private startup files that define `codex`, `pi`, and `herdr` functions, unless you already have a function (or, in bash and zsh, an alias) with that name. Your rc files are sourced, never edited.
- **Agent control:** with Chat, the helper can type prompts into a verified agent's terminal, tmux pane, or herdr pane. It can start `codex app-server --stdio` for side conversations, and create tmux windows and herdr tabs.
- **Commands:** the helper is a terminal server. The Chat, hooks, tmux, and herdr grants each let the Mac open remote terminals that run any command and type into them; tmux also lets it send tmux commands. The helper also connects to agents' and herdr's own sockets.
- **Left behind after disconnect** (there is no uninstall):
  - in `~/.dispatch/`: the helper copy and the most recently used helper versions in `bin/`, herdr recovery records in `state/`, and session folders for up to a day;
  - lock files in agent config folders;
  - the hook entries above (run `~/.dispatch/bin/dispatch-helper uninstall-hooks` on the host to remove them);

**Reconnect.** Reconnecting re-checks the machine ID, user, boot ID, and grant, and only reattaches to existing tmux/herdr sessions. Anything you type while a connection is recovering is discarded, not queued. Automatic reconnect (off by default) logs in with `BatchMode=yes` only, so it never prompts, and stops when OpenSSH refuses the login instead of retrying it.

## tmux and herdr

**tmux.**

- Dispatch switches to native tmux mode when control-mode output appears in a terminal. It doesn't check that the foreground program really is tmux.
- In native mode it reads each pane's full scrollback (`capture-pane -S -`), its working directory, titles, and paste buffers. Paste buffers are copied to the macOS clipboard under the clipboard rule above.
- It sets a `@dispatch-window` option on windows and adds `DISPATCH_*` variables, `PATH`, and `ZDOTDIR` to windows it creates. These stay after Dispatch quits, while the `/tmp` folders they point to are deleted.
- Closing **the launching tab** keeps its control connection open privately until the tmux session ends.

**herdr.**

- Dispatch talks to herdr's own socket. It checks that the peer is your user, but herdr has no token of its own.
- If no herdr server is running, Dispatch starts `herdr server`, and that server keeps running after Dispatch quits.
- Remote herdr goes through the helper, with a fixed list of allowed operations.

Quitting doesn't ask for confirmation when only tmux and herdr tabs are open.

## Data stored on your Mac

| What | Where | Contents | When | Protection |
| --- | --- | --- | --- | --- |
| Settings | `~/Library/Application Support/Dispatch/Local/settings.json` | Preferences, including the starting folder | On change | Atomic write; default file mode |
| Spaces | `…/Dispatch/host-session.json` | Spaces, tabs, titles, and folders; host records; SSH executables, options, and destinations; remote uid and boot ID; herdr recovery tokens; tmux sessions. No credentials or launch commands. | On window close and quit, while **Reopen spaces on launch** is on (on). Deleted when that setting is turned off. | 0600, atomic |
| Terminal output | `…/Dispatch/terminal-history.json` | The raw text of plain local and SSH tabs: commands, output, and anything else visible, possibly secrets. Not tmux or herdr tabs. | Only on a normal quit, with **Restore tab history** (off) and **Reopen spaces** both on. Deleted from disk early in the next launch, ignored after 7 days, and deleted when the setting is turned off. | 0600, atomic, excluded from backups. Capped at one scrollback per tab and 1/32 of RAM in total. Replayed without control sequences. |
| Chat drafts | `…/Dispatch/drafts.json` | Working and saved drafts, plus a copy of each prompt from before it is sent until delivery is confirmed, per host, agent, and conversation | 300 ms after typing stops, and at most every 2 s | Owner-only atomic write; excluded from backups; no expiry |
| Helper files | `~/.dispatch/` | `bin/dispatch-helper`, the helper copy that hook entries run; `run/*/` hook sockets and startup files of running helpers; `routes/` which helper serves each hook; `state/` herdr recovery records | `bin/dispatch-helper` is refreshed when a helper writes a hook or startup command; each `run/*/` exists while its helper runs | Folders 0700, sockets 0600 |
| Diagnostics | `~/Library/Logs/Dispatch/Diagnostics/` | Chat scroll and viewport events and geometry. Row IDs are replaced with keyed hashes; no conversation text, hosts, or paths. | Only while **Diagnostics** is on (off). Turning it off doesn't delete existing files. | 0600, rotated at 4 MiB |
| UserDefaults (`dev.dispatch.local`) | `~/Library/Preferences` | Chat and hook switches, SSH grants (`SSHIntegrationPermissions.v2`), host records (`HostRegistry.v1`), herdr presentation, window frame | On change | Default |

Dispatch doesn't store transcripts, approvals, statistics, or model lists; those stay in memory only. Agent histories and tmux/herdr sessions belong to those tools. Logging is minimal and contains no terminal or chat content.

## Notifications

With **Notifications** on (default), Dispatch asks macOS for notification permission. When an agent needs you while its pane isn't visible, it sends a notification:

- **Title:** the pane name.
- **Subtitle:** the pane's folder.
- **Body:** up to 160 characters of the agent's reply, the requested operation, or the question.

These can appear on the lock screen, depending on your macOS notification settings. Turning the setting off removes notifications already delivered. The Dock badge (on) shows how many panes are waiting.

## Build and distribution

- Release and Debug builds are ad-hoc signed (`CODE_SIGN_IDENTITY "-"`) with the hardened runtime and no entitlements. They are not notarized, so a copy you receive can't be traced to who built it.
- The tmux bridge and the macOS SSH helper are signed the same way. The Linux SSH helpers are not signed.
- Release builds leave out the helper's capture and replay test hooks. In Debug builds, setting `DISPATCH_CAPTURE` for the app makes every helper it starts, SSH ones included, write all of its I/O to trace files, unredacted.
- Dispatch registers no URL schemes, services, AppleScript support, or login items, and needs no privacy permissions.
- Setup asks before downloading. Downloads are `https`-only, pinned by SHA-256 (`scripts/build.lock.json`, `scripts/test-tools.lock.json`), and kept under `build/`. The SSH helper has no third-party Rust dependencies and builds offline (`cargo build --offline --frozen`).
- Desktop, SSH, and agent tests need sudo and take over the desktop; run them only in the [test VM](vm_testing.md).
