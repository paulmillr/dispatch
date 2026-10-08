# Architecture

Each rule here guards against lost sessions, misdelivered input, or leaked data. Build and test mechanics are in [CLAUDE.md](../CLAUDE.md) and [test/README.md](../test/README.md); tmux, herdr, SSH, and agent lifecycles are in [integrations](integrations.md).

| Owner | Owns |
| --- | --- |
| [AppDelegate](../Dispatch/AppDelegate.swift) | Wiring, restoration, shutdown order. |
| [Workspace](../Dispatch/Workspace.swift) | Spaces, panes, tabs, selection, host placement. Related mutations publish together through `updateLayout`. |
| [TerminalRuntime](../Dispatch/Terminal/TerminalRuntime.swift) | The terminal engine and its surfaces, keyed by stable UUID. |
| [Hosts](../Dispatch/Hosts/) | Presentation identity, kept separate from live process ownership and connection recipes. |
| [SSH](../Dispatch/SSH/) | Enhanced-connection authentication and per-connection feature grants. |
| [Tmux](../Dispatch/Tmux/) / [Herdr](../Dispatch/Herdr/) | Mapping server-owned sessions into native spaces and tabs. |
| [Chat](../Dispatch/Chat/) | Agent discovery, per-surface sessions, drafts, submissions, approvals. |
| [Views](../Dispatch/Views/) | Presentation only. Views never own shell lifetime. |

## Invariants

- **Threading.** Workspace and UI coordinators are `@MainActor`. Blocking I/O, process inspection, and heavy parsing run on transport actors or background workers that report back to the owning coordinator.
- **Identity.** Host changes, reorders, splits, and Terminal↔Chat switches preserve surface and conversation identity. Presentation changes never relaunch a shell or acquire input authority.
- **Server-owned sessions.** Detaching a native view from tmux/herdr is not terminating server work. Backend snapshots reconcile existing presentation identities in place.
- **Remote trust.** Host grouping is presentation, not a permission boundary: grouped aliases can have different grants. Remote operations carry authenticated connection/process identities and generations, and a remote PID is never a local PID. Agent hooks on a remote connection need that connection's grant. Ordinary SSH works without the helper.
- **Delivery.** After async work or reconnect, a submission revalidates its destination. Uncertain delivery is never retried automatically.
- **Agent requests.** Chat attaches only after discovery establishes process and conversation ownership. Approvals and question replies belong to a live request and never migrate with presentation state. Losing verification pauses input but keeps history and drafts.
- **Persistence.** Dispatch saves only what `SettingsStore`, `HostSessionStore`, `TerminalHistoryStore`, and `ChatDraftRepository` save; it never restores shell processes. Sensitive files go through `PrivateFile` (owner-only, atomic). Agent histories and tmux/herdr sessions belong to those tools.
- **Diagnostics.** `ChatViewportTrace` is opt-in, bounded, and never records conversation text, host/user details, paths, or original row IDs.
- **Engine.** The terminal is the Swift terminal (`Vendor/Term`, ported from Ghostty) behind [`TerminalBackend`](../Dispatch/Terminal/TerminalBackend.swift). It reads a Ghostty-syntax config, bundles Ghostty's shell integration and themes (`Vendor/Term/Resources`), and draws with the contrast shader in [`Shaders.swift`](../Vendor/Term/Sources/TermApple/Shaders.swift).
- **Shutdown.** Save the remote workspace, unmount native views, stop coordinators, destroy surfaces, release the terminal engine, then await SSH/launcher cleanup.
