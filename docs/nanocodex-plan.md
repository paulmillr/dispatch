# Nanocodex integration

Target: nanocodex master after [#681](https://github.com/gakonst/nanocodex/pull/681) (`03bc8460`,
workspace version 0.6.6, not yet tagged); verified at `99f0846f`. Protocol reference:
[RICH_TERMINAL_INTEGRATION.md](../tmp/nanocodex-master/docs/RICH_TERMINAL_INTEGRATION.md). User-facing
behavior is documented in [integrations](integrations.md#nanocodex).

## Design

The earlier plan rebuilt history from the socket (`history.list`, `history.pending`, byte cursors).
That is unnecessary for the native TUI: its rollout is Codex-format JSONL, readable by the existing
`TranscriptParser`, backward paging, and search. The integration therefore has the same shape as Pi:
a registration file for discovery, the transcript for saved history, and a structured bridge for
live state and input.

| Concern | Source |
| --- | --- |
| Discovery | `$CODEX_HOME/nanocodex/tui/instances/*.json` with the process's PID, published after its birth, in a private directory (`NanocodexAgent.swift`). The socket handshake checks `LOCAL_PEERPID` and user before sending the token. |
| Saved history | The registration's `rollout_path` (the composer target's conversation). Committed at the end of every turn, including cancelled and failed ones. `input_accepted` records render as user rows; a steer has no `user_message`. |
| Live output | One persistent control connection per attached conversation (`NanocodexControl.swift`): `hello` → `history.live` for active turns only → `events.subscribe` after the snapshot `seq`. `agent.event` payloads map onto rollout identities (`user-<content>`, response `item_id`, `tool-<call_id>`) so the committed turn merges in place. Deltas are coalesced (~60 ms). Nested Code Mode calls (`call/code-N`) are skipped, as in the rollout. `replay_gap` reseeds from its snapshot. |
| Busy / turn | State carried by `state.changed`/`settings.changed` and run events (older TUIs: `state.get` after each), plus `state.get` after `conversation.active_changed`: `execution`, `active_turns`, `ui_blocked`, settings. |
| Input | `prompt`; `steer` with the active turn (Send now while busy); queued messages drain on idle; `cancel` for Stop, waiting for the turn to end. Every request carries instance, conversation and generation. `rejected` → not sent (draft kept); `pending` → `request.get` with the same ID; `unknown`/timeout → uncertain, never retried. |
| Settings | `models.list` + revision-checked `settings.set` behind the shared structured model picker (also used by Pi). Only the current model is offered once `model_mutable` is false; side conversations are read-only. |
| Slash commands | `/model`, `/effort` open the picker. Others use the `command` method when advertised; older TUIs receive them as typed input only when idle, unblocked, without a menu, and with an empty composer. `/btw` goes to nanocodex (Dispatch's own side conversation is not used). |

## Upstream changes (merged in nanocodex #681)

Dispatch works with 0.6.5 and later, but 0.6.5 rejects every Chat prompt; use a build that includes #681.

- **Native prompt admission.** Control prompts forwarded their request ID as a caller-owned
  `PromptRequest` identity, which needs an execution policy the native TUI never configures, so every
  external prompt was `admission_failed`. The ledger already deduplicates by
  request ID and the receipt carries the canonical `turn_id`.
- **Event filter.** `events.subscribe` accepts `exclude_types`. Raw provider `api.event` frames were
  94–95% of stream bytes in real turns; Dispatch excludes them and `model.*`.
- **State in notifications.** `state.changed` carries the non-draft state, `composer_empty` and
  `active_turns`; `settings.changed` carries settings. Dispatch no longer fetches state after changes.
- **`command`.** Runs one slash command in the native TUI without touching the composer, with receipt
  deduplication. Dispatch uses it when `capabilities.commands` is true and otherwise types commands
  into an idle, empty TUI composer.

The `tui_control` journey drives the real TUI in a PTY against a mock Responses socket with a filtered
and an unfiltered client; it fails without the admission fix.

## SSH

The Rust helper adds a `nanocodex` agent kind, `agent.inspect` session reports from the TUI's registration,
and an `agent.nanocodex` stream that authenticates on the host and relays allowlisted control methods
(see the helper README). The helper policy derives `agent.nanocodex` from the Chat grant's `agent.events` and
`agent.submit`, so existing grants cover it, revoking either ends the relay, and older helpers are detected.
This describes the legacy remote transport. The app now uses the common `HelperChat` interface;
the helper owns native control and prompt acknowledgements. Registering the common remote helper
connection replaces the legacy relay.

## Verification

- `NanocodexTests` (fast): live events reconcile with the committed rollout, including a steer after a
  fresh reload; registration identity and privacy checks; pending receipts resolve by request ID,
  rejections are not-sent.
- `NanocodexChatIntegrationTests` (full, desktop): the real binary against `scripts/codex_fixture.py`
  over HTTPS (`--api-key dispatch-fixture`, accepted only as that sentinel), locally and through
  `SSHTestServer`. Covers discovery, terminal draft preservation, commands, prompt, steer, queue, Stop,
  and effort changes.

## Not yet supported

1. **Managed `nanocodex2`.** No local rollout (`rollout_path` is null). History would come from
   `history.list` (`before` cursor) and `managed.event`; outer lifecycle events are authoritative, and
   steer/cancel can use `command.status`. Discovery currently reports it as unsupported.
2. **Reasoning summaries live.** `reasoning.summary.delta` has no item ID matching the rollout's
   reasoning item; summaries appear when the turn commits.
3. **Steer placement after reload.** Steers are persisted before the turn's committed items, so a
   reloaded transcript shows them with the prompt instead of where they were admitted.
4. **Test tooling.** nanocodex is not in `scripts/test-tools.lock.json`; the integration test depends
   on a locally linked master build until a tagged release includes #681, which can then be pinned.
