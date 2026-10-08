"""Strict xcresult case extraction and selection-aware timing reports."""
from collections import defaultdict
import json
import math
from selection import normalize


def cases_from_result(value):
    if not isinstance(value, dict) or not isinstance(value.get('testNodes'), list):
        raise ValueError('Missing XCTest result tree')
    cases = []

    def visit(node):
        if node.get('nodeType') == 'Test Case':
            identifier = normalize([node['nodeIdentifier']])[0]
            if len(identifier.split('/')) != 3:
                raise ValueError('Incomplete result identifier: ' + identifier)
            outcome = node.get('result')
            seconds = node.get('durationInSeconds')
            if not (seconds is None and outcome in ('Failed', 'Skipped')) and (
                    type(seconds) not in (float, int) or not math.isfinite(seconds) or seconds < 0):
                raise ValueError('Invalid case duration: ' + identifier)
            if not isinstance(outcome, str):
                raise ValueError('Missing case outcome: ' + identifier)
            cases.append({'identifier': identifier, 'seconds': seconds, 'outcome': outcome})
            return
        for child in node.get('children', []):
            visit(child)

    for node in value['testNodes']:
        visit(node)
    return cases


def report(selection, cases, fingerprint, versions, stages):
    identifiers = [case['identifier'] for case in cases]
    selected, executed = set(selection['selected']), set(identifiers)
    classes = defaultdict(float)
    for case in cases:
        if case['seconds'] is not None:
            classes[case['identifier'].rsplit('/', 1)[0]] += case['seconds']
    duplicates = sorted(identifier for identifier in executed if identifiers.count(identifier) != 1)
    return {
        'version': 1, 'suite': selection['suite'], 'source_fingerprint': fingerprint,
        'tool_versions': versions, 'stages': stages,
        'selected_identifiers': selection['selected'], 'executed_identifiers': identifiers,
        'excluded_identifiers': selection['excluded'],
        'missing_identifiers': sorted(selected - executed), 'unexpected_identifiers': sorted(executed - selected),
        'duplicate_identifiers': duplicates,
        'complete': bool(cases) and selected == executed and not duplicates,
        'cases': cases,
        'missing_duration_identifiers': [case['identifier'] for case in cases if case['seconds'] is None],
        'slowest_cases': sorted((case for case in cases if case['seconds'] is not None),
                                key=lambda case: case['seconds'], reverse=True)[:25],
        'slowest_classes': sorted(({'identifier': name, 'seconds': seconds} for name, seconds in classes.items()),
                                  key=lambda item: item['seconds'], reverse=True)[:25],
    }


def compare(current, baseline):
    before = {case['identifier']: case for case in baseline['cases']}
    after = {case['identifier']: case for case in current['cases']}
    common = sorted(name for name in before.keys() & after.keys()
                    if before[name]['seconds'] is not None and after[name]['seconds'] is not None)
    return {
        'baseline_suite': baseline['suite'], 'current_suite': current['suite'],
        'same_selection': before.keys() == after.keys(),
        'added_identifiers': sorted(after.keys() - before.keys()),
        'removed_identifiers': sorted(before.keys() - after.keys()),
        'common_case_count': len(common),
        'common_before_seconds': sum(before[name]['seconds'] for name in common),
        'common_after_seconds': sum(after[name]['seconds'] for name in common),
        'note': 'Case-time sums exclude runner overhead. Changed selections do not measure an unchanged suite speedup.',
    }
