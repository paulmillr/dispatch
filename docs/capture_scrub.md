# Scrub captures before sharing them

- **Keep the original captures private.** Find the private values yourself; `capture replace` rewrites exactly those, then checks that the helper still replays.
  - Put every related capture in one input directory (local and SSH helpers, app journals of the same case): one invocation gives every file the same substitutions. Copy them there: the tool does not follow symbolic links inside a directory (it lists them on stderr).
  - Captures come from real runs. Never edit recorded I/O to make a check pass.
  - A passing replay proves behavior for this helper and these captures. It does **not** prove that every private value was found.

- **Why there is no allowlist or denylist.** Agent output is arbitrary user/model text and changes with every agent version.
  - A list of public words never ends and goes stale; a list of private words misses the next account, host or path.
  - Masking blindly changes what parsers see. Review what was recorded and name the exact private values.
  - Only UUIDs and IPv4 addresses are found by their shape (`--uuids`, `--ips` below): their shape says what they are.
  - **Process lists are the exception.** Host statistics list every process of a test machine (the helper's `stats.processes`), and a needle hides only the token it names. `replace` removes every row of such a list but the few processes the tests need (`replace`, below): what is gone cannot be guessed back.

- **Build the helper with the `capture` feature: it is the tool too** (`dispatch-helper capture <command>`, docs/replay.md). From `helper/`:

  ```sh
  cargo build --offline --package dispatch-helper --features dispatch-helper/capture
  HELPER="$PWD/target/debug/dispatch-helper"
  umask 077; mkdir -p review
  ```

  - Replay with the current helper: a capture replays on the latest helper or is dropped (`capture prune`, docs/replay.md). Keep `review/` out of anything you publish.
  - `grep` and `replace` read the captures `--jobs N` at a time (default: every core). `replace` writes its output as the corpus keeps it (zstd level 9, long window).

- **List what a run may record: `test/leak.py`.** It takes the same arguments as `test/run.sh` and prints a needles file draft:

  ```sh
  test/leak.py --suite full > review/needles.txt
  ```

  - For this Mac and every SSH test host of the checkout's profiles (`build/linux-ssh.json`, `build/host-linux-ssh.json`): account and full name, home and temporary directories, host names, machine/boot/hardware ids, network addresses, SSH host key fingerprints, git identity, time zone (agents write it into what they send; a zone name comes with a real zone of its byte length, picked at random, as its value: masked, it is easy to guess back; its comment counts the zones of that length and warns below 10; a zone no other shares its length with stops it: handle that one by hand; UTC under any of its names is no place and gives none), and their parts (path components, host name labels). Also each machine's prompts (`account@host`, the host's first label too: a label alone is too short a needle, and a terminal redraw can cut the full name) and its shell startup files linked elsewhere with the repository holding them (test shells source them and print their paths). For each SSH profile also what `ssh -G` resolves: user, host, key files and their fingerprints. For this Mac also the login session's launchd agent socket folder (Xcode's test host inherits it as `SSH_AUTH_SOCK`; the app drops it while testing, older recordings hold it).
  - Login banners ("Last login: Fri Oct 16 14:44:47 on ttys007") hold the account's login times, and the run's own logins make most of them: after the recording, `test/leak.py … --captures build/captures` adds each time the captures show, with a time on 1 January 1970 of the same shape as its value (distinct: `replace` refuses equal values).
  - The test runner has no SSH arguments: the tests read their hosts from those profiles, so every profile is included whatever the selection. Recordings hold the staging path (`build/captures/<TestFile>/<testName>/`), the same in every capture.
  - The runner hands tests UTC and one basic locale (`LANG=en_US.UTF-8`, CoreFoundation's `__CF_USER_TEXT_ENCODING` with region US, no `LANGUAGE` or `LC_*`): every recorded environment holds them (the helper's, each command's). Recordings made before that hold the account's own (its languages, its region, its terminal's `LC_TERMINAL`): name those values as needles, with same-length values.
  - A host it cannot reach is printed as `NOT REACHED` with the error: its values are missing, not absent.
  - Process lists are printed as `#` comments (context): copy their private parts as needles.
  - Environments are not printed (they can hold credentials). The helper records its own at startup: `capture grep` lists every capture's (below).
  - The draft holds public values too (`Users`, `home`, `tmp`, `com`): delete them. A short or common needle changes public syntax and fails the replay check.

- **The needles file: one needle per line**, the same file for `grep`, `replace` and the plain-tools check below:

  ```text
  # lines starting with # are comments
  private-user
  private-host
  /Users/name/projects/private	/Users/name/projects/public1
  ```

  - Every line is a literal (no patterns), searched everywhere, inside larger names and paths too. At one position the longest needle wins.
  - A line `needle<TAB>value` replaces the needle by that value. The value must have the needle's **byte length**: lengths around a value are recorded too (wire frame and value lengths, sizes, terminal columns), so another length breaks every frame it is in. Pad or shorten a readable value to fit.
  - A line `needle<TAB>needle` keeps the needle as it is: a value `--ips` or `--uuids` would replace but must stay.
  - Without a value, the needle gets a mask of the same length: each letter and digit is replaced by another of its kind (digits, `a-f`, `g-z`, and the same for upper case); other characters stay. Paths stay absolute paths and hex ids hex: `/Users/name` becomes something like `/Gzenq/gzch`. A needle that is a UUID or an IPv4 address gets a random one of its kind.
  - Masks come from a fixed pseudo-random stream per needle position, never from the needle itself. The same file always gives the same output. A replacement never equals a needle or another replacement.
  - A mask keeps the needle's shape: its length and where its digits, letters and upper case letters are (`robin07` gives five letters and two digits, a host name keeps the lengths of its labels). A guessed value can be checked against that shape. Choose each replacement yourself (`needle<TAB>value`) wherever the shape says something about the value: names, host names, accounts; take the mask only where it says nothing.

- **Search: `capture grep`.** One pass over every capture under the paths, the needles grouped by where they are:

  ```sh
  "$HELPER" capture grep replays --needles review/needles.txt > review/found.txt
  "$HELPER" capture grep private-name replays > review/name.txt
  ```

  - A single needle can be given before the paths instead of `--needles`. The search is literal and case sensitive.
  - Per needle: its matches, then per place how many, in how many files, and the first with up to 80 bytes either side, escaped. Lists stop at `--limit` (default 200) and say how many were not shown.
  - A place is the record's section, op and field, and inside our own frames and plain values also the frame's kind, method and field there: `startup write output -> notify chat.records params.records[].id`.
  - Every text and bytes value of every record is searched (map keys included) the way a reader of it sees it, on views. Base64, hex or hex pairs other programs wrote (tmux `send-keys -H`, ids, keys) are not decoded. Our own frames and values are structure, not an encoding: they only make places deeper.
    - A stream is one view across its records: one side of a connection (its descriptor, else the app lifetime; per op and part), and inside our frames each text or bytes per method, path and terminal (`notify terminal.output params.bytes (terminal N)`). A needle a record boundary or a frame boundary cuts in two is found whole and listed as `(cut)`.
    - Line breaks (CR, LF) and CSI sequences (ESC `[` ... final byte: colors, cursor moves) are not part of a view: a needle a terminal wrapped (`secr` line break `et7`, or a cursor move in between) is found and listed as `(wrapped)`; its bytes stay where they were recorded.
    - A value of its own (a command's output, a file) is one view alone: wraps inside it count, nothing joins it to the next one.
    - **The screen** a terminal draws is a view too: a program that redraws only the cells that changed jumps the cursor over cells already showing the right character, so a needle can be whole on the screen and in no run of bytes. Every terminal stream drives a terminal of its size, as the terminal that showed it drew it (Ghostty, the app's and herdr's; system/capture/screen.fixtures holds the cases compared with it): autowrap, scroll regions, insert and delete, the alternate screen, origin mode, tab stops, wide characters, and the rewrap a resize does.
      - The sizes come from the recording, in record order: a helper's pty from its `spawn` and `resize`, the helper's own terminal from `tty.start` / `tty.grid` (its `stdio` descriptors), an app's pty from its section's `in.size`, a terminal of ours from `terminals.attach` / `terminals.resize` and the topology, a herdr pane from each frame's width and height.
      - Only terminals have screens: a stream that carries a protocol (our frames, a multiplexer's lines, a websocket), a text of ours that is no terminal's and input sent to a terminal have none. A plain stream that names no size is drawn on a screen of no size (256 rows, 1024 columns, no wrap, scrolling at its last row); `grep` lists every such stream (`screens of no size`): there a needle the terminal shows only after wrapping or scrolling is not found.
      - After each piece the lines it drew on (a row and the rows it wraps into) are searched, and so are the lines it takes off the screen (scrolled out, deleted, cleared); a needle found there and by no byte view is listed as `(screen)`, and `replace` replaces every cell's byte where it was written, in this piece or an earlier one (a cell shows exactly the byte that wrote it). In a decoded field the unit holding the byte is encoded again.
      - `(screen, shared)`: a cell of it shows a byte of other text (written between bytes that are not the needle's: the program skipped a cell that text left showing). The program skipped it because that text had the needle's character there, so the recording ties that character to the other text whatever value replaces the needle: a value that keeps the character shows it; one that changes it changes the other text, whose other copies give the character back; a frame drawn again in the same length still says that one cell matched. Record the test again (such text is mostly random: temporary paths, ids) until `grep` shows no shared cell.
      - herdr's binary client protocol (the stream a helper relays between a herdr server and its controller) is not decoded: its frames are drawn on a screen of no size; their copy in the controller's JSON lines is decoded and sized.
    - UUIDs and IPv4 addresses (`replace --ips`/`--uuids`) are matched on the bytes as recorded, joined across records too (a line break next to a number keeps it from looking like part of an address).
  - Three protocols the helper speaks are understood too, read per stream across reads (a closed descriptor ends its open line):
    - Herdr (one JSON object per line): the `bytes` field of `terminal.frame` (pane output) and of `terminal.input` (what we type) is base64, decoded and searched (`mux read output -> herdr terminal.frame bytes (base64)`, `mux write output -> herdr terminal.input bytes (base64)`).
    - Tmux control mode: the helper types raw input as `send-keys -H -t %N` and a byte per space and two hex digits (multiplexers/tmux `commands.rs`); the pairs are decoded per pane and line and searched (`mux write output -> tmux send-keys -H (hex pairs)`). Tmux does not echo them back.
    - Websocket: a client masks every frame it sends (RFC 6455: the payload XOR a 4-byte key in the frame's header), and the helper is one (its requests to Codex's app-server). On any stream starting with an HTTP request that upgrades to a websocket, each frame's masked payload is decoded and searched (`harness write output -> websocket (masked)`). A server's frames are not masked: the stream's views read them.
    - A decoded field is a view of its own: wraps inside it are found, a needle cut across two lines (two frames, two commands, two websocket frames) is not. The joined views of the raw stream around them do not see inside the encoding either.
  - **The helper's environment comes first**: every variable of the environment each helper recorded at startup (`startup context`; the local and the SSH test accounts'), and its distinct values, the most frequent first, with file counts and the first `file:record`. It is recorded whole, before any scrub, and no needle or shape finds a credential nobody listed: read every value; private ones are needles.
  - **Encoded text is a warning**, listed before the needles: every text that looks like hex, hex byte pairs or base64 by its shape (16 bytes and longer), but the fields above. Per place: how many texts, how often, in how many files; then each text as it is, most frequent first, with its count, files and first `file:record`.
    - Needles are not searched inside them, and `replace` does not change them. Judge each: another program's encoding that holds no private data is fine.
    - Private data inside another program's encoding, or an encoding our own helper or app made (hex or base64 inside our own protocol), is a finding: fix it at its source, never work around it in `replace`.
  - **Values nobody listed yet**: `--values SHAPE` (any number of times, with or without needles) lists every distinct line of the values at places holding SHAPE, digit runs shown as `#` (pids and counters), the most frequent first, with counts, files and the first `file:record`. Read them for private entries and make those needles.
    - Network interfaces record what a test machine has (the SSH test host, this Mac): `--values 'network[].name'`. Process lists need no review: `replace` keeps only the allowed rows.
  - **Per needle, the whole tokens holding it or its replacement**, as recorded: the match with the letters, digits, `-_.@+~%` and non-ASCII bytes beside it (a path component, a name, a host), inside one value, the most frequent first. With `--needles` the replacements are the ones `replace` makes of that file.
    - On a scrubbed tree it shows what a mask left standing (`<mask>-collector`): name the rest too, or the whole name. Before the scrub it shows what will stand beside the mask.
  - The needles come last: what a scrub must bring to zero ends the output.
  - The output contains the private values. Never attach it.

- **Replace and verify in one command.** The output must be a new directory:

  ```sh
  "$HELPER" capture replace replays review/attempt-1 --needles review/needles.txt --ips
  ```

  - `--ips` replaces every IPv4 address of a machine (not `0.x`, loopback `127.x` or `224` and up) by a random valid one with the same digit counts; `--uuids` every UUID by random hex digits (version and variant kept). Needles win over both.
    - It prints every value they found with its replacement: review the list (a 4-part version looks like an address, and so does `27.0.0.1`, the rest of a `127.0.0.1` a read cut in two) and keep such values with `value<TAB>value` lines. This output names private values: keep it private.
    - Replacements depend on the order values are met (files sorted by path, records in order), never on the value: the same input gives the same output, and the same value gets the same replacement in every file. App journals and helper captures of a case must be scrubbed in one run to stay linked.
    - **`--uuids` breaks replays wherever an id is made rather than read**: the app makes most of its ids from the seed its journal records (AppReplay) and makes them again in replay; the helper formats some from recorded random bytes. Those no longer match their replaced copies. Use it only for captures nothing makes ids in; otherwise list the private UUIDs as needles (machine and boot ids come from `leak.py`).
  - **First, `replace` removes process rows.** Every statistics process list (an array of objects with a `pid`, a `name` and an `rss`) keeps only the rows whose name is allowed (helper/bin/src/capture.rs `ALLOWED`: the agents, ripgrep, the multiplexers, ours, ssh, the shells and `yes`, a test's CPU load); every other row goes.
    - Where: the stats job's result in the helper capture, the reply frame the helper writes, a remote host's `connect` bridge passing it on, and the app's reads of it. A stream's bytes are cut into the same records again: each keeps its share, and a cut inside a changed frame stays as far into it as it was (every record keeps a byte). Only captures that name `stats.processes` are rewritten; it prints how many.
    - Rows carry a name, never a path (macOS: the last part of `ps`'s path; Linux: the process name): a kept `bash` says only that some process called so ran.
    - Removing a row the app or a test needs (a test reads `yes` from the list) breaks that test's replay: add the name to `ALLOWED`.
    - A list sent in chunks (a reply over 64 KiB) stays as recorded: none so far.
    - Other values with a pid are single processes the tests started (a pane's shell, an agent's binding): needles cover their paths.
  - Literal bytes change, on the same views as `grep` reads (a needle cut across records or frames, or wrapped by a terminal, has each of its bytes replaced where it was recorded), and the herdr, tmux and websocket fields above decoded (encoded again in the same length and case, or with the same mask key; only the changed units are written). Text inside any other base64 or hex stays as it is (`grep` lists it). A field that cannot be decoded is listed as `NOT DECODED`, never skipped silently.
    - A match reaching back into records already written makes `replace` write that file again with those bytes changed (a second pass over the file).
  - **Hashes follow**: for every value of its own `replace` changed (a command's output, a file), the SHA-256 of it before (lowercase hex) is replaced everywhere by the SHA-256 of what it became. Our code hashes text it reads (an SSH configuration's fingerprint is the SHA-256 of `ssh -G` output): in replay the app hashes the replaced text, and the original's hash, which confirms a guess of the private text, is gone. It prints how many hashes it followed. A hash of built-up text (parts joined, lines filtered) is not followed: the app replay fails on it; capture that scenario again with non-private values.
    - **Ids hashed from part of a value are the limit.** The helper ids Codex records by the SHA-256 of a transcript line or a prompt, and keys Pi's history by its session header line. A value scrubbed inside such a line changes the id the replay makes, so the check fails, and the recorded id, a hash of the original line, confirms a guess of the value. Keep such values out of the capture (tests run with `TZ=UTC`: Codex writes the time zone into its lines) or leave them as recorded (dates in Codex transcripts).
  - First every helper capture replays as recorded (`review/attempt-1.replay-original/`), then the rewritten ones (`review/attempt-1.replay-candidate/`). It prints each capture the scrub broke (`BROKEN BY THE SCRUB`) with the replay's reason: the record and op it stopped at, and its mismatch file (`"$HELPER" capture value FILE`). A capture that does not replay before the scrub either is `NOT CHECKED`. Either exits non-zero.
  - **Last, every output file gets a random name** in its directory (`.rpl.zst`: the output is zstd, as the corpus keeps it). A stored capture is named by its content key, a hash of the original's records: kept for a changed capture, it would confirm any guess at what the scrub replaced. Until that step (and on any failure) the output files keep their input names, so the reports above name the same files as the input.
  - A needle or pattern in a record's section or op is refused: those are names the helper itself chose.
  - App journals get the same substitutions, but only their app tests can replay them: run those tests (on the Mac) before relying on them.

- **Check with plain tools too.** Captures are zstd around our binary records, with no hex or base64 layer of ours: `zstd -dc --long=27` and `grep` see every literal needle but those inside the encodings above.

  ```sh
  grep -v -e '^#' -e '^$' review/needles.txt | cut -f1 > review/plain.txt
  find replays -name '*.rpl.zst' -exec zstd -dcq --long=27 {} + | LC_ALL=C grep -aoFf review/plain.txt | sort | uniq -c
  ```

  - Before the scrub it counts each needle; after it, it must print nothing (but the values kept with `value<TAB>value`).
  - It does not see a value cut in two or wrapped, nor inside herdr's base64, tmux's hex pairs or a websocket client's masked frames: `capture grep` does.

- **Review the candidate again before publishing.** A zero exit means replay succeeded, not that the files are private.
  - `grep` the candidate for the needles, the broader shapes (`/Users/`, `/home/`, `@`) and its encoded texts again; read terminal output and user/model text.
  - Replay reports and logs beside the output name original paths: keep them private.
  - Attach only the reviewed candidate captures.

- **If verification fails, keep the evidence and find out why.** Never skip the check or drop a capture.
  - If an original fails, the helper or the capture does not match: replay with the run's own helper first.
  - If only the candidate fails, the needle changed syntax, a relation the helper or app derives (lengths, a hash of built-up text, parsed numbers, case changes, sorting), or the value also sits in another program's encoding the helper decodes (`grep` warns of it). Inspect the original at the record the replay names; pick a narrower private component and start again from the original.
  - If a value cannot be replaced without changing behavior, capture the scenario again with a non-private account or path.
