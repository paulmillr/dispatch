# Security and privacy

Dispatch is a macOS terminal. It runs with your user account's full permissions: there is no App Sandbox. Anything a terminal program can do, Dispatch and its helpers can do too. This page lists everything Dispatch reads, writes, runs, or stores beyond drawing a terminal, both on your Mac and on SSH hosts. Defaults are given in parentheses. Dispatch for iPhone is covered in [its own section](#dispatch-for-iphone).

## Summary

- **No network traffic of its own:** no telemetry, analytics, crash reporting, or update checks. The one download it makes is a Whisper dictation model, when you ask for it.
- **Agent hooks are installed automatically** into Codex and Claude config while Chat is on (default).
- **SSH hosts can get a helper** that, once granted, runs remote terminals, reads processes, metrics, readable files, and transcripts, and edits agent config. Any process running as your remote user can use it too.
- **Unsafe pastes are confirmed automatically**, so a multi-line paste can run commands immediately.
- **Builds are ad-hoc signed and not notarized.**

## Network

- The only outbound connections Dispatch makes are the system `ssh`, which you start, an optional `ws://` WebSocket to a local Codex app-server, and the [Whisper model downloads](#dictation) you start in Settings.
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
- Programs can write to your clipboard without asking while **Programs can copy** (Settings › General) is on (on). This covers OSC 52, the kitty clipboard protocol, and tmux paste buffers up to 8 MiB.
- The setting applies to every tab alike, local, plain SSH, or with the helper: a local program relaying a remote one (mosh, `docker exec`, a local tmux) can't be told apart from a local one.

**Paste.** The terminal detects unsafe pastes: text with newlines outside bracketed paste, or an embedded end-of-paste sequence. Dispatch confirms them automatically, so you never see a warning. There is no setting to turn this off.

**Links.**

- Cmd-click opens HTTP(S) URLs and existing paths with `/usr/bin/open`; other URL schemes ask first.
- OSC 8 hyperlinks are never opened by the Swift engine.
- In chat, links open only if they are `http(s)` with a host and no embedded credentials. File citations open in an in-app preview (regular UTF-8 files up to 2 MB, symlinks followed). Every other link is removed. Chat doesn't load remote images.

**Kitty graphics.** Kitty's terminal image protocol is off by default. Turning on **Kitty graphics** in Settings → General lets terminal programs display images. Only trusted local tabs may ask the Swift engine to read a regular file or shared-memory object; remote tabs can send inline image bytes but cannot name resources on the Mac. File reads exclude `/proc`, `/sys`, and `/dev`. The Swift engine caps decoded image storage at 64 MiB per terminal, individual decoded images at 32 MiB, and placements at 1,024.

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

**Hooks Dispatch installs on your Mac.** A fresh install's first launch asks whether you'll use agents on this Mac. Yes installs the hooks of the Codex and Claude CLIs it finds in your login shell (Pi stays opt-in); no turns this Mac's agent hooks off. After that, each launch completes an installation an older Dispatch made with fewer hooks, unless you turned that agent's hooks off in Settings.

- Codex: `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`) gets session, prompt, tool, compaction, stop, interrupt, permission and subagent events. Codex then asks you to trust the hook in `/hooks`.
- Claude: `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude/settings.json`) gets `PermissionRequest`, `PreToolUse` for `AskUserQuestion`, and the session, prompt, tool, stop and subagent lifecycle events.
- How the edit is made: Dispatch only adds or removes entries whose command is its own. It refuses invalid JSON and aborts if the file changed while it was working. It rewrites the whole file pretty-printed with sorted keys, so your formatting changes. It doesn't make a backup and doesn't set the file mode.
- The hook command runs the helper's stable copy, `~/.dispatch/bin/dispatch-helper hook {codex,claude}`. It sends the hook's JSON — your prompts, tool inputs and outputs, and the agent's replies — to the running helper over a Unix socket in `~/.dispatch/run/*/` (folder 0700). It does nothing when no Dispatch helper is running.
- Turning Chat off removes Dispatch's Claude entries for the current helper path. It leaves the Codex entries in place, because Codex's trust is keyed by each hook's position. The hook script itself stays on disk.
- To remove every Dispatch hook, for both agents and from any helper version, run `~/.dispatch/bin/dispatch-helper uninstall-hooks` (add `--dry-run` to preview). It edits `$CLAUDE_CONFIG_DIR`/`~/.claude/settings.json` and `$CODEX_HOME`/`~/.codex/hooks.json`, keeps other handlers, settings, the file mode and symlinks, and drops matcher groups and events it leaves empty. Codex asks again in `/hooks` to trust any of your own hooks that sit after a removed one. Turn this Mac's agent hooks off in Settings first, or Dispatch may install them again. To remove Dispatch entirely, see [Removing Dispatch](#removing-dispatch).
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

**Attachments.** The app reads only files you pick, drop or paste into Chat, once, in its own process (so the agent never opens your original, and macOS asks no Desktop/Documents permission on Dispatch's behalf), and uploads the bytes to the helper on the agent's host:

- Before upload the app strips location (GPS), Exif, IPTC and camera TIFF metadata from images, keeping the orientation: a JPEG is copied without re-encoding, a PNG re-encoded losslessly, a WebP with metadata becomes a PNG; a GIF, and any image without metadata, goes byte for byte.
- The helper writes each upload to `~/.dispatch/attachments/<random>/<name>`, the name reduced to letters, digits, `.`, `_` and `-` (no spaces, quotes, shell or bidi characters reach an agent in the path): a new folder (0700, never an existing one) and a new file (0600), every level checked to be yours and private and never reached through a symlink; at most 8 MB each. The message names that copy; the agent reads it (Claude Code and Codex from the pasted path; Pi, and every file that is not an image, by the path line in the message, with the agent's own tools).
- Copies are kept so an agent can read one again later in its turn and a queued message can wait; folders untouched for 7 days are removed when a helper starts.
- For Claude Code, whose transcript keeps only the image data, the helper records which copies it sent with which message: `~/.dispatch/state/attachments/<hash>.idx` (0600; a SHA-256 of the message text, the copies' paths and when the send started, newest 200 messages per conversation; written only for a send that may have reached Claude), so history can show the thumbnail again. Only an app that asked for attachments causes it to be read.
- A connected app reads a copy back (`attachments.read`) only from that folder and only under the same checks, for thumbnails on another device. A queued message with attachments keeps their paths in the queue file.
- The Mac's Quick Look preview of an attachment writes a private copy to `$TMPDIR/Dispatch attachments/<uuid>/` (0600), replaced by the next preview and deleted when the panel closes; the folder is removed at quit, and anything a crash left there at the next preview.

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

- **Remote helper** (Settings › Features, on by default) decides whether the helper is uploaded at all; off, every host connects over plain SSH and saved grants are kept. **Auto-confirm uploads** (off by default) chooses what happens the first time you connect: off asks with a sheet, on grants everything without one.
- The Ask sheet offers the helper upload, Stats, Files (which also covers Git), and Codex/Claude/Pi hooks. On a new host, every box is checked.
- Pressing **Don't connect** (Esc) or waiting 120 s aborts the `ssh`; Dispatch never silently falls back to plain SSH.
- With **Auto-confirm uploads** there is no sheet: everything is granted, Codex and Claude hooks are on, and Pi hooks are off.
- A grant is tied to one ssh executable, destination, resolved-config fingerprint, and remote user. Aliases that differ in any of these never share a grant. Grouping hosts in the sidebar doesn't share permissions either.
- Grants are stored in UserDefaults (`SSHIntegrationPermissions.v2`). Removing a permission takes effect on live connections; adding one needs a new connection. **Reset** forgets the grants and revokes them on live connections.

**The helper on the remote host.**

- It is uploaded to `~/.dispatch/bin/versions/<sha256>/dispatch-helper`. Before running it, Dispatch requires private permissions (umask 077, folders 0700, owned by you, no symlinks, `$HOME` not writable by group or others) and a matching size and SHA-256.
- Its only verification is that hash; there is no code signature.
- It runs as a child of `sshd`, not as a daemon, and exits when the connection closes. The one exception is the queue drainer (below). Started directly on an exec channel without the login wrapper (`--remote … --stdio`, as the iPhone app does), it first runs your login shell once (`$SHELL -lc`, no input, at most 3 s) to learn its `PATH`, so tmux, herdr and agents are found where your shell finds them; your profile runs, nothing is written. If its login shell exits while other Dispatch connections to that host still use it, it keeps serving them until they disconnect or 24 hours pass without traffic from any of them.
- Its capabilities and session ID are visible in the remote process list. It has no credentials of its own: any process running as your remote user can connect to its socket and use everything the grant allows, including running commands. Only other users are kept out.
- Per-connection state lives in `~/.dispatch/sessions/<session>/` (the login hand-off, the login's bus socket, and its exit status) and `~/.dispatch/run/<random>/` (hook sockets, shell startup files). Folders are 0700, so only your user can connect. A local tab on the Mac gets no startup files: the app's own environment carries the shell integration, so the helper writes nothing before it starts the shell.
- **Queued chat messages** for Claude Code and Pi are kept on the host, in `~/.dispatch/state/queue/` (folder 0700, one file per conversation, 0600, full message text), from the moment the host accepts them until they are sent or you remove them. Every Dispatch connection to that host, Mac or iPhone, sees and edits the same queue. A message is sent only to the exact agent process and conversation it was queued for; one that may have been sent when a helper stopped is paused for you and never sent again automatically.
- **The queue drainer.** When a helper exits while such a queue still has messages to send, and the agent runs in tmux or herdr, it starts `dispatch-helper queue-drain` as a background process of your user (one per account, a lock in that folder). It runs a helper of its own, opens only tmux or herdr servers that already run, never starts one, and sends each message once its agent is idle, typing it into the agent's terminal as Chat does, checked against the terminal's screen as the multiplexer reports it. It takes no part in agent hooks (approvals stay with your connections), and ends once nothing it can reach is left to send, after at most 24 hours. Stop, a paused message or turning Chat off for the connection stops it from sending.
- Each helper start removes what no running helper holds: run folders of exited helpers, and session folders and uploaded helper versions that are unlocked and unchanged for a day.

**What the helper reads**, depending on the grant:

- **Stats:** CPU, memory, swap, load, uptime, network counters, and disk space for `/` and your home folder. It also reads a process table (pid, name, CPU, memory). It covers every user's processes: on macOS it comes from `/bin/ps`, on Linux from `/proc`. Stats are sampled every 5 s while connected (15 s in Low Power Mode) and every 2 s while the stats view is open; latency is pinged every 60 s in the background. On the Mac, stats are kept in memory for up to an hour and never written to disk.
- **Host identity:** sent with every connection. It is the machine ID (`/etc/machine-id` or `kern.uuid`), boot ID, uid, home folder, hostname, and OS/distribution.
- **Processes**, for agent discovery: executable, full argument list, working directory, open files, and a short allowlist of environment variables. Agent processes are verified again (pid, start time, executable) before every operation.
- **Files** (granted by Files, Git, or Chat): any regular file your remote account can read, by absolute path, with symlinks followed and no folder allowlist. Text reads are capped at 2 MB; byte reads continue to the end of the file unless the request gives a length. The same grant (`file.text`) lists folders one level at a time, without following symlinks: names, kinds, sizes, and dates. Copying out packs the selection (symlinks stored as links, never followed) into a temporary archive, `dispatch-pack-<random>.tar.zst` (0600), in that machine's temp folder; it is removed when the copy ends or the connection closes, and one a helper left behind is removed by a later copy after a day.
- **Files you copy in** (`file.write`, granted by Files only): the helper writes them as you.
  - A file is written under a temporary name beside its target, then renamed into place. Folders and many files arrive as one archive, staged and unpacked in a new hidden `.dispatch-copy-…` folder (0700) inside the destination and moved in last.
  - The destination folder and every overwrite are bound to the device/inode identities from the listing you acted on. A single-file overwrite atomically swaps and verifies the displaced entry before deleting it; an archive moves an existing entry aside through pinned directories and verifies it before publishing the incoming one. If a name appeared or changed meanwhile, the copy reports it as changed and does not overwrite it.
  - Refused before anything moves: absolute names, `..`, paths through a symlink, hard links, devices, and any top-level name the app did not pack (an extra `.zprofile` beside the folder you dragged, or another folder in its place). Conflicts are settled only for the packed names, and nothing is overwritten without asking.
  - Bounds: names and link targets up to 4096 bytes, at most 1,000,000 entries, 64 GiB of expanded content, 128 GiB of staged compressed data, and never past the destination's free space less 64 MiB. Outgoing packs have the same entry/content/free-space bounds, and wide directories are bounded while listed rather than retained whole.
  - The hidden folder is removed when the copy ends, is cancelled, or its connection closes (even after the connection's grants were reduced), but only while it and the destination are still the folders the copy started with: a destination renamed mid-copy keeps it (the error says so), and a helper killed mid-copy can leave it behind. A replace that cannot complete leaves the original in place, beside it under a numbered name, or in the hidden folder, and says where.
- **Git, through the Files grant** (`git.read`, granted by Files and Git): for the Review and Commits tabs the helper runs `git` as you, in the folder the tab shows, and only to read.
  - Commands: `rev-parse`, `status`, `diff`, `log`, `show` and `for-each-ref`, each with a fixed list of options. Nothing that commits, checks out, stashes, fetches or pushes runs.
  - Refused: `--output`, `--ext-diff`, `--textconv`, `--binary`, `-c`, `--git-dir`, `--work-tree` and `--exec-path`; paths that are not relative to the folder or climb out of it with `..` (so `diff` cannot compare files elsewhere on the machine); and a log format given by name (a name is looked up in the repository's configuration, which could make it check signatures).
  - Environment: absolute components of `PATH`, an absolute `HOME`, `USER` and the C locale only (no relative executable lookup, `GIT_DIR`, `GIT_EXTERNAL_DIFF`, `GIT_CONFIG_PARAMETERS`, `GIT_SSH*` or `GIT_PROXY*`), with `GIT_OPTIONAL_LOCKS=0` and the diff's index refresh off, so it neither takes `index.lock` nor rewrites the index.
  - Configuration that would run a program is overridden: system and user configuration are ignored, and there is no fsmonitor hook, external diff, diff driver, textconv, pager, signature check (including signature sort fields; every gpg program points at a path that does not exist) or network fetch for a partial clone. Immediately before every command, the helper asks git which filters are configured in repository and included configuration and turns each one's clean and process commands off by name, so a changing included file or branch-conditional include cannot evade the check. A filter whose name git cannot be told to skip (one holding `=`) stops the command instead. Helper file writes and archive commits cannot overlap the scan and command, closing the config swap window for clients of that helper.
  - What that costs: a filtered file whose timestamps changed while its content did not (an LFS file after a checkout) may show as modified until `git status` in your shell refreshes the index, and a submodule shows as changed when its checked-out commit moved, not for edits inside it (git never runs inside a submodule's checkout, which would use the submodule's configuration and filters).
  - Limits: output capped at 8 MiB (2 MiB unless the app asks for more); each command stopped, with everything it started, after 20 s; two helper workers of their own, so a slow command never holds up file listings or reads.
- **Agent sessions:** Codex rollout files and app-server socket, `~/.claude/sessions` and `~/.claude/projects` transcripts, Pi session records, and Nanocodex registrations.

**What the helper changes on the remote host.**

- **Agent hooks:**
  - It adds hooks to `$CODEX_HOME/hooks.json` and `~/.claude/settings.json`, in the config folder used by the live agent process.
  - The edit only appends, refuses invalid JSON, takes an exclusive lock, requires files owned by you that others can't write and that are at most 1 MiB, keeps the existing file mode, and replaces the file atomically. It makes no backup.
  - Turning hooks off stops routing but **leaves the entries in place**. A leftover hook does nothing once no Dispatch connection is live.
  - Hook events forward their full JSON to your Mac, up to 250 KB each, including prompts and tool input.
- **Helper command:** `~/.dispatch/bin/dispatch-helper`, the stable path that hook entries and shell startup files run. It points to an immutable executable in `bin/launchers/<sha256>/`; updates atomically switch this link without replacing a running launcher's executable. These builds are separate from the repairable SSH upload cache in `bin/versions/`. Cleanup retains the published target, running builds, and builds used within the last day.
- **Pi:** the extension `<pi agent dir>/extensions/dispatch-chat.js` is removed again when Pi hooks are turned off.
- **Shell startup:** when agent hooks are granted, the remote shell starts through private startup files that define `claude`, `codex`, `pi`, and `herdr` functions, unless you already have a function (or, in bash and zsh, an alias) with that name. Your rc files are sourced, never edited.
- **Agent control:** with Chat, the helper can type prompts into a verified agent's terminal, tmux pane, or herdr pane. It can start `codex app-server --stdio` for side conversations, and create tmux windows and herdr tabs.
- **Commands:** the helper is a terminal server. The Chat, hooks, tmux, and herdr grants each let the Mac open remote terminals that run any command and type into them; tmux also lets it send tmux commands. The helper also connects to agents' and herdr's own sockets.
- **Left behind after disconnect** (until you [remove Dispatch](#removing-dispatch) from the host):
  - in `~/.dispatch/`: the helper copy and the most recently used helper versions in `bin/`, herdr recovery records in `state/`, session folders for up to a day, and chat attachments in `attachments/` for 7 days (with their delivery index in `state/attachments/`);
  - lock files in agent config folders;
  - the hook entries above;

<a id="removing-dispatch"></a>**Removing Dispatch.** Run `~/.dispatch/bin/dispatch-helper uninstall` on each machine (add `--dry-run` to preview). It removes every Dispatch hook (as `uninstall-hooks`), Pi's Dispatch extension and its `dispatch/` folder when the extension is unmodified, older helpers' empty `.dispatch-hooks.lock` files in the agents' folders, and `~/.dispatch`. It refuses while a Dispatch helper runs on that machine, and keeps `~/.dispatch` when a hook file can't be cleaned, so the remaining hooks still run a helper that does nothing. Settings › Hosts does the same for you: **Remove Dispatch…** on an SSH host forgets the host, then runs it there over SSH (keys or the SSH agent only); **Remove Dispatch from this Mac…** quits Dispatch, runs it here, and can also delete the app's settings, drafts and saved hosts. Both show the dry run first. The app itself goes to the Trash as usual.

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

## Dictation

The chat composer's microphone turns speech into a draft on the Mac; no audio or text leaves it.

- **Microphone.** macOS asks once, on the first dictation ("Dispatch listens while you dictate a chat message."). The app is signed with `com.apple.security.device.audio-input`, which the hardened runtime requires for that. It listens only from start to stop: right ⌘ held down for one message, or conversation mode, from a click of the microphone or a tap of right ⌘ until the next one (macOS shows its microphone indicator meanwhile). Conversation mode keeps listening between messages, so it also stops by itself: while Dispatch isn't the frontmost app or the screen is locked (it listens again when you come back), and after 5 minutes without speech. The right ⌘ shortcut is an in-app event monitor, active only while Dispatch is frontmost; it needs no Accessibility or Input Monitoring permission and can be turned off in Settings › Dictation. A recording is kept in memory only until it is transcribed, never written to disk; the text it turns into goes into the draft as it is heard, and drafts are saved like typed ones. A transcript that starts with a wake word ("Dispatch" or "Captain" unless you chose others in Settings › Dictation) and names a space or tab, or the sidebar (Settings › Dictation › Navigate by voice), only switches the window to it or shows or hides the sidebar, and is not kept; the other "Dispatch, …" commands act only on the chat the window shows: send or steer its draft, edit the draft, stop the agent's turn, deny a permission request, or pick an option of the agent's question. No voice command allows a permission request, and none types into a terminal.
- **Reading aloud.** With Read replies aloud on (Settings › Dictation), conversation mode reads the chat's replies, permission requests and questions with macOS's on-device speech synthesizer (`AVSpeechSynthesizer`), and names other chats whose agents finish or need you. Nothing is sent anywhere; the microphone is ignored while it speaks.
- **Apple (default).** On macOS 26 and later, Speech's `SpeechAnalyzer`, which runs on the Mac; the first dictation in a language may have macOS download that language's model, as system dictation does. On macOS 14 and 15, `SFSpeechRecognizer` with `requiresOnDeviceRecognition`: it fails rather than send audio to Apple, and macOS also asks for **Speech Recognition** permission.
- **Whisper.** `Packages/WhisperEngine`, a Swift port of whisper.cpp (its Metal kernels adapted from ggml), in the app. Settings downloads the models you choose over `https` from `huggingface.co/ggerganov/whisper.cpp`; a model is used only once its size and SHA-256 match the values built into the app. Models are kept in `~/Library/Application Support/Dispatch/Whisper/` until you delete them in Settings, and the last one used stays in memory for 3 minutes after a dictation.
- The transcript goes into the draft at the caret, as typing would; nothing is sent until you send.

## Data stored on your Mac

| What | Where | Contents | When | Protection |
| --- | --- | --- | --- | --- |
| Settings | `~/Library/Application Support/Dispatch/Local/settings.json` | Preferences, including the starting folder | On change | Atomic write; default file mode |
| Spaces | `…/Dispatch/host-session.json` | Spaces, tabs, titles, and folders; host records; SSH executables, options, and destinations; remote uid and boot ID; herdr recovery tokens; tmux sessions. No credentials or launch commands. | On window close and quit, while **Reopen spaces on launch** is on (on). Deleted when that setting is turned off. | 0600, atomic |
| Terminal output | `…/Dispatch/terminal-history.json` | The raw text of plain local and SSH tabs: commands, output, and anything else visible, possibly secrets. Not tmux or herdr tabs. | Only on a normal quit, with **Restore tab history** (off) and **Reopen spaces** both on. Deleted from disk early in the next launch, ignored after 7 days, and deleted when the setting is turned off. | 0600, atomic, excluded from backups. Capped at one scrollback per tab and 1/32 of RAM in total. Replayed without control sequences. |
| Chat drafts | `…/Dispatch/drafts.json` | Working and saved drafts, plus a copy of each prompt from before it is sent until delivery is confirmed, per host, agent, and conversation; a draft with attachments keeps their names, sizes, host paths and small JPEG thumbnails (the files themselves stay on the host) | 300 ms after typing stops, and at most every 2 s | Owner-only atomic write; excluded from backups; no expiry |
| Reviews | `…/Dispatch/reviews.json` | The Review tab's comments per host and repository folder: each comment's text, file path, line numbers, and the lines of code it is on as they read then; the overall comment | When a comment is saved, edited, or deleted, and 300 ms after typing in the overall comment stops. Create review removes the review (its Undo is in memory only). | Owner-only atomic write; excluded from backups; a review unchanged for 60 days is deleted |
| Helper files | `~/.dispatch/` | `bin/dispatch-helper`, a stable link to an immutable build in `bin/launchers/` that hook entries run; `run/*/` hook sockets and startup files of running helpers; `routes/` which helper serves each hook; `state/` herdr recovery records; `state/queue/` chat messages you queued for Claude Code or Pi, in full, until they are sent or removed; `attachments/` copies of files you attached in Chat, with `state/attachments/` naming the copies each message sent | `bin/dispatch-helper` is refreshed when a helper writes a hook or startup command; each `run/*/` exists while its helper runs; attachment folders are removed 7 days after they last changed | Folders 0700, sockets 0600 |
| Color schemes | `~/.config/dispatch/themes/` | Your own color schemes, as Ghostty theme files: colors only | When you make or add one in Settings › Appearance › Custom color schemes, or import one in Settings › Extra; deleted (to the Trash) in Custom color schemes | Default file mode, atomic |
| Whisper models | `…/Dispatch/Whisper/` | The ggml model files you downloaded for dictation | When you download one in Settings; deleted there | Default file mode |
| Diagnostics | `~/Library/Logs/Dispatch/Diagnostics/` | Chat scroll and viewport events and geometry. Row IDs are replaced with keyed hashes; no conversation text, hosts, or paths. | Only while **Diagnostics** is on (off). Turning it off doesn't delete existing files. | 0600, rotated at 4 MiB |
| UserDefaults (`yachts.dispatch.app`) | `~/Library/Preferences` | Chat and hook switches, SSH grants (`SSHIntegrationPermissions.v2`), host records (`HostRegistry.v1`), herdr presentation, window frame | On change | Default |

**Imports and export (Settings › Extra).** Only when you ask, Dispatch reads Ghostty's config (`$XDG_CONFIG_HOME/ghostty/config` or `~/.config/ghostty/config`, `~/Library/Application Support/com.mitchellh.ghostty/config`, and files they include), iTerm2's preferences (`com.googlecode.iterm2`) or Terminal's (`com.apple.Terminal`), and shows what it would take before applying anything: fonts, colors, cursor, Option keys, scrollback, shell, and starting folder. It never changes those files. It always reads Ghostty's own themes folder (`~/.config/ghostty/themes`) to list and use them. Export writes a folder you choose with a Ghostty `config`, your color schemes, and `dispatch-settings.json` (all of Settings, including the starting folder and shell).

Dispatch doesn't store transcripts, approvals, statistics, or model lists; those stay in memory only. Agent histories and tmux/herdr sessions belong to those tools. Logging is minimal and contains no terminal or chat content.

## Notifications

With **Notifications** on (default), Dispatch asks macOS for notification permission. When an agent needs you while its pane isn't visible, it sends a notification:

- **Title:** the pane name.
- **Subtitle:** the pane's folder.
- **Body:** up to 160 characters of the agent's reply, the requested operation, or the question.

These can appear on the lock screen, depending on your macOS notification settings. Turning the setting off removes notifications already delivered. The Dock badge (on) shows how many panes are waiting.

## Build and distribution

- Release and Debug builds are ad-hoc signed (`CODE_SIGN_IDENTITY "-"`) with the hardened runtime and one entitlement, `com.apple.security.device.audio-input` (dictation). They are not notarized, so a copy you receive can't be traced to who built it.
- The tmux bridge and the macOS SSH helper are signed the same way. The Linux SSH helpers are not signed.
- Release builds leave out the helper's capture and replay test hooks. In Debug builds, setting `DISPATCH_CAPTURE` for the app makes every helper it starts, SSH ones included, write all of its I/O to trace files, unredacted.
- Dispatch registers no URL schemes, services, AppleScript support, or login items. The only privacy permissions it asks for are the microphone and, on macOS 14 and 15, Speech Recognition, both on the first [dictation](#dictation).
- Setup asks before downloading. Downloads are `https`-only, pinned by SHA-256 (`scripts/build.lock.json`, `scripts/test-tools.lock.json`), and kept under `build/`. The SSH helper has no third-party Rust dependencies and builds offline (`cargo build --offline --frozen`).
- Desktop, SSH, and agent tests need sudo and take over the desktop; run them only in the [test VM](vm_testing.md).

## Dispatch for iPhone

The iPhone app ([docs/ios.md](ios.md)) is sandboxed like every iOS app and sideloaded: you build it and sign it with your own Apple team. It runs nothing on the phone but itself; on each host it runs the same helper as the Mac, with one fixed grant.

**Network.**

- The only connections it makes are SSH connections to the hosts you add, to the address and port you typed, and the Whisper model downloads you start in Settings › Dictation (as on the Mac: `huggingface.co`, size and SHA-256 checked). No telemetry, analytics, crash reporting, update checks, push service or iCloud.
- **Dictation** works as on the [Mac](#dictation): iOS asks for the **microphone** on the first dictation, Apple's engine is `SpeechAnalyzer` on the phone, Whisper runs in the app, and the recording stays in memory until it is transcribed. Leaving the conversation stops listening.
- iOS asks once for **Local Network** access ("Dispatch connects to SSH hosts on your local network."); hosts on your LAN need it, hosts on the internet don't.
- Network changes are watched (`NWPathMonitor`, no traffic) only to reconnect sooner.

**Host keys: trust on first use.**

- The first connection to a host and port shows the key's algorithm and SHA-256 fingerprint; nothing is sent past the key exchange until you tap Trust. Cancel ends the connection.
- A trusted key is kept per host and port (`known_hosts.json`, as OpenSSH names them). A different key or algorithm later is a hard stop: the sheet shows both fingerprints and offers only Remove and retry, which forgets the old key and asks again. There is no "connect anyway".
- Background refresh never asks: an untrusted or changed key fails that run.
- Removing a host forgets its key unless another host uses the same address and port.
- **Rekeys are not re-checked.** The key is checked at the connection's first key exchange only. SSH re-runs the exchange inside the encrypted connection (russh every hour by default, servers after their own limits), and russh 0.64.1, which the phone's engine uses, verifies that exchange's signature but does not hand its host key to the app, so a server that authenticated with the trusted key could present a different one at a rekey. Only the server end of the established, authenticated connection can do that (a rekey runs under the current session keys), so this is not a man-in-the-middle opening; the app does not patch russh for it. What a patch needs is noted beside the engine's `check_server_key` (`Mobile/Transport/Core/src/session.rs`).
- A `known_hosts.json` the app cannot read (damaged, another version) fails closed: no host connects and nothing is trusted or asked about until you choose Retry or Reset in Spaces; Reset sets the file aside (kept until Remove all data) and every host asks about its key again. A trusted key that could not be saved stays trusted for the run and Spaces says so with Retry.

**Keys and passwords.**

- New keys are ED25519, made on the phone. The private half is a Keychain item (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronized) behind a `biometryCurrentSet` access control: Face ID unlocks it ("Dispatch uses Face ID to unlock your SSH keys."), once per foreground run of the app, and enrolling another face or turning Face ID off makes the key unusable.
- **Secure Enclave** keys (P-256, offered as `ecdsa-sha2-nistp256`) are made inside the enclave with the same access control and never leave it; every signature asks Face ID.
- Imported OpenSSH keys (from Files or pasted) are kept behind Face ID the same way. Their passphrases, host passwords and Secure Enclave keys' handles are Keychain items without biometry, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by the app once the phone has been unlocked since it started, also while it is locked, so a watch request or background refresh logs in with a password while the phone is in a pocket. The trade-off: code running as the app on a phone unlocked once since boot can read them while it is locked; they still never leave the device, sync or reach a backup, and a key behind Face ID (or in the Secure Enclave) is never used without it (a read that may not prompt fails, `interactionNotAllowed`). Items an older build kept `WhenUnlockedThisDeviceOnly` move to the new class at the first launch while the phone is unlocked; the move reads no secret and never touches a Face ID item. Keyboard-interactive answers are sent and not stored.
- Copy and Share public key give out only the `authorized_keys` line.
- **Secrets in memory.** The engine (Rust) wipes its copies of passwords, passphrases and answers. On the Swift side, a key file and its passphrase read from the Keychain are copied once into a buffer of the app's own (`SecretBytes`), passed to the engine as bytes (never as a `String`) and overwritten with zeros (`memset_s`) once the engine has parsed the key (or failed to); an ED25519 seed's buffer is wiped as soon as CryptoKit holds the key (CryptoKit zeroes its own). The C copies of keyboard-interactive answers are wiped before they are freed. What remains: the buffer the Keychain returns (`SecItemCopyMatching`'s immutable data) is released without a wipe; passwords are Swift `String`s from the Keychain until the login ends; and what you type (a password, a passphrase on import, a keyboard-interactive answer) passes through SwiftUI text fields as `String`s, which Swift cannot overwrite. None of these is written anywhere.

**Data on the phone.** Everything stays on the phone: no iCloud, no sync, and the app's files are excluded from device backups, so a backup restored onto another phone brings no host, key, password or trusted key along. Files are in the app's Application Support, written whole, owner-only (0600) and atomically, in data protection class C (`completeUntilFirstUserAuthentication`): like the passwords, readable after the first unlock since the phone started, so a watch request with the phone locked can read the hosts, keys and trusted host keys and write the queue, markers and cache. Files an older build wrote in class A (`complete`) move at the first launch while the phone is unlocked.

| What | Where | Contents |
| --- | --- | --- |
| Hosts | `hosts.json` | Name, address, port, user, which key or password (the secret is in the Keychain), multiplexer preference, Chat on or off, order, last connection, the OS and machine colour the helper reported |
| Trusted host keys | `known_hosts.json` | Algorithm and key per host and port |
| Keys | `keys.json` | Names, types, `authorized_keys` lines and fingerprints; private halves in the Keychain |
| Launch cache | `host-cache.json` | Per host the last hello (identity, OS, homes), multiplexers, topology (space, tab and pane names, folders), and Agents' rows with at most 280 characters of the last message and the conversation's title (which names the row). No transcript beyond that, no secret. |
| Chat | `chat-queue.json`, `drafts.json`, `chat-markers.json`, `chat-models.json` | Queued messages until delivered, drafts, seen times and mutes, the last agent, model and effort |
| Activity | `tab-activity-2.json` | When each pane last changed (seen live), at most 400 panes per host and 60 days |
| Spaces | `spaces.json` | Per host: the space New tab goes to, collapsed host sections, the phone's order of its spaces (space keys hold tmux session and herdr workspace names) |
| Settings | UserDefaults | Appearance, font sizes, Spaces' sort, filter and tree toggle, Background refresh, the dictation engine and Whisper model (nothing that names a host; older builds' per-host keys move to `spaces.json`) |
| Whisper models | `Whisper/` | The ggml model files you downloaded for dictation, excluded from backups like the rest; deleted in Settings › Dictation |

Transcripts, terminal output and stats are kept in memory only. Debug builds read test switches from the environment (`DISPATCH_MOBILE_*`); Release builds compile them out.

**Remove all data** (Settings) deletes every host, key and Keychain item of the app, trusted host keys, the cache, drafts, the queue, markers and mutes, the remembered agents and models, and Spaces' per-host values (`spaces.json`, and any an older build left in UserDefaults); turns background refresh off; and removes delivered notifications. Appearance, font sizes and Spaces' menu stay, and nothing changes on the hosts. **Remove all data except SSH keys** does the same but keeps the SSH keys and their Keychain items (private keys, Secure Enclave handles and passphrases); host passwords still go.

**Notifications.** Only with **Background refresh** on (off) and notification permission granted. Roughly every 15 minutes or more, as iOS decides, the app connects to every host with Chat on that needs no prompt (a password host; not a Face ID key, a keyboard-interactive login or an untrusted host key; its Keychain reads set `interactionNotAllowed`, so a Face ID key fails at once instead of attempting a prompt and the host is skipped), reads the agents' state, disconnects, and posts one notification per conversation that newly needs you: title "tab · host", body the last line of the agent's newest text. These can appear on the lock screen, depending on your iOS settings; with previews hidden (Show Previews: When Unlocked or Never) the lock screen shows only "An agent needs you", without the title or the agent's line.

**Apple Watch.** The watch app ([docs/watch.md](watch.md)) holds no host address, key, password, node id or helper connection: over WatchConnectivity the phone sends it what the phone's own lists show (host display names, colours and states, with connection failures naming a host by its display name instead of its address, port or user; Agents rows with at most 120 characters of the last message, space, tab and folder names) and, for a conversation opened on the watch, a page of its transcript (each item at most 1,000 characters); the watch sends back answers, messages and seen marks, which the phone applies as its own. An approval or message sent from the watch rests on the watch's lock (its passcode and wrist detection), not on the phone's Face ID. A watch request while the phone app is in the background connects the one host it needs, as background refresh does (no Face ID key, untrusted host key or keyboard-interactive login), and disconnects it 60 s after the last request; with the phone locked too, since passwords are readable after the first unlock (a Face ID key host never connects so). There is no switch: removing Dispatch from the watch stops it, and Settings shows whether it is installed.

**What the helper does on your host.** The same helper as the Mac's, uploaded (macOS on Apple silicon, Linux arm64 and x86-64) with the same checks ([the helper on the remote host](#ssh-integration): private permissions, size and SHA-256 before it is moved into place and before every run, no code signature on Linux), with the same reach for what it reads and changes (hooks in Claude Code's and Codex's config, Pi's extension, terminals it opens and types into, tmux and herdr control), and the same login-shell `PATH` probe when started without the Mac's login wrapper. What differs on the phone:

- **Command.** One exec channel per host, no PTY and no environment variables. Your login shell's `-c` (as sshd runs every command) execs `/bin/sh` with a fixed script: it enters `~/.dispatch/bin/versions/<sha256>` through the private-folder checks, checks the file's size and SHA-256 again, and runs `exec ./dispatch-helper --remote --capabilities '<grant>' --stdio`. Nothing the host sends goes into that command. The helper is a child of sshd, not a daemon.
- **The grant** is fixed (the Mac's **Full features** with hooks, less `file.write` and `git.read`): `agent.events`, `agent.inspect`, `agent.pi`, `agent.pi.configure`, `agent.queue`, `agent.side`, `agent.submit`, `agent.version`, `backend.register`, `cancel`, `events`, `file.read`, `file.text`, `herdr.rpc`, `herdr.start`, `herdr.terminal`, `hooks.configure`, `host.identity`, `input.window`, `shell.lifecycle`, `stats.ping`, `stats.processes`, `stats.sample`, `tmux.pane`. The New host sheet says so in words before the first connection ("Dispatch installs its helper in ~/.dispatch on the host and runs it over this connection, as your user. …"); a test fails if a capability has no words there.
- **Hello features** the phone adds (specified in `helper/PROTOCOL.md`): `interaction.options` (Claude's "This session" approval, which adds the suggested allow rules for that Claude session only), `chat.list` and `projects.recent` (read-only summaries: agent rows, and recent project folders from Claude's, Codex's and Pi's history), `multiplexers.versions` (installed versions and whether a server runs, probed without starting one), `terminals.coalesce`, `terminals.activity` (read-only: when tmux last saw output in each window, `#{window_activity}`, asked through the helper's own tmux control connection), `launch.names` (names a launched window or tab after its agent; the name, `DISPATCH_LAUNCH_NAME`, goes to tmux, herdr or the helper's own terminals and never into the agent's environment) and `stdio.liveness`: the helper exits when the phone has sent nothing for 45 s (the phone pings every 10 s while connected), so a connection whose close never arrives leaves no helper behind. Shells and agents live in tmux or herdr and keep running. A helper serving a Mac at the same time keeps the Mac's behaviour on the Mac's connection.
- **Servers.** Connecting never starts tmux or herdr; **New space** does (`backends.create`), and that server keeps running after the phone disconnects, as on the Mac. Close Tab and Close Space follow the Mac's close policy: only verified-idle work is terminated, anything else is detached.
- **Removing.** Removing a host on the phone changes nothing on the host. To remove Dispatch from a host, run `~/.dispatch/bin/dispatch-helper uninstall` there ([Removing Dispatch](#removing-dispatch)).

**Per-host Chat switch.** Settings lists each host with a **Chat** switch (on). Off, the helper runs without `hooks.configure` and every `agent.*` capability: it installs no hooks, reads no transcripts and drives no agent, and the host's agents show as plain terminals (background refresh skips the host). Turning it off on a live connection shrinks the running helper's grant (`permissions.reduce`, a reconnect if that fails); turning it on reconnects, since a grant only shrinks. Hooks installed earlier stay in the agents' config, inert while no Dispatch connection routes them, until `dispatch-helper uninstall-hooks` removes them.
