"""Split one XCTest selection across macOS VMs by whole class, then merge results.

Each shard is an ordinary single-VM run: cases never share a desktop, and a
class keeps its cases (and their order) together in one VM. Only the primary
VM is paired with the Linux SSH server, so every Linux-dependent class stays
there.
"""
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent.parent
TARGET = 'DispatchTests'
# Classes that read the per-run Linux pairing profile (SSHLinuxTestProfile).
PRIMARY_ONLY = frozenset(TARGET + '/' + name for name in (
    'SSHLinuxIntegrationTests', 'SSHHostIsolationIntegrationTests', 'HostLinuxIntegrationTests',
    'SSHLinuxClaudeIntegrationTests', 'SSHLinuxPiIntegrationTests', 'SSHProcessStatisticsIntegrationTests'))
EXCLUDED = 'other VM shard'
GIB = 1024 ** 3
# Automatic sharding needs at least this much planned work on the lighter VM;
# smaller selections finish sooner without a second source sync and build.
MIN_SHARD_SECONDS = 180
# Live free memory required beyond the VMs being booted, for other host apps.
HEADROOM = 4 * GIB


def class_of(case):
    return case.rsplit('/', 1)[0]


def history(root=ROOT):
    """Latest recorded seconds per case and Linux pairing time, newest run first."""
    durations, pairing = {}, None
    runs = sorted((root / 'tmp/profiling/test-runs').glob('*/TestTimings.json'), reverse=True)
    for path in runs + [root / 'test/baseline-timings.json']:
        try:
            timing = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for case in timing.get('cases', []) if isinstance(timing, dict) else []:
            if isinstance(case, dict) and isinstance(case.get('seconds'), (int, float)):
                durations.setdefault(case.get('identifier'), float(case['seconds']))
        for stage in timing.get('host_stages', []) if isinstance(timing, dict) else []:
            if pairing is None and stage.get('name') == 'linux_preparation':
                pairing = float(stage.get('seconds') or 0)
    return durations, pairing


def plan(cases, count, durations=None, primary_overhead=0.0):
    """Longest-processing-time assignment of whole classes; shard 0 is primary.

    Deterministic for identical inputs. Returns sorted class lists, omitting
    nothing: every selected case's class appears in exactly one shard.
    """
    if count < 1:
        raise ValueError('Shard count must be positive')
    durations, selected = durations or {}, set(cases)
    known = [seconds for case, seconds in durations.items() if case in selected]
    fallback = statistics.median(known) if known else 1.0
    weights = {}
    for case in cases:
        weights[class_of(case)] = weights.get(class_of(case), 0.0) + durations.get(case, fallback)
    loads = [0.0] * count
    shards = [[] for _ in range(count)]
    primary = sorted(name for name in weights if name in PRIMARY_ONLY)
    if primary:
        loads[0] += primary_overhead
    for name in primary:
        shards[0].append(name)
        loads[0] += weights[name]
    for name in sorted((name for name in weights if name not in PRIMARY_ONLY), key=lambda name: (-weights[name], name)):
        index = min(range(count), key=lambda index: (loads[index], index))
        shards[index].append(name)
        loads[index] += weights[name]
    return [sorted(shard) for shard in shards], loads


def restrict(selection, classes):
    """Keep the suite name while limiting the selection to this shard's classes."""
    classes = set(classes)
    if not classes or any(len(name.split('/')) != 2 or not name.startswith(TARGET + '/') for name in classes):
        raise ValueError('Invalid shard class list')
    selected = [case for case in selection['selected'] if class_of(case) in classes]
    if not selected:
        raise ValueError('Shard contains no selected XCTest cases')
    excluded = dict(selection['excluded'])
    excluded.update({case: EXCLUDED for case in selection['selected'] if class_of(case) not in classes})
    return {**selection, 'selected': selected, 'excluded': excluded,
            'unclassified': [case for case in selection['unclassified'] if class_of(case) in classes]}


def merge_summaries(summaries):
    """Combine xcresult summaries so failures from every shard stay selectable."""
    merged = dict(summaries[0])
    for name in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'expectedFailures'):
        merged[name] = sum(summary.get(name, 0) for summary in summaries)
    merged['testFailures'] = [failure for summary in summaries for failure in summary.get('testFailures', [])]
    merged['devicesAndConfigurations'] = [item for summary in summaries
                                          for item in summary.get('devicesAndConfigurations', [])]
    merged['topInsights'] = [item for summary in summaries for item in summary.get('topInsights', [])]
    merged['startTime'] = min(summary.get('startTime', 0) for summary in summaries)
    merged['finishTime'] = max(summary.get('finishTime', 0) for summary in summaries)
    merged['result'] = 'Passed' if all(summary.get('result') == 'Passed' for summary in summaries) else 'Failed'
    return merged


def merge_timings(selection, timings):
    """Validate the union of shard runs against the parent's full selection."""
    cases = [case for timing in timings for case in timing.get('cases', [])]
    identifiers = [case['identifier'] for case in cases]
    selected, executed = set(selection['selected']), set(identifiers)
    duplicates = sorted(identifier for identifier in executed if identifiers.count(identifier) != 1)
    errors = [timing['runner_error'] for timing in timings if timing.get('runner_error')]
    merged = {
        'version': 1, 'suite': selection['suite'], 'sharded': True,
        'source_fingerprints': sorted({timing.get('source_fingerprint') for timing in timings}),
        'selected_identifiers': selection['selected'], 'executed_identifiers': identifiers,
        'excluded_identifiers': selection['excluded'],
        'missing_identifiers': sorted(selected - executed), 'unexpected_identifiers': sorted(executed - selected),
        'duplicate_identifiers': duplicates,
        'complete': bool(cases) and selected == executed and not duplicates
                    and all(timing.get('complete') for timing in timings),
        'cases': cases,
        'missing_duration_identifiers': [case['identifier'] for case in cases if case['seconds'] is None],
        'slowest_cases': sorted((case for case in cases if case['seconds'] is not None),
                                key=lambda case: case['seconds'], reverse=True)[:25],
    }
    if errors:
        merged['runner_error'] = '; '.join(errors)
    return merged


def host_reserve(total):
    """Memory never promised to VMs: a quarter of RAM, and at least 8 GB."""
    return max(8 * GIB, total // 4)


def capacity(total, available, cpus, running, starting):
    """Return why the VMs cannot safely run together, or None.

    running and starting list (name, memory bytes, CPUs). Allocations are
    counted in full: a VM's untouched memory is lazily backed, so live free
    memory alone would admit a VM that later grows into swap.
    """
    committed = sum(memory for _, memory, _ in running + starting)
    budget = total - host_reserve(total)
    if committed > budget:
        return (f"VMs would need {committed / GIB:.0f} GB, above the {budget / GIB:.0f} GB "
                f"left after reserving {host_reserve(total) / GIB:.0f} GB of {total / GIB:.0f} GB for macOS")
    needed = sum(memory for _, memory, _ in starting)
    if needed and available < needed + HEADROOM:
        return (f"{available / GIB:.0f} GB is free; booting {', '.join(name for name, _, _ in starting)} "
                f"needs {(needed + HEADROOM) / GIB:.0f} GB")
    requested = sum(count for _, _, count in running + starting)
    if requested > cpus:
        return f"VMs would need {requested} CPUs; this host has {cpus}"
    return None


def worthwhile(groups, loads):
    """Whether a second VM saves meaningful time for this selection."""
    return all(groups) and min(loads) >= MIN_SHARD_SECONDS
