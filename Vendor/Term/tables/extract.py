#!/usr/bin/env python3
"""Refresh inputs/ (what gen.py reads) from the pinned Ghostty; run after a pin bump.

usage: extract.py <ghostty git checkout> <ghostty-oracle --tables output> <inputs dir>

Ghostty files are read from the checkout's HEAD commit (the pristine pin: the oracle patch is not
in it) and cut down to the regions gen.py reads, verbatim (RULES: path -> (start, end) markers,
end included; None: the whole file; a pattern: its matching lines). The oracle's output keeps the
kinds gen.py reads plus `break` and `x11`, which Dispatch's tests compare the tables Term builds
at first use with. PROVENANCE.md records the sha-256 of every whole source file.
"""
import hashlib
import os
import re
import subprocess
import sys

RULES = {
    'terminal/modes.zig': [('const entries: []const ModeEntry', '\n};')],
    'terminal/device_status.zig': [('const entries: []const Entry', '\n};')],
    'terminal/res/rgb.txt': None,
    'terminal/mouse.zig': [('pub const Shape = enum', '\n    pub fn'), ('const string_map', '});')],
    'terminal/color.zig': [('pub fn default(self: Name)', 'else =>')],
    'input/key_encode.zig': [('fn ctrlSeq(', 'else => null')],
    'input/paste.zig': [('const strip: []const u8 = &.{', '};')],
    'config/Config.zig': r'^(?:@"[a-z0-9-]+"|[a-z][a-z0-9_]*): .*\n',
}
ORACLE = r'^(props|constraint|key|kitty|fkey|fmods|keycode|xtgettcap|emoji_presentation|word|digit|symbol|url_regex|size|align|capacity|break|x11)( |$)'

checkout, oracle, out = sys.argv[1:4]
git = lambda *a: subprocess.run(['git', '-C', checkout, *a], check=True, capture_output=True).stdout
provenance = []
for path, rule in RULES.items():
    text = git('show', f'HEAD:src/{path}').decode()
    if rule is None:
        part = text
    elif isinstance(rule, str):
        part = ''.join(m.group(0) for m in re.finditer(rule, text, re.M))
    else:
        part = '\n'.join(text[text.index(a):text.index(b, text.index(a)) + len(b)] for a, b in rule) + '\n'
    os.makedirs(os.path.dirname(f'{out}/ghostty/src/{path}'), exist_ok=True)
    open(f'{out}/ghostty/src/{path}', 'w').write(part)
    provenance.append(f'| src/{path} | {hashlib.sha256(text.encode()).hexdigest()} |')
lines = [l for l in open(oracle) if re.match(ORACLE, l)]
open(f'{out}/oracle-tables.txt', 'w').writelines(lines)
provenance.append(f'| ghostty-oracle --tables (kinds above) | {hashlib.sha256("".join(lines).encode()).hexdigest()} |')
open(f'{out}/PROVENANCE.md', 'w').write('\n'.join([
    '# Inputs of tables/gen.py',
    '',
    'Written by `tables/extract.py <ghostty checkout> <ghostty-oracle --tables output> inputs` (do not edit).',
    'Ghostty: 31bdcd5a79639bbac97c1a94e0f41d0f5ff84ca2 (MIT, see Resources/ghostty/LICENSE); its Unicode data: uucode 0.2.0 (Unicode 17.0.0).',
    '`ghostty/src/...` hold verbatim regions of those files (extract.py RULES); the oracle is that Ghostty',
    'plus tables/ghostty-oracle.patch (`git diff HEAD` of the oracle checkout, trailing blanks stripped: `git apply`',
    'gives the same tree), built with `zig build -Dapp-runtime=none -Demit-bench=true -Doptimize=ReleaseFast`.',
    '',
    '| source | sha-256 of the whole file / the kept lines |',
    '| --- | --- |',
    *provenance, '']))
print(f'{len(RULES)} Ghostty files, {len(lines)} oracle lines')
