# Third-party notices

## Ghostty

Dispatch bundles Ghostty's unmodified shell-integration resources and themes from Ghostty
commit 31bdcd5a79639bbac97c1a94e0f41d0f5ff84ca2, vendored in
`Vendor/Term/Resources` (see `Vendor/Term/Resources/PROVENANCE.md`).
The themes are generated from iTerm2-Color-Schemes
(https://github.com/mbadolato/iTerm2-Color-Schemes), also under the MIT license.
Ghostty is copyright its contributors and distributed under the MIT license.
See `ThirdPartyLicenses/Ghostty-MIT.txt` and the copy included in the app's
Ghostty resource directory. Source: https://github.com/ghostty-org/ghostty.

## Swift terminal

`Vendor/Term` is a Swift port of the parts of Ghostty that Dispatch uses (terminal
emulation, input encoding, search, the renderer and its Metal shaders, config and theme
parsing, process and shell-integration setup), following that same revision. It is derived from Ghostty (MIT license; see
`ThirdPartyLicenses/Ghostty-MIT.txt`). It bundles JetBrains Mono (SIL Open Font License
1.1) and Symbols Nerd Font (MIT); their notices are next to the fonts in
`Vendor/Term/Sources/TermApple/Resources/`. `Vendor/Term/tables` generates its tables from
excerpts of Ghostty's sources and the output of a patched Ghostty (MIT; see
`Vendor/Term/tables/inputs/PROVENANCE.md`).

## AppKit input adapter

`Dispatch/Terminal/TerminalView+Input.swift` adapts the keyboard, mouse, and IME
adapter from the previous Dispatch attempt. That adapter credits agterm
(https://github.com/umputun/agterm), copyright 2026 Umputun, and macterm
(https://github.com/thdxg/macterm). Both use the MIT license. Their license
texts are in `ThirdPartyLicenses/` and bundled with the app.

## Bundled fonts

Source Code Pro (Adobe) and 0xProto (0xType) are redistributed under the SIL Open
Font License 1.1. Their original notices are included in
`ThirdPartyLicenses/SourceCodePro-OFL.txt` and `ThirdPartyLicenses/0xProto-OFL.txt`.
Source Code Pro is an unmodified copy from the user-provided distribution.
0xProto is an unmodified copy of the 2.502 release:
https://github.com/0xType/0xProto/releases/tag/2.502.

Departure Mono 1.500 (Helena Zhang), Ioskeley Mono Term 2.1.0 (Ahmed Hatem),
and JetBrains Mono 2.304 (The JetBrains Mono Project Authors) are bundled
under the SIL Open Font License 1.1. Their original notices are in
`ThirdPartyLicenses/DepartureMono-OFL.txt`, `ThirdPartyLicenses/IoskeleyMono-OFL.txt`,
and `ThirdPartyLicenses/JetBrainsMono-OFL.txt`. Departure Mono and JetBrains Mono
are unmodified. Ioskeley uses the normal-width, unhinted terminal build, subset with
fontTools 4.60.2 to JetBrains Mono 2.304's characters plus arrows, geometric shapes,
Ѐ ѐ Ѝ ѝ and the status symbols command-line tools print (checks, stars, suits, media
controls, circled numbers, currency, sub/superscripts, fractions), without the ranges
the terminal draws itself (box drawing, blocks, Braille, Powerline, legacy computing),
the opt-in language ligature sets and glyph names; kept glyphs, metrics and features
are unchanged:

```sh
python3 -c '
import sys; from fontTools.ttLib import TTFont
u, j = (set(TTFont(p).getBestCmap()) for p in sys.argv[1:])
inr = lambda c, rs: any(a <= c <= b for a, b in rs)
keep = [(0x2190,0x21FF),(0x25A0,0x25FF),(0x27F0,0x27FF),(0x2900,0x297F),(0x400,0x400),(0x40D,0x40D),(0x450,0x450),(0x45D,0x45D)]
drawn = [(0x2500,0x259F),(0x25E2,0x25E5),(0x25F8,0x25FA),(0x25FF,0x25FF),(0x2800,0x28FF),(0xE0B0,0xE0BF),(0xE0D2,0xE0D2),(0xE0D4,0xE0D4),(0xF5D0,0xF60D)]
symbols = "✔✘✖☐☑☒❌★☆✦✧✱✲✳✴✷✸✹✺❇❈❉❊❋♥♡♠♤♣♧♦♢❤⚙⚑⚐☀☹☺☻⚛⚪⚫⚬⛭♩♪♫♬♮☜☝☞☟➡➢➣➤➥➦➧⬅⬆⬇⬈⬉⬊⬋⬌⬍①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳⓪❶❷❸❹❺❻❼❽❾❿➀➁➂➃➄➅➆➇➈➉➊➋➌➍➎➏➐➑➒➓⏏⏩⏪⏫⏬⏭⏮⏯⏰⏱⏲⏳⏴⏵⏶⏷⏸⏹⏺⌚⌛⌧⎈⎇₡₣₤₥₦₧₨₩₪₭₯₱₲₳₵₸₹₺₼₾⁻⁽⁾ⁱⁿ₊₋₌₍₎ₐₑₒₓₔₕₖₗₘₙₚₛₜ⅓⅔⅕⅖⅗⅘⅙⅚⅛⅜⅝⅞⅐⅑⅒↉℃℉℗℠ℹ℧⁇⁈⁉‣⁃※‱‵⁎⁑⁂⸮⹀‧"
print(",".join("U+%04X" % c for c in sorted(u) if 0x20 <= c <= 0xFFFD and c != 0xFEFF and (c in j or chr(c) in symbols or inr(c, keep)) and not inr(c, drawn)))
' IoskeleyMonoTerm-Regular.ttf JetBrainsMono-Variable.ttf > unicodes.txt
pyftsubset IoskeleyMonoTerm-$STYLE.ttf --output-file=IoskeleyMonoTerm-$STYLE.ttf --unicodes-file=unicodes.txt \
  --layout-features='calt,ccmp,dlig,dnom,frac,lnum,locl,numr,onum,zero,mark,mkmk' \
  --name-IDs='*' --name-languages='*' --notdef-outline --legacy-kern --no-bidi-closure --drop-tables=
```

Sources:
https://github.com/rektdeckard/departure-mono/releases/tag/v1.500,
https://github.com/ahatem/IoskeleyMono/releases/tag/v2.1.0, and
https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304.

Latin Modern 2.004 (B. Jackowski and J. M. Nowacki, on behalf of TeX users
groups) is bundled unmodified under the GUST Font License, whose text is in
`ThirdPartyLicenses/LatinModern-GUST.txt`: Roman 10 (regular, italic, bold, bold
italic), Mono 10 (regular, italic) and Mono Light 10 (bold, bold oblique, Mono's
bold faces). Source: https://www.gust.org.pl/projects/e-foundry/latin-modern
(also CTAN `fonts/lm`).

More coding fonts, listed under a separator in Settings' terminal font menu (Mac only), are bundled unmodified, each
with its license text in `ThirdPartyLicenses/`:

| Font | Version | License | Files | Source |
|---|---|---|---|---|
| Cascadia Code | 2407.24 | OFL 1.1 (`CascadiaCode-OFL.txt`) | variable upright and italic | https://github.com/google/fonts/tree/main/ofl/cascadiacode |
| Commit Mono | 1.143 | OFL 1.1 (`CommitMono-LICENSE.txt`) | 400 and 700, upright and italic | https://github.com/eigilnikolajsen/commit-mono/releases/tag/v1.143 |
| Geist Mono | 1.701 | OFL 1.1 (`GeistMono-OFL.txt`) | variable upright and italic | https://github.com/google/fonts/tree/main/ofl/geistmono |
| Hack | 3.003 | MIT and Bitstream Vera (`Hack-LICENSE.md`) | regular, bold, italic, bold italic | https://github.com/source-foundry/Hack/releases/tag/v3.003 |
| Hasklig | 1.2 | OFL 1.1 (`Hasklig-OFL.md`) | regular, bold, italic, bold italic | https://github.com/i-tu/Hasklig/releases/tag/v1.2 |
| IBM Plex Mono | 2.3 | OFL 1.1 (`IBMPlexMono-OFL.txt`) | regular, bold, italic, bold italic | https://github.com/google/fonts/tree/main/ofl/ibmplexmono |
| Inconsolata | 3.000 | OFL 1.1 (`Inconsolata-OFL.txt`) | variable | https://github.com/googlefonts/Inconsolata/releases/tag/v3.000 |
| Intel One Mono | 1.400 | OFL 1.1 (`IntelOneMono-OFL.txt`) | regular, bold, italic, bold italic | https://github.com/intel/intel-one-mono/releases/tag/V1.4.0 |
| Maple Mono | 7.9 | OFL 1.1 (`MapleMono-OFL.txt`) | variable upright and italic | https://github.com/subframe7536/maple-font/releases/tag/v7.9 |
| Rec Mono Casual (Recursive) | 1.085 | OFL 1.1 (`Recursive-OFL.txt`) | regular, bold, italic, bold italic | https://github.com/arrowtype/recursive/releases/tag/v1.085 |
| Victor Mono | 1.561 | OFL 1.1 (`VictorMono-OFL.txt`) | variable upright and italic | https://github.com/google/fonts/tree/main/ofl/victormono |

Variable files are renamed `<Family>-Variable.ttf` and `<Family>-Italic-Variable.ttf`; Rec Mono drops the version from
its file names. The fonts themselves are unchanged.

## Rust SSH helper

The helper uses the Rust standard library and the exact crates locked and
vendored in `Helpers/ssh-helper/`. Their license texts, copyright notices and
Rust standard-library attribution are preserved in
`ThirdPartyLicenses/RustSSHHelper/` and bundled with the app.

## yyjson transcript parser

Dispatch uses yyjson 0.12.0, copyright 2020 YaoYuan, under the MIT license
for selective Codex transcript decoding. `Vendor/yyjson/` includes the source,
header, license, and a documented backport of upstream number-parser fix
`1e4b0d830506d99fd94d364613538fbcb72bde35`. The original license is bundled in
`ThirdPartyLicenses/yyjson-MIT.txt`.
Source: https://github.com/ibireme/yyjson/tree/0.12.0.

## Zstandard

Dispatch uses Zstandard 1.5.7, copyright Meta Platforms, Inc. and affiliates, under the BSD license: the bundled
helper compresses the archives that carry copied files between hosts, and the test tooling compresses the replay
corpus (the app's Debug replays and the helper's capture tool).
`Vendor/Zstd/` holds the unmodified library sources and license (see `Vendor/Zstd/PROVENANCE.md`). The license is
bundled in `ThirdPartyLicenses/Zstandard-BSD.txt`. Source: https://github.com/facebook/zstd/tree/v1.5.7.

## whisper.cpp

The optional Whisper dictation engine (Mac and iPhone) is Dispatch's own Swift port of whisper.cpp,
`Packages/WhisperEngine`. Its Metal kernels, in `Packages/WhisperEngine/Sources/WhisperEngine/Kernels/`, are adapted
from the ggml library in whisper.cpp 1.9.5, copyright the ggml authors, under the MIT license; so are the Metal
backend's dispatch rules and its half-float conversion (from ggml-impl.h, which took it from the FP16 library,
copyright 2017 Facebook Inc. and Marat Dukhan, MIT). Which files, and what changed, is in that directory's
`PROVENANCE.md`; the rest of the engine is Dispatch's own Swift. The license is bundled in
`ThirdPartyLicenses/whisper.cpp-MIT.txt`. Source: https://github.com/ggml-org/whisper.cpp/tree/v1.9.5.
Whisper's model weights (OpenAI, MIT license) are not bundled: Settings downloads them on request from
https://huggingface.co/ggerganov/whisper.cpp.

## iPhone SSH transport

Dispatch for iPhone's SSH engine (`Mobile/Transport/Core`, static library `DispatchMobileSSHCore`) links
russh 0.64.1 (Apache 2.0) and its dependency tree, pinned in `Mobile/Transport/Core/Cargo.lock`: 125 crates
under MIT, Apache 2.0, BSD-3-Clause, ISC, Unlicense and Unicode-3.0 terms, among them ring 0.17.14
(Apache 2.0 and ISC, with BoringSSL-derived code), tokio, and the RustCrypto crates (ssh-key, rsa, p256,
p384, p521, ed25519-dalek, aes, chacha20, bcrypt-pbkdf, Blowfish and others). Their license files are
reproduced in `Mobile/ThirdPartyLicenses/MobileTransport/Dependencies.txt`, written by
`scripts/mobile-transport-licenses.py`; the Rust standard library's attribution is the one in
`ThirdPartyLicenses/RustSSHHelper/`.
