# Native integrations

Rules every integration follows: server jobs and agent processes belong to their servers and agents; Dispatch only presents them. Detaching, closing, quitting, forgetting a host, and resetting permissions never kill remote work. Reconnect and retry never create replacement jobs, replay commands, or resend input whose delivery is uncertain.

## tmux and herdr

Launch with `tmux -CC new-session -A -s work`, or `herdr` (`--session NAME`, `session attach NAME`). tmux windows become tabs that keep their server splits; herdr workspaces/tabs become spaces/tabs.

- **Close tab** terminates only if every pane is verified idle (foreground, background, and stopped jobs). Otherwise, or if inspection is unavailable (e.g. disconnected), it detaches. Close space, Detach, and quit always detach.
- **Detached** sidebar items reattach to the original client or session, never a replacement. The list lasts only for the current run.
- Layout presets rearrange tabs locally; they never touch server processes or nested splits. Tabs move only between spaces on the same backend connection.
- A successful handoff closes the launching tab, over SSH too. Settings no longer offers to keep it; `closeLaunching` stays in the preferences for settings files that turned it off and for tests that keep the tab as a shell to reattach from. The tmux gateway lives while native panes need it, and remote herdr keeps its SSH connection until the last native view detaches. A failed attach leaves the terminal usable.
- Versions: herdr validated on 0.9.0, and its CLI forms pass through. tmux ≥ 3.7 reports bracketed-paste state. Older servers fall back to paste markers, with a Chat warning that readiness can't be verified. Ownership, copy-mode, disabled-input, and synchronized-pane checks still apply.

## SSH

OpenSSH owns host keys, identities, aliases, ports, and jumps. **On new hosts** (Ask by default; Full features; Plain SSH) decides whether to upload the helper; Escape or a timeout aborts the `ssh` (status 130) rather than silently falling back to plain SSH. What the helper may read and change is listed in [security](security.md#ssh-integration).

- **Helper:** the bundled Rust helper (macOS 14+, Linux arm64/x86-64) needs no remote compiler or Python; its contract is in [`Helpers/ssh-helper/README.md`](../Helpers/ssh-helper/README.md). Unsupported hosts fall back to ordinary SSH. Cached legacy C helpers grant nothing.
- **Grants are per configuration:** executable, destination, account, port, proxy, and identity. Hosts that share a sidebar card (same destination, account, port, proxy route, and host-key alias) share presentation only; each connection keeps its own generation and grant. Conflicting machine identities split the card.
- **Grant changes:** reductions take effect immediately (helper operations, hooks, and native views stop; the shell and jobs stay). Increases apply on the next explicit connection. Helper updates keep existing grants, but new capabilities need a new choice. Reset/Forget/Reset all revoke live grants and clear saved choices without touching remote jobs.
- **Passthrough:** noninteractive commands, RemoteCommand, multiplexing overrides, tunnels, and subsystems run as plain SSH. `ssh -tt host cmd` can be enhanced. Nested interactive SSH stays plain and suppresses outer-host agent discovery. Clones use `ClearAllForwardings=yes`.
- **Shell integration** keeps user aliases and functions, resolves executables through the caller's `PATH` (skipping Dispatch's shims), and never wraps `sudo`.
- **Stats** never start or keep an SSH connection. Latency is a `stats.ping` round trip through the helper, not ICMP; one probe runs at a time, with a 3 s timeout that never disconnects.

### Reconnect

Quit saves remote hosts, layouts, and plain local spaces to `~/Library/Application Support/Dispatch/host-session.json` (when **Reopen spaces on launch** is on). They reopen disconnected, with no automatic login. Tabs keep their placement, renderer, loaded Chat history, and drafts across transport loss. Recovery re-verifies the SSH configuration, grant, account, and host identity over a fresh connection. tmux/herdr reattach to existing servers and panes only, and a missing session stays an error. Chat rejects reads and input from the old connection, and queues stay paused. Direct `/usr/bin/ssh` and plain-SSH connections get no managed recovery. Recovery state does not survive an app restart.

**Reconnect automatically** (SSH settings, off by default) recovers a connection that dropped while Dispatch was running: only after the launcher reports a transport loss with no exit status or receipt, never after Disconnect, a normal exit, or a launch restore. Automatic attempts run the same verified recovery, but never show anything: the remembered grant only, and OpenSSH with `BatchMode=yes` (keys and the agent). An unreachable host is retried 2 s, 4 s… up to a minute apart, and at once on wake or a network change. OpenSSH refusing the login (a password, passphrase, or changed host key), any later recovery failure, a closed login tab (e.g. herdr's after handoff, whose recovery opens a login tab), and your own Reconnect, Cancel, or Disconnect each end the retries for that drop and leave the Reconnect bar.

## Chat

Codex, Claude Code, Pi, and Nanocodex attach to the agent already running in a local terminal, tmux/herdr pane, or SSH session (remote discovery needs Full integration on that connection; Nanocodex needs only the Chat grant). Terminal and Chat share that process.

- **Ownership:** discovery must verify both the process and the conversation. A matching directory, inherited tmux environment, or coincidental PID proves nothing. Ambiguity (e.g. multiple main Codex rollouts) pauses input but keeps the transcript and draft. Codex guardian reviews and subagents are excluded. A direct registered SSH connection outranks its enclosing pane.
- **Input:** destinations are revalidated before paste and Return, and uncertain delivery pauses for review instead of retrying. Text already in an agent's native editor blocks submission. Multiline text starting with `/` or `!` stays literal. Only an explicit user action switches to Terminal. A bare `/resume` is one: once Claude Code or Codex has it, Chat switches to Terminal for the agent's session picker and follows the conversation picked there.
- **Approvals and questions** are bound to the live request, process, and conversation. They never migrate, replay, or let one approval cover a later request. They need Dispatch's agent hooks (installed as described in [security](security.md#agent-chat)); agents must restart to load them, and remote hooks also need the hooks grant.
- **Queue:** messages keep their send order and their conversation/process binding. Delivery waits for Terminal view, menus, questions, approvals, history loading, and open side sheets. Stop pauses the queue until Resume. When the native queue API exists (Codex locally, or `agent.queue` over SSH), Chat mirrors Codex's own queue instead, and an accepted entry never falls back to terminal input.
- **Side conversations:** `/btw` is a read-only fork and `/side` a full-permission fork, for local/remote Codex and local Claude. Their replies stay out of the parent transcript, and closing the sheet ends the child process.

### Per agent

- **Codex:** local launches through shell integration use a private App Server with the native TUI. Chat follows the main thread across `/new` and `/resume` and ignores ephemeral threads. Explicit `--remote` endpoints keep their own server. Sessions that bypass shell integration, older CLIs, and unsupported flags stay Terminal-only. Live diffs need an accessible App Server (Unix socket, the helper channel, or an unauthenticated local WebSocket), and partial diffs need Codex's `features.apply_patch_streaming_events`. Dispatch never enables experimental flags.
- **Claude Code:** adds `PermissionRequest` and an `AskUserQuestion`-only `PreToolUse` hook. Questions expire after 180 s; Skip denies them. Disabling hooks returns requests to the native UI without approving them. Stop sends one Escape after verifying the working conversation; it must never open the rewind menu.
- **Pi:** needs the **Pi chat extension** setting, then `/reload`. Chat follows the current branch of the session tree. `--no-session`, print, and RPC processes don't attach. Remote installs resolve `PI_CODING_AGENT_DIR` and touch only Dispatch's extension.
- **Nanocodex:** no install step. Discovery reads a private registration under `$CODEX_HOME/nanocodex/tui/instances` that must name the same, already-running PID. Before sending its token, the connection verifies the socket peer's PID and user. Every command carries the instance, conversation, and generation. Sending needs nanocodex ≥ 0.6.6 (#681). Live rows come from the socket and merge with the rollout when the turn commits. Chat never touches the TUI's draft. Remotely, the helper authenticates on the host and relays allowlisted methods; the token never leaves the host. `NANOCODEX_TUI_CONTROL=off` opts a TUI out, and managed `nanocodex2` sessions stay Terminal-only.

Fixtures and validation: [testing](vm_testing.md#chat-and-ui-fixtures).
