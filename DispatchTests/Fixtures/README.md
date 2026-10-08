# Codex fixtures

`codex-formatting-0.154.0.jsonl` contains real Codex 0.154.0 records captured with
`test/codex-chat.py` and the synthetic `formatting preview`
prompt. It covers completed user/agent items, tool output and exit status, model
metadata, and turn lifecycle records. Working directories are anonymized;
injected instructions and unrelated records are omitted. ChatFormattingTests
feeds both this capture and the 0.153.4 capture incrementally to check parsing,
message deduplication, and readable failure output.

`codex-content-items.jsonl` is a constructed fixture using the content-item wire
shapes in the local Codex checkout: `protocol/src/models.rs`
(`FunctionCallOutputBody` / `FunctionCallOutputContentItem`),
`core/src/tools/code_mode/mod.rs` (`prepend_script_status`), and
`core/src/tools/context.rs` (`McpToolOutput::response_payload`). It covers separate
status, Markdown, MCP and shell JSON text items. It is not captured traffic.

`codex-formatting-0.153.4.jsonl` contains real 0.153.4 rollout records for the
synthetic `formatting preview` prompt against the loopback fixture. It includes
the shell argument array, exit code 7, output envelope, and formatted assistant
response. The working directory is anonymized; injected instructions and unrelated
records are omitted. This is also exercised incrementally by ChatFormattingTests.

`codex-observed-0.153.2.jsonl` contains actual rollout records from the installed
CLI running `tool check` against `scripts/codex_fixture.py`. Session IDs, turn
IDs, and routing paths are anonymized; system/developer instructions and unrelated
records are omitted. Tool and message record shapes are retained.

`hooks-observed-0.153.2.json` contains actual hook inputs collected after reviewing
fixture hooks in Codex's native UI, submitting `approval test`, allowing its
harmless printf command, running `/compact`, and quitting. Only IDs and paths
are anonymized. PermissionRequest notably has no tool_use_id in this version.

`codex-0.153.2.jsonl` and `hooks-0.153.2.json` are small constructed boundary
fixtures for deterministic partial-write, unknown-record, and overlap tests.
They are not described as captured traffic.

The constructed Codex 0.157 compatibility cases in `ChatCommandTests`,
`ChatModelChoicesCacheTests`, and `ChatRoutingIntegrationTests` use the upstream
[Codex source](https://github.com/openai/codex/tree/00c972ed5d6ff6499317fd41b7f23605b8e6850d)
at commit `00c972ed5d6ff6499317fd41b7f23605b8e6850d`. Model names, identifiers and
paths are synthetic. The source files and SHA-256 hashes are:

| Source under `codex-rs/` | SHA-256 |
| --- | --- |
| `tui/src/chatwidget/snapshots/codex_tui__chatwidget__tests__custom_model_display_name_all_models.snap` | `bd1491206a13ac9d477917b530d9b6c303bd75ae6cf764d4b306b9fc266d44fa` |
| `tui/src/chatwidget/snapshots/codex_tui__chatwidget__tests__custom_model_display_name_reasoning.snap` | `2b05fa46372a09b6eaee5e4094b0afa4cd059a467513ef705742976d224a9fc6` |
| `tui/src/chatwidget/snapshots/codex_tui__chatwidget__tests__goal_edit_prompt.snap` | `2ca09140dd2a03f751dabf8721c7e14e0a027c97c1d15eec0597b0b73cf2f9e0` |
| `tui/src/chatwidget/snapshots/codex_tui__chatwidget__tests__review_during_mcp_startup.snap` | `02e77f412b835920ec17a4175339f8edc4a7ce4282a336c5041210d15b93af3b` |
| `tui/src/app/event_dispatch.rs` (Plan-only effort changes) | `bacc97e83ec3644f63e7b1050567bf1c5a67909f79287f9b9aa36823cc653b7e` |
| `protocol/src/protocol.rs` (`TurnStartedEvent.root_turn_id`) | `78c5ae9d664a3985c03caae1d42b7ad12d73e0afa59190bb2bec56d4a2277359` |
| `core/src/hook_runtime.rs` (review hooks use child turn IDs) | `7c1d358b03fbe9d9069ba54c2251368d6f59afa7dedf071b26d2c80d65339dd5` |

Regenerate real traffic using `python3 test/codex-chat.py --keep /tmp/new-results`.
Use only synthetic local prompts when refreshing these fixtures.

All captured fixtures use synthetic identifiers (including nested thread, turn,
message, tool-call, tool-output, and process IDs). Each capture starts at
2000-01-01T00:00:00Z; all other timestamps, including nested numeric epoch fields,
are shifted by the same amount to preserve event order and durations. UUIDv7
identifiers also encode only synthetic times; changing JSON dates alone is not
enough. Constructed fixtures use neutral dates, with explicit clock times and
timezone offsets retained where they exercise parsing or display behavior.
When refreshing a capture, review every nested field and tool output before
committing; replacing only the top-level session ID is insufficient. Raw
`rollout-*.jsonl` files are ignored and excluded from test resources and VM sync.

# Nanocodex fixtures

`nanocodex-0.6.5.jsonl` and `nanocodex-control-0.6.5.jsonl` are one real turn from
nanocodex 0.6.5 (with the prompt admission fix later merged as nanocodex #681) running against
`scripts/codex_fixture.py` over its HTTPS transport. Chat submitted
`SLOW_RESPONSE tool check` and steered it with `steer: keep it short` through the
TUI control socket. The first file is the committed rollout for that turn after its
`session_meta`; the second holds the matching `agent.event` payloads in socket order.
Instructions, environment context, `world_state`, provider frames, and `model.*`
timing events are omitted. Session, turn, message, call, and request IDs are
synthetic, paths are `/work`, and timestamps are shifted to start at
2000-01-01T00:00:00Z. The fixture server does not echo request metadata, so the
assistant message carries the `internal_chat_message_metadata_passthrough.turn_id`
(`<session>:<n>`) that OpenAI's backend writes from nanocodex's provider turn ID;
it names no rollout turn.
