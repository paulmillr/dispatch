# Primitive test vectors

Third-party test data for `ChaCha20Tests`, `Poly1305Tests` and `ChaChaPolyDifferentialTests`, loaded by
`VectorFiles.swift`. Test-only: not built into the engine or the app. Every file is copied unchanged, byte for byte,
so it can be compared with its upstream; `VectorFiles` refuses a file whose SHA-256 is not the one below.

| File | SHA-256 |
| --- | --- |
| `stablelib_chacha20.json` | `8dc3b66cb5b20d3247b6020866f1938a23bfb01d1aefaf74a58f31b0eedc3113` |
| `stablelib_poly1305.json` | `d4d434d82ed36b4a4acc15485a14291cbecbf02aed67e5b3b013e648158041d6` |
| `stablelib_chacha20poly1305.json` | `5b9752192bb80df28929411be425cd01b38c7e392eeebc127f2eb26e6e26e228` |
| `chacha20_poly1305_test.json` | `fe61d25f90e1bde4461d00eafe61049e5f29bd999f36b766df9cda90906ad53d` |

## StableLib vectors, from noble-ciphers

`stablelib_chacha20.json` (5 ChaCha20 streams, original layout: 8-byte nonce, from block 0),
`stablelib_poly1305.json` (32 Poly1305 vectors) and `stablelib_chacha20poly1305.json` (67 RFC 8439 AEAD vectors,
`result` = ciphertext ‖ tag) are `test/vectors/` of @noble/ciphers 2.4.0, commit
`fe4336756e8b352ea520d8bd6e8547552e352189` (https://github.com/paulmillr/noble-ciphers). noble-ciphers names
StableLib (https://github.com/StableLib/stablelib) as their upstream in the file names.

Licence: MIT. noble-ciphers: copyright 2022 Paul Miller, 2016 Thomas Pornin; its licence, as published at that
commit, is `LICENSE-noble-ciphers.txt`. StableLib: MIT, copyright 2016 Dmitry Chestnykh.

`ChaCha20Tests.testLibsodiumStreamCarriesIntoTheHighCounterWord` also takes one expected value, as a Swift literal,
from that commit's `test/arx.test.ts` ("counter oracles", "chacha20orig: libsodium raw stream carries into the high
32 bits"): libsodium's output, pinned there.

## Wycheproof

`chacha20_poly1305_test.json` (325 AEAD tests, `aead_test_schema_v1.json`) is
`testvectors_v1/chacha20_poly1305_test.json` of Project Wycheproof (https://github.com/C2SP/wycheproof) at commit
`65ca494727a52944c204441c860b039e6786b99b` (the file last changed in `e0df04e0c033f2d25c5051dd06230336c7822358`; git
blob `1ad9ff254d1f26f0812a27135fe95769f34adba5`).

Licence: Apache License 2.0; the repository's `LICENSE` at that commit is `LICENSE-wycheproof.txt`. The repository has
no `NOTICE` file.
