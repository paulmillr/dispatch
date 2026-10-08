#!/usr/bin/env python3
"""Report Swift/Rust structural metrics and compare revisions using the same measurement rules."""
import argparse
import csv
import io
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import os
ROOT = Path(os.environ.get('QUALITY_METRICS_ROOT') or Path(__file__).resolve().parent.parent)
SWIFT_SCOPE = ROOT / 'Dispatch'
RUST_SCOPE = ROOT / 'Helpers/helper4'
COMPLEXITY_THRESHOLD = 15
LENGTH_THRESHOLD = 80
TOP = 12
NESTING_THRESHOLD = 4
CO_CHANGE_MINIMUM = 3
COORDINATORS = [
    'Dispatch/Chat/ChatCoordinator.swift',
    'Dispatch/Tmux/TmuxCoordinator.swift',
    'Dispatch/SSH/SSHCoordinator.swift',
    'Dispatch/SSH/SSHHelperConnection.swift',
    'Dispatch/Herdr/HerdrCoordinator.swift',
    'Dispatch/Hosts/HostCoordinator.swift',
]
COLLECTION_PROPERTY = re.compile(
    r'^    (?:@\w+ )*(?:(?:private|fileprivate|nonisolated|weak|lazy|unowned)(?:\(set\))? )*'
    r'(?:var|let) \w+:\s*(?:\[|Set<)', re.M)
SPACES_MUTATION = r'(?:\s*(?:[-+*/]|\?\?)?=(?!=)|\.(?:append|insert|remove|removeAll|removeFirst|removeLast|removeSubrange|swapAt|popLast|sort|reverse)\b)'
SPACES_CHAIN = r'(?:\[[^\]]*\](?:\.\w+[?!]?|\[[^\]]*\])*)?'
# Naming is only a heuristic: these names are reserved for updateLayout drafts.
LAYOUT_DRAFT = r'(?<!\bnext)(?<!\blayout)(?<!\$0)'
SPACES_WRITER = re.compile(LAYOUT_DRAFT + r'\.spaces' + SPACES_CHAIN + SPACES_MUTATION)
BARE_SPACES_WRITER = re.compile(r'(?<![\w.$])(?<!let )(?<!var )spaces' + SPACES_CHAIN + SPACES_MUTATION)
SELECTION_WRITER = re.compile(LAYOUT_DRAFT + r'\.selectedSpace\s*=(?!=)')
BARE_SELECTION_WRITER = re.compile(r'(?<![\w.$])(?<!let )(?<!var )selectedSpace\s*=(?!=)')
# Lizard treats Swift's .init(...) expressions as initializer declarations.
SWIFT_INIT = re.compile(r'\.init(?=\s*\()')
RUNTIME_REACH = re.compile(r'TerminalRuntime\.shared\.(\w+)')
CFG_TEST = re.compile(r'^\s*#\[cfg\(test\)\]\s*$', re.M)
# lizard's Rust reader treats the quotes of a byte-char literal as a string
# delimiter and then desynchronises for the rest of the file, so whole modules
# go unmeasured. Neutralise the literals in the measured copy.
RUST_BYTE_CHAR = re.compile(r"b'(\\.|[^'\\])'")


def swift_files():
    return sorted(SWIFT_SCOPE.rglob('*.swift'))


def rust_files():
    return sorted(RUST_SCOPE.rglob('*.rs'))


def strip_rust_tests(source):
    """Blank out `#[cfg(test)] mod ... { ... }` blocks so inline tests do not count as production.

    Line count is preserved so reported line numbers still match the real file."""
    out = []
    position = 0
    for match in CFG_TEST.finditer(source):
        brace = source.find('{', match.end())
        if brace < 0:
            break
        depth = 0
        end = brace
        while end < len(source):
            depth += {'{': 1, '}': -1}.get(source[end], 0)
            if depth == 0:
                break
            end += 1
        out.append(source[position:match.start()])
        out.append('\n' * source.count('\n', match.start(), end + 1))
        position = end + 1
    out.append(source[position:])
    return ''.join(out)


def run_lizard(language, paths):
    """Return lizard rows (nloc, ccn, length, function, file, line) or None if lizard is unavailable."""
    try:
        import lizard  # noqa: F401
    except ImportError:
        return None
    command = [sys.executable, '-m', 'lizard', '-l', language, '--csv'] + [str(p) for p in paths]
    output = subprocess.run(command, capture_output=True, text=True, cwd=ROOT).stdout
    rows = []
    for row in csv.reader(io.StringIO(output)):
        if not row or not row[0].isdigit():
            continue
        # nloc, ccn, token, param, length, location, file, function, long name, start, end
        rows.append({'nloc': int(row[0]), 'ccn': int(row[1]), 'length': int(row[4]),
                     'function': row[7], 'file': row[6], 'line': int(row[9])})
    return rows


def lizard_version():
    try:
        import lizard
        return lizard.version
    except ImportError:
        return None


def summarize(rows):
    def percentile(values, q):
        values = sorted(values)
        return values[min(len(values) - 1, int(len(values) * q))] if values else 0

    ccn = [r['ccn'] for r in rows]
    length = [r['length'] for r in rows]
    totals = {}
    for r in rows:
        parts = Path(r['file']).parts
        key = parts[-2] if len(parts) > 1 else parts[0]
        totals[key] = totals.get(key, 0) + r['ccn']
    return {
        'ccn_total': sum(ccn),
        'ccn_by_directory': dict(sorted(totals.items(), key=lambda kv: -kv[1])),
        'functions': len(rows),
        'ccn_median': percentile(ccn, 0.5), 'ccn_p90': percentile(ccn, 0.9), 'ccn_max': max(ccn, default=0),
        'ccn_over_threshold': sum(c > COMPLEXITY_THRESHOLD for c in ccn),
        'length_median': percentile(length, 0.5), 'length_p90': percentile(length, 0.9),
        'length_max': max(length, default=0),
        'length_over_threshold': sum(n > LENGTH_THRESHOLD for n in length),
        'worst': [{'function': r['function'], 'ccn': r['ccn'], 'length': r['length'],
                   'file': str(Path(r['file']).relative_to(ROOT)) if Path(r['file']).is_absolute() else r['file'],
                   'line': r['line']}
                  for r in sorted(rows, key=lambda r: (-r['ccn'], -r['length']))[:TOP]],
    }


def complexity(temporary_root):
    swift_root = temporary_root / 'swift'
    for path in swift_files():
        target = swift_root / path.relative_to(SWIFT_SCOPE)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(SWIFT_INIT.sub('.__initializer', path.read_text()))
    swift = run_lizard('swift', [swift_root])
    if swift is None:
        return None
    for row in swift:
        row['file'] = str(SWIFT_SCOPE.relative_to(ROOT) / Path(row['file']).resolve().relative_to(swift_root.resolve()))
    # Copy Rust sources with inline test modules removed; lizard has no exclusion for them.
    stripped = temporary_root / 'rust'
    for path in rust_files():
        target = stripped / path.relative_to(RUST_SCOPE)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(RUST_BYTE_CHAR.sub('0x00', strip_rust_tests(path.read_text())))
    rust = run_lizard('rust', [stripped])
    for row in rust:
        row['file'] = str(RUST_SCOPE.relative_to(ROOT) / Path(row['file']).resolve().relative_to(stripped.resolve()))
    return {'swift': summarize(swift), 'rust': summarize(rust)}


def duplication(temporary_root):
    """Exact-clone lines via jscpd when npx is available; textual duplication is low in this repo."""
    if not shutil.which('npx'):
        return None
    result = {}
    for language, scope in (('swift', SWIFT_SCOPE), ('rust', RUST_SCOPE)):
        output = temporary_root / f'jscpd-{language}'
        command = ['npx', '--yes', 'jscpd@4', '--silent', '--reporters', 'json', '--output', str(output),
                   '--min-tokens', '70', '--min-lines', '8', '--format', language, str(scope)]
        subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
        report = output / 'jscpd-report.json'
        if report.exists():
            total = json.loads(report.read_text())['statistics']['total']
            result[language] = {'clones': total['clones'], 'lines': total['duplicatedLines'],
                                'percent': total['percentage']}
    return result or None


def coupling():
    reach = {}
    reach_files = 0
    spaces_writers = {}
    selection_writers = {}
    for path in swift_files():
        text = path.read_text()
        relative = str(path.relative_to(ROOT))
        members = RUNTIME_REACH.findall(text)
        if members:
            reach_files += 1
            for member in members:
                reach[member] = reach.get(member, 0) + 1
        if relative != 'Dispatch/Workspace.swift':
            count = len(SPACES_WRITER.findall(text))
            selections = len(SELECTION_WRITER.findall(text))
            if 'extension Workspace' in text:
                count += len(BARE_SPACES_WRITER.findall(text))
                selections += len(BARE_SELECTION_WRITER.findall(text))
            if selections:
                selection_writers[relative] = selections
            if count:
                spaces_writers[relative] = count
    collections = {}
    for relative in COORDINATORS:
        path = ROOT / relative
        if path.exists():
            collections[relative] = len(COLLECTION_PROPERTY.findall(path.read_text()))
    return {
        'runtime_shared_files': reach_files,
        'runtime_shared_members': dict(sorted(reach.items(), key=lambda kv: -kv[1])[:8]),
        'spaces_writers_outside_workspace': spaces_writers,
        'selection_writers_outside_workspace': selection_writers,
        'collection_properties': collections,
    }


def sizes():
    def count(paths):
        return sum(len(p.read_text().splitlines()) for p in paths)
    return {
        'swift_production_lines': count(swift_files()),
        'swift_test_lines': count((ROOT / 'DispatchTests').rglob('*.swift')),
        'rust_production_lines': count(rust_files()),
        'rust_inline_test_functions': sum(p.read_text().count('#[test]') for p in rust_files()),
    }


def nesting(paths, function_pattern):
    """Maximum brace depth inside each function body, relative to its opening brace."""
    depths = []
    for path in paths:
        text = path.read_text()
        if path.suffix == '.rs':
            text = strip_rust_tests(text)
        for match in function_pattern.finditer(text):
            brace = text.find('{', match.end())
            if brace < 0:
                continue
            depth = deepest = 0
            index = brace
            while index < len(text):
                character = text[index]
                if character == '{':
                    depth += 1
                    deepest = max(deepest, depth)
                elif character == '}':
                    depth -= 1
                    if depth == 0:
                        break
                index += 1
            depths.append({'function': match.group(1), 'depth': deepest - 1,
                           'file': str(path.relative_to(ROOT)), 'line': text.count('\n', 0, match.start()) + 1})
    values = sorted(d['depth'] for d in depths)
    percentile = values[min(len(values) - 1, int(len(values) * 0.9))] if values else 0
    return {'functions': len(depths), 'p90': percentile, 'max': values[-1] if values else 0,
            'over_threshold': sum(v > NESTING_THRESHOLD for v in values),
            'worst': sorted(depths, key=lambda d: -d['depth'])[:TOP]}


SWIFT_FUNCTION = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|static|override|'
                            r'nonisolated|final|mutating|class)\s+)*func\s+(\w+)', re.M)
RUST_FUNCTION = re.compile(r'^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+|unsafe\s+|const\s+)*fn\s+(\w+)', re.M)


def co_change():
    """Production files that change together, from the whole git history.

    Cheap and post hoc, so it measures the change amplification that actually
    happened rather than an estimate. Splitting one logical change across commits
    is the only way to game it."""
    log = subprocess.run(['git', 'log', '--format=%x00%h', '--name-only', '--', 'Dispatch', 'Helpers/helper4'],
                         capture_output=True, text=True, cwd=ROOT).stdout
    commits = []
    for block in log.split('\x00')[1:]:
        names = [line for line in block.splitlines()[1:] if line.endswith(('.swift', '.rs'))]
        if 1 < len(names) <= 40:  # very large commits carry no locality signal
            commits.append(sorted(set(names)))
    pairs = {}
    partners = {}
    for names in commits:
        for i, left in enumerate(names):
            for right in names[i + 1:]:
                pairs[(left, right)] = pairs.get((left, right), 0) + 1
    for (left, right), count in pairs.items():
        if count >= CO_CHANGE_MINIMUM:
            partners.setdefault(left, set()).add(right)
            partners.setdefault(right, set()).add(left)
    top_pairs = sorted(pairs.items(), key=lambda kv: -kv[1])[:TOP]
    top_partners = sorted(partners.items(), key=lambda kv: -len(kv[1]))[:TOP]
    return {'commits': len(commits), 'minimum': CO_CHANGE_MINIMUM,
            'pairs': [{'files': list(files), 'commits': count} for files, count in top_pairs],
            'partners': [{'file': file, 'partners': len(names)} for file, names in top_partners]}


def feedback():
    """Which production Swift files are named by a headless test, i.e. one that never asks for the desktop."""
    tests = list((ROOT / 'DispatchTests').glob('*.swift'))
    headless = [t.read_text() for t in tests if 'DesktopTestSupport' not in t.read_text()]
    desktop = len(tests) - len(headless)
    covered, uncovered = [], []
    for path in swift_files():
        stem = path.stem.split('+')[0]
        (covered if any(re.search(r'\b' + re.escape(stem) + r'\b', text) for text in headless) else uncovered).append(str(path.relative_to(ROOT)))
    return {'test_files': len(tests), 'desktop_test_files': desktop, 'headless_test_files': len(headless),
            'production_files': len(covered) + len(uncovered), 'named_by_headless_test': len(covered),
            'not_named_by_headless_test': sorted(uncovered)}


def git_commit():
    try:
        return subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def print_text(report):
    print(f"commit {report['commit']}  lizard {report['tools']['lizard'] or 'missing'}")
    for language in ('swift', 'rust'):
        s = report['sizes']
        print(f"\n[{language}] production lines: {s[language + '_production_lines']}")
        c = (report['complexity'] or {}).get(language)
        if not c:
            print('  complexity: lizard not installed (pip install --user lizard)')
            continue
        print(f"  functions {c['functions']}  CCN median/p90/max {c['ccn_median']}/{c['ccn_p90']}/{c['ccn_max']}"
              f"  CCN>{COMPLEXITY_THRESHOLD}: {c['ccn_over_threshold']}"
              f"  length median/p90/max {c['length_median']}/{c['length_p90']}/{c['length_max']}"
              f"  length>{LENGTH_THRESHOLD}: {c['length_over_threshold']}")
        print(f"  CCN total {c['ccn_total']} by directory: "
              + ', '.join(f'{k} {v}' for k, v in list(c['ccn_by_directory'].items())[:8]))
        for w in c['worst']:
            print(f"    CCN {w['ccn']:>3}  len {w['length']:>4}  {w['function']}  {w['file']}:{w['line']}")
        d = (report['duplication'] or {}).get(language)
        if d:
            print(f"  exact clones: {d['clones']} ({d['lines']} lines, {d['percent']}%)")
    n = report['nesting']
    print(f"\n[nesting] swift p90/max {n['swift']['p90']}/{n['swift']['max']}  >{NESTING_THRESHOLD}: {n['swift']['over_threshold']}"
          f"  | rust p90/max {n['rust']['p90']}/{n['rust']['max']}  >{NESTING_THRESHOLD}: {n['rust']['over_threshold']}")
    for language in ('swift', 'rust'):
        for w in n[language]['worst'][:5]:
            print(f"    depth {w['depth']}  {w['function']}  {w['file']}:{w['line']}")
    c = report['co_change']
    print(f"\n[co-change] {c['commits']} multi-file commits; partners counted at >= {c['minimum']} shared commits")
    for pair in c['pairs'][:8]:
        print(f"    {pair['commits']:>3}  {Path(pair['files'][0]).name} + {Path(pair['files'][1]).name}")
    print('  most partners: ' + ', '.join(f"{Path(x['file']).name} {x['partners']}" for x in c['partners'][:8]))
    f = report['feedback']
    print(f"\n[feedback] test files {f['test_files']} (desktop {f['desktop_test_files']}, headless {f['headless_test_files']});"
          f" production Swift files named by a headless test: {f['named_by_headless_test']}/{f['production_files']}")
    k = report['coupling']
    print(f"\n[coupling] files reaching TerminalRuntime.shared: {k['runtime_shared_files']}")
    print('  members: ' + ', '.join(f'{m} {n}' for m, n in k['runtime_shared_members'].items()))
    print('  writers of .spaces outside Workspace.swift: '
          + ', '.join(f'{f} {n}' for f, n in k['spaces_writers_outside_workspace'].items()))
    print('  writers of .selectedSpace outside Workspace.swift: '
          + ', '.join(f'{f} {n}' for f, n in k['selection_writers_outside_workspace'].items()))
    print('  collection-typed stored properties: '
          + ', '.join(f"{Path(f).name} {n}" for f, n in k['collection_properties'].items()))


def compare(ref):
    """Run this script inside a temporary worktree at `ref` and print CCN totals side by side."""
    import tempfile
    with tempfile.TemporaryDirectory() as temporary:
        worktree = Path(temporary) / 'worktree'
        subprocess.run(['git', 'worktree', 'add', '--detach', str(worktree), ref], cwd=ROOT, check=True,
                       capture_output=True)
        try:
            # Apply the same parser corrections and scope to both revisions.
            script = Path(__file__).resolve()
            other = json.loads(subprocess.run([sys.executable, str(script), '--json'], capture_output=True, text=True,
                                              cwd=worktree, check=True, env={**os.environ, 'QUALITY_METRICS_ROOT': str(worktree)}).stdout)
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(worktree)], cwd=ROOT, capture_output=True)
    here = json.loads(subprocess.run([sys.executable, str(Path(__file__).resolve()), '--json'], capture_output=True,
                                     text=True, cwd=ROOT, check=True).stdout)
    print(f"{'measure':<38} {ref[:12]:>14} {'working tree':>14} {'delta':>8}")
    for language in ('swift', 'rust'):
        a = (other['complexity'] or {}).get(language) or {}
        b = (here['complexity'] or {}).get(language) or {}
        rows = [(f'{language} CCN total', 'ccn_total'), (f'{language} functions', 'functions'),
                (f'{language} CCN > {COMPLEXITY_THRESHOLD}', 'ccn_over_threshold'),
                (f'{language} length > {LENGTH_THRESHOLD}', 'length_over_threshold')]
        for label, key in rows:
            x, y = a.get(key, 0), b.get(key, 0)
            print(f"{label:<38} {x:>14} {y:>14} {y - x:>+8}")
        for directory in sorted(set(a.get('ccn_by_directory', {})) | set(b.get('ccn_by_directory', {}))):
            x = a.get('ccn_by_directory', {}).get(directory, 0)
            y = b.get('ccn_by_directory', {}).get(directory, 0)
            if x != y:
                print(f"{'  ' + language + ' ' + directory:<38} {x:>14} {y:>14} {y - x:>+8}")
    x, y = other['sizes']['swift_production_lines'] + other['sizes']['rust_production_lines'], \
        here['sizes']['swift_production_lines'] + here['sizes']['rust_production_lines']
    print(f"{'production lines':<38} {x:>14} {y:>14} {y - x:>+8}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true', help='print the full report as JSON')
    parser.add_argument('--duplication', action='store_true', help='also run jscpd via npx (downloads the tool)')
    parser.add_argument('--against', metavar='REF', help='compare CCN totals of the working tree with a git ref')
    args = parser.parse_args()
    if args.against:
        compare(args.against)
        return
    import tempfile
    with tempfile.TemporaryDirectory() as temporary:
        report = {
            'commit': git_commit(),
            'tools': {'lizard': lizard_version(), 'thresholds': {'ccn': COMPLEXITY_THRESHOLD, 'length': LENGTH_THRESHOLD}},
            'sizes': sizes(),
            'complexity': complexity(Path(temporary)),
            'duplication': duplication(Path(temporary)) if args.duplication else None,
            'coupling': coupling(),
            'nesting': {'swift': nesting(swift_files(), SWIFT_FUNCTION), 'rust': nesting(rust_files(), RUST_FUNCTION)},
            'co_change': co_change(),
            'feedback': feedback(),
        }
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_text(report)


if __name__ == '__main__':
    main()
