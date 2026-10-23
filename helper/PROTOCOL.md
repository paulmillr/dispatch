# Helper protocol

Maintained by hand until its generator, `helper/protocol.py`, exists: keep it in step with `helper/core/src/dispatch/table.rs` and the encoded records.

This describes the current compiled interfaces. Native availability is checked by the selected producer; an explicit implementation is not a guarantee for every native version.

## Framing

Each frame is `u32LE length | u8 kind | u64LE request_id | body`. Length counts kind, id and body (9 + body bytes); the complete header is 13 bytes.

Kinds: `Request = 1, Response = 2, Notify = 3, Cancel = 4, Chunk = 5,`. Request/response/notify bodies use the generated binary value codec: eight-byte schema id, LE numbers/lengths, generated symbol/record ids. JSON is never sent on the UI wire. Cancel addresses the original request id. IDs identify a client request, not a native process.

The advertised frame body limit is 12000013 bytes. Any response or notification exceeding 65536 bytes uses ordered Chunk frames; small messages remain inline.

A Chunk body is `u64LE sequence | raw bytes`, starting at sequence 0, with at most 65536 raw bytes. Its id is the original request id. The final original-kind binary frame has `stream: {chunks:u64, bytes:u64, encoding:"value"|"binary"}` and optional `result` metadata or `error`.

For value streams concatenate raw chunks and decode the original full binary envelope; for binary streams keep raw bytes and the final result metadata. Validate id, contiguous sequences and exact totals. A final error discards partial data. Logical size and per-frame size are distinct.

Request: `{method:string, params:operation parameters}`. Response: `{result:value}` or `{error:Error}`. Notify: `{method:string, params:value}`. Backend/terminal/chat opens install observers on that request id. Cancellation retires an observer and unsent data; a begun frame is completed so later frames remain valid.

Envelope syntax and duplicate keys are checked first; disabled operations return permission_denied before per-operation decoding. Allowed requests reject unknown parameters and decoded duplicate keys, including nested objects. Schema fields below are accepted fields; handlers enforce required fields and value relationships. Missing params use the existing empty-params path.

Integers use binary numeric tags, paths are UTF-8 strings, Option<T> encodes null, Vec<T> encodes arrays, tuples encode arrays and unit encodes null. i128 metadata timestamps retain decimal strings. Ordinary byte fields retain base64; binary response chunks do not. Hello.version is the generated schema id interpreted as LE u64; a mismatched body schema returns outdated and requires reinstall.

## Operations

E means the shared Error object: invalid_input, permission_denied, unsupported, unavailable, expired, destination_changed, cancelled, io_failure, busy or deadline when returned by the selected path. Producer inventories below add native/runtime errors; error lists are not promises that every operation emits every code.

Mux references are opaque registration indexes; global entity IDs carry their mux route. With no explicit route core resolves the entity or registered default backend. A chat session selector resolves only a current parent/side Binding; the app never substitutes a PID.

| Operation | Accepted params | Result | Route / producer entry points | Errors |
| --- | --- | --- | --- | --- |
| `hello` | `{ features: string[] (optional, see Features) }` | `Hello JSON object encoded by this handler; with features: also features: string[] (the accepted ones) and the feature operations in ops` | core.hello | E + producer errors |
| `echo` | `JSON` | `the unchanged params JSON value` | core.echo | E + producer errors |
| `permissions.reduce` | `{ capabilities: string[] }` | `null` | core.reduce; claude.revoke (override); codex.revoke (override); nanocodex.revoke (trait default); pi.revoke (trait default) | E + producer errors |
| `backends.list` | `{ mux: u64 }` | `Vec<Backend> without mux; Vec<String> with mux` | core.backends; herdr.backends (override); native.backends (override); tmux.backends (override); herdr.external (override); native.external (override); tmux.external (override) | E + producer errors |
| `backends.open` | `{ mux: u64; key: string }` | `Id, published as backend.opened` | core.open; herdr.open (override); native.open (override); tmux.open (override) | E + producer errors |
| `backends.create` | `{ mux: u64; key: string }` | `Id` | herdr.start (trait default: open); native.start (trait default: open); tmux.start (override: starts a detached session when no server runs); herdr.open (override); native.open (override); tmux.open (override) | E + producer errors |
| `multiplexers.list` | `{ }` | `list of {mux, name, external, claimed, program} for every registered multiplexer` | core.multiplexers | E + producer errors |
| `launches.list` | `{ }` | `Vec<Launch>` | core.launches | E + producer errors |
| `containers.create` | `{ mux: u64; parent: u64 }` | `Id` | herdr.create (override); native.create (override); tmux.create (override) | E + producer errors |
| `terminals.create` | `{ mux: u64; parent: u64; beside: u64; cwd: string or null; launch: u64; command: string or null; size: { rows: u64; columns: u64; cell_width: u64; cell_height: u64 }; rows: u64; columns: u64; cell_width: u64; cell_height: u64; environment: string[]; integration: bool }` | `Id; with size, terminal.created then the terminals.attach stream` | core.create; claude.key (override); codex.key (override); nanocodex.key (override); pi.key (override); herdr.attach (override); native.attach (override); tmux.attach (override); herdr.create (override); native.create (override); tmux.create (override) | E + producer errors |
| `backends.prefix` | `{ mux: u64; node: u64 }` | `Prefix` | herdr.prefix (override); native.prefix (trait default); tmux.prefix (override) | E + producer errors |
| `backends.command` | `{ mux: u64; node: u64; command: string }` | `()` | herdr.command (trait default); native.command (trait default); tmux.command (override) | E + producer errors |
| `entities.rename` | `{ mux: u64; node: u64; name: string }` | `()` | herdr.rename (override); native.rename (override); tmux.rename (override) | E + producer errors |
| `entities.focus` | `{ mux: u64; node: u64 }` | `()` | herdr.focus (override); native.focus (override); tmux.focus (override) | E + producer errors |
| `memberships.move` | `{ mux: u64; node: u64; parent: u64; before: u64 }` | `()` | herdr.move_member (override); native.move_member (trait default: r#move); tmux.move_member (trait default: r#move); herdr.r#move (override); native.r#move (override); tmux.r#move (override) | E + producer errors |
| `memberships.reorder` | `{ mux: u64; node: u64; parent: u64; before: u64 }` | `()` | herdr.r#move (override); native.r#move (override); tmux.r#move (override) | E + producer errors |
| `memberships.place` | `{ mux: u64; node: u64; place: { kind: string; parent: u64; before: u64; label: string; workspace: u64; target: u64; axis: string; ratio: number } }` | `()` | herdr.place (override); native.place (override); tmux.place (override) | E + producer errors |
| `layouts.resize` | `{ mux: u64; node: u64; ratio: number }` | `()` | herdr.split (override); native.split (override); tmux.split (override) | E + producer errors |
| `layouts.zoom` | `{ mux: u64; terminal: u64; zoomed: bool }` | `()` | herdr.zoom (override); native.zoom (override); tmux.zoom (override) | E + producer errors |
| `close.request` | `{ mux: u64; node: u64; policy: string; check: bool }` | `Closed` | core.close; herdr.close (override); native.close (override); tmux.close (override); herdr.idle (override); native.idle (override); tmux.idle (override) | E + producer errors |
| `terminals.attach` | `{ mux: u64; terminal: u64; size: { rows: u64; columns: u64; cell_width: u64; cell_height: u64 }; rows: u64; columns: u64; cell_width: u64; cell_height: u64; takeover: bool }` | `() (notification; observer stays open)` | herdr.attach (override); native.attach (override); tmux.attach (override) | E + producer errors |
| `terminals.observe` | `{ terminal: u64 }` | `notifications until cancellation; only failure ends the request.` | core.observe | E + producer errors |
| `backends.claim` | `{ mux: u64; enabled: bool }` | `null. enabled:false stops claiming that mux's clients in terminals.` | core.claim; herdr.enable (trait default); native.enable (trait default); tmux.enable (override) | E + producer errors |
| `terminals.release` | `{ mux: u64; terminal: u64 }` | `null once the client the probe found in `terminal` left` | core.release; herdr.release (override); native.release (trait default); tmux.release (trait default) | E + producer errors |
| `terminals.input` | `{ mux: u64; terminal: u64; bytes: base64 string or u8[]; subscription: u64 }` | `null; input_window renewal follows committed native input` | core.input; herdr.input (override); native.input (override); tmux.input (override) | E + producer errors |
| `terminals.keys` | `{ terminal: u64; keys: base64 string or u8[]; binding: { session: string; pid: u64; start: u64[] } }` | `null` | core.keys; claude.identify (override); codex.identify (override); nanocodex.identify (override); pi.identify (override); herdr.keys (override); native.keys (override); tmux.keys (override) | E + producer errors |
| `terminals.resize` | `{ mux: u64; terminal: u64; size: { rows: u64; columns: u64; cell_width: u64; cell_height: u64 }; rows: u64; columns: u64; cell_width: u64; cell_height: u64 }` | `()` | herdr.resize (override); native.resize (override); tmux.resize (override) | E + producer errors |
| `terminals.scroll` | `{ mux: u64; terminal: u64; lines: i64; page: bool; column: u64; row: u64; modifiers: u64 }` | `()` | herdr.scroll (override); native.scroll (override); tmux.scroll (override) | E + producer errors |
| `terminals.ready` | `{ mux: u64; terminal: u64 }` | `Screen` | herdr.screen (override); native.screen (override); tmux.screen (override) | E + producer errors |
| `terminals.publish` | `{ mux: u64; terminal: u64; text: string; cursor: { column: u64; row: u64 }; faint_tail: bool }` | `null` | core.publish; herdr.publish (override); native.publish (override); tmux.publish (override) | E + producer errors |
| `terminals.control` | `{ terminal: u64; event: string; bytes: base64 string or u8[] }` | `ControlTarget when claimed; null on data/end` | core.control; herdr.control (trait default); native.control (override); tmux.control (trait default); herdr.claim (trait default); native.claim (trait default); tmux.claim (override); herdr.stream (trait default); native.stream (trait default); tmux.stream (override) | E + producer errors |
| `renderer.request` | `{ mux: u64; terminal: u64; changed: bool }` | `Screen` | herdr.screen (override); native.screen (override); tmux.screen (override) | E + producer errors |
| `terminals.seek` | `{ mux: u64; terminal: u64; offset: u64 }` | `()` | herdr.seek (override); native.seek (override); tmux.seek (trait default) | E + producer errors |
| `terminals.history` | `{ terminal: u64 }` | `none` | no producer | unsupported |
| `clipboard.request` | `{ terminal: u64 }` | `none` | no producer | unsupported |
| `chat.open` | `{ terminal: u64; session: string or null; transcript: { key: string; path: string; session: string; earlier: string or null } }` | `Chat for {terminal, session?}; for {transcript}, chat.archive` | core.chat; claude.key (override); codex.key (override); nanocodex.key (override); pi.key (override); claude.name (override); codex.name (override); nanocodex.name (override); pi.name (override); claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.state (override); codex.state (override); nanocodex.state (override); pi.state (override); claude.commands (override); codex.commands (override); nanocodex.commands (override); pi.commands (override); claude.history (override); codex.history (override); nanocodex.history (override); pi.history (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override) | E + producer errors |
| `chat.state` | `{ terminal: u64; session: string or null }` | `Observed` | core.state; claude.state (override); codex.state (override); nanocodex.state (override); pi.state (override); herdr.check (override); native.check (override); tmux.check (override) | E + producer errors |
| `chat.page` | `{ terminal: u64; session: string or null; earlier: string or null; transcript: { key: string; path: string; session: string; earlier: string or null } }` | `Page for {terminal, session?, earlier?} (a live binding); Archive for {transcript} alone (with terminal: invalid_input)` | core.page; claude.history (override); codex.history (override); nanocodex.history (override); pi.history (override); claude.read (override); codex.read (override); nanocodex.read (override); pi.read (override) | E + producer errors |
| `chat.send` | `{ terminal: u64; session: string or null; text: string; mode: string; command: bool; attachments: string[] (optional, see Attachments) }` | `Sent` | claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override) | E + producer errors |
| `chat.command` | `{ terminal: u64; session: string or null; text: string }` | `Outcome` | core.command; claude.command (unsupported stub); codex.command (override); nanocodex.command (override); pi.command (override); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override) | E + producer errors |
| `chat.stop` | `{ terminal: u64; session: string or null }` | `Sent` | core.stop; claude.stop (override); codex.stop (override); nanocodex.stop (override); pi.stop (override) | E + producer errors |
| `chat.models` | `{ terminal: u64; session: string or null }` | `Menu` | claude.models (override); codex.models (override); nanocodex.models (override); pi.models (override) | E + producer errors |
| `chat.settings` | `{ terminal: u64; session: string or null; model: string }` | `Menu` | claude.efforts (override); codex.efforts (override); nanocodex.efforts (override); pi.efforts (override) | E + producer errors |
| `chat.settings.set` | `{ terminal: u64; session: string or null; model: string; effort: string or null }` | `Sent` | claude.select (override); codex.select (override); nanocodex.select (override); pi.select (override) | E + producer errors |
| `chat.tools` | `{ terminal: u64; session: string or null; record: string }` | `Record` | claude.tool (override); codex.tool (override); nanocodex.tool (override); pi.tool (override) | E + producer errors |
| `interactions.answer` | `{ terminal: u64; session: string or null; interaction: string; answers: JSON }` | `Sent` | core.answer; claude.answer (override); codex.answer (override); nanocodex.answer (override); pi.answer (override); herdr.keys (override); native.keys (override); tmux.keys (override) | E + producer errors |
| `interactions.dismiss` | `{ terminal: u64; session: string or null; interaction: string }` | `Sent` | core.answer; claude.answer (override); codex.answer (override); nanocodex.answer (override); pi.answer (override); herdr.keys (override); native.keys (override); tmux.keys (override) | E + producer errors |
| `queue.list` | `{ terminal: u64; session: string or null }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.add` | `{ terminal: u64; session: string or null; text: string; mode: string; command: bool; attachments: string[] (optional, see Attachments) }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.update` | `{ terminal: u64; session: string or null; item: string; revision: u64; text: string or null; command: bool }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.remove` | `{ terminal: u64; session: string or null; item: string; revision: u64 }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.start` | `{ terminal: u64; session: string or null; item: string; revision: u64; mode: string }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.reorder` | `{ terminal: u64; session: string or null; items: string[] }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.restore` | `{ terminal: u64; session: string or null }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.edit` | `{ terminal: u64; session: string or null; item: string; revision: u64; editing: bool }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `queue.hold` | `{ terminal: u64; session: string or null; held: bool }` | `list Vec<Queued>; add Queued; start Sent; others null` | core.queue; claude.native_queue (trait default); codex.native_queue (override); nanocodex.native_queue (trait default); pi.native_queue (trait default); claude.send (override); codex.send (override); nanocodex.send (override); pi.send (override); claude.queue (override); codex.queue (override); nanocodex.queue (override); pi.queue (override); claude.queue_add (unsupported stub); codex.queue_add (override); nanocodex.queue_add (unsupported stub); pi.queue_add (override); claude.queue_edit (unsupported stub); codex.queue_edit (override); nanocodex.queue_edit (unsupported stub); pi.queue_edit (override); claude.queue_send (unsupported stub); codex.queue_send (override); nanocodex.queue_send (unsupported stub); pi.queue_send (override); claude.queue_order (unsupported stub); codex.queue_order (override); nanocodex.queue_order (unsupported stub); pi.queue_order (override) | E + producer errors |
| `chat.side` | `{ terminal: u64; session: string or null; question: string; read_only: bool }` | `Binding when opening; null when closing` | core.side; claude.side (override); codex.side (override); nanocodex.side (override); pi.side (override); claude.side_close (override); codex.side_close (override); nanocodex.side_close (override); pi.side_close (override) | E + producer errors |
| `chat.side.close` | `{ terminal: u64; session: string or null }` | `Binding when opening; null when closing` | core.side; claude.side (override); codex.side (override); nanocodex.side (override); pi.side (override); claude.side_close (override); codex.side_close (override); nanocodex.side_close (override); pi.side_close (override) | E + producer errors |
| `installation.install` | `{ launch: u64; enabled: bool; terminal: u64 }` | `Install with status off, restart or ready` | core.install; claude.install (override); codex.install (override); nanocodex.install (override); pi.install (override) | E + producer errors |
| `installation.audit` | `{ launch: u64; terminal: u64 }` | `Install with status off, restart or ready` | core.install; claude.install (override); codex.install (override); nanocodex.install (override); pi.install (override) | E + producer errors |
| `files.text` | `{ plugin: string; path: string }` | `String` | files.text (override); stats.text (trait default) | E + producer errors |
| `files.branch` | `{ plugin: string; path: string }` | `Option<String>` | files.branch (override); stats.branch (trait default) | E + producer errors |
| `files.read` | `{ plugin: string; path: string; offset: u64; length: u64; revision: { kind: string; size: u64; device: u64; inode: u64; modified_ns: i128 string or integer; changed_ns: i128 string or integer } or null }` | `binary chunks followed by Metadata` | core.read; files.read (override); stats.read (trait default) | E + producer errors |
| `files.list` | `{ plugin: string; path: string; hidden: bool; limit: u64; git: bool }` | `Listing`: one level of the absolute directory `path` (itself followed if a symlink), with the directory's `device` and `inode`; entries are lstat'ed, never followed, and carry their own `device` and `inode`; a symlink's `target` is its target's kind, null when it cannot be resolved; `kind` `other` is anything not a file, directory or symlink (fifos, sockets, devices); a directory's `size` is 0; `modified_ns` is nanoseconds since the epoch. The listing fails `changed` if the directory is replaced while it is read. Bytewise name order; names that are not UTF-8 come lossily (U+FFFD), never dropped. `hidden` false leaves out dot-names before counting; `limit` 0 or above 10,000 is 10,000, `truncated` when more exist. `git` is accepted and ignored (`mark` null). A relative path is `invalid_request`, a non-directory `not_directory` | files.list (override); stats.list (trait default) | E + producer errors |
| `files.summary` | `{ plugin: string; path: string; limit: u64 }` | `FolderSummary`: totals of everything below the absolute directory `path`, never following a symlink below it; `files` counts regular files, symlinks and other kinds, `bytes` only regular files' sizes, `folders` directories. Visits at most `limit` entries (0 is 100,000; above 1,000,000 is 1,000,000) and walks at most 5 s; either bound sets `truncated`. Subdirectories it cannot read count as folders, their contents are skipped. A relative path is `invalid_request`, a non-directory `not_directory`, an unreadable `path` `permission_denied` | files.summary (override); stats.summary (trait default) | E + producer errors |
| `files.write` | `{ plugin: string; path: string; bytes: raw bytes (tag 11); mode: u64 or null; replace: bool; parent: FileIdentity; replaced: FileIdentity or null }` | `Metadata` of the written file. The whole file in one request, at most 8 MiB (`limit`): a temporary name beside the target, fsync, then an atomic rename. The parent must still have the identity the client listed; `replace` requires `replaced` and replaces only that exact regular-file identity (`changed` otherwise). `replace` false requires `replaced` null, and anything at the path (a symlink, a socket or an unreadable file too) → `exists`; a file system that cannot rename without replacing → `unsupported`; the parent must exist (`not_found`, `not_directory`) and is resolved first; `mode` null is 0644; the umask applies and set-id bits are dropped. A write cannot overlap a Git config scan/command or archive commit (`busy`) | files.write (override); stats.write (trait default) | E + producer errors |
| `files.pack` | `{ plugin: string; transfer: string; base: string; paths: string[]; limit: u64 }` | `Packed`: one worker job writes a POSIX ustar tar with pax extended headers (long `path`/`linkpath`, `size` over 8 GiB, `mtime` with nanoseconds, large `uid`/`gid`) through one zstd level-1 frame with a content checksum to `<system temporary folder>/dispatch-pack-<32 hex>.tar.zst` (0600, created exclusively). Regular files, folders and symlinks (never followed: each folder is opened without following a link, checked to be what its path showed, and listed through its descriptor); sockets, fifos, devices, and files or folders this account cannot read count in `skipped`; a path inside another selected one is stored once. `paths` must lie inside `base` after `.`/`..` (`invalid_request`). `limit` 0 is 250,000 entries and above 1,000,000 is 1,000,000; more, over 64 GiB of regular-file content, or an archive that would consume the temporary volume's last 64 MiB fails with `limit` and removes the archive. A wide directory is bounded while it is read, before all its names are retained. One pack or commit (`files.unpack.close` with `commit`) per helper at a time (`busy`); a pack dropped while it runs stops during the next 128 KiB file window or before its next entry and answers `cancelled`. A file that changes while packed (identity, size or timestamps) → `changed`; a failure writing the archive → `io`. The first pack of a helper removes this account's `dispatch-pack-*` files older than 24 h | files.pack (override); stats.pack (trait default) | E + producer errors |
| `files.pack.drop` | `{ plugin: string; transfer: string }` | `()`: removes the archive, or marks a running pack so its archive is removed when it ends; an unknown transfer is already gone. A client's packs are dropped when it disconnects | files.pack_drop (override); stats.pack_drop (trait default) | E + producer errors |
| `files.unpack.open` | `{ plugin: string; transfer: string; target: string; policy: string; names: string[]; parent: FileIdentity; replacements: { name: string; device: u64; inode: u64 }[] }` | `Transfer`: after verifying `target` still has the listed `parent` identity, creates `<target>/.dispatch-copy-<32 hex>/` (0700, never one that exists: `exists`) holding an empty `archive.tar.zst`; later calls touch it only through descriptors while it and `target` are still those folders. `target` an existing folder (`not_directory`, `not_found`), `policy` `replace`, `keep` or `skip` (`invalid_request`). `names` is the exact set of top-level entry names the client packed (1 to 100,000 single names, none empty, `.`, `..`, with `/` or NUL, or starting `.dispatch-copy-`: `invalid_request`); the commit refuses an archive with any other top-level entry, and `policy` applies only to these names. `replacements` is empty for `keep` and `skip`; for `replace` it identifies the subset of those names that existed when listed. A conflict without a replacement identity, or whose identity changed before it is atomically moved aside, is refused (`changed`) and the existing entry stays in place. One open transfer per helper (`busy`); one still open when its client disconnects is closed without commit, whatever grants the client has left by then (a stdio helper waits up to 30 s for that, and for a running commit until it ends) | files.unpack_open (override); stats.unpack_open (trait default) | E + producer errors |
| `files.unpack.write` | `{ plugin: string; transfer: string; bytes: raw bytes (tag 11) }` | `Progress`: the archive bytes staged so far. At most 8 MiB per call and 128 GiB per transfer; a write that would consume the target volume's last 64 MiB also fails (`limit`). A write while the previous one runs → `busy` | files.unpack_write (override); stats.unpack_write (trait default) | E + producer errors |
| `files.unpack.close` | `{ plugin: string; transfer: string; commit: bool }` | `Unpacked`. `commit` false removes the staging folder and reports zeros. `commit` true extracts into `<staging>/tree/` (files created exclusively, never through a symlink; symlinks made last, as stored; modes under the umask without set-id bits; mtimes restored), refusing a top-level entry not in the open's `names` (the message names the first one), absolute names, `..`, empty names, names or link targets over 4096 bytes, name components over 255, entries under a symlink, duplicates, hard links, devices and fifos, a damaged or cut archive, a frame window over 8 MiB (`invalid_request`), more than 1,000,000 entries, 64 MiB of kept names, 64 GiB of content, or content the target's free space less 64 MiB cannot take, checked before each file is created (`limit`), before anything reaches `target`. A commit while a pack, Git command or file write runs → `busy` (the transfer stays open). An uncommitted close (its client leaving) during the commit stops the extraction before its next entry: the commit answers `cancelled` and nothing moves; once entries are moving in it runs to its end. A `target` renamed or replaced since the open → `io` naming the staging folder, which is left where it is; a file system that cannot rename without replacing → `unsupported`. Then each top-level entry moves in by a no-replace rename; on a conflict `replace` sets the existing one aside, moves the new one in and removes the old; if the new one cannot take the name, the old one goes back, or to `name 2`, `name 3`… when its name was taken meanwhile (`io`, the message names it), or stays in `<staging>/old/` when it cannot move at all (`io` naming that path; the staging folder is then kept), `keep` uses `name 2`, `name 3`… (before a file's extension), `skip` leaves it. The staging folder is removed in every other case. A close sent while an archive write runs waits for it | files.unpack_close (override); stats.unpack_close (trait default) | E + producer errors |
| `files.git` | `{ plugin: string; path: string; args: string[]; limit: u64 }` | `Git`: one read-only git command, run as `git -C <path> --no-pager -c core.quotepath=false -c color.ui=never -c color.diff=never -c core.fsmonitor=false -c diff.external= -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/ -c diff.relative=false -c diff.submodule=short -c diff.autoRefreshIndex=false -c log.showSignature=false -c log.decorate=short -c format.pretty=medium -c gpg.program=/nonexistent -c gpg.openpgp.program=/nonexistent -c gpg.x509.program=/nonexistent -c gpg.ssh.program=/nonexistent -c protocol.allow=never [<filters off>] <args…>` (`diff`, `log` and `show` also get `--no-ext-diff --no-textconv` right after the subcommand, and `status` and `diff` get `--ignore-submodules=dirty`, so a submodule is compared by its commit and git never runs inside its checkout), with an absolute trusted `git`, a child `PATH` containing only its directory, `/usr/bin`, and `/bin`, an absolute `HOME`, `USER`, `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat` and `GIT_NO_LAZY_FETCH=1`; system and global configuration are disabled. Filters off: immediately before every requested command the helper runs (in the same way, not through the list below) `git config -z --name-only --get-regexp '^filter\..*\.(clean\|process\|smudge)$'`, and the command gets `-c filter.<name>.clean= -c filter.<name>.process= -c filter.<name>.required=false` for each filter name found. The query is never cached, because included files and conditional includes can change without the repository's config file changing. Helper file writes and archive commits cannot overlap the query and command (`busy`), so a client cannot swap executable configuration into that window. A filter name holding `=` (which `-c` cannot carry) → `unsupported`, git not run. `path` absolute (`invalid_request`). `args[0]` is `rev-parse`, `status`, `diff`, `log`, `show`, `for-each-ref` or `verify-commit` and every later argument must be on that command's list, else `invalid_request` naming it: rev-parse `--show-toplevel`, `--abbrev-ref`, `--verify`, `--short`, ref names; status `--porcelain=v2`, `--branch`, `-z`, `--untracked-files=normal\|all\|no`, `--ignored`, `--ignored=matching\|traditional\|no`, `--no-renames`; diff `--cached`, `--staged`, `--numstat`, `--name-status`, `--stat`, `-z`, `-U<n>`, `--unified=<n>`, `--no-color`, `--find-renames`, `-M`, `HEAD`, object names (4 to 64 hex digits); log `-n <n>`, `-n<n>`, `--max-count=<n>` (n at most 1,000), `--skip=<n>`, `--format=…`, `--pretty=…` (here and for show: empty, holding a `%`, or starting `format:` or `tformat:`; a bare word is a `pretty.<name>` alias from the configuration), `--date=unix\|iso-strict\|raw`, `--all`, `--branches`, `--remotes`, `--tags`, `--grep=…`, `--author=…`, `--regexp-ignore-case`, `-i`, `--fixed-strings`, `-F`, `--topo-order`, `--date-order`, `--first-parent`, `--no-merges`, `--decorate=full\|short\|no`, ref names; show `--numstat`, `--name-status`, `--stat`, `-z`, `-U<n>`, `--unified=<n>`, `--no-color`, `--find-renames`, `-M`, `--format=…`, `--pretty=…`, `-s`, `--no-patch`, object names; for-each-ref `--format=…`, `--sort=<field>` (never a `signature…` field), `--count=<n>`, `--points-at=<object name>`, `refs/heads`, `refs/remotes`, `refs/tags`; verify-commit `--raw`, object names. verify-commit is the one signature check: before it the helper reads `gpg.ssh.allowedSignersFile` from the user's own `~/.gitconfig`, then `~/.config/git/config` (`git config --file <file> --includes --path --get`, the first absolute answer), and the command gets, after the settings above, `-c gpg.program=<gpg> -c gpg.openpgp.program=<gpg> -c gpg.ssh.program=<ssh-keygen> -c gpg.x509.program=/nonexistent -c gpg.ssh.allowedSignersFile=<that file, else /dev/null> -c gpg.minTrustLevel=undefined`, where `gpg` and `ssh-keygen` are absolute trusted paths found in the helper's `PATH` and then `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/local/MacGPG2/bin`, `/usr/bin`, `/bin` (`/nonexistent` when none is), so they run as the user with the user's `HOME` (keyring) and never with a program or signers file the repository names; every other command keeps every signing program at `/nonexistent`. status, diff, log and show take `--` and then paths relative to `path`, none absolute and none with a `..` component (`diff` outside a repository, or naming a path outside the work tree, is an implicit `--no-index`). A ref name is one `git check-ref-format` allows (never starting with `-`; no `..`, `@{`, `~`, `^`, `:`, so no revision ranges). A format may not hold `%G…` (also `%+G…`, `%-G…`, `% G…`) or `%(signature…)` / `%(*signature…)` (signature checks run gpg); ref formats may peel tags (`%(*objectname)`, `%(objecttype)`). Records should end with `%x00`: `git commit` refuses a NUL in a message, while a message may hold 0x1E or 0x1F. The run is killed with its process group after 20 s: `status` -1, `output` "git took longer than 20 s". `limit` 0 is 2 MiB, above 8 MiB is 8 MiB; past it git is stopped, `truncated` is set, `status` is 0, and `output` ends after the last record end within the bound (NUL with `-z` or when a format holds `%x00`, else 0x1E when a format holds `%x1e`, else a newline). `output` is stdout when `status` is 0, else stderr (its first 64 KiB), lossy UTF-8 either way; a git ended by a signal is -1. Outside a repository git itself answers: 128 and its message for `rev-parse`, `status`, `log`, `show` and `for-each-ref`; `diff` without paths 129 and its usage, and `diff -- <a> <b>` compares the two files in the folder (`--no-index`). Commands run on two helper workers of their own, so slow ones never hold other jobs; a command waiting for one starts its 20 s when it runs; more than 16 waiting or running → `busy`. No `git` on the sanitized PATH → `unsupported` | files.git (override); stats.git (trait default) | E + producer errors |
| `stats.sample` | `{ plugin: string }` | `Sample` | files.sample (trait default); stats.sample (override) | E + producer errors |
| `stats.processes` | `{ plugin: string }` | `(Vec<Row>, bool)` | files.processes (trait default); stats.processes (override) | E + producer errors |
| `stats.disks` | `{ plugin: string }` | `Vec<Disk>` | files.disks (trait default); stats.disks (override) | E + producer errors |
| `plugins.reset` | `{ plugin: string; topics: string[] }` | `()` | files.reset (trait default); stats.reset (override) | E + producer errors |

### Held queues

`queue.*` on a harness without a native queue (Claude Code, Pi) address the host's queue store: one file per conversation (`~/.dispatch/state/queue/`, keyed by harness and session), shared by every helper of the account. A file is format 1; one whose items have attachments is format 2, which helpers before chat.attachments leave alone (they could not send it); format 1 files read as before. Ids (`q-` and 16 hex digits) and revisions are the store's, the same for every helper and client of the host, and outlive the helper. `queue.add` answers once the item is in the file; `chat.open` announces a non-empty stored queue (`chat.queue`) after the chat's readiness. The helper bound to the agent sends the head item once its claim is in the file; an item claimed by a helper that is gone becomes `uncertain`. A conversation without a session (a provisional binding) keeps its queue in the helper's memory only, as before. Errors: `storage` (the file could not be read or written, or is not private), `busy` (the item is being sent).

### Attachments

A client of `chat.attachments` (Features) uploads a file's bytes with `attachments.put` and names the stored copy in `chat.send` / `queue.add` `attachments`. Copies live at `~/.dispatch/attachments/<32 lowercase hex>/<name>` (`DISPATCH_TEST_ROOT` instead of `HOME` like the rest of `~/.dispatch`), `<name>` the upload's last path component with every run of characters other than `[A-Za-z0-9._-]` (spaces, quotes, shell metacharacters, bidi and line separators) one `_`, leading dots dropped, the extension kept, at most 255 bytes, `attachment` when empty (agents get it as a raw path; the reply's `name` is what the app shows): the folder is new for each upload (0700, created exclusively, never an existing one), the file 0600 and created exclusively, every level opened without following a symlink and checked to be this account's and private (native jobs `attachment.put`, `attachment.read`, and `attachment.clock` for the delivery index, system/attachment.rs). Folders whose newest time is older than a day are removed at helper start (the storage collection), except those a queue file (`state/queue/*.q`) names; nothing is removed at send time.

- `attachments` on `chat.send` / `queue.add`: at most 10 paths, each exactly `<attachments root>/<32 hex>/<name>` of an existing copy (read before anything is typed; an image by its first bytes), else `invalid_input` naming it. With attachments `text` may be empty; `command: true` or a side conversation's `session` → `invalid_input`. An absent or empty list is the operation as before.
- Delivery: Claude Code gets each image path as its own bracketed paste and the walk waits for its `[Image #n]` placeholder: a path Claude keeps as text (it read no image there) stays in the composer as that image's path and is never pasted again; one that shows nothing for five settled screens (about five seconds) goes as a path line with the text; anything else in the composer, once the screen settled, fails the send before Enter. Then the text, then Enter. Codex: the main TUI gets each image path pasted alone (single-quoted when it has other characters), then the text, then Enter; native input (owned sides, `thread/queue/add`, a queued steer) is `[{type:"text",text,text_elements:[]}, {type:"localImage",path}...]`. Pi, Nanocodex, and every file that is not an image: the text fallback, `text + "\n\n" + one path per line` (only the paths without text). Where a text that starts like a command is fenced (Claude Code, the Codex TUI, when no placeholder precedes it), only the typed text is: the path lines follow the closing fence, and an empty text is never fenced.
- Queued: a stored item keeps its attachments; its preview is `Text(text)` (none when the text is empty) then `{kind:"attachment", type:"image"|"file"}` each; it is not editable (`queue.update` with text → `invalid_input`); `queue.start` and the drain deliver it like `chat.send`. Codex rows preview `type: "localImage"`.
- History, for a client of `chat.attachments` only: a user record's `text` is what the user typed (or its fence) — the leading `[Image #n]` placeholders (at most one per image the agent attached) and stored paths, and the trailing fallback path lines after an empty line, removed; only paths under this helper's own attachments root count — and `blocks` gain `{kind:"image"|"file", path: string|null, text: name|null}` per attachment: the agent's images in order, then the paths. Codex local images and fallback lines carry their paths; Claude images (its transcript keeps only the data) get theirs from the conversation's delivery index (`~/.dispatch/state/attachments/<hash>.idx`, 0600, format 2, newest 200 sends: digest of the trimmed text, the image paths, and the Unix milliseconds the send started; an entry is added in memory when a send starts, kept and written once the send may have reached the agent, dropped for a refusal). A record takes the latest send of its text and image count that started before it (within 10 minutes): sends of a conversation follow one another, so repeated texts (an image alone has none) each get their own, whatever page they come in. Without a match `path` and `text` are null. The index file is read only for such a client whose page has an unnamed image. Every other client gets user records (`chat.page`, `chat.open`, `chat.records`, `chat.archive`) byte for byte as before: `[Image]` lines and placeholders in `text`, no attachment blocks; `attachments` on its `chat.send` / `queue.add` → `invalid_input`.

## Features

Opt-in behaviour a client names in `hello.params.features` (helper/core/src/dispatch/features.rs; hand-maintained, not generated). Unknown names are dropped; the reply's `features` lists the accepted ones. A client that names none gets exactly the pre-feature replies. The Mac names `terminals.coalesce`; its replay compares a hello without its features, so recordings made before it named any (pre-feature replies) still replay. Features change neither the wire schema id nor any output for other clients of the same helper.

| Feature | Effect for that client |
| --- | --- |
| (any feature) | The hello reply's `account` may add `login_home`: `$HOME` as the user's login environment sees it (the login shell's, which a `--remote --stdio` helper probes with its PATH; else the helper's own environment), only when it is an absolute path other than the passwd `home`. |
| `stdio.liveness` | Only for a `--remote --stdio` helper without the login wrapper (otherwise dropped from the accepted list): when this client has sent nothing for 45 s, the helper ends as if its stdin had closed, so a connection whose close never arrives (NAT, port forward) does not keep a helper serving the same phone. The client sends `echo` (its latency ping) at least every 15 s. `DISPATCH_STDIO_LIVENESS_SECONDS` (2 to 600) overrides the limit for tests. |
| `terminals.integration` | `terminals.create` of a default shell takes `integration` (default true). With it the helper writes the shell's startup files (zsh ZDOTDIR wrapper, bash ENV rcfile) into a private directory before the spawn, one `mkdir` and one `write` job each through the disk workers. `false` writes none: the client's `environment` carries the integration (the Mac app sends Ghostty's `ZDOTDIR` or `ENV` and its launch functions, so those files were never read), the command and fish's inline functions stay the same, and the shell is spawned at once. SSH login shells and remote helpers keep the default. |
| `launch.names` | `terminals.create` with `launch` names the new tmux window (`new-window -n`, so tmux does not rename it after the launcher) or herdr tab (`tab.rename`) after the agent: `claude`, `codex`, `pi`. Splits keep their window's name. The name travels to the multiplexer as `DISPATCH_LAUNCH_NAME` on the launch command and never reaches the program's environment. |
| `terminals.coalesce` | `terminal.output` notifications of one stream and terminal are held for at most 4 ms and joined up to 60 000 bytes (inline frames); any other message for that client releases held output first, so order is kept. 50 MB of `yes` through a tmux window on macOS: 2.86 M frames and 270 MB on the wire without it, 6 085 frames and 79 MB with it. |
| `multiplexers.versions` | `multiplexers.list` rows also carry `installed` (bool; null for a kind with no program of its own, e.g. native), `version` (the first line's last word of `tmux -V` / `herdr --version`, run with the helper's resolved PATH, 3 s limit) `paste_state` (tmux only: whether it reports bracketed-paste state, 3.7 and later) and `running` (whether its server runs for this user, probed without starting one: tmux `-N list-sessions` on the default socket, `herdr status server` on the configured socket; false when not installed, null when unknown). `backends.open` for herdr starts a server, so a client checks `running` first. |
| `terminals.activity` | Operation `terminals.activity {}` (no params; any → `invalid_input`) → `[{node, key, kind, time_ms}]` by node: when the server last saw activity in a published node (not detached), as its multiplexer reports it; `key` is the node's topology key (node ids are per connection), `kind` its topology kind, `time_ms` Unix milliseconds. tmux: one row per window (`kind` `tab`), `#{window_activity}` (the last output in any of its panes, whole seconds), read by one `list-windows -a` per opened backend through the helper's existing control client; tmux keeps no per-pane time. herdr 0.9.5 and native report no times (no rows). A multiplexer that cannot answer (its client just ended) adds no rows; the reply never fails for it. Each multiplexer's grant applies (`tmux.pane`, `herdr.*`); the operation itself needs `backend.register`. Nothing is asked of tmux for other clients. |
| `projects.recent` | Operation `projects.recent {limit?: 1..200, default 30}` → `[{path, time_ms, agents, exists}]`, newest first: folders named by the agents' own session stores under `CLAUDE_CONFIG_DIR` (else `~/.claude`) `projects/*`, `CODEX_HOME` (else `~/.codex`) `sessions/Y/M/D`, `PI_CODING_AGENT_DIR` (else `~/.pi/agent`) `sessions/*`; reads the first lines of at most 400 session files per agent (native job `projects.recent`); grant `agent.inspect`. |
| `chat.list` | Operation `chat.list {}` → one row per agent-bound terminal, by terminal id: `{terminal, session, binding, key, label, name, cwd, busy, attention, activity, title, state_error, preview, time_ms, history_error, waiting}`; `preview` is the newest assistant text (at most 280 characters, then …), `time_ms` the newest record time, `waiting` whether an approval or blocking question of the conversation is open (published and not yet answered or closed). Same harness reads as `chat.state` and `chat.page`; grant `agent.inspect`. |
| `chat.attachments` | Operations `attachments.put {name: string, bytes: bytes}` → `{path, name, kind: "image"\|"file", size}` (grant `agent.submit`; at most 8 MiB, empty → `invalid_input`; `path` ends in the stored name (Attachments); `name` is the upload's last path component without control, bidi and line separator characters, at most 255 bytes (the stored name when nothing is left), for the app to show; `kind` `image` when the bytes start with a PNG, JPEG, GIF or WebP signature and the name has the matching extension, `.png .jpg .jpeg .gif .webp` in any case) and `attachments.read {path}` → `{bytes, size}` (grant `agent.inspect`; a path not of the stored shape, a symlink, another account's or a shared file → `invalid_request`; gone → `not_found`). `attachments` on `chat.send` and `queue.add` (Attachments; from another client `invalid_input`); user records with their attachments as blocks in this client's history pages and updates (Attachments), the delivery index read for them. |
| `memberships.append` | `memberships.move` of a herdr tab within its workspace without `before` puts it after the workspace's last tab (`tab.move` `insert_index` one past the last tab: herdr inserts before the tab at that index, counting the moved tab where it is). Other clients keep the last tab's index, which puts the tab before the last tab, as the Mac's recordings expect. `memberships.reorder`, tmux, native and herdr workspaces are unchanged. |
| `interaction.options` | `interaction.opened` carries every choice the producer offers. Claude approvals add choice id `Session` (label "This session", detail names the rules) after Allow, Deny, Terminal when Claude's `permission_suggestions` hold allow rules; `interactions.answer` with its index allows and applies those rules with destination `session` (until Claude exits). Codex 0.162 refuses `updatedPermissions` in PermissionRequest hooks, so Codex offers no session choice. Other clients never see `Session` choices. |

## Producer error inventories

These are literal codes in each producer; native error codes/details and platform IO failures can also be passed through.

| Producer | Literal codes |
| --- | --- |
| harnesses/claude | `changed`, `exited`, `expired`, `hook`, `identity`, `input`, `invalid`, `io`, `json`, `limit`, `menu`, `missing`, `question`, `session`, `settings`, `shape`, `side`, `state`, `transcript`, `unsupported` |
| harnesses/codex | `busy`, `capacity`, `changed`, `channel`, `closed`, `command_arguments`, `endpoint`, `environment`, `goal`, `history`, `hook`, `identity`, `input`, `io`, `json`, `menu`, `models`, `native`, `not_found`, `process`, `question`, `queue`, `removed`, `side`, `socket`, `stale`, `thread`, `timeout`, `tool`, `turn`, `unsupported` |
| harnesses/nanocodex | `busy`, `changed`, `closed`, `command_arguments`, `deadline`, `history`, `io`, `native`, `not_found`, `not_sent`, `protocol`, `terminal`, `unavailable`, `unknown`, `unsupported` |
| harnesses/pi | `attention`, `changed`, `command_arguments`, `deadline`, `history`, `install`, `io`, `may_have_sent`, `menu`, `models`, `native`, `not_found`, `not_sent`, `setup`, `side`, `state`, `unsupported` |
| multiplexers/herdr | `busy`, `closed`, `expired`, `herdr`, `raw_input`, `uncertain` |
| multiplexers/native | `agent_changed`, `backend_unavailable`, `busy`, `control_process_unavailable`, `destination_unavailable`, `expired`, `foreground_missing`, `input_closed`, `input_unavailable`, `io_failure`, `layout_app_owned`, `process_identity_invalid`, `process_identity_missing`, `process_missing`, `scrollback_app_owned`, `uncertain` |
| multiplexers/tmux | `expired`, `invalidFrame`, `malformed`, `scrollback_app_owned`, `stale`, `tmux`, `uncertain`, `unsupported` |
| plugins/files | `busy`, `cancelled`, `changed`, `exists`, `internal`, `invalid_request`, `limit`, `not_directory`, `unsupported` |
| plugins/stats | `stats_busy`, `stats_invalid`, `stats_output` |

## Updates

The UI adapter resolves Binding -> terminal/session before publication and filters recipients by the open observer. Terminal Output/Exit follow terminal observers; chat updates follow the exact session. Client is an internal verified-client observation that schedules mux probe, not a wire payload.

| API variant | API payload | Wire notification | Wire fields |
| --- | --- | --- | --- |
| `Topology` | `Topology { backend: Id, nodes: Vec<Node>, layouts: Vec<Layout>, focus: Option<Id>, }` | `topology` | backend, nodes, layouts |
| `Output` | `Output { terminal: Id, bytes: Vec<u8>, }` | `internal only` | not published |
| `Stderr` | `Stderr { terminal: Id, bytes: Vec<u8>, }` | `internal only` | terminal, bytes |
| `Exit` | `Exit { terminal: Id, status: Option<i32>, }` | `terminal.exit` | terminal.exit, terminal, status |
| `Agent` | `Agent { terminal: Id, summary: Summary, }` | `agent.changed` | agent.changed, terminal, summary |
| `Client` | `Client { terminal: Id, process: Process, }` | `internal only` | not published |
| `Candidate` | `Candidate { terminal: Id, process: Option<Process>, }` | `internal only` | not published |
| `Records` | `Records { binding: Binding, records: Vec<Record>, }` | `chat.records` | chat.records, terminal, session, records |
| `History` | `History { binding: Binding, page: Page, }` | `chat.records` | chat.records, terminal, session, records, replace, earlier |
| `State` | `State { binding: Binding, state: State, }` | `chat.state` | chat.state, terminal, session, state |
| `Queue` | `Queue { binding: Binding, items: Vec<Queued>, error: Option<Error>, }` | `chat.queue` | terminal, session, items, error, chat.queue |
| `Interaction` | `Interaction { binding: Binding, interaction: Interaction, }` | `interaction.opened` | interaction.opened, terminal, session, interaction |
| `Clipboard` | `Clipboard { bytes: Vec<u8>, }` | `clipboard` | clipboard, bytes |
| `Scroll` | `Scroll { terminal: Id, offset: u64, max: u64, viewport: u32, }` | `terminal.scroll` | terminal.scroll, terminal, offset, max, viewport |

## Encoded records

Fields here come from the production encoder and API definitions. Nullable fields are emitted as null; fields are not normalized by the app.

| Type | Fields / API types |
| --- | --- |
| `Metadata` | `kind: FileKind`; `size: u64`; `device: u64`; `inode: u64`; `modified_ns: i128`; `changed_ns: i128` |
| `Grid` | `columns: u16`; `rows: u16` |
| `Screen` | `text: String`; `cursor: (u32, u32)`; `faint_tail: bool` |
| `Summary` | `waiting: Option<String>`; `busy: bool`; `activity: Option<String>`; `revision: u64` |
| `InputWindow` | `terminal: Id`; `credit: u32` |
| `Record` | `id: String`; `turn: Option<String>`; `kind: RecordKind`; `text: String`; `title: String`; `output: String`; `blocks: Vec<Block>`; `completed: bool`; `exit_code: Option<i32>`; `patch: Option<String>`; `documents: Vec<Document>`; `tool: Option<Tool>`; `inline_reasoning: bool`; `time_ms: Option<i64>`; `position: Option<FilePosition>` |
| `Tool` | `kind: String`; `title: String`; `symbol: String`; `summary: String`; `input: String`; `language: String`; `directory: Option<PathBuf>`; `failed: bool`; `read: Option<ToolRead>`; `search: Option<ToolSearch>`; `shell: Option<ToolShell>`; `children: Vec<Record>`; `orchestration: bool`; `patch: bool`; `confirmed_result: Option<String>`; `additions: u64`; `deletions: u64` |
| `ToolRead` | `path: String`; `selection: ReadSelection`; `source: bool` |
| `ToolSearch` | `pattern: String`; `paths: Vec<String>`; `filters: Vec<String>`; `standard_input: bool` |
| `ToolShell` | `command: String`; `kind: String`; `swift_tests: bool` |
| `Document` | `path: String`; `kind: Option<DocumentKind>`; `diff: String`; `workdir: Option<PathBuf>` |
| `Error` | `code: &'static str`; `message: String` |
| `Page` | `records: Vec<Record>`; `earlier: Option<String>` |
| `Snapshot` | `generation: String`; `session: Option<String>`; `version: Option<String>`; `initial: bool`; `caught_up: bool`; `invalidated: bool`; `awaiting_creation: bool`; `file: Option<FileIdentity>` |
| `FileIdentity` | `device: u64`; `inode: u64` |
| `FilePosition` | `file: FileIdentity`; `offset: u64` |
| `State` | `busy: bool`; `activity: Option<String>`; `model: Option<String>`; `model_label: Option<String>`; `effort: Option<String>`; `usage: Option<String>`; `goal: Option<String>`; `draft: Option<String>`; `attention: Option<String>`; `leaf: Option<String>`; `dialog: Option<String>`; `title: Option<String>`; `version: Option<String>`; `pending: bool`; `compacting: bool`; `service_tier: Option<String>`; `mode: Option<String>`; `agents: Vec<String>` |
| `Choice` | `id: String`; `label: String`; `detail: Option<String>` |
| `Prefix` | `key: Option<String>`; `repeat_ms: Option<u64>`; `bindings: Vec<PrefixBinding>` |
| `PrefixBinding` | `key: String`; `command: String`; `repeat: bool` |
| `Question` | `id: String`; `header: String`; `text: String`; `secret: bool`; `options: Vec<Choice>`; `multiple: bool`; `custom: bool`; `blocks: Vec<Block>` |
| `Interaction` | `id: String`; `key: Option<String>`; `approval: bool`; `blocking: bool`; `questions: Vec<Question>`; `turn: Option<String>`; `record: Option<String>` |
| `Menu` | `choices: Vec<Choice>`; `current: Option<String>`; `default: Option<String>` |
| `Queued` | `id: String`; `mode: Mode`; `revision: u64`; `preview: Vec<Preview>`; `editable: bool`; `editing: bool`; `paused: Option<Pause>`; `error: Option<Error>` |
| `Sample` | `boot: String`; `cpu_present: bool`; `cpu: Option<f64>`; `cores: Vec<f64>`; `load: Vec<f64>`; `memory: Option<(u64, u64)>`; `swap: Option<(u64, u64)>`; `received_per_second: Option<f64>`; `sent_per_second: Option<f64>`; `uptime: f64` |
| `Row` | `pid: u32`; `start: Option<String>`; `name: String`; `cpu: Option<f64>`; `rss: Option<u64>` |
| `Disk` | `identity: u64`; `paths: Vec<PathBuf>`; `total: u64`; `available: u64` |
| `Entry` | `name: String`; `kind: FileKind`; `size: u64`; `modified_ns: i128`; `target: Option<FileKind>`; `mark: Option<String>` |
| `Listing` | `path: String`; `entries: Vec<Entry>`; `truncated: bool` |
| `FolderSummary` | `files: u64`; `folders: u64`; `bytes: u64`; `truncated: bool` |
| `Packed` | `archive: String`; `entries: u64`; `files: u64`; `folders: u64`; `bytes: u64`; `size: u64`; `skipped: u64` |
| `Transfer` | `transfer: String`; `staging: String` |
| `Progress` | `bytes: u64` |
| `Unpacked` | `entries: u64`; `bytes: u64`; `replaced: u64`; `kept: u64`; `skipped: u64` |
| `Git` | `status: i64`; `output: String`; `truncated: bool` |
| `Install` | `edits: Vec<Edit>`; `restart: bool`; `installed: bool`; `optional: bool`; `reload: Option<String>`; `trust: Option<String>` |
| `Layout` | `container: Id`; `full: Split`; `visible: Split`; `focus: Option<Id>` |

Field contracts from the API:

- `Record.inline_reasoning`: Producer-defined presentation; never inferred from an ID prefix by the app.
- `Record.position`: Transcript source position; prompt acknowledgement compares this independently of clocks.
- `ToolShell.kind`: Common display category, such as build, test, search, or wait.
- `Snapshot.session`: Native session id and harness version from the transcript header.
- `State.model_label`: Display label for `model` from the producer's verified catalog or menu; None shows the model id. c1654cc ChatModelPicker.swift:74-115.
- `State.usage`: c1654cc ChatUsage JSON: {info:{total_token_usage:{input_tokens,output_tokens},last_token_usage:{total_tokens},model_context_window,total_cost_usd}}; missing counters remain absent.
- `State.leaf`: Selected native transcript entry; c1654cc ChatCoordinator.swift:846.
- `State.dialog`: Native dialog kind when Terminal is waiting; c1654cc PiBridge.swift:49-60.
- `State.title`: Native session title; c1654cc ChatCoordinator.swift:888 (session.title = state.name).
- `State.version`: Running agent's native version (Claude registry, Codex CLI); the app keeps it per session, c1654cc ChatCoordinator.swift:1106,1234; old claude.rs:207.
- `State.pending`: The native side holds accepted input it has not consumed yet (steer/follow-up).
- `State.compacting`: Native context compaction is running (Claude PreCompact until PostCompact); the app keeps its own caption. c1654cc ChatCoordinator.swift:795-796.
- `State.service_tier`: Native service tier (Codex /fast); c1654cc ChatCommands.swift:418-458 (serviceTier).
- `State.mode`: Native collaboration mode, including the acknowledged /plan setting.
- `State.agents`: Running subagents' types, oldest first (Claude and Codex SubagentStart until SubagentStop). They can outlive the turn that started them (background agents).
- `Question.blocks`: Complete presentation, e.g. an approval operation as Block::Code with language json; c1654cc ChatSideConversation.swift:79-85.
- `Interaction.key`: Stable approval metadata identity when separate requests need distinct decision ids. Absent when id already identifies both the metadata and the decision.
- `Interaction.approval`: For approval interactions, normalized option0 allows and option1 denies. Additional choices and ordinary question indices keep their producer meanings.
- `Interaction.turn`: The turn and tool record this interaction belongs to (the ids of Record.turn and Record.id); None when the producer cannot tell. Old app: approval turnID and tool item.
- `Menu.default`: The native catalog's default choice, distinct from the current selection.
- `Queued.editing`: Editing holds this item until commit/cancel; native uploads must skip it.
- `Sample.boot`: Native boot identity; visible CPU fallback is retained only within this boot.
- `Sample.cpu_present`: Native counters were present, even when no interval delta exists.
- `Entry.target`: A symlink's target kind; None when dangling or not a symlink.
- `Entry.mark`: Reserved for git marks ("M", "A", "U", "D", "R", "!"); None until files.list honors `git`.
- `FolderSummary.bytes`: Regular-file sizes only.
- `Packed.skipped`: Sockets, fifos and devices left out, and files or folders this account cannot read (a folder counts once, its content unseen).
- `Install.installed`: Hooks/extension are currently installed; c1654cc ChatCoordinator.swift:218-220.
- `Install.optional`: Installation is optional and removable; c1654cc SettingsView.swift:417,429-431.
- `Install.reload`: Native command that applies an installation without restart; c1654cc SettingsView.swift:415.
- `Install.trust`: Native command to trust the installation after restart; c1654cc SettingsView.swift:414.

Enums and non-record encoders (generated from the actual codec):

```rust
tags!(FileKind {File => "file", Directory => "directory", Symlink => "symlink", Other => "other"});
```

```rust
tags!(Kind {Workspace => "workspace", Tab => "tab", Terminal => "terminal"});
```

```rust
tags!(Mode {Prompt => "prompt", Steer => "steer", FollowUp => "follow_up"});
```

```rust
tags!(Pause {Stopped => "stopped", Uncertain => "uncertain", DestinationChanged => "destination_changed", NeedsEdit => "needs_edit"});
```

```rust
tags!(RecordKind {TurnStarted => "turn_started", TurnEnded => "turn_ended", User => "user", Assistant => "assistant", Reasoning => "reasoning", Tool => "tool", Notice => "notice", Output => "output"});
```

```rust
tags!(DocumentKind {Add => "add", Delete => "delete", Update => "update"});
```

```rust
impl Encode for Binding {
    fn encode(&self, out: &mut Vec<u8>) {
        object(
            out,
            &[
                ("session", &self.session),
                ("transcript", &self.transcript),
                ("pid", &u64::from(self.process.pid)),
                ("start", &self.process.start.to_vec()),
                ("executable", &self.process.executable),
            ],
        );
    }
}
```

```rust
impl Encode for Node {
    fn encode(&self, out: &mut Vec<u8>) {
        let agent = self.agent.as_ref().map(|(_, binding)| binding.clone());
        object(
            out,
            &[
                ("id", &self.id),
                ("parent", &self.parent),
                ("key", &self.key),
                ("kind", &self.kind),
                ("name", &self.name),
                ("renamed", &self.renamed),
                ("cwd", &self.cwd),
                ("size", &self.size),
                ("agent", &agent),
                ("tty", &self.tty),
                ("detached", &self.detached),
            ],
        );
    }
}
```

```rust
impl Encode for Preview {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Text(text) => object(out, &[("kind", &"text"), ("text", text)]),
            Self::Attachment(kind) => object(out, &[("kind", &"attachment"), ("type", kind)]),
        }
    }
}
```

```rust
impl Encode for ReadSelection {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::All => object(out, &[("kind", &"all")]),
            Self::Lines { start, end } => {
                object(out, &[("kind", &"lines"), ("start", start), ("end", end)])
            }
            Self::First(count) | Self::Last(count) => object(
                out,
                &[
                    (
                        "kind",
                        &if matches!(self, Self::First(_)) {
                            "first"
                        } else {
                            "last"
                        },
                    ),
                    ("count", count),
                ],
            ),
        }
    }
}
```

```rust
impl Encode for Block {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Code { language, text } => object(
                out,
                &[("kind", &"code"), ("language", language), ("text", text)],
            ),
            Self::Markdown(text) => object(out, &[("kind", &"markdown"), ("text", text)]),
            Self::Attachment(path) => object(out, &[("kind", &"attachment"), ("path", path)]),
            Self::File(shown) => object(
                out,
                &[("kind", &if shown.image { "image" } else { "file" }), ("path", &shown.path), ("text", &shown.name)],
            ),
        }
    }
}
```

```rust
impl Encode for Split {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Leaf(id) => object(out, &[("terminal", id)]),
            Self::Branch { id, axis, children } => {
                let axis = match axis {
                    Axis::Rows => "rows",
                    Axis::Columns => "columns",
                };
                let children: Vec<_> = children
                    .iter()
                    .map(|(weight, split)| Child {
                        weight: *weight,
                        split,
                    })
                    .collect();
                object(out, &[("id", id), ("axis", &axis), ("children", &children)]);
            }
        }
    }
}
```

```rust
impl Encode for Child<'_> {
    fn encode(&self, out: &mut Vec<u8>) {
        object(out, &[("weight", &self.weight), ("split", self.split)]);
    }
}
```

```rust
impl Encode for Sent {
    fn encode(&self, out: &mut Vec<u8>) {
        match self {
            Self::Native {
                written,
                may_have_sent,
                reason,
            } => object(
                out,
                &[
                    ("written", written),
                    ("may_have_sent", may_have_sent),
                    ("reason", reason),
                ],
            ),
            Self::Keys(_) => unreachable!("terminal keys must be delivered by the multiplexer"),
        }
    }
}
```

```rust
impl Encode for Edit {
    fn encode(&self, out: &mut Vec<u8>) {
        let before = self.before.as_ref().map(|v| base64(v));
        let after = self.after.as_ref().map(|v| base64(v));
        object(
            out,
            &[
                ("path", &self.path),
                ("before", &before),
                ("after", &after),
                ("backup", &self.backup),
            ],
        );
    }
}
```

## Compound results

These handlers combine API values or catalog/observation metadata. Their result annotations and encoders are the source for the operation rows above.

### Backend

```rust
struct Backend {
    mux: u64,
    key: String,
    label: String,
    default: bool,
                                                                                           
    external: bool,
}
```

### Launch

```rust
struct Launch {
    launch: u64,
    key: String,
    label: String,
                                                                                                
    program: Option<String>,
}
```

### Closed

```rust
struct Closed {
    closed: bool,
    confirmation: bool,
}
```

### Observed

```rust
struct Observed {
    binding: Binding,
    state: State,
}
```

### Chat

```rust
struct Chat {
    terminal: Id,
    binding: Binding,
    label: String,
    key: String,
    commands: Vec<String>,
    native_queue: bool,
    state: Option<State>,
    state_error: Option<Error>,
    page: Page,
    history_error: Option<Error>,
    pending: bool,
}
```

### ControlTarget

```rust
struct ControlTarget {
    pub key: String,
    pub id: Id,
}
```

```rust
impl Encode for Observed {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(out, &[("binding", &self.binding), ("state", &self.state)]);
    }
}
```

```rust
impl Encode for Archive {
    fn encode(&self, out: &mut Vec<u8>) {
        crate::encode::object(
            out,
            &[
                ("records", &self.page.records),
                ("earlier", &self.page.earlier),
                ("snapshot", &self.snapshot),
                ("state", &self.state),
            ],
        );
    }
}
```

```rust
impl Encode for Chat {
    fn encode(&self, out: &mut Vec<u8>) {
        let mut capabilities = Vec::new();
        if self.state.is_some() {
            capabilities.push("state");
        }
        if !self.pending && self.history_error.is_none() {
            capabilities.push("history");
        }
        if !self.commands.is_empty() {
            capabilities.push("commands");
        }
        crate::encode::object(
            out,
            &[
                ("terminal", &self.terminal),
                ("binding", &self.binding),
                ("session", &self.binding.session),
                ("label", &self.label),
                ("key", &self.key),
                ("commands", &self.commands),
                ("native_queue", &self.native_queue),
                ("state", &self.state),
                ("state_error", &self.state_error),
                ("records", &self.page.records),
                ("earlier", &self.page.earlier),
                ("history_error", &self.history_error),
                ("history_pending", &self.pending),
                ("capabilities", &capabilities),
            ],
        );
    }
}
```

### Hello

```rust
fn hello(&mut self, _p: Value<'_>) -> Result<(), Error> {

        if !self.helper.answerable() {
            if self.helper.identity.is_none() && self.helper.identity_job.is_none() {
                let job = self.io.submit(Job::Native {
                    name: "host.identity",
                    input: b"{}".to_vec(),
                });
                self.helper.identity_job = Some(job.map_err(|error| Error {
                    code: "io_failure",
                    message: error.to_string(),
                })?);
            }
            self.helper
                .hellos
                .push((self.fd, self.id, self.document.clone()));
            return Ok(());
        }
        let plugins: Vec<_> = self
            .helper
            .plugins
            .iter()
            .map(|p| p.borrow().name().to_owned())
            .collect();
        let mut out = Vec::new();
        let (uid, home) = crate::system::System::account().map_err(|error| Error {
            code: "io_failure",
            message: error.to_string(),
        })?;
        let home = home.to_string_lossy();
        let account = crate::json::Data::Object(vec![
            ("uid", crate::json::Data::Unsigned(uid.into())),
            ("home", crate::json::Data::String(&home)),
        ]);
        let (terminal, process) = self
            .helper
            .login
            .as_ref()
            .map(|login| {
                let login = login.borrow();
                (login.terminal, login.process.clone())
            })
            .unwrap_or_default();
        let process = process.as_ref().map(|process| {
            crate::json::Data::Object(vec![
                ("pid", crate::json::Data::Unsigned(process.pid.into())),
                (
                    "start",
                    crate::json::Data::Array(
                        process
                            .start
                            .iter()
                            .map(|value| crate::json::Data::Unsigned(*value))
                            .collect(),
                    ),
                ),
            ])
        });
        let identity = self
            .helper
            .identity
            .as_ref()
            .map(|json| crate::json::Data::Value(json.root()));
        crate::encode::object(
            &mut out,
            &[
                ("version", &wire::VERSION),
                ("frame_limit", &wire::LIMIT),
                ("chunk_kind", &(wire::Kind::Chunk as u64)),
                ("chunk_limit", &(wire::CHUNK as u64)),
                ("os", &std::env::consts::OS),
                ("arch", &std::env::consts::ARCH),
                ("account", &account),
                ("terminal", &terminal),
                ("process", &process),
                ("identity", &identity),
                ("plugins", &plugins),
                ("unavailable_harnesses", &self.helper.unavailable),
                (
                    "ops",
                    &OPERATIONS
                        .iter()
                        .filter(|method| self.helper.allowed(method) && self.registered(method))
                        .map(|s| s.to_string())
                        .collect::<Vec<_>>(),
                ),
            ],
        );
        self.replies.borrow_mut().push_back((
            self.fd,
            wire::Kind::Response,
            self.id,
            [b"{\"result\":".as_slice(), &out, b"}"].concat(),
        ));
        Ok(())
}
```

## API identity

The following digest covers API types, dispatch/schema handlers, framing and encoding. It is maintained by hand until `helper/protocol.py` exists and was last generated before the files operations, so it no longer matches; the wire's own identity is the schema id (`HelperBinary.version`).

`sha256 380f47ab6192a22905ddf6c8d919b9ad305e07c5a00e60873c9dd8451b9d8344`
