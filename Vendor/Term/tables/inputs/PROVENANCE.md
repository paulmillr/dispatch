# Inputs of tables/gen.py

Written by `tables/extract.py <ghostty checkout> <ghostty-oracle --tables output> inputs` (do not edit).
Ghostty: 31bdcd5a79639bbac97c1a94e0f41d0f5ff84ca2 (MIT, see Resources/ghostty/LICENSE).
Unicode data (props, emoji_presentation, symbol, break): tables/unicode.py on uucode ea62149739404a73c202b48a33bf6dd2af4bd9b0
(Unicode 18.0.0; Ghostty v1.4.0 commit 9cdbf798), not the oracle.
Those kinds of oracle-tables.txt are now unicode.py's output, not the Zig oracle's: unicode.py was validated byte for byte
against the oracle on the old data only, so for them TermTablesTests checks self-consistency (Tables.swift and Term's
break table against these inputs), not agreement with a Ghostty build.
unicode.py ports uucode's build components with Ghostty's uucode_config.zig and uucode's grapheme break rules; on
uucode 2826a37 (Ghostty 31bdcd5's, Unicode 17.0.0) `unicode.py <ucd> --old` prints the oracle's lines byte for byte,
and its break rules agree with each version's GraphemeBreakTest.txt (controls excluded, uucode's emoji-modifier
tailoring applied). The ucd/ directory is in https://deps.files.ghostty.org/uucode-ea62149739404a73c202b48a33bf6dd2af4bd9b0.tar.gz.
The device-status entries additionally backport `cursor_position_extended` (DECXCPR) from
Ghostty v1.4.0, commit fbda61b8. The hashes below identify the original baseline files;
`device_status.zig`'s kept entries include that additional row. Preserve it if extracting
again from the old baseline, or extract from a newer baseline containing the fix.
`ghostty/src/...` hold verbatim regions of those files (extract.py RULES); the oracle is that Ghostty
plus tables/ghostty-oracle.patch (`git diff HEAD` of the oracle checkout, trailing blanks stripped: `git apply`
gives the same tree), built with `zig build -Dapp-runtime=none -Demit-bench=true -Doptimize=ReleaseFast`.

| source | sha-256 of the whole file / the kept lines |
| --- | --- |
| src/terminal/modes.zig | 3acd54343dd5c53448020708fb3182fd3396ac029b21fe9305a20e9e107af4e1 |
| src/terminal/device_status.zig | 244a5aa349845a7780dfff4cd2cda2efa574153774d0655727bf4d22d12f579f |
| src/terminal/res/rgb.txt | f8e3a7bea17acc0b91e6285c5d32001db27d84c4461c655afdbce9dbeb4fb6f0 |
| src/terminal/mouse.zig | eaea76cf03c660e43fb5dfb9942e8cc274a689ac5905b40f4f1df667a9ad585a |
| src/terminal/color.zig | 9704dc19bb5916c11a90eee73d6332fb1a76dec1320f64186f6d95805544c665 |
| src/input/key_encode.zig | 3fea157f46eb7e53406ea6a72dcc55ed6047c543ad50633aecb1eafb10d2b2bb |
| src/input/paste.zig | 81cc2943b84787062afcc72547471252dde929038eb32b3c61be235309198bc4 |
| src/config/Config.zig | b025a65a53c44b46cc1b7a260bff142c930e08de8afa0ba5d81805bae37e32c9 |
| ghostty-oracle --tables (kinds above, Unicode kinds from unicode.py) | 68017e81c64ee65e242d6e7542a984dc665c90fd2574ed2bd99f811bbad9dc9c |
