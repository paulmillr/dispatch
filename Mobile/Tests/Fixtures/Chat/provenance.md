# Chat fixtures (iPhone)

The real helper's `chat.page` replies for transcripts read without a live terminal (the archive read), stored DECODED
as JSON: a list of pages, each `{records, earlier, state, snapshot}` exactly as the current helper's codec produced
it. `ChatSessionTests` replays them through a scripted helper (`ChatTestSupport.swift`) inside `chat.history`
notifications shaped like `helper/core/src/dispatch/chat.rs` `Chat`.

| fixture | transcript | records |
| --- | --- | --- |
| claude-thread | constructed Claude Code transcript (`test/mobile-chat-fixtures.py`): the M4a mockup's two turns, five and four tool calls, 1m 26s and 52s | 26 |
| codex-formatting-0.154.0 | `DispatchTests/Fixtures/codex-formatting-0.154.0.jsonl` (real Codex 0.154.0 rollout) | 5 |
| codex-observed-0.153.2 | `DispatchTests/Fixtures/codex-observed-0.153.2.jsonl` (real Codex 0.153.2 rollout) | 5 |

Producer: `python3 test/mobile-chat-fixtures.py` compiles `test/mobile-chat-record.swift` with the production client
(HelperConnection), runs `build/helper-rust/bin/darwin-arm64 --stdio` with a private HOME and writes the replies.
Edits: the snapshot's generation and file identity (device, inode) are neutral values. Identifiers, paths and times
are those of the inputs (synthetic: /work and /tmp/project paths, 2000-01-01 times).

Approvals and questions have no archive read; the tests build `interaction.opened` values in the shape
`helper/harnesses/claude/src/hooks.rs` produces from the real PermissionRequest hook input in
`DispatchTests/Fixtures/hooks-observed-0.153.2.json`.
