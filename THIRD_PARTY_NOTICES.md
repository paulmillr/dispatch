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
unmodified under the SIL Open Font License 1.1. Their original notices are in
`ThirdPartyLicenses/DepartureMono-OFL.txt`, `ThirdPartyLicenses/IoskeleyMono-OFL.txt`,
and `ThirdPartyLicenses/JetBrainsMono-OFL.txt`. Ioskeley uses the normal-width,
hinted terminal build. Sources:
https://github.com/rektdeckard/departure-mono/releases/tag/v1.500,
https://github.com/ahatem/IoskeleyMono/releases/tag/v2.1.0, and
https://github.com/JetBrains/JetBrainsMono/releases/tag/v2.304.

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
