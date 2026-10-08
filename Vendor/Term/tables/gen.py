#!/usr/bin/env python3
"""Generate Sources/Term/Tables.swift from inputs/ (the pinned Ghostty's data, see
inputs/PROVENANCE.md; extract.py refreshes it after a pin bump).

usage: gen.py <inputs dir> <out.swift>

Tables are data from Ghostty, never typed by hand: modes (modes.zig),
device status requests (device_status.zig), mouse shapes (mouse.zig), rgb.txt,
config keys (Config.zig); from the oracle: Unicode properties, the Zig sizes
the page layout needs, and the input tables (keys, kitty keys, PC-style
function keys, modifyOtherKeys modifier sets, mac keycodes). Tables that are
cheap to build (grapheme breaks, X11 names) are built by Term at first use.
"""
import re
import sys

inputs, out = sys.argv[1], sys.argv[2]
src, tables = f'{inputs}/ghostty/src', f'{inputs}/oracle-tables.txt'
read = lambda p: open(f'{src}/terminal/{p}').read()


def entries(text, start):
    body = text[text.index(start):]
    body = body[:body.index('\n};')]
    return re.findall(r'\.\{\s*\.name = "([^"]+)",\s*\.value = (\d+)(.*?)\}', body, re.S)


def camel(name):
    parts = name.split('_')
    s = parts[0] + ''.join(p.capitalize() for p in parts[1:])
    return 'mode' + s[0].upper() + s[1:] if s[0].isdigit() else s


modes, mode_names = [], []
for name, value, rest in entries(read('modes.zig'), 'const entries: []const ModeEntry'):
    mode_names.append(name)
    # Ghostty's one `disabled` rule (off macOS, outside libghostty-vt) is false on macOS, and Term
    # answers Ghostty's OS questions as macOS (Dispatch runs there). Another rule needs a look.
    if '.disabled' in rest and '.disabled = build_options.artifact != .lib and builtin.os.tag != .macos' not in rest:
        raise SystemExit(f'mode {name}: new disabled rule')
    modes.append(f'    ("{name}", {value}, {"true" if ".ansi = true" in rest else "false"}, '
                 f'{"true" if ".default = true" in rest else "false"}),')

status = [f'    ("{n}", {v}, {"true" if ".question = true" in r else "false"}),'
          for n, v, r in entries(read('device_status.zig'), 'const entries: []const Entry')]

x11 = open(f'{src}/terminal/res/rgb.txt').read()
assert '"""#' not in x11

mouse = read('mouse.zig')
shape_body = mouse[mouse.index('pub const Shape = enum'):]
shape_body = shape_body[shape_body.index('{') + 1:shape_body.index('\n    pub fn')]
shapes = re.findall(r'^\s*([a-z_]+),', shape_body, re.M)
smap_body = mouse[mouse.index('const string_map'):]
smap_body = smap_body[:smap_body.index('});')]
strings = [f'    ("{s}", {shapes.index(e)}),' for s, e in re.findall(r'\.\{ "([^"]+)", \.([a-z_]+) \}', smap_body)]

color = read('color.zig')
color_body = color[color.index('pub fn default(self: Name)'):]
color_body = color_body[:color_body.index('else =>')]
named = [f'RGB(r: {int(r, 16)}, g: {int(g, 16)}, b: {int(b, 16)})'
         for r, g, b in re.findall(r'RGB\{ \.r = 0x(..), \.g = 0x(..), \.b = 0x(..) \}', color_body)]
assert len(named) == 16, len(named)


def fields(text):
    """`a=1 b={c:2}` -> {'a': '1', 'b': '{c:2}'} (top level only)."""
    result, depth, key, start = {}, 0, None, 0
    for i, c in enumerate(text + ' '):
        if c in '{': depth += 1
        elif c in '}': depth -= 1
        elif c == '=' and depth == 0 and key is None: key, start = text[start:i], i + 1
        elif c == ' ' and depth == 0 and key is not None: result[key], key, start = text[start:i], None, i + 1
    return result


zig, runs, tcap = [], [], []
keys, kitty, fkeys, fmods, keycodes, coverage, constraints = [], [], [], [], [], {}, []
unescape = lambda v: re.sub('%([0-9A-F]{2})', lambda m: chr(int(m.group(1), 16)), v)
swift_string = lambda v: '"' + ''.join(c if 0x20 <= ord(c) < 0x7F and c not in '"\\' else f'\\u{{{ord(c):X}}}' for c in v) + '"'


def raw7(bs):
    """Bytes < 127 as a StaticString literal of byte + 1: static data, read through utf8Start.
    Never a NUL: Swift 6.0 truncates string literals at NUL when it inlines them into another module."""
    assert all(0 <= b < 127 for b in bs)
    return swift_string(''.join(chr(b + 1) for b in bs))


for line in open(tables):
    kind, _, rest = line.rstrip('\n').partition(' ')
    if kind == 'url_regex':
        url_regex = rest
        continue
    f = fields(rest)
    if kind == 'align':
        zig.append(f'    public static let {camel(f["name"])}Align = {f["base"]}')
    elif kind == 'size':
        zig.append(f'    public static let {camel(f["name"])} = (size: {f["size"]}, align: {f["align"]})')
    elif kind == 'capacity':
        for name, v in f.items():
            args = ', '.join(f'{camel(k)}: {x}' for k, x in (kv.split(':') for kv in v.strip('{}').split(',')))
            zig.append(f'    public static let {name}Capacity = Capacity({args})')
    elif kind == 'props':
        start, count, value = rest.split()
        runs.append((int(start), int(count), int(value, 16)))
    elif kind == 'constraint':
        start, count, kv = rest.split(' ', 2)
        f = fields(kv)
        h = lambda k: 'Double(bitPattern: 0x%s)' % f[k]
        size = {'fit_cover1': 'fitCover1'}.get(f['size'], f['size'])
        cfields = [f'c.size = .{size}', f'c.alignVertical = .{f["av"]}', f'c.alignHorizontal = .{f["ah"]}']
        cfields += [f'c.{n} = {h(k)}' for n, k in (('padTop', 'pt'), ('padLeft', 'pl'), ('padRight', 'pr'), ('padBottom', 'pb'), ('relativeWidth', 'rw'),
                                                    ('relativeHeight', 'rh'), ('relativeX', 'rx'), ('relativeY', 'ry'))]
        if f['xy'] != '-':
            cfields.append(f'c.maxXYRatio = {h("xy")}')
        cfields += [f'c.maxConstraintWidth = {f["mcw"]}', f'c.iconHeight = {"true" if f["h"] == "icon" else "false"}']
        constraints.append(f'    ({start}, {count}, {{ var c = GlyphConstraint(); ' + '; '.join(cfields) + '; return c }()),')
    elif kind in ('emoji_presentation', 'word', 'digit', 'symbol'):
        coverage.setdefault(kind, []).append('(%s, %s)' % tuple(rest.split()))
    elif kind == 'key':
        keys.append((f['name'], 0 if f['codepoint'] == '-' else int(f['codepoint'])))
    elif kind == 'kitty':
        kitty.append(f'    (.{camel(f["key"])}, {f["code"]}, {f["final"]}, {"true" if f["modifier"] == "1" else "false"}),')
    elif kind == 'fkey':
        # A text line per entry (a big literal of initializers takes gigabytes to type-check).
        modes3 = ['any', 'normal', 'application']
        fkeys.append(' '.join([str([n for n, _ in keys].index(f['key'])), f['mods'], f['any'], str(modes3.index(f['cursor'])), str(modes3.index(f['keypad'])),
                               str(['any', 'set', 'set_other'].index(f['modify_other_keys'])), swift_string(unescape(f['seq']))[1:-1],
                               '-' if f['decbkm'] == '-' else swift_string(unescape(f['decbkm']))[1:-1]]))
    elif kind == 'fmods':
        fmods.append(f['mods'])
    elif kind == 'keycode' and f['key'] != 'unidentified':
        keycodes.append(f'    {f["mac"]}: .{camel(f["key"])},')
    elif kind == 'xtgettcap':
        tcap.append(f'    {swift_string(unescape(f["key"]))}: {swift_string(unescape(f["value"]))},')
encoder = open(f'{src}/input/key_encode.zig').read()
ctrl_body = encoder[encoder.index('fn ctrlSeq('):]
ctrl_body = ctrl_body[ctrl_body.index('return switch (char) {'):ctrl_body.index('else => null')]
ctrl = [(ord(c.replace('\\\\', '\\')), int(v)) for c, v in re.findall(r"^\s*'(\\\\|.)' => (\d+),", ctrl_body, re.M)]
paste = open(f'{src}/input/paste.zig').read()
strip_body = paste[paste.index('const strip: []const u8 = &.{'):]
strip = re.findall(r'0x([0-9A-F]{2}),', strip_body[:strip_body.index('};')])
config_keys = [a or b for a, b in re.findall(r'^(?:@"([a-z0-9-]+)"|([a-z][a-z0-9_]*)): ', open(f'{src}/config/Config.zig').read(), re.M)]
values = sorted(set(v for _, _, v in runs))
cps = [0] * 0x110000
for start, count, value in runs:
    cps[start:start + count] = [values.index(value)] * count
blocks, stage1 = {}, []
for b in range(0x1100):
    stage1.append(blocks.setdefault(tuple(cps[b * 256:(b + 1) * 256]), len(blocks)))

open(out, 'w').write('\n'.join([
    '// Generated by tables/gen.py from tables/inputs (Ghostty 31bdcd5, uucode 0.2.0 = Unicode 17.0.0; see',
    '// tables/inputs/PROVENANCE.md). Do not edit: `python3 tables/gen.py tables/inputs Sources/Term/Tables.swift`.',
    '',
    '/// (name, value, ansi, default) in Ghostty\'s order.',
    'let modeTable: [(name: String, value: UInt16, ansi: Bool, isDefault: Bool)] = [',
    *modes, ']', '',
    '/// Every mode by its Ghostty name in camelCase ("mode" before a leading digit).',
    'extension Mode {',
    *[f'    static var {camel(n)}: Mode {{ Mode(index: {i}) }}' for i, n in enumerate(mode_names)],
    '}', '',
    '/// (name, value, question): DSR requests.',
    'let deviceStatusTable: [(name: String, value: UInt16, question: Bool)] = [',
    *status, ']', '',
    '/// Mouse shape names in enum order, and the OSC 22 strings that select them.',
    'let mouseShapeNames: [String] = [' + ', '.join(f'"{s}"' for s in shapes) + ']',
    'let mouseShapeStrings: [(String, Int)] = [',
    *strings, ']', '',
    '/// Ghostty\'s res/rgb.txt, verbatim (OSC.swift reads it at first use, as x11_color.zig at comptime).',
    'let x11Text = #"""', x11 + '"""#', '',
    '/// The 16 named colors of Ghostty\'s default palette (color.zig Name.default).',
    'let ghosttyNamedColors: [RGB] = [' + ', '.join(named) + ']', '',
    '/// Zig sizes and alignments the page layout uses, measured from the pinned Ghostty.',
    '@_spi(Test) public enum Zig {', *zig, '}', '',
    '/// Unicode properties (unicode/props.zig, packed u16) in 2 stages: code point >> 8 -> block,',
    '/// block * 256 + low byte -> index into propsValues (2 bytes each, low 7 bits first).',
    '/// Tables are 7-bit StaticStrings: static data, no initialization, cheap to compile.',
    f'let propsValues: StaticString = {raw7([b for v in values for b in (v & 127, v >> 7)])}',
    f'let propsBlocks: StaticString = {raw7(stage1)}',
    f'let propsIndex: StaticString = {raw7([i for blk in blocks for i in blk])}',
    '',
    '/// XTGETTCAP: hex capability name -> full reply (terminfo/ghostty.zig via the oracle).',
    'let xtgettcapReplies: [String: String] = [', *tcap, ']', '',
    '/// Physical keys (Ghostty\'s input.Key, W3C codes), in Ghostty\'s order.',
    'public enum Key: UInt16, CaseIterable, Sendable {', *[f'    case {camel(n)}' for n, _ in keys], '}', '',
    '@_spi(Test) public let keyNames: [String] = [' + ', '.join(f'"{n}"' for n, _ in keys) + ']',
    '/// The printable code point of each key (0: none), by raw value.',
    f'let keyCodepoints: StaticString = {raw7([c for _, c in keys])}', '',
    '/// Kitty keyboard protocol keys (input/kitty.zig), in Ghostty\'s order: key, code, final byte, modifier.',
    '@_spi(Test) public let kittyKeys: [(key: Key, code: UInt32, final: UInt8, modifier: Bool)] = [', *kitty, ']', '',
    '/// PC-style function keys (input/function_keys.zig, resolved), a line per entry in Ghostty\'s order: key, mods,',
    '/// any mods, cursor, keypad, modifyOtherKeys (raw values), sequence, DECBKM sequence or -.',
    'let functionKeyTable = """', *fkeys, '"""', '',
    '/// modifyOtherKeys modifier sets: CSI 27 ; <index + 2> ; <code point> ~.',
    '@_spi(Test) public let modifyOtherKeysMods: [Mods] = [' + ', '.join(f'Mods(rawValue: {m})' for m in fmods) + ']', '',
    '/// Ctrl+character -> C0 byte (key_encode.zig ctrlSeq, Kitty\'s table).',
    'let ctrlSequences: [UInt8: UInt8] = [' + ', '.join(f'{c}: {v}' for c, v in ctrl) + ']', '',
    '/// Bytes a paste never sends as is: replaced by spaces (paste.zig, xterm\'s list).',
    'let pasteStrip: [UInt8] = [' + ', '.join(f'0x{b}' for b in strip) + ']', '',
    '/// Code point runs whose default presentation is emoji (Emoji_Presentation).',
    'let emojiPresentationRuns: [(UInt32, UInt32)] = [' + ', '.join(coverage['emoji_presentation']) + ']', '',
    '/// Code point runs oniguruma\'s \\w and \\d match in UTF-8 (link regexes).',
    'let wordRuns: [(UInt32, UInt32)] = [' + ', '.join(coverage['word']) + ']',
    'let digitRuns: [(UInt32, UInt32)] = [' + ', '.join(coverage['digit']) + ']',
    '/// Code point runs the renderer treats as symbols (renderer/cell.zig).',
    'let symbolRuns: [(UInt32, UInt32)] = [' + ', '.join(coverage['symbol']) + ']',
    '/// The Nerd Font glyph attributes (font/nerd_font_attributes.zig) as runs of equal constraints.',
    'let glyphConstraints: [(start: UInt32, count: UInt32, constraint: GlyphConstraint)] = [', *constraints, ']',
    '/// The default link\'s pattern (config/url.zig).',
    'public let urlRegex = ##"' + url_regex + '"##', '',
    '/// Mac virtual keycodes (keycodes.zig mac column, first match like apprt/embedded.zig).',
    'let macKeycodes: [UInt32: Key] = [', *keycodes, ']', '',
    '/// Every key of Ghostty\'s config (the pinned Config.zig\'s fields): the ones Config does not model are',
    '/// accepted without a look at their values, anything else is an unknown field.',
    'let ghosttyConfigKeys: Set<String> = [' + ', '.join(f'"{k}"' for k in config_keys) + ']', '',
]))
print(f'keys={len(keys)} kitty={len(kitty)} fkeys={len(fkeys)} fmods={len(fmods)} keycodes={len(keycodes)} ctrl={len(ctrl)} strip={len(strip)}')
print(f'modes={len(modes)} status={len(status)} shapes={len(shapes)} strings={len(strings)} props={len(values)}/{len(blocks)} config={len(config_keys)}')
