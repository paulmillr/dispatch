# HelperClient fixtures

Real UI wire messages, recorded on a macOS test machine, stored DECODED: each body is the value the
helper's own binary codec decoded it to, so a codec change does not invalidate them. `schema` in
each fixture names the codec the frames were captured with (4270909662526680981 for all six);
HelperClientTests encode the values with the current codec at replay, give the hello reply the
current codec version (that field names the codec), and chunk a streamed reply (`stream`: "value",
or "binary" with the payload in `bytes`) by the hello's chunk settings, as the helper sends it.
Values survive JSON exactly: no reals, integers below 2^53 except the hello version.
`source_sha256` names the capture. The edits: the recording machine's identity from the hello reply
(account home and uid, hostname, host and boot ids) is replaced by fixed placeholders wherever it
appears in a value; then the written file goes through `scripts/redact.py` (machine or run data
masked at equal width, timestamps moved to the tool's fixed base; the write is refused if some
remains). In binary-reply the temporary file's name, its modification time, device and inode are
neutral values (the redaction masked the read path's directory).

Requests come from the production Swift client (Dispatch/Helper HelperConnection, HelperWire,
HelperTransport, HelperBinary); the tests check that the client sends exactly the recorded values:

| fixture | exchange | producer |
| --- | --- | --- |
| streamed-replies | hello, echo of a ~480 KB string (chunked reply), echo "small" | `test/helper-client-record.swift <helper> streamed` |
| binary-reply | hello, files.read of a 200 000-byte file (bytes 0...255 repeating): binary chunks + Metadata | `test/helper-client-record.swift <helper> binary <file>` |
| request-error | backends.open {key} without a mux: the helper's real error reply | `test/helper-client-record.swift <helper> error` |
| startup | hello, launches.list | `test/helper-client-probe.swift --stdio <helper> <out>` |
| live-tmux | backends.open of a private real tmux server (two sessions, four panes, both split axes), topology, cancel, echo | `test/helper-client-e2e.py` (probe + real tmux; live-native.tsv is the native list-panes oracle) |
| notifications | first notification of each method from a real client session (the live tmux capture) | that capture |

The producers above still record (`DISPATCH_CAPTURE=<dir>/capture.rpl.zst` and a private HOME;
the recorder ends the helper by EOF, not a signal: a killed helper can lose its last capture
records); `capture inspect` reads what they recorded.
