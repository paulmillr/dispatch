# Capture and replay

- **Tests replay recorded I/O by default.** A test with a recording in `replays/` runs without the outside world: no helper, no SSH, no agents, no real time. A test without one runs live.
  - Live runs can record; recordings of passed tests go to `replays/` after checks (below).
  - Release builds and archives contain no capture or replay code (Swift `DEBUG`, Rust `capture` feature).

- **What is recorded**
  - The **app journal**: everything the app exchanges with the outside world in one test: helper connections (bytes both ways), terminal ptys, commands it runs, files it reads and writes, what it observes (process state, file existence, the time), its own waits (`System.sleep`) and the test's steps.
  - One **helper capture** per helper process the test started: its startup facts, every I/O request and its result, its end (return status, handoff or signal).
  - Helpers on SSH hosts (the Mac's own test sshd, the Linux test host) write their captures there; each test collects them when it ends.
  - The file format is the same for both: zstd around length-prefixed frames, binary values (`helper/core/src/system/capture/trace.rs`). Bytes stay bytes.
  - Live captures are zstd level 1, fast and in a small window; the corpus keeps them at level 9 with `--long=27` (`.rpl.zst` either way: `Vendor/Zstd/PROVENANCE.md`), whose 128 MiB window stores a payload recorded again and again (the bootstrap tests upload the helper binary many times) once. `capture store` compresses again as it stores. `zstd -dc --long=27` expands either.
  - Captures hold unredacted I/O: never publish one without [capture_scrub.md](capture_scrub.md).

- **The corpus**: `replays/<TestFile>/<testName>/<key>.rpl.zst`
  - `<TestFile>` is the Swift file declaring the test class; `<testName>` the test method.
  - A test's directory holds its app journal and all its helper captures (local and remote).
  - `<key>` is a hash of what replay sees (records without the bookkeeping clock or wire version): the same content is one file. A scrubbed corpus has random names instead ([capture_scrub.md](capture_scrub.md)); nothing reads a key from a name.
  - **One app journal per test for now.** A recording names its run's pids, seeds and temp paths, so without deduplication every live re-run would look like a new variant. `store` skips a test that already has one.
  - **The corpus is its own repository**, a git submodule at `replays/` (`scripts/split-replays.py` made it one). Its path never changes: recordings name `/tmp/dt-journal/checkout/replays`.
    - Get it: `git clone --recurse-submodules`, or `git submodule update --init replays` in a checkout. Without it `test/xcode.py` refuses to run (only `--live` runs) and the Debug build skips its corpus check with a warning.
    - Changed recordings (`--capture`, `capture prune`, a deleted test directory) are changes in the submodule: commit them there and push, then stage the new `replays` commit here with the change that made them. Never push a checkout's commit before the corpus commit it names.

## Common tasks

Most work needs no full live run. Replaying every recording takes about 15 minutes, one class seconds. Run live only what you changed on purpose, record it, and replay the rest.

**Recording everything again is the last resort**, for when no recording can replay at all (a new wire version, below). After any change, yours or merged, replay the corpus first: the replays that fail are exactly what changed. Read each failure, then record again only those tests, and only once you know why each one changed. Never guess that a change "probably touches everything": a fresh recording passes by construction, so recording everything hides exactly what the replay would have shown. When the recording format itself changes, convert the existing recordings instead of recording them again.

- **Prefer changes that touch few recordings.** A change to what many tests do (startup requests every test sends, a timer every test runs, common helper behavior) changes many recordings: each one must be checked and recorded again, which is slow, and recordings that passed are what tells us the rest still works. Before such a change, look for a narrower one; when it is needed, make it on its own, not mixed with other work.

- **I work on the app only**
  - Check with the recordings: `python3 test/xcode.py --suite exhaustive` (or one class: `python3 test/xcode.py DispatchTests/ChatTests`).
  - App replays passing means the app still sends and asks exactly what was recorded, so the helper sees nothing new either.
  - A replay that fails where you did not mean to change anything: the app now does something else there ([Reading a failed app replay](#reading-a-failed-app-replay)).
  - A test you changed on purpose, or a new test: delete its `replays/<TestFile>/<testName>/` (if any), then record it and replay that recording:

    ```sh
    python3 test/xcode.py --capture DispatchTests/ChatTests/testNew
    python3 test/xcode.py --replay DispatchTests/ChatTests/testNew
    ```

- **I work on the helper only**
  - Check with the recordings: replay every helper capture on your helper (minutes; on Linux too; the Debug app build does the same and fails on any failure):

    ```sh
    "$HELPER" capture replay replays --completion required --output results/my-change
    ```

  - Rust unit tests: `cd helper && cargo test --offline --features dispatch-helper/capture` (the capture and replay tests need the `capture` feature).
  - Helper replays passing means the helper answers every recorded request as before, so the app's recordings still hold.
  - A capture that fails: the helper now does something else for that request (`report.jsonl` names the record). If that is the change you meant, the test that recorded it is stale: record that app test again. Helper captures are only recorded through app tests (`--capture`).

- **I merged other changes** (upstream commits, another branch)
  - Same as any change: replay every recording on the merged code (app and helper). The failures list what the merged changes do differently; read each before recording it again. Tests outside what the merge touched must still pass: a failure there is a regression of the merge, not a stale recording.

- **I fix a bug** (the cause is in the app, the helper, or both)
  - Reproduce it from a recording first: a live failure recorded with `--capture` replays with `--replay`, the same way every time ([Investigating a test that fails live sometimes](#investigating-a-test-that-fails-live-sometimes)).
  - App fix: replay the test's class, then every app recording. Tests that now fail are exactly the ones whose recorded behavior the fix changed: check each failure is the intended change, then record those tests again.
  - Helper fix: replay every helper capture. The failing captures name the tests the fix changes: record those again (live, `--capture`), then replay them in the app.
  - Both: helper first (its failing captures list the affected tests), then record those tests again and replay all app recordings.
  - `"$HELPER" capture prune replays --dry-run` lists every helper capture that no longer replays.

- **I change the protocol** (the wire schema in `helper/core/src/wire`)
  - **Avoid it when you can: the protocol should become stable.** A schema change is slow and risky to verify, so before making one ask:
    - Is it avoidable (an existing message, field or request that already carries this)?
    - If not, what shape makes further changes unnecessary (one general field instead of one per feature)?
  - Why it is expensive: names are numbered by their place in the schema's sorted symbol table, so one new name renumbers every name after it and nearly every recorded message is encoded differently. Upstream's one new field (`agents`) did that to the 490 recordings that carry helper messages.
  - The wire version is a hash of the schema: after any schema change no app journal of the old version replays (the test fails and names `capture prune`).
  - Replay the helper captures first: they show which recorded behavior changed beyond the encoding.
  - Then record everything again (below): the one change that needs a full live run.

- **I want to know the recordings are not stale** (rare): record everything again into a fresh corpus and replay it.

  ```sh
  git -C replays rm -r -q .            # start empty; the corpus repository's history keeps the old one
  python3 test/xcode.py --capture --live --suite exhaustive
  python3 test/xcode.py --replay --suite exhaustive
  ```

  - Tests that fail the second command are stale in a way the first run did not reveal (UI timing it decided differently): read their failure.

- **I want to check that a test's app and helper recordings belong together**: `capture check` ([The three checks](#the-three-checks)) pairs every connection's two sides and fails on any byte that differs.

- **I want to know the recordings hold no private data**: [capture_scrub.md](capture_scrub.md).

- **I write a test that replays and does not flake**: [Writing tests that replay](#writing-tests-that-replay). In short: all I/O and machine facts through `System`, waits through `TestSupport.eventually`, timers named, ids from `System.uuid()`, nothing left behind for the next test.

## Workflows

- **Run tests** (default): replay what `replays/` has, run the rest live.

  ```sh
  python3 test/xcode.py DispatchTests/ChatTests
  python3 test/xcode.py --live DispatchTests/ChatTests     # every test live, the corpus ignored
  ```

  - A test whose journal diverges fails: missing recording means live, a wrong recording means failure.
  - A journal of another protocol version fails its test with a hint to run `capture prune`.

- **Record** live tests and add the passed ones to the corpus.

  ```sh
  python3 test/xcode.py --capture DispatchTests/ChatTests
  python3 test/xcode.py --capture --live DispatchTests/ChatTests   # record tests already in the corpus too
  ```

  - Everything stays in `build/captures/` for debugging, failed tests included, laid out as the corpus: `<TestFile>/<testName>/` holds the test's app journal (`<uuid>.rpl.zst`), its local helper captures (`helper-<pid>-<start>.rpl.zst`) and a folder per SSH host with that host's.
    - `cases.jsonl`: each test's start, end and outcome; `tests.json`: each test class's file (the runner's, not a capture format).
    - Its path is the same in every capture (test processes see it, and recordings hold it), so it names no run: `--capture` refuses a `build/captures` that holds an earlier capture. Move that one away to keep it (and back to replay it).
    - On an SSH host a test's helpers write into `~/.cache/dispatch-capture/<digest of its staging folder>/`, the same folder in every capture of that test; after the test its new files come over (a copied file is acknowledged there, never deleted). Files left by a capture whose collection failed come along with the next capture of that test: they link to no journal, so `store` refuses the test ("not linked"). Capture it again.
  - Then `capture store` takes each passed test: every helper capture must replay on the current helper, and `capture check` must find its app and helper ends agreeing and linked. Only then are its files placed in `replays/`.
  - A test that does not pass these checks is listed and stays in staging only; the run reports it.

- **Verify one run** by replaying only its recordings (nothing runs live).

  ```sh
  python3 test/xcode.py --replay DispatchTests/ChatTests
  ```

  - The capture's tests go to a scratch corpus under `build/app-replay/<id>/`, failed ones included (they reproduce their failure); a selected test without a journal there fails.

- **Building checks the helper against the corpus.** A Debug build, right after building the helper, replays every helper capture in `replays/` on it.
  - Any failure fails the build and names the captures; the replay results stay in `build/helper-rust/replay-results-<pid>/`.
  - Either the change broke the helper, or the recordings no longer apply (a deliberate protocol change): then drop them.

- **Changed a test?** Its recording describes the old test: replay fails it as a different capture. Delete its directory (`replays/<TestFile>/<testName>/`); the next `--capture` run records it again.
  - A test's steps (its waits) are told apart by their order alone: moving code leaves its recording valid; adding or removing a wait changes it. Each step also records its source line, for reports only.

- **A fresh recording that fails its own replay** (passes live, fails replayed alone every time) caught an order replay does not reproduce: the app's reaction overtaken by a later input, a hangup or write the app does only after work it did first in capture. Look at the frontier first (`Reading a failed app replay`); if the failure is the same with the original and a scrubbed copy, record it again in its class: move its directory out of `replays/` (`capture store` skips a test already in the corpus), run `--capture <run> DispatchTests/<Class>` (the class's other tests replay, this one runs live), then replay it alone a few times.
  - 2026-10-13 full capture: TabClose SSH, SSHCompatibility toggles in an open SSH shell, NativeTabClose remote herdr close and SSHProfile tmux control mode with ordinary SSH each needed one or two more captures; the SSHProfile one failed 2 of 5 replays before scrubbing too.

- **Drop recordings that no longer replay**, never silently.

  ```sh
  "$HELPER" capture prune replays/ --dry-run
  "$HELPER" capture prune replays/
  ```

  - Every helper capture replays on that helper; one that fails is dropped. App journals of another protocol version are dropped too (the app reads only its own).
  - The next `--capture` run records those tests again.

## The three checks

- **Helper replay** (fast, Rust): each helper capture runs the current helper against its recording.
  - The helper runs its real event loop; the replay answers each I/O request with the recorded result and fails on any request the recording does not have next (operation, arguments, full write buffers).
  - `--completion required`: the replay must also end the way the recording did (return status, handoff, signal) and consume the whole recording.
  - Captures from macOS replay on Linux and the other way round: the recorded platform facts travel with them, and on replay nothing calls the system (every system call is a System operation, answered as recorded, whatever the OS).
    - A recorded failure keeps its errno as the recording system numbered it. Replayed on the other system it becomes the same error there (`file::recorded`, a table of the errors macOS and Linux number or word differently, from both systems' `<errno.h>` and `strerror`): code that compares errno constants, checks the error kind, or writes the error's text gets what it got in capture (the text keeps the recording system's words and number). Code compares a replayed error's number through `system::errno`, not `raw_os_error`, and copies an error with `system::copy`.
- **App replay** (slower, XCTest): the test runs against its app journal.
  - Requests the app makes must match the recording; inputs (helper replies, terminal output, process exits) come back in recorded order.
    - The app sends independent requests in its own order (a slot limiter sends the next only after an answer): an answer to a request it sent does not wait behind requests recorded earlier that it has not sent yet, even when one read carries both; the answers to those wait until their requests are sent.
  - Observations answer what the recording saw at the app's own progress, not a later or earlier state. A test's step is the test's progress, not the app's: what the app asks on its own (while the test waits for that step, or before the test began that wait) answers past it (up to what the app makes next); the test's own reads and checks see the state as of its next step (SSHReconnect reset in local tmux: the host poll after the reset ran while the test was still in its reset call).
    - Each app task asks in its own order, and capture recorded its asks in that order: a task is never answered from before where it can have been (past the first record of each thing it asked, from where it was before). When work the app has not made yet (the test's next tab mounting) holds the progress before what a task already saw, that task is answered from there on (TabCloseSelection SSH: the launch check that saw the new ssh finds it in its terminal; capture ran that check after the test's next tab). That point never passes the app's progress: a poll that asked something capture asked only later is not held ahead once the app moved on. Tasks that saw nothing newer, and the test's checks, keep the progress rule.
  - A test's waits (`TestSupport.eventually`) continue where the recording's did: the recorded step says where the test checked its condition, and replay holds back what came after that check until the test steps.
    - Capture reads on while a check runs: the check that held may have seen input read while it ran (pty output parsed before the screen was read), or not (a redraw that clears what the test waited for). The step records where that check began and returned (`mark`, `end`). Replay first holds everything from the mark. A check that fails on the settled state twice with nothing reached in between (the app may need a turn to react) frees held input read before `end`: one input, then as many as the window passed so far (a flood read during a slow check comes in a few rounds), until the condition holds. Input read after the check returned never comes before the step (except what a check's own answer was recorded behind, below); a recording without `end` frees nothing.
    - While a check runs, only its own I/O comes past the hold: answers to requests it sends through the app's connections (with what that connection read before them) and inputs of lifetimes it opens. Anything else (another terminal's redraw, the answer to a chat.open the app itself sent meanwhile) waits for the step, so the test continues on the state capture's check saw. A check's own I/O is not the app's progress: a check that reads through the helper and keeps failing still frees what it may have seen. When the connection's next record before such an answer is a request the app has not sent, followed by more than answers (a read with notifications), the app may send that request only after held input (SSHLinux tmux hooks: tmux output relayed from the outer terminal): then what the recording read before that answer comes first, in recorded order, even past `end` (capture's check got its answer only after all of it).
    - **Recordings without `end`** (every recording made before steps carried it) keep the old rules: while a check runs every input comes, and failing checks free nothing. The precise rules apply to a test only after it is recorded again (e.g. SSHHerdr revocation: the screen output its check saw; ChatModelPicker local herdr: chat.history arriving during the check).
  - What a terminal's renderer child hands back (the bytes typed into its pty, read on its slave) comes once the app typed them: replay never types ahead of the test (a test that polls without a step still gets the state its capture saw before it typed).
    - The pty does not change typed bytes, except CR read as NL before it is raw. Replay matches them so: what else the app typed (a pointer report the recording lacks) is passed over.
    - Focus reports (DECSET 1004: `ESC [ I`, `ESC [ O`) follow window key and app activation, which the cases run before in the same process decide: environment, not the test's typing (iso60: five recorded focus hand-backs never came when each class ran alone). Matching ignores them on both sides: a hand-back made only of them waits for nothing, and a typed one never splits a match. The hand-back still comes as recorded, so the app relays to its helper what capture relayed.
    - A test waiting for its step types nothing: then a hand-back of what this run never typed (a report the recording has and this run's screen did not send) goes on.
    - What the app sends the renderer is never compared: its drawing, and its typing beyond these waits.
    - A child capture saw connect just before the app took its tab's view down (the app then closed that connection with the view) is handed over after what took the view down (the tab's close answer): the app refuses it, as live when a child connects late, and hangs up its pty. What capture recorded on that connection (its close, its end) never happens (TabCloseSelection native, SSHCompatibility toggles: fix43).
- **App <-> helper check**: both sides of every connection carried the same bytes.

  ```sh
  "$HELPER" capture check build/captures/<TestFile>/<testName>
  ```

  - Pairs app lifetimes with helper stdio, spawned children with their helpers, socket connects with accepts, hook senders with the hook server's messages (by pid, or by the datagram's bytes).
  - Prints each pair (`equal`, `stopped reading`, or `DIFFERENT from byte N`) and `linked to the app journal: X of Y captures`; exits non-zero on a difference or an unlinked capture.
  - `question 1 answered without a record by the hook server`: a known gap: the hook server answers "does this helper own the asking process" without recording it.

## The capture tool

- **The tool is part of the helper**: `dispatch-helper capture <command>`, only in a helper built with the `capture` feature (Debug builds: `build/helper-rust/bin/<platform>` and the app's bundled `dispatch-helper`).
  - Its replays run the same executable, one process per capture: the tool and the helper it checks are always one build.
  - A helper built without the feature has no `capture` command and refuses to start with `DISPATCH_REPLAY` (it would ignore it and run live, on this machine).

- **Build it** with the helper's Cargo workspace:

  ```sh
  cd helper
  cargo build --offline --package dispatch-helper --features dispatch-helper/capture
  HELPER="$PWD/target/debug/dispatch-helper"
  ```

- Options (`--limit N`, `--output DIR`, `--dry-run`, ...) go anywhere after the command.

- **Read a capture**

  ```sh
  "$HELPER" capture inspect replays/ChatTests/testX/<key>.rpl.zst --limit 200
  "$HELPER" capture inspect replays/ChatTests/testX/<key>.rpl.zst --from 280 --limit 20   # around a replay message's record 290
  "$HELPER" capture value results/000003.mismatch/mismatch.value
  "$HELPER" capture key replays/ChatTests
  "$HELPER" capture diff old/<key>.rpl.zst new/helper-<pid>-<start>.rpl.zst   # or two directories of captures
  ```

  - `inspect` prints one line per record: its number (app replay messages name the same `record N`), milliseconds since the capture started, section, operation, what was asked, then `->` and what came back (`null`, sequence 0 and no error print nothing). A record holding several wire frames prints one line per frame, so `grep` finds a method together with its record. Our own frames print decoded (`request 45 terminals.attach {size: ...}`, `notify 45 terminal.output {...}`, `cancel 45`). A frame split over several reads prints whole on the record where it completes; the reads before it show `response 3 continues (22530 of 65544 bytes)`. A streamed reply prints its chunks as `chunk 3 #0 (65536 bytes)` and the whole message, decoded, with its last frame (`response 3 {...} (streamed)`). Other bytes as text when UTF-8, as the value when they are one of our plain values (a hook question's body), else hex (only bytes nothing here knows the structure of: hashes, random bytes, OS structs, binary files). `--from N` starts at record N. It says `complete` at the footer, or how to see more.
  - A capture without its footer is cut (its process ended mid-write or is still running).
  - `diff` compares two captures on what `inspect` decodes: records aligned on their section and operation (lifetime numbers aside), then each one's sequence, error, frames, fields and values; text and bytes word by word (a terminal escape sequence and a character beyond ASCII are words of their own). The same change anywhere is one group: how often, in how many pairs of captures, and its first place (both files and record numbers, section, operation, `args`/`output` and the path inside: frame, field, list index). Not compared: the clock and the wire version (as `key`). Two directories: the captures of each test directory are paired by their records whatever their names; the rest are listed unpaired. It fails when anything differs. Both sides are read with this helper: recordings of another wire version need their own helper's `inspect` (below).

- **Search** every text and bytes value, keys included (a literal, case-sensitive substring):

  ```sh
  "$HELPER" capture grep '/Users/' replays
  "$HELPER" capture grep 'Authorization' --limit 50 build/captures
  ```

- **Replay helper captures**

  ```sh
  "$HELPER" capture replay replays --completion required --output results/replay-01
  ```

  - `report.jsonl` has one row per capture: `status` (pass, fail, timeout, skip), the replay's exit, its completion receipt, a diagnostic and, on a mismatch, `mismatch` (the expected and actual operation as a value).
  - `skip` means the capture has nothing to replay (empty: its helper ended before recording anything) or no supported entry.

- **Store, prune, check, scrub**: `store STAGE REPLAYS --tests DispatchTests`, `prune REPLAYS [--dry-run]`, `check PATH...` (above), `grep PATH... --needles FILE [--jobs N]` and `replace DIR OUT [--needles FILE] [--ips] [--uuids] [--jobs N]` (needles: one per line, optional TAB and replacement; [capture_scrub.md](capture_scrub.md)).

## Reading a failed app replay

- **Stall** ("no recorded event was reached for X while the app was idle (capture reached it after Y)"): idle (the main queue, and every queue the journal feeds, answers within a second: replay hands input over at once, and a helper connection still decoding that burst holds what the app sends after it; mix47 HerdrTests large session; and no live work runs, `AppReplay.live`) for 4x the time capture took from the record before the frontier to the frontier, at least 3 seconds (the app's own wall-time timers overlap recorded activity in capture). A slow screen took long in capture too; an answer replay holds back took moments. Once only the journal's own closing records are left (the ids made, finish), nothing is owed: the case's end judges what remains. Printed with:
  - `frontier`: the first record replay is waiting for. An `open.*` or `out.*` there is something the app never did; an `in.*` is an input nobody listened for; an `in.slave.read` is typing the app never did (its lifetime line shows what it typed instead); an `open.step` names the test's wait (its source line in the recording). `record N` is the number `inspect` prints.
  - `recent`: the last records replay consumed.
  - `stale observation`: an observation answered with an older recorded value than the newest one (it shows which record the app's progress pointed at).
  - one line per lifetime with its next record and what the app waits for there; `typed`: what the app typed into a renderer that no hand-back took yet; `held`: why its next input waits for the app's own state (a pty size: `the app's pty is 31x42; recorded 32x42, later 30x42`: the app's layout gave the pane another size than capture's). Once the app hangs up or closes that pty, or asks its helper to close the terminal it shows, nothing holds there anymore: a closing view gets no more layout. While its view is in a window, a gate holds everything recorded after it: what follows can move the view away before its layout reaches that size (mix53: a herdr launch's release reply selected the new space before the launcher's view got the sidebar's width). While its view is in no window (it gets no layout there), what it holds waits without holding the other lifetimes (`held: ... (in no window: the others go on)`): a redraw drawn at the stale size would be lost when the view shrinks back (an alternate screen does not reflow; mix46 herdr+tmux coexist). A size capture's layout passed through for a moment that replay's never produces (mix49 repeated detach: 146 columns, the sidebar hidden during a detach) still holds: such a moment is a flash on screen, found and fixed in the app. As a last resort, when replay would otherwise stall with nothing but such sizes holding input (the app's layout went another way: the herdr launcher left the window before the sidebar's width reached it), those inputs come at the app's size and the test's relaxed list names them ("size not reached on lifetime N: ..."); a passing replay never gets there.
- **Mismatch** ("expected X, received Y"): the app did something else than the recording at that point. The two events are written to `build/replay-diagnostics/<test>-<journal>.mismatch-<id>.rpl.zst` (`capture inspect` reads it); the message names the file.
- **"made ids differently"**: a site made another number of ids than in the recording; later ids from that site shift. Usually the symptom of an earlier divergence, not its cause.
- **"relaxed"**: requests replay answered or dropped because UI timing differed from the recording (listed, not a failure by itself).
  - "after its end X": the app closed its side of a connection (or pty channel), or sent it request X, after replay had already delivered its recorded end and before its transport's queue took that end; capture's transport had stopped first and recorded nothing. Nothing answers such a request (nothing could take the answer).
  - "size not reached on lifetime N: ...": replay was about to stall on a pty size the app's layout never gave that view; its held input came at the app's size (see the stall bullet).
  - "answered X" / "unrecorded X": the app sent X and the recording lacks it; replay gave the recording's answer when unambiguous, else "unavailable". "unanswered X": an equal X the app sent earlier is still open in the recording (neither answered nor cancelled yet: a chat.open the app refreshed); the helper is still answering that one, so the new one gets no answer, as in capture, which never sent it (ChatModelPicker queued revocation: an agent.changed just before the step starts a reopen; in capture the test's revocation came first and made it moot).
  - "unsent X": the recording has X, the app never sent it: X was still unanswered when the app closed that connection, or X changed nothing on the helper (the app cancelled it before anything came back, or the helper refused it at once). Such an X holds no later record; sent late, it still gets its recorded refusal. Sent after replay already reached that refusal and after every input recorded before an equal later request came (or waits only behind another request of that connection the app has not sent yet: its requests go out in any order), it is that later one (the app sent it after what followed the refusal, e.g. the agent.changed that let the next chat.open through) and X stays unsent. Equal requests go out in order: an X the app went past that way stays unsent for good, and an equal request it sends much later is a later one (SSHLinuxPi tmux: the chat.open after /new).
- A replay that passes prints "App replay verified: <test> (longest wait <idle>, capture <gap>)": of the idle times that ended with a record reached, the one furthest beyond 4x what capture took for that record. The stall bound is measured against these.

## When a recording changed

After an app or helper change (or an upstream merge) a replay that fails says: this test now does something else than it recorded. Decide quickly whether that is the change you meant or a bug, then either record the test again or fix the code and replay the old recording again (seconds).

- **Keep the old side.** Before a protocol change or a merge, copy `replays/` and the helper built from the old checkout (with `capture`) outside the checkout: recordings of another protocol version decode only with their own helper's tool.
- **Start at the first difference the replay names** ([Reading a failed app replay](#reading-a-failed-app-replay); for a helper capture, `mismatch` in `report.jsonl`), and read the recording around it:

  ```sh
  "$HELPER" capture inspect replays/ChatTests/testX/<key>.rpl.zst --from 280 --limit 40   # record 300 named by the failure
  ```

- **Compare the old recording with a new one** of the same test (`--capture` it live, then find its file in `build/captures/<TestFile>/<testName>/`): `"$HELPER" capture diff old/<key>.rpl.zst new/<file>.rpl.zst` (ids, pids and uuids that differ in every run show as changes, grouped). Recorded with another wire version (a merge changed the protocol), each side needs its own helper's `inspect`; numbers that differ in every run (record numbers, times, lifetimes, request ids, pids, uuids) are masked so only real differences remain:

  ```sh
  norm() { "$1" capture inspect "$2" --limit 100000000 | sed -E 's/^[0-9]+ [0-9.]+ //; s#app/[0-9]+#app/L#g;
    s/(request|response|notify|cancel) [0-9]+/\1 N/g; s/[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/UUID/g; s/[0-9]{4,}/N/g'; }
  diff <(norm "$OLD_HELPER" old/<key>.rpl.zst) <(norm "$HELPER" new/<file>.rpl.zst) | head -100
  ```

  - The first block that differs is usually the cause; the rest follows from it. Terminal bytes are split differently in every run: compare what a stream carried, not where reads split it.
  - Compare the app's own log lines of both runs (the XCTest output of that test) too: they show which code path it took.
- **Intended change**: delete the test's old recording and keep the new one (`--capture`, then `--replay` it once). **Not intended**: fix the code and replay the old recording again until it passes; no live run needed.
- **Many tests changed the same way** (one shared request, a renamed field): fix or accept that one cause first, then replay all again; most of the other failures go with it.

## Investigating a test that fails live sometimes

A test that fails only now and then is a race in the app or the test, often one users can hit too. A recording turns it into a repeatable failure:

- **Keep the failing run's recordings.** Run with `--capture`: `build/captures/` keeps every test's journal and helper captures, failed ones included.
- **Reproduce it.** `python3 test/xcode.py --replay DispatchTests/Class/testName` replays the failed test from its own journal: the app gets the same inputs in the same order, so it takes the same path and fails the same way, every time.
- **Find the difference.** Compare with a passing recording of the same test (an earlier capture you moved away, or `replays/`):
  - `capture inspect` both journals; the terminal output, the app's requests (`out.wire request N method {...}`) and the files it consumed show where the runs part. Terminal bytes are split differently in every run: compare what a stream carried, not how it was chunked.
  - The app's own log lines of both runs (the XCTest output) show which code path it took.
- **Ask the app why.** Add log lines around the suspected decision, rebuild and replay the failed recording again. Log lines change nothing the app sends or asks, so the recording still applies: the replay prints the reason in seconds instead of waiting for the race to happen again live.
  - A fix that makes the app ask the outside world something new (another process query, another file read) gets "unknown" from an old recording: confirm it with live runs and record anew.
- Example: ssh typed in a terminal sometimes hung. Replaying the failing recording showed the launch request was refused because the process probe took ssh's own forked ControlPersist master (same process group) for the user's ssh.

## Writing tests that replay

- I/O goes through `System` (`observe`, `act`, `run`, `sleep`, `pty`): whatever bypasses it is invisible to the journal and makes replay diverge.
- Facts about the machine come from `System` too: `home`, `temporary`, `checkout`, `bundle`, `executable`, `resources`, `environment(name)`, `inherited`, `path`, `machine` (recorded: the account's name, own home, shell and quiet login, the machine's name and memory; `machine.launch` is what the terminal engine reads of the machine, handed in from here: its `Session` checks OSC 7 folder reports against the name), `pid` and `uid` (this process's, recorded), `resolve(url)` (a link resolved is a disk read).
  - While testing they name paths in the run's private root (`/tmp/dt-journal`): the test home, `tmp/`, and `checkout`, the runner's link to the checkout (the bundle is seen through it). These are the same on every Mac, so recordings replay from any checkout and account.
  - `test/xcode.py` refuses to run when app, test or terminal engine sources read them directly (`ProcessInfo...environment`, `NSHomeDirectory()`, `temporaryDirectory`, `Bundle.main` paths, `NSUserName()`, `resolvingSymlinksInPath`, `#filePath` as a path, `gethostname`, `physicalMemory`, `processInfo.hostName`, `getpwuid`, `Machine.current`) outside `System.swift`, `AppReplay.swift` and the engine's standalone parts, and lists the lines.
  - A fact read live where a recorded one meets it breaks replay on any other Mac, and after scrubbing on this one: the engine compared the recorded OSC 7 host (the shell's report) with the live `gethostname()`, so a scrubbed host name, or another Mac's, dropped every folder report (TerminalIntegration real shell, scrubbed corpus).
  - Configuration that exists only on the recording machine (the Linux host profile, the account name) is read through `System` (`read`, `exists`, `machine`): replay answers the recorded values.
  - So is a bundled file whose content reaches what the app sends: the SSH helper's digest and size name its remote cache path in every bootstrap command, so they are observed (`payload`). A rebuilt helper then changes no recording. A test that names that cache path or compares its bytes asks the same observation (SSHTransportTests' `BootstrapFixture.payload`), never the bundled file itself: a rebuilt helper would move its path off the recording.
- Wait with `TestSupport.eventually` (or helpers built on it), never a bare sleep for I/O: its step is where replay continues the test.
  - Wait for everything the next action depends on, not only what the screen shows: a prompt sent before its chat's history arrived names no conversation, by timing.
  - A test's own I/O that is not recorded (an in-process pipe) has no order against recorded events (a replayed timer ends at once): wait for it with a step before what it races.
  - Work a test does live on purpose, in replay too (real shells running the app's wrappers: NativeSSHEnvironmentTests), runs inside `AppReplay.live`: the journal does not see it, and without it the watchdog calls the app idle while it runs (mix52: a shell that took 3 s once). A test runs a process to its end with `TestSupport.live` (inside `AppReplay.live`) and starts one beside it with `TestSupport.start`; one whose result the recording depends on is recorded instead (`System.run`, `System.Child`, `TestSupport.fixture`, so replay starts nothing). `test/xcode.py` refuses `.run()` or `.waitUntilExit()` in test sources outside TestSupport and lists the lines.
  - A fake the app awaits in place of remote work (`SSHStatisticsStoreTests.Provider`'s `sample`) takes its time through `System.sleep`, never `Task.sleep`, as the helper round trip it stands in for is recorded. On wall time two providers' calls end in another order in replay, and identical timers (each provider's next `metrics` wait) take their recorded wakes in recorded order: one account's 20 ms loop got another's 15 s timer and never sampled again (mix42b).
  - A wait does not end while the sidebar slides (`TestSupport.eventually` also checks no split's `sidebarAnimating`): the slide runs on wall time, so layout read or changed during it differs between runs.
  - What a wait's condition asks the outside world (a fixture's `tmux list-panes`, any query made while `System.polling`) is a read, asked as often as the test checks: replay answers it with what capture saw as far as the app got, never by count, and the wait's recorded asks are not owed. How often a test checks is wall time (a check refuses while the sidebar slides): counted, the HostNative host-move test ran out of recorded asks in most replays.
  - Fixture code that does real file work in replay (copying helper resources into a test server's root) must not rely on its recorded cleanup: replay answers the cleanup from the recording, so the next replay of the same recording finds the leftovers.
- Every `System.sleep` (and `SSHTimeout.run`) names its timer (`System.sleep(for: interval, "poll")`): a recording knows it by file and name, so editing other lines of the file keeps the recordings that use it (a line number did not: one added line above a polling timer failed every test that polls).
- In the app, a timer that bounds I/O (`SSHTimeout`) sleeps through `System.sleep`: a replay times out exactly where its capture did, never on its own clock. A sleep the capture's caller cancelled (the operation finished first) ends in replay only when its caller cancels it: its recorded cancellation holds nothing and reaches no one (identical timers running at once cannot take each other's).
- A race the app decides between its own work and what a helper reports (a queued attach whose tab may have moved on) is recorded where it is decided (`System.observe("bound", terminal)`): the app then sends what its capture sent. Values the app reads from its layout into a request are not decisions to record: a request's `size` is never compared (geometry follows drawing), and screen publications and resizes are acknowledged by replay itself. A request the recording lacks points at such an unrecorded decision.
- An order the app waits for so that identical requests go out alike (a chat setup's launches.list after its helper's discovery) must not wait for anything a stop waits for: a test's next case can start while the previous one still stops, and a helper made then discovers only after that stop, which waits for the setups turning integrations off (a deadlock, live too). Check such a change with a full run: a test run alone never starts during a stop.
- Work that must not depend on when SwiftUI renders follows the model instead: a shown tab's terminal is created at the layout commit (`HelperWorkspace.present`), a terminal view attaches only to a host whose container is in a window, and a split keeps its divider share (resizes never re-derive it from rounded frames).
- Ids come from `System.uuid()`: replay makes the same ones per site.
- End helpers by closing their stdin (EOF). A stdio helper still running when the app's grace ends gets SIGTERM and finishes its capture before it exits; SIGKILL loses the rows it had not written yet. At EOF a stdio helper also ends the control streams its client fed, so a tmux command waiting on one fails instead of keeping the helper alive.
- A test should not depend on state an earlier test left behind: each journal replays alone.
  - Every case starts from the same app state (`TestSupport.isolate`): process-wide caches that decide what the app asks its helpers (the host backend cache, the chat's launches and integration facts) are emptied at each case's start, and every integration is turned off (`TestSupport.launches`), so a recording does not depend on which cases ran before it. A case that tests an integration turns it on itself (`TestSupport.integrations`). Off, not "nothing turned off": installed hooks stay in the test account between cases (the helper keeps a turn-off only while it runs), so nothing turned off would mean on by accident; a fixture's restore used to leave every integration off on the shared chat, and recordings made after one replayed only after such a case (mix54/mix57). The app is active (each case activates it): cases activate it and nothing undoes that, while the app polls space branches, reports terminal focus and holds attention back only while active (SpaceBranch sidebar modes failed alone, iso63). Integrations a case turns on (`TestSupport.integrations`) and leaves on are turned off at its end, after the runtime stop the case began (if any) ended: turned off during that stop, they would reach the stopping helper or start a new one, by timing; TestState reports any other change a case leaves behind.
  - Every case ends with the same teardown whether it replays, records or runs live: the app runtime stops and its shutdown work (launch mailboxes, SSH masters, helpers) finishes inside the case, never in the next one's journal.
