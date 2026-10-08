# Replay fixtures

One file per test case, `<Class>.<test>.json`. Each holds the exchange between the app and the helper,
extracted from time slices around passing cases in a shared-helper end-to-end run. These slices are historical candidates: fresh per-case captures are required to verify attribution. The format is the
decoded HelperClient fixture form (see ../HelperClient/Fixtures/provenance.md; this file has its own name because test resources share one folder). One addition: every
helper message has `after`, the number of app requests the helper had received before sending it.

A replay run sets DISPATCH_TEST_REPLAY=1 (TEST_RUNNER_DISPATCH_TEST_REPLAY for xcodebuild). Each case's helper is
then `scripts/replay-helper.py` playing that case's file:
- It answers each request as recorded.
- It fails the case on a request the recording lacks, or on a recorded request the app never made.

How the files were made:
- Source: the RAW helper capture slice of the case. Decoding a scrubbed capture can be wrong, because masks change bytes inside binary frames.
- Command: `scripts/capture-helper-wire.py --source <slice> --hello-from <the helper's whole capture> --codec <that build's HelperBinary.py>`.
  - `--hello-from` matters when the helper was shared by several cases: the slice then starts mid-session, and this puts the helper's hello first.
- The output is written through `scripts/redact.py`, and `Helpers/helper4/tools/private.py --check` finds nothing.

| fixture | app commit, schema | source_sha256 (raw slice) |
| --- | --- | --- |
| ChatComposerTests.testComposer4aNarrowWrappingScrollingThemesAndEditorIdentity | 1b591169, 9405033819973544973 | 785a90d3657322ecc7bdb8ca1aef8e7af7c36c075f72489cbd0fe6ae73ddca09 |
| ChatComposerTests.testUnreadActivityFollowsMountedTabsAndSpaces | 1b591169, 9405033819973544973 | 5aea09aad19b5d4cccd32dbd1907313b647c46942ee06a298a1a117d89411066 |
| ChatHistoryTests.testToolDenseInitialHistoryIncludesMoreRepliesWhileEarlierPagesStayBounded | 1b591169, 9405033819973544973 | 42f4388a377d63ba1a61226798f892bec1c6f5ee3f966294e601c4d7dbe6b073 |

Tool-dense history: raw passing run137 case slice39975, decoded with its captured codec and whole helper hello; 6 requests/6 replies. Explicit machine patterns used for canonical scrub/check; independent local leak check passed. Fixture SHA256 `bc81d53e3e96cce37bf52fd07711242bb91d820ea7939f1cdcb9b9577671719f`. The earlier 10s PASS on b9eb5e0c + patch a676f84a did not select the player: fixture lookup incorrectly assumed XCTest identifiers always include a module. It is not replay verification. After identifier normalization on 7a0b3b73 + capture patch d35b6af7, actual playback failed in15s: chat.open was unexpected and recorded chat.page requests were missing. Preserve this candidate until a fresh whole-session recording replaces it.

The same normalized-identifier check failed both Composer candidates with no player report. The wrapping case uses a disabled coordinator and makes no helper calls; shared-helper slice attribution is therefore unverified. Passing ordinary tests and absence of mismatch text do not prove replay. Require actual player completion (`Replay verified: <fixture>.json`) before counting a fixture as green. Whole-session capture mode records independent startup through observed exit and retains raw originals on the Mac.
