# Scrub captures before sharing them

- **Keep the original captures private.** Find the private values yourself; `capture replace` rewrites exactly those, then checks that the helper still replays.
  - Put every related capture in one input directory (local and SSH helpers, app journals of the same case): one invocation gives every file the same substitutions.
  - Captures come from real runs. Never edit recorded I/O to make a check pass.
  - A passing replay proves behavior for this helper and these captures. It does **not** prove that every private value was found.

- **Why there is no allowlist or denylist.** Agent output is arbitrary user/model text and changes with every agent version.
  - A list of public words never ends and goes stale; a list of private words misses the next account, host or path.
  - Masking blindly changes what parsers see. Review what was recorded and name the exact private values.
  - Only UUIDs and IPv4 addresses are found by their shape (`--uuids`, `--ips` below): their shape says what they are.

- **Build the helper with the `capture` feature: it is the tool too** (`dispatch-helper capture <command>`, docs/replay.md). From `helper/`:

  ```sh
  cargo build --offline --package dispatch-helper --features dispatch-helper/capture
  HELPER="$PWD/target/debug/dispatch-helper"
  umask 077; mkdir -p review
  ```

  - Replay with the current helper: a capture replays on the latest helper or is dropped (`capture prune`, docs/replay.md). Keep `review/` out of anything you publish.
  - `grep` and `replace` read the captures `--jobs N` at a time (default: every core). With 4 jobs, `grep` over 324 MB of bzip2 takes under a minute at about 1.1 GB of memory; `replace` over 383 MB took about 11 minutes (mostly compressing again).

- **List what a run may record: `test/leak.py`.** It takes the same arguments as `test/run.sh` and prints a needles file draft:

  ```sh
  test/leak.py --suite full > review/needles.txt
  ```

  - For this Mac and every SSH test host of the checkout's profiles (`build/linux-ssh.json`, `build/host-linux-ssh.json`): account and full name, home and temporary directories, host names, machine/boot/hardware ids, network addresses, SSH host key fingerprints, git identity, and their parts (path components, host name labels). For each SSH profile also what `ssh -G` resolves: user, host, key files and their fingerprints.
  - The test runner has no SSH arguments: the tests read their hosts from those profiles, so every profile is included whatever the selection. The arguments name the capture run (`--capture RUN` is in recorded paths).
  - A host it cannot reach is printed as `NOT REACHED` with the error: its values are missing, not absent.
  - Process lists are printed as `#` comments (context): copy their private parts as needles.
  - Environments are not printed (they can hold credentials). The helper records its own at startup: read it with `"$HELPER" capture inspect FILE --limit 5` (`startup context`) in one local and one remote capture.
  - The draft holds public values too (`Users`, `home`, `tmp`, `com`): delete them. A short or common needle changes public syntax and fails the replay check.

- **The needles file: one needle per line**, the same file for `grep`, `replace` and the plain-tools check below:

  ```text
  # lines starting with # are comments
  private-user
  private-host
  /Users/user/runs/private-run	/Users/user/runs/public-run1
  ```

  - Every line is a literal (no patterns), searched everywhere, inside larger names and paths too. At one position the longest needle wins.
  - A line `needle<TAB>value` replaces the needle by that value. The value must have the needle's **byte length**: lengths around a value are recorded too (wire frame and value lengths, sizes, terminal columns), so another length breaks every frame it is in. Pad or shorten a readable value to fit.
  - A line `needle<TAB>needle` keeps the needle as it is: a value `--ips` or `--uuids` would replace but must stay.
  - Without a value, the needle gets a mask of the same length: each letter and digit is replaced by another of its kind (digits, `a-f`, `g-z`, and the same for upper case); other characters stay. Paths stay absolute paths and hex ids hex: `/Users/name` becomes something like `/Gzenq/gzch`. A needle that is a UUID or an IPv4 address gets a random one of its kind.
  - Masks come from a fixed pseudo-random stream per needle position, never from the needle itself: a mask shows only the needle's length and character kinds, and a guessed value cannot be checked against it. The same file always gives the same output. A replacement never equals a needle or another replacement.

- **Search: `capture grep`.** One pass over every capture under the paths, the needles grouped by where they are:

  ```sh
  "$HELPER" capture grep captures --needles review/needles.txt > review/found.txt
  "$HELPER" capture grep private-name captures > review/name.txt
  ```

  - A single needle can be given before the paths instead of `--needles`. The search is literal and case sensitive.
  - Per needle: its matches, then per place how many, in how many files, and the first with up to 80 bytes either side, escaped. Lists stop at `--limit` (default 200) and say how many were not shown.
  - A place is the record's section, op and field, and inside our own frames and plain values also the frame's kind, method and field there: `startup write output -> notify chat.records params.records[].id`.
  - Every text and bytes value of every record is searched (map keys included) the way a reader of it sees it, on views. Base64, hex or hex pairs other programs wrote (tmux `send-keys -H`, ids, keys) are not decoded. Our own frames and values are structure, not an encoding: they only make places deeper.
    - A stream is one view across its records: one side of a connection (its descriptor, else the app lifetime; per op and part), and inside our frames each text or bytes per method, path and terminal (`notify terminal.output params.bytes (terminal N)`). A needle a record boundary or a frame boundary cuts in two is found whole and listed as `(cut)`.
    - Line breaks (CR, LF) and CSI sequences (ESC `[` ... final byte: colors, cursor moves) are not part of a view: a needle a terminal wrapped (`secr` line break `et7`, or a cursor move in between) is found and listed as `(wrapped)`; its bytes stay where they were recorded.
    - A value of its own (a command's output, a file) is one view alone: wraps inside it count, nothing joins it to the next one.
    - **The screen** a joined stream draws is a view too: a program that redraws only the cells that changed jumps the cursor over cells already showing the right character, so a needle can be whole on the screen and in no run of bytes. Each terminal stream (a side, our frames per terminal, a herdr pane's decoded frames) drives a screen of 256 rows and 1024 columns: cursor addressing, erase, CR, LF, BS, TAB, save/restore, scrolling at the bottom; no autowrap (line wraps are the byte view's), no scroll regions, no insert/delete, no alternate buffer. After each piece the rows it drew on are searched; a needle found there and by no byte view is listed as `(screen)`, and `replace` replaces every cell's byte where it was written, in this piece or an earlier one (a cell shows exactly the byte that wrote it). In a decoded field the unit holding the byte is encoded again.
    - UUIDs and IPv4 addresses (`replace --ips`/`--uuids`) are matched on the bytes as recorded, joined across records too (a line break next to a number keeps it from looking like part of an address).
  - Two protocols the helper speaks in text are understood too, read per stream across reads (a closed descriptor ends its open line):
    - Herdr (one JSON object per line): the `bytes` field of `terminal.frame` (pane output) and of `terminal.input` (what we type) is base64, decoded and searched (`mux read output -> herdr terminal.frame bytes (base64)`, `mux write output -> herdr terminal.input bytes (base64)`).
    - Tmux control mode: the helper types raw input as `send-keys -H -t %N` and a byte per space and two hex digits (multiplexers/tmux `commands.rs`); the pairs are decoded per pane and line and searched (`mux write output -> tmux send-keys -H (hex pairs)`). Tmux does not echo them back.
    - A decoded field is a view of its own: wraps inside it are found, a needle cut across two lines (two frames, two commands) is not. The joined views of the raw stream around them do not see inside the encoding either.
  - **Encoded text is a warning**, listed first: every text that looks like hex, hex byte pairs or base64 by its shape (16 bytes and longer), but the fields above. Per place: how many texts, how often, in how many files; then each text as it is, most frequent first, with its count, files and first `file:record`.
    - Needles are not searched inside them, and `replace` does not change them. Judge each: another program's encoding that holds no private data is fine.
    - Private data inside another program's encoding, or an encoding our own helper or app made (hex or base64 inside our own protocol), is a finding: fix it at its source, never work around it in `replace`.
  - **Values nobody listed yet**: `--values SHAPE` (any number of times, with or without needles) lists every distinct line of the values at places holding SHAPE, digit runs shown as `#` (pids and counters), the most frequent first, with counts, files and the first `file:record`. Read them for private entries and make those needles.
    - Process lists and network interfaces record whatever ran on a test machine (the SSH test host, this Mac): `--values 'processes[].name' --values 'processes[].arguments' --values 'network[].name' --values 'result[][].name'`, and a test's own `ps` output at its place (`--values 'in.result output.output'`).
  - The needles come last: what a scrub must bring to zero ends the output.
  - The output contains the private values. Never attach it.

- **Replace and verify in one command.** The output must be a new directory:

  ```sh
  "$HELPER" capture replace captures review/attempt-1 --needles review/needles.txt --ips
  ```

  - `--ips` replaces every IPv4 address of a machine (not `0.x`, loopback `127.x` or `224` and up) by a random valid one with the same digit counts; `--uuids` every UUID by random hex digits (version and variant kept). Needles win over both.
    - It prints every value they found with its replacement: review the list (a 4-part version looks like an address, and so does `27.0.0.1`, the rest of a `127.0.0.1` a read cut in two) and keep such values with `value<TAB>value` lines. This output names private values: keep it private.
    - Replacements depend on the order values are met (files sorted by path, records in order), never on the value: the same input gives the same output, and the same value gets the same replacement in every file. App journals and helper captures of a case must be scrubbed in one run to stay linked.
    - **`--uuids` breaks replays wherever an id is made rather than read**: the app makes most of its ids from the seed its journal records (AppReplay) and makes them again in replay; the helper formats some from recorded random bytes. Those no longer match their replaced copies. Use it only for captures nothing makes ids in; otherwise list the private UUIDs as needles (machine and boot ids come from `leak.py`).
  - Literal bytes change, on the same views as `grep` reads (a needle cut across records or frames, or wrapped by a terminal, has each of its bytes replaced where it was recorded), and the herdr and tmux fields above decoded (encoded again in the same length and case; only the changed units are written). Text inside any other base64 or hex stays as it is (`grep` lists it). A field that cannot be decoded is listed as `NOT DECODED`, never skipped silently.
    - A match reaching back into records already written makes `replace` write that file again with those bytes changed (a second pass over the file).
  - **Hashes follow**: for every value of its own `replace` changed (a command's output, a file), the SHA-256 of it before (lowercase hex) is replaced everywhere by the SHA-256 of what it became. Our code hashes text it reads (an SSH configuration's fingerprint is the SHA-256 of `ssh -G` output): in replay the app hashes the replaced text, and the original's hash, which confirms a guess of the private text, is gone. It prints how many hashes it followed. A hash of built-up text (parts joined, lines filtered) is not followed: the app replay fails on it; capture that scenario again with non-private values.
  - First every helper capture replays as recorded (`review/attempt-1.replay-original/`), then the rewritten ones (`review/attempt-1.replay-candidate/`). It prints each capture the scrub broke (`BROKEN BY THE SCRUB`) with the replay's reason: the record and op it stopped at, and its mismatch file (`"$HELPER" capture value FILE`). A capture that does not replay before the scrub either is `NOT CHECKED`. Either exits non-zero.
  - A needle or pattern in a record's section or op is refused: those are names the helper itself chose.
  - App journals get the same substitutions, but only their app tests can replay them: run those tests (on the Mac) before relying on them.

- **Check with plain tools too.** Captures are bzip2 around our binary records, with no hex or base64 layer of ours: `bzcat` and `grep` see every literal needle.

  ```sh
  grep -v -e '^#' -e '^$' review/needles.txt | cut -f1 > review/plain.txt
  find captures -name '*.rpl.bz2' -exec bzcat {} + | LC_ALL=C grep -aoFf review/plain.txt | sort | uniq -c
  ```

  - Before the scrub it counts each needle; after it, it must print nothing (but the values kept with `value<TAB>value`).
  - It does not see a value cut in two or wrapped, nor inside herdr's base64 or tmux's hex pairs: `capture grep` does.

- **Review the candidate again before publishing.** A zero exit means replay succeeded, not that the files are private.
  - `grep` the candidate for the needles, the broader shapes (`/Users/`, `/home/`, `@`) and its encoded texts again; read terminal output and user/model text.
  - Replay reports and logs beside the output name original paths: keep them private.
  - Attach only the reviewed candidate captures.

- **If verification fails, keep the evidence and find out why.** Never skip the check or drop a capture.
  - If an original fails, the helper or the capture does not match: replay with the run's own helper first.
  - If only the candidate fails, the needle changed syntax, a relation the helper or app derives (lengths, a hash of built-up text, parsed numbers, case changes, sorting), or the value also sits in another program's encoding the helper decodes (`grep` warns of it). Inspect the original at the record the replay names; pick a narrower private component and start again from the original.
  - If a value cannot be replaced without changing behavior, capture the scenario again with a non-private account or path.
