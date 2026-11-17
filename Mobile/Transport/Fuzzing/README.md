# SSHEngine fuzzing

This separate Swift package keeps the libFuzzer entry points, unsafe compiler flags and runtime out of
`Mobile/Transport`'s normal build and test graph. It covers:

- `fuzz-client-initial`: `ClientCore` from the identification byte onward;
- `fuzz-client-post-kex`: authenticated payloads after deterministic AES-128-GCM keys, across authentication and
  channel phases;
- `fuzz-messages`, `fuzz-key-blobs`, and `fuzz-signatures`: the wire decoders and their canonical round trips;
- `fuzz-key-files`: PEM armor, PKCS#8/PKCS#1/SEC1 DER, and `openssh-key-v1`, with bcrypt capped at four rounds.

`run.sh` generates corpora in `build/ssh-fuzz-corpora`. Message and phase seeds come from
`Tests/SSHEngineTests/Robustness` and `Wire/MutationTests.swift`; key-file seeds are fictional, temporary keys made in
the same way as the key-file tests. No generated private key is kept in the checkout.

## Toolchain and running

The verified macOS toolchain is Apple Swift 6.4 from Xcode 27.2 with AddressSanitizer and sanitizer coverage, plus
Homebrew LLVM 22.1.8's arm64 `libclang_rt.fuzzer_osx.a`. Swift emits modern inline counters and PC tables; the
runtime links to macOS's libc++. Install `llvm@22`, or set `FUZZER_LLVM_ROOT`/`FUZZER_RUNTIME`.

From this directory:

```sh
./run.sh fuzz-messages -max_total_time=60
./run.sh all -runs=10000
```

Inputs and crashes stay below `build/` by default. `SSHENGINE_FUZZ_BUILD`, `SSHENGINE_FUZZ_CORPORA`, and
`SSHENGINE_FUZZ_ARTIFACTS` override those paths. A run fails on a trap, sanitizer finding, ten-second input timeout,
limit assertion, non-`SSHError` core end, duplicate end, or event after the end.

The fuzz-package-only regression tests run with:

```sh
swift test --scratch-path ../../../build/spm-ssh-fuzz-tests \
  -Xswiftc -DSSHENGINE_FUZZING
```

## Verification run

On 2026-11-17, a fresh generated corpus completed 10,000 executions per target under the toolchain above with no
crash, hang, AddressSanitizer report, limit assertion, or untyped/duplicate end. `cov` is libFuzzer's raw covered-edge
counter and `ft` is its feature count; neither is a source-line percentage.

| Target | Executions | `cov` | `ft` |
| --- | ---: | ---: | ---: |
| `fuzz-client-initial` | 10,000 | 935 | 1,469 |
| `fuzz-client-post-kex` | 10,000 | 1,891 | 3,226 |
| `fuzz-messages` | 10,000 | 500 | 940 |
| `fuzz-key-blobs` | 10,000 | 197 | 282 |
| `fuzz-signatures` | 10,000 | 198 | 427 |
| `fuzz-key-files` | 10,000 | 1,286 | 2,240 |

The first post-key-exchange smoke run found a checked integer narrowing in the harness's UInt32 encoder. The encoder
now truncates each shifted byte deliberately, and `SSHEngineFuzzingTests` retains selectors 4 and 5 as the regression.
It was a harness defect, not an engine or protocol defect.
