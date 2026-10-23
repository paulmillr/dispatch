# Demo fixtures (iPhone simulator demo)

Everything here is invented: the user is alex, anyone else Sam Example, hosts and repos are fictional, times are on
2000-01-01 (the demo re-times them). Written by `test/mobile-demo-fixtures.py`; rerun it after a helper change to the
chat record encoders:

    python3 test/mobile-demo-fixtures.py [--helper build/helper-rust/bin/darwin-arm64]

- `chats/<name>.json`: the real helper's `chat.page` pages for transcripts authored in the script (Claude Code JSONL,
  Codex rollouts), recorded and neutralised exactly as `test/mobile-chat-fixtures.py` records the chat fixtures.
  `web-dark-mode` ends mid-turn (still running); `api-rate-limit` ends before an approval; the others are complete.
- `terminals/<name>.vt`: the bytes a tmux pane replays on attach (CRLF, SGR colours). Shell tabs end with a prompt;
  the live tabs (`web-dev`, `api-logs`, `train-gpu`) end with the running process's last line and a CRLF.
  `agent-claude` / `agent-codex` are the agent CLIs' screens at rest, for an agent tab's Terminal segment.
- `live/<name>.txt`: lines the demo appends to a live tab one at a time, looping.
