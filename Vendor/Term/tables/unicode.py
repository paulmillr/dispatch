#!/usr/bin/env python3
"""Ghostty's Unicode tables from the Unicode Character Database, for inputs/oracle-tables.txt.

usage: unicode.py <ucd dir> [--old]

Prints the oracle's Unicode lines (`props`, `emoji_presentation`, `symbol`, `break`, in that order:
their kinds' order in oracle-tables.txt) for the UCD files of a uucode checkout (`<uucode>/ucd`).
A Python port of what Ghostty builds from uucode: uucode's build components (UnicodeData,
DerivedCoreProperties, DerivedEastAsianWidth, GraphemeBreakProperty, emoji data, Wcwidth,
GraphemeBreakDerived) with Ghostty's src/build/uucode_config.zig (width, is_symbol), packed as
src/unicode/props.zig, and uucode's computeGraphemeBreakNoControl for the `break` lines.

uucode changed its grapheme classes and break state for Unicode 18 (InCB=Linker split into
linker_extend/linker_other, GB9c without a leading consonant, `after_linker` beside the state):
`--old` selects the earlier rules (uucode 2826a37, Unicode 17). With `--old` and uucode 2826a37's
ucd/ this prints exactly the lines the Ghostty 31bdcd5 oracle printed (see PROVENANCE.md).
"""
import re
import sys

ucd, old = sys.argv[1], '--old' in sys.argv[2:]
N = 0x110000


def data(path):
    """(first, last, fields) of each data line of a UCD file."""
    for line in open(f'{ucd}/{path}', encoding='utf-8'):
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        fields = [f.strip() for f in line.split(';')]
        a, _, b = fields[0].partition('..')
        yield int(a, 16), int(b or a, 16), fields[1:]


def ranges(path, want, value=True, field=0, into=None):
    table = into if into is not None else [False] * N
    for a, b, f in data(path):
        if f[field] == want:
            table[a:b + 1] = [value] * (b + 1 - a)
    return table


# UnicodeData: general category, ranges given by <..., First> / <..., Last> pairs.
gc = ['Cn'] * N
first = None
for line in open(f'{ucd}/UnicodeData.txt', encoding='utf-8'):
    f = line.split(';')
    cp = int(f[0], 16)
    if f[1].endswith(', First>'):
        first = cp
        continue
    if f[1].endswith(', Last>'):
        gc[first:cp + 1] = [f[2]] * (cp + 1 - first)
        continue
    gc[cp] = f[2]

ignorable = ranges('DerivedCoreProperties.txt', 'Default_Ignorable_Code_Point')
incb = ['None'] * N
for a, b, f in data('DerivedCoreProperties.txt'):
    if f[0] == 'InCB':
        incb[a:b + 1] = [f[1]] * (b + 1 - a)
eaw = ['N'] * N
for line in open(f'{ucd}/extracted/DerivedEastAsianWidth.txt', encoding='utf-8'):
    # Unassigned code points of the CJK blocks and planes 2-3 default to Wide (uucode reads these).
    if m := re.match(r'# @missing: ([0-9A-F]+)\.\.([0-9A-F]+); Wide', line):
        a, b = int(m[1], 16), int(m[2], 16)
        eaw[a:b + 1] = ['W'] * (b + 1 - a)
for a, b, f in data('extracted/DerivedEastAsianWidth.txt'):
    eaw[a:b + 1] = [f[0]] * (b + 1 - a)
gcb = ['Other'] * N
for a, b, f in data('auxiliary/GraphemeBreakProperty.txt'):
    gcb[a:b + 1] = [f[0]] * (b + 1 - a)
emoji = {k: ranges('emoji/emoji-data.txt', k) for k in ('Emoji_Presentation', 'Emoji_Modifier', 'Emoji_Modifier_Base', 'Extended_Pictographic')}
vs_base = [False] * N
for line in open(f'{ucd}/emoji/emoji-variation-sequences.txt', encoding='utf-8'):
    line = line.split('#', 1)[0].strip()
    if line:
        cp, vs = (int(x, 16) for x in line.split(';')[0].split())
        if vs == 0xFE0E:
            vs_base[cp] = True
blocks = ['No_Block'] * N
for a, b, f in data('Blocks.txt'):
    blocks[a:b + 1] = [f[0]] * (b + 1 - a)

# uucode's GraphemeBreakNoControl, in enum order (controls, CR and LF are `other`).
CLASSES = ['other', 'prepend', 'regional_indicator', 'spacing_mark', 'l', 'v', 't', 'lv', 'lvt', 'zwj', 'zwnj',
           'extended_pictographic', 'emoji_modifier_base', 'emoji_modifier', 'indic_conjunct_break_extend']
CLASSES += ['indic_conjunct_break_linker'] if old else ['indic_conjunct_break_linker_extend', 'indic_conjunct_break_linker_other']
CLASSES += ['indic_conjunct_break_consonant']
ORIGINAL = {'Prepend': 'prepend', 'Regional_Indicator': 'regional_indicator', 'SpacingMark': 'spacing_mark', 'L': 'l', 'V': 'v',
            'T': 't', 'LV': 'lv', 'LVT': 'lvt', 'ZWJ': 'zwj', 'Extend': 'extend', 'Other': 'other',
            'Control': 'other', 'CR': 'other', 'LF': 'other'}


def grapheme_break(cp):
    """uucode's GraphemeBreakDerived, then GraphemeBreakNoControl."""
    original = ORIGINAL[gcb[cp]]
    if emoji['Emoji_Modifier'][cp]:
        assert original == 'extend'
        return 'emoji_modifier'
    if emoji['Emoji_Modifier_Base'][cp]:
        return 'emoji_modifier_base'
    if emoji['Extended_Pictographic'][cp]:
        assert original == 'other'
        return 'extended_pictographic'
    if incb[cp] == 'None':
        if original == 'extend':
            assert cp == 0x200C, hex(cp)
            return 'zwnj'
        return original
    if incb[cp] == 'Extend':
        return 'zwj' if cp == 0x200D else 'indic_conjunct_break_extend'
    if incb[cp] == 'Linker':
        if old:
            assert original == 'extend'
            return 'indic_conjunct_break_linker'
        return {'extend': 'indic_conjunct_break_linker_extend', 'other': 'indic_conjunct_break_linker_other'}[original]
    assert incb[cp] == 'Consonant' and original == 'other'
    return 'indic_conjunct_break_consonant'


def props(cp):
    """src/unicode/props.zig Properties as u16: width u2, width_zero_in_grapheme, grapheme_break u5, emoji_vs_base."""
    g, cat = grapheme_break(cp), gc[cp]
    # uucode's Wcwidth (its grapheme_break input is the derived one, with control/cr/lf).
    if cat in ('Cc', 'Cs', 'Zl', 'Zp'):
        width = 0
    elif cp == 0x00AD:
        width = 1
    elif ignorable[cp]:
        width = 0
    elif cp == 0x2E3A:
        width = 2
    elif cp == 0x2E3B:
        width = 3
    elif eaw[cp] in ('W', 'F') or g == 'regional_indicator':
        width = 2
    else:
        width = 1
    standalone = 2 if cp == 0x20E3 else width
    zero_in_grapheme = (width == 0 or emoji['Emoji_Modifier'][cp] or cat in ('Mn', 'Me') or g in ('v', 't', 'prepend'))
    # Ghostty's uucode_config.zig WidthComponent.
    if zero_in_grapheme and not emoji['Emoji_Modifier'][cp] and g != 'prepend':
        width = 0
    else:
        width = min(2, standalone)
    return width | zero_in_grapheme << 2 | CLASSES.index(g) << 3 | vs_base[cp] << 8


SYMBOL_BLOCKS = {'Arrows', 'Dingbats', 'Emoticons', 'Miscellaneous Symbols', 'Enclosed Alphanumerics',
                 'Enclosed Alphanumeric Supplement', 'Miscellaneous Symbols and Pictographs', 'Transport and Map Symbols'}


def runs(kind, values):
    start = 0
    for cp in range(1, N + 1):
        if cp < N and values[cp] == values[start]:
            continue
        yield start, cp - start, values[start]
        start = cp


out = []
p = [props(cp) for cp in range(N)]
out += [f'props {a} {n} {v:x}' for a, n, v in runs('props', p)]
out += [f'emoji_presentation {a} {n}' for a, n, v in runs('', emoji['Emoji_Presentation']) if v]
symbol = [gc[cp] == 'Co' or blocks[cp] in SYMBOL_BLOCKS for cp in range(N)]
out += [f'symbol {a} {n}' for a, n, v in runs('', symbol) if v]


def extend(g):
    return g in ('zwnj', 'indic_conjunct_break_extend', 'indic_conjunct_break_linker' if old else 'indic_conjunct_break_linker_extend')


def pictographic(g):
    return g in ('extended_pictographic', 'emoji_modifier_base')


def common(g1, g2):
    """GB6-GB9b: a result, or None to go on."""
    if g1 == 'l' and g2 in ('l', 'v', 'lv', 'lvt'):
        return False
    if g1 in ('lv', 'v') and g2 in ('v', 't'):
        return False
    if g1 in ('lvt', 't') and g2 == 't':
        return False
    if g2 == 'spacing_mark' or g1 == 'prepend':
        return False
    return None


EMOJI_KEEP = ('indic_conjunct_break_extend', 'zwnj', 'zwj', 'extended_pictographic', 'emoji_modifier_base', 'emoji_modifier')


def tail(g1, g2, base):
    """GB11, GB12/13, GB9 on uucode's `base` state (default, extended_pictographic, regional_indicator)."""
    if pictographic(g1):
        if extend(g2) or g2 == 'zwj' or (g1 == 'emoji_modifier_base' and g2 == 'emoji_modifier'):
            return False, 'extended_pictographic'
    elif base == 'extended_pictographic':
        if (extend(g1) or g1 == 'emoji_modifier') and (extend(g2) or g2 == 'zwj'):
            return False, base
        if g1 == 'zwj' and pictographic(g2):
            return False, 'default'
        base = 'default'
    if g1 == 'regional_indicator' and g2 == 'regional_indicator':
        return (False, 'regional_indicator') if base == 'default' else (True, 'default')
    return not (extend(g2) or g2 == 'zwj'), base


def break_old(g1, g2, state):
    """uucode 2826a37: states default, regional_indicator, extended_pictographic, incb_consonant, incb_linker."""
    keep_incb = ('indic_conjunct_break_consonant', 'indic_conjunct_break_linker', 'indic_conjunct_break_extend', 'zwj')
    if state == 'regional_indicator' and (g1 != 'regional_indicator' or g2 != 'regional_indicator'):
        state = 'default'
    elif state == 'extended_pictographic' and (g1 not in EMOJI_KEEP + ('indic_conjunct_break_linker',) or g2 not in EMOJI_KEEP + ('indic_conjunct_break_linker',)):
        state = 'default'
    elif state in ('incb_consonant', 'incb_linker') and (g1 not in keep_incb or g2 not in keep_incb):
        state = 'default'
    r = common(g1, g2)
    if r is not None:
        return r, state
    incb_extend = g2 in ('indic_conjunct_break_extend', 'zwj')
    if g1 == 'indic_conjunct_break_consonant':
        if incb_extend:
            return False, 'incb_consonant'
        if g2 == 'indic_conjunct_break_linker':
            return False, 'incb_linker'
    elif state == 'incb_consonant':
        if g2 == 'indic_conjunct_break_linker':
            return False, 'incb_linker'
        if incb_extend:
            return False, state
        state = 'default'
    elif state == 'incb_linker':
        if g2 == 'indic_conjunct_break_linker' or incb_extend:
            return False, state
        state = 'default'
        if g2 == 'indic_conjunct_break_consonant':
            return False, state
    # Only `default`, `regional_indicator` and `extended_pictographic` reach GB11-13 as themselves.
    return tail(g1, g2, state)


def break_new(g1, g2, state):
    """uucode ea62149: state (after_linker, base), table index base * 2 + after_linker."""
    after_linker, base = state
    linker = g1 in ('indic_conjunct_break_linker_extend', 'indic_conjunct_break_linker_other')
    incb_extend = lambda g: g in ('indic_conjunct_break_extend', 'zwj')
    now = linker or (after_linker and incb_extend(g1))
    after_linker = now and incb_extend(g2)
    keep = EMOJI_KEEP + ('indic_conjunct_break_linker_extend',)
    if base == 'regional_indicator' and (g1 != 'regional_indicator' or g2 != 'regional_indicator'):
        base = 'default'
    elif base == 'extended_pictographic' and (g1 not in keep or g2 not in keep):
        base = 'default'
    r = common(g1, g2)
    if r is not None:
        return r, (after_linker, base)
    if now and g2 == 'indic_conjunct_break_consonant':
        return False, (after_linker, 'default')
    broken, base = tail(g1, g2, base)
    return broken, (after_linker, base)


if old:
    states = ['default', 'regional_indicator', 'extended_pictographic', 'incb_consonant', 'incb_linker']
    index, compute = states.index, break_old
else:
    bases = ['default', 'extended_pictographic', 'regional_indicator']
    states = [(bool(i & 1), bases[i >> 1]) for i in range(5)]  # (regional_indicator, after_linker) never occurs
    index, compute = (lambda s: bases.index(s[1]) * 2 + s[0]), break_new
reps = {}
for cp in range(N):
    reps.setdefault(p[cp] >> 3 & 31, cp)
for s in states:
    for a in sorted(reps):
        for b in sorted(reps):
            broken, new = compute(CLASSES[a], CLASSES[b], s)
            out.append(f'break {index(s)} {a} {b} {int(broken)} {index(new)}')

print('\n'.join(out))
