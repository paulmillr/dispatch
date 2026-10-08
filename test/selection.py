"""Shared XCTest selection and explicit failed-run selection."""
import json
from pathlib import Path
import re

TARGET = "DispatchTests"


def normalize(values):
    result = []
    for value in values:
        value = value.removesuffix("()")
        parts = value.split("/")
        if parts[0] != TARGET:
            parts.insert(0, TARGET)
        if not 1 <= len(parts) <= 3 or any(not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part) for part in parts):
            raise ValueError("Invalid XCTest identifier: " + value)
        identifier = "/".join(parts)
        if identifier not in result:
            result.append(identifier)
    return result


def failed_tests(path):
    path = Path(path)
    if path.is_dir():
        path = path / ("build/TestSummary.json" if (path / "build/TestSummary.json").exists() else "TestSummary.json")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get("testFailures"), list):
        raise ValueError("Expected an XCTest summary with testFailures: " + str(path))
    values = []
    for failure in data["testFailures"]:
        if not isinstance(failure, dict) or failure.get("targetName") != TARGET:
            raise ValueError("Cannot safely select a failure from this test target")
        identifier = failure.get("testIdentifierString")
        if not isinstance(identifier, str) or len(identifier.removesuffix("()").split("/")) != 2:
            raise ValueError("Failure has no complete XCTest case identifier")
        values.append(identifier)
    if not values:
        raise ValueError("This run has no failed XCTest cases; no tests were started")
    return normalize(values)


SUITES = ('fast', 'full', 'exhaustive')
BENCHMARKS = ('DispatchTests/ChatScrollBenchmarkTests', 'DispatchTests/HostScalingBenchmarkTests', 'DispatchTests/UIBenchmarkTests',
              'DispatchTests/UISettingsBenchmarkTests', 'DispatchTests/TerminalFPSBenchmarkTests')
ROOT = Path(__file__).resolve().parent.parent


def inventory(root=ROOT):
    """Discover the repository's named XCTest methods, including mixed classes.

    Classification is deliberately separate: discovering a new method never
    authorizes it for fast execution. Result identifiers verify this inventory.
    """
    cases = []
    tokens = re.compile(r'//[^\n]*|/\*|(?P<raw>\#*)(?P<quote>"""|")(?:\\(?P=raw).|(?!(?P=quote)(?P=raw)).)*(?P=quote)(?P=raw)', re.S)
    comments = re.compile(r'/\*|\*/')
    for path in sorted((root / 'DispatchTests').rglob('*.swift')):
        source = path.read_text()
        parts, offset, depth = [], 0, 0
        while token := (comments if depth else tokens).search(source, offset):
            parts.append('\n' * source[offset:token.start()].count('\n') if depth else source[offset:token.start()])
            if token[0] == '/*':
                depth += 1
            elif token[0] == '*/':
                depth -= 1
            parts.append(' ' + '\n' * token[0].count('\n'))
            offset = token.end()
        if depth:
            raise ValueError('Unterminated Swift comment: ' + str(path))
        parts.append(source[offset:])
        owner = None
        for line in ''.join(parts).splitlines():
            declaration = re.match(r'\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b', line)
            extension = re.match(r'\s*extension\s+(\w+Tests)\b', line)
            if declaration or extension:
                owner = (declaration or extension)[1]
            method = re.match(r'\s*(?:@\w+\s+)?func\s+(test\w+)\s*\(\s*\)', line)
            if owner and method:
                cases.append(f'{TARGET}/{owner}/{method[1]}')
    if not cases or len(cases) != len(set(cases)):
        raise ValueError('Empty or ambiguous XCTest source inventory')
    return sorted(cases)


def matches(case, selectors):
    return any(case == item or case.startswith(item + '/') for item in selectors)


def resolve(tests=(), skips=(), suite=None, benchmarks=False, root=ROOT):
    tests, skips = normalize(tests), normalize(skips)
    if suite and tests:
        raise ValueError('Choose explicit test identifiers or --suite, not both')
    if suite is not None and suite not in SUITES:
        raise ValueError('Unknown test suite: ' + suite)
    selected_suite = 'explicit' if tests else suite or ('full' if benchmarks else 'fast')
    if selected_suite == 'fast' and benchmarks:
        raise ValueError('--benchmarks cannot be combined with --suite fast')
    cases = inventory(root)
    manifest = json.loads((root / 'test/suites.json').read_text())
    if manifest.get('version') != 1 or not isinstance(manifest.get('cases'), dict):
        raise ValueError('Invalid suite manifest')
    classifications = manifest['cases']
    for case, tier in classifications.items():
        if case not in cases or tier not in SUITES:
            raise ValueError('Stale or invalid suite manifest entry: ' + case)
    for selector in tests + skips:
        if not any(matches(case, [selector]) for case in cases):
            raise ValueError('Unknown XCTest selector: ' + selector)
    selected, excluded = [], {}
    for case in cases:
        reason = None
        tier = classifications.get(case, 'full')
        if matches(case, skips):
            reason = 'explicit skip'
        elif tests:
            if not matches(case, tests):
                reason = 'outside explicit selection'
        elif matches(case, BENCHMARKS):
            if not benchmarks:
                reason = 'benchmark (opt-in)'
        elif SUITES.index(tier) > SUITES.index(selected_suite):
            reason = tier + ' coverage'
        if reason:
            excluded[case] = reason
        else:
            selected.append(case)
    if not selected:
        raise ValueError('Selection contains no XCTest cases; no tests were started')
    return {'suite': selected_suite, 'selected': selected, 'excluded': excluded,
            'unclassified': [case for case in cases if case not in classifications]}


def describe(selection, list_cases=False):
    from collections import Counter
    print(f"XCTest suite: {selection['suite']}; expected cases: {len(selection['selected'])}", flush=True)
    counts = Counter(selection['excluded'].values())
    print('Exclusions: ' + (', '.join(f'{reason}: {count}' for reason, count in sorted(counts.items())) or 'none'), flush=True)
    if selection['unclassified']:
        print(f"Unclassified cases retained in full/exhaustive: {len(selection['unclassified'])}", flush=True)
    if list_cases:
        for case in selection['selected']:
            print(case)
        for case, reason in selection['excluded'].items():
            print(f'- {case}: {reason}')


def add_arguments(parser):
    parser.add_argument('tests', nargs='*', help='Explicit XCTest class/case identifiers (cannot combine with --suite)')
    parser.add_argument('--skip', action='append', default=[])
    parser.add_argument('--suite', choices=SUITES, help='Default: fast. A default pass establishes fast checks only.')
    parser.add_argument('--list', action='store_true', help='Show selected cases and exclusions without preparing dependencies')
    parser.add_argument('--recheck', action='store_true', help='Force the build despite matching fingerprints')
    parser.add_argument('--benchmarks', action='store_true', help='Include benchmarks; implies full when no suite is given')
