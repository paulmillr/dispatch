# json benchmark results: Rust port vs yyjson 0.12.0

Produced by `core/benches/json.bench.rs` at commit 32d9b55 (8a3faa7 for the repository classes).
The bench and the yyjson oracle it compares against were removed afterwards; see Reproduce.

## Machine

- CPU: Intel Xeon E5-2689 v4 @ 3.10GHz (Broadwell, AVX2 path used), 18 cores visible
- Target: x86_64-unknown-linux-gnu, rustc 1.100.0-nightly (67854e511 2026-08-15), bench profile
  (= release: lto, codegen-units 1)
- yyjson: unchanged `Vendor/yyjson` 0.12.0, built by `core/json-oracle/build.rs` (removed) with
  `cc -std=c99 -O3` (Debian gcc 14.2.0)
- Load: shared machine, load average 26-31 on 18 cores during the runs. Wall-clock times were
  not reproducible under this load (the same class moved 2x between runs), hence thread CPU
  time below. Expect absolute MB/s to be higher on an idle machine; the ratios are what is
  compared.

## Method

- Same inputs to both libraries. Before timing, every class checks that both produce
  identical bytes for: compact and PrettySorted writes of every document, json::write of
  every rebuilt Data tree, json::write of every string. The bench aborts on any difference.
- Each measurement alternates ours / yyjson runs (so load changes hit both), 31 runs per
  side. A run repeats the whole class until it used 20 ms of thread CPU time
  (`clock_gettime(CLOCK_THREAD_CPUTIME_ID)`).
- MB/s = input bytes of the class / median run time. `x` = median of the per-run ratios
  yyjson time / ours: above 1 means the Rust port is faster.
- Columns:
  - parse: `Json::parse` of every document
  - compact: `Value::write()` of every parsed document (compact)
  - pretty: `Value::write_with(Format::PrettySorted)`. The yyjson side is the former core
    path (yyjson mutable document + Foundation post-processing).
  - data tree: `json::write(&Data)` of a Data tree rebuilt from every document (code-built
    trees are ~99.7% of write calls in helper4's own test replays)
  - strings: `json::write(&Data::String(s))` for every string of the class, keys included
    (the `wire::string` / `encode.rs` path). The MB/s figure uses the class's input bytes,
    so only `x` is meaningful in this column.

## Results (two consecutive runs)

| class | bytes | docs | parse x | compact x | pretty x | data tree x | strings x |
|---|---:|---:|---:|---:|---:|---:|---:|
| small messages | 194059 | 153 | 1.00 / 0.99 | 0.85 / 0.82 | 3.39 / 3.37 | 1.44 / 1.39 | 1.46 / 1.42 |
| transcripts | 1356929 | 1654 | 1.09 / 1.10 | 0.99 / 0.97 | 3.25 / 3.18 | 1.34 / 1.29 | 1.43 / 1.43 |
| number-heavy | 518086 | 8 | 1.05 / 1.05 | 0.79 / 0.83 | 4.46 / 4.50 | 1.54 / 1.55 | 1.36 / 1.36 |
| string-heavy | 7337010 | 275 | 2.83 / 2.86 | 1.73 / 1.86 | 15.39 / 15.16 | 3.64 / 3.44 | 2.82 / 2.80 |
| non-ASCII | 14243 | 1 | 0.88 / 0.92 | 1.94 / 1.86 | 4.64 / 4.68 | 1.84 / 1.92 | 1.48 / 1.48 |

MB/s, first run (ours / yyjson):

| class | parse | compact | pretty | data tree | strings |
|---|---|---|---|---|---|
| small messages | 935 / 938 | 1192 / 1431 | 257 / 77 | 405 / 285 | 115 / 79 |
| transcripts | 885 / 805 | 916 / 951 | 227 / 72 | 345 / 253 | 129 / 89 |
| number-heavy | 264 / 252 | 298 / 377 | 135 / 30 | 190 / 124 | 32120 / 23159 |
| string-heavy | 4110 / 1452 | 6471 / 3732 | 4373 / 284 | 4450 / 1218 | 3498 / 1271 |
| non-ASCII | 1007 / 1173 | 1877 / 976 | 769 / 158 | 1198 / 651 | 398 / 273 |

Below 1: compact write of parsed values for small and number-heavy documents (parsed-value
writes are ~0.2% of write calls in helper4's test replays), and parse of the non-ASCII
fixture (one 14 KB document of escape-dense terminal text). No large or CJK-heavy real
transcripts were available to measure.

## Private local transcript (not included)

One real Codex rollout from the author's machine: 989,236,774 bytes, 64,535 lines (largest
line 4.08 MB). Private local transcript, not included; only numbers are reported.

Same bench, `JSON_BENCH_FILE=<path>` (lines measured in 64 MB batches so memory stays
bounded; `x` = total yyjson time / total ours over the batches):

| class | bytes | lines | parse x | compact x | pretty x | data tree x | strings x |
|---|---:|---:|---:|---:|---:|---:|---:|
| private transcript | 989172239 | 64535 | 2.02 | 1.59 | 6.24 | 2.43 | 1.91 |

MB/s (ours / yyjson): parse 2638 / 1308, compact 3154 / 1982, pretty 1331 / 213,
data tree 2143 / 882, strings 1349 / 706.

### End to end: the Codex harness reading that transcript

The Codex harness transcript reader (`Codex::read` -> paging reader -> history page parser,
streaming over the file and skipping most records), from the codex part's current code
(dda9c02), built twice in release (lto) with the same code: once on the yyjson core, once on
this Rust json. Driven by real `System` io (2 workers) in a small driver outside the
repository. Process CPU time; 5 rounds alternating the two builds; each round reads the
first page and then every earlier page until none is left (442 pages). Both builds produced
identical pages and state on every round (digest compared).

| measure (median of 5 rounds) | yyjson core | Rust json | x |
|---|---:|---:|---:|
| first page | 154.2 ms | 117.7 ms | 1.31 |
| earlier page (median page) | 71.4 ms | 61.5 ms | 1.16 |
| full scan, 442 pages | 34.2 s | 29.2 s | 1.17 |

The live path (app-server notifications) is not exercised by a transcript read.

## Inputs (repository files; JSONL files are split into lines, others are one document)

- small messages: `core/tests/fixtures/json/native.jsonl`, `core/tests/fixtures/json/rpc.jsonl`,
  `harnesses/nanocodex/tests/fixtures/nanocodex-master-755b23cc-notifications.jsonl`
- transcripts: `harnesses/codex/tests/fixtures/codex-0.159.2-history-60.jsonl`,
  `core/src/system/file/fixtures/claude.jsonl`,
  `harnesses/nanocodex/tests/fixtures/nanocodex-master-755b23cc-paging-rollout.jsonl`,
  `harnesses/pi/tests/fixtures/paging/paging.jsonl`
- number-heavy: `harnesses/nanocodex/tests/fixtures/nanocodex-master-755b23cc-journal-chunks.jsonl`
- string-heavy: `plugins/files/tests/fixtures/wire/expected.json`,
  `plugins/stats/tests/fixtures/process-names/wire/system.jsonl`
- non-ASCII: `harnesses/claude/tests/fixtures/2.1.286/readiness/records.json`

(paths relative to `Helpers/helper4/`)

## Reproduce

From `Helpers/helper4/`, with a C compiler available (only the yyjson side needs it):

```
cargo bench -p dispatch-helper4-core --bench json
```

Optional filter: `cargo bench -p dispatch-helper4-core --bench json -- <class substring>
[parse|compact|pretty|tree|strings]`. A local JSONL file outside the repository:
`JSON_BENCH_FILE=<path> cargo bench -p dispatch-helper4-core --bench json -- local`.

The bench and its yyjson side (the temporary `core/json-oracle` dev-dependency) are no longer
in the tree. To reproduce the comparison, check out 32d9b55 (or 8a3faa7 for the repository
classes only) and run the command above there.
