#!/usr/bin/env python3
"""Run reproducible Dispatch benchmarks and compare compatible completed runs."""
import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/benchmarks'
VERSION = 1
UI = 'DispatchTests/UIBenchmarkTests/'
QUICK = ['testChatHistoryAndCodePreviews']
FULL = QUICK + ['testDesktopNavigationAndResize', 'testLiveTerminalInputAndScroll',
                'testSidebarScrollingAndFiltering', 'testSettings',
                'testTerminalLifecycle', 'testIdleTerminals', 'testMixedOutputAndNavigation']
EXPECTED = {
    'testChatHistoryAndCodePreviews': ['chat-mixed-history-scroll-450', 'code-block-resize-350-lines', 'code-document-resize-350-lines'],
    'testDesktopNavigationAndResize': ['desktop-space-switch-6', 'desktop-tab-switch-12', 'desktop-sidebar-toggle', 'desktop-split-window-resize'],
    'testLiveTerminalInputAndScroll': [backend + '-' + action for backend in ('local', 'ssh', 'tmux', 'herdr')
                                       for action in ('input-reply', 'terminal-scroll')],
    'testSidebarScrollingAndFiltering': [f'sidebar-{action}-{size}' for size in (40, 240) for action in ('scroll', 'filter')],
    'testSettings': ['settings-scroll'],
    'testTerminalLifecycle': ['local-terminal-create-ready-close'],
    'testIdleTerminals': ['idle-four-terminals'],
    'testMixedOutputAndNavigation': ['mixed-three-output-space-switch', 'mixed-three-output-sustained'],
}


# Reserved for the user's manual SSH testing; never a benchmark server.
MANUAL_LIMA = 'dispatch-manual-ssh'


def ssh_backend(folder):
    """Choose the ssh workload's server. Release helpers always require a
    root-owned sshd monitor: prefer a running Dispatch Lima VM (root sshd in
    the VM), else a loopback sshd started through passwordless sudo, else skip."""
    if shutil.which('limactl'):
        try:
            lines = subprocess.check_output(['limactl', 'list', '--json'], text=True, timeout=30).splitlines()
        except (OSError, subprocess.SubprocessError):
            lines = []
        for item in sorted((json.loads(line) for line in lines if line.strip()), key=lambda item: item['name']):
            if item.get('status') != 'Running' or not item['name'].startswith('dispatch-') or item['name'] == MANUAL_LIMA:
                continue
            try:
                settings = {}
                for line in subprocess.check_output(['ssh', '-G', '-F', item['sshConfigFile'], item['hostname']],
                                                    text=True, stderr=subprocess.DEVNULL, timeout=30).splitlines():
                    key, _, value = line.partition(' ')
                    settings.setdefault(key, value)
                # Not Lima's ssh.config: its connection sharing keeps Dispatch's helper out.
                # Like that config, the loopback VM's host key is not pinned.
                options = ['-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'IdentitiesOnly=yes',
                           '-i', settings['identityfile'], '-p', settings['port'], '-o', 'StrictHostKeyChecking=no',
                           '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR']
                destination = settings['user'] + '@' + settings['hostname']
                if subprocess.run(['ssh', '-T', *options, destination, 'true'], stdin=subprocess.DEVNULL,
                                  capture_output=True, timeout=30).returncode != 0:
                    continue
            except (OSError, KeyError, subprocess.SubprocessError):
                continue
            profile = folder / 'lima-ssh.json'
            write_json(profile, {'destination': destination, 'options': options})
            return {'mode': 'lima', 'server': item['name']}, profile
    if subprocess.run(['sudo', '-n', 'true'], stdin=subprocess.DEVNULL, capture_output=True).returncode == 0:
        return {'mode': 'loopback'}, None
    return {'mode': 'skipped', 'reason': 'No running Dispatch Lima VM, and sudo needs a password'}, None


def ssh_mode(report):
    # Reports from before this choice always measured the loopback sshd.
    return (report.get('ssh_backend') or {'mode': 'loopback'})['mode']


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')
    temporary.replace(path)


def capture(*command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def source_identity():
    # Include untracked source and working-tree edits without storing their contents.
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT)
    digest = hashlib.sha256()
    for name in sorted(set(paths.split(b'\0')) - {b''}):
        path = ROOT / os.fsdecode(name)
        digest.update(name + b'\0')
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode())
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
        else:
            digest.update(b'<missing>')
    return {'revision': capture('git', 'rev-parse', 'HEAD'),
            'dirty': bool(capture('git', 'status', '--porcelain')),
            'sha256': digest.hexdigest()}


def environment(kind):
    return {'kind': kind, 'os': platform.platform(), 'architecture': platform.machine(),
            'hardware': capture('sysctl', '-n', 'hw.model'),
            'cpu': capture('sysctl', '-n', 'machdep.cpu.brand_string'),
            'memory_bytes': capture('sysctl', '-n', 'hw.memsize'),
            'xcode': capture('xcodebuild', '-version'),
            'swift': capture('xcrun', 'swiftc', '--version'),
            'power': capture('pmset', '-g', 'batt').splitlines()[0]}


def desktop_environment():
    displays = json.loads(capture('system_profiler', 'SPDisplaysDataType', '-json'))
    # Retain display configuration, excluding serial numbers and unrelated inventory.
    configuration = []
    for gpu in displays.get('SPDisplaysDataType', []):
        configuration.append({'gpu': gpu.get('sppci_model'), 'displays': [
            {key: value for key, value in display.items() if key in
             ('_name', '_spdisplays_resolution', 'spdisplays_resolution', 'spdisplays_pixels',
              'spdisplays_main', 'spdisplays_online', 'spdisplays_refresh_rate', 'spdisplays_retina')}
            for display in gpu.get('spdisplays_ndrvs', [])]})
    tools = {}
    for name, flag in [('tmux', '-V'), ('herdr', '--version')]:
        path = Path('/opt/homebrew/bin') / name
        tools[name] = capture(str(path), flag) if path.exists() else 'unavailable'
    return {'displays': configuration, 'tools': tools}


def command(args, log, env=None):
    print(f'Running {args[0]} — {log}', flush=True)
    with log.open('w') as stream:
        subprocess.run(args, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)


def metric(name, unit, samples, direction='lower', sampling='fixed'):
    if not samples or any(type(x) not in (int, float) or not math.isfinite(x) for x in samples):
        raise ValueError(f'Invalid samples: {name}')
    if direction not in ('lower', 'higher') or sampling not in ('fixed', 'observed'):
        raise ValueError(f'Invalid metric semantics: {name}')
    return {'name': name, 'unit': unit, 'direction': direction, 'sampling': sampling, 'samples': samples}


def ui_reports(folder):
    reports = []
    for path in sorted((folder / 'ui').glob('*.json')):
        value = json.loads(path.read_text())
        name = value['name']
        reports.extend([
            metric(name + '/latency', 'ms', [x * 1000 for x in value['seconds']]),
            metric(name + '/cpu', 's', [value['cpuSeconds']]),
            metric(name + '/peak-rss', 'MiB', [value['peakResident'] / 2**20]),
            metric(name + '/rss-growth', 'MiB', [(value['residentAfter'] - value['residentBefore']) / 2**20])])
        if value['heartbeatSeconds']:
            reports.append(metric(name + '/heartbeat-gap', 'ms', [x * 1000 for x in value['heartbeatSeconds']], sampling='observed'))
    lifecycle = folder / 'settings/settings-lifecycle.json'
    if lifecycle.exists():
        values = json.loads(lifecycle.read_text())
        if len(values) != 12:
            raise ValueError('Incomplete settings lifecycle')
        reports.extend([
            metric('settings-lifecycle/cold-open', 'ms', [values[0]['seconds'] * 1000]),
            metric('settings-lifecycle/warm-open', 'ms', [v['seconds'] * 1000 for v in values[1:]]),
            metric('settings-lifecycle/closed-growth', 'MiB',
                   [(values[-1]['residentClosed'] - values[0]['residentClosed']) / 2**20])])
    for path in sorted((folder / 'dense').glob('*.json')):
        value = json.loads(path.read_text())
        name = 'dense-history-' + str(value['stepsPerReply'])
        reports.append(metric(name + '/page-read', 'ms', value['readMs']))
        reports.append(metric(name + '/release-layout', 'ms', [v['releaseToLayoutMs'] for v in value['gestures']]))
    if not reports:
        raise ValueError(f'No benchmark reports in {folder}')
    return reports


def test_targets(plan):
    if 'TestConfigurations' in plan:
        return [target for config in plan['TestConfigurations'] for target in config['TestTargets']]
    return [value for key, value in plan.items() if not key.startswith('__') and isinstance(value, dict)]


def run_ui(plan, selection, folder, seconds, ssh=None, ssh_profile=None):
    folder.mkdir()
    data = plistlib.loads(plan.read_bytes())
    for target in test_targets(data):
        for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
            env = target.setdefault(key, {})
            env['DYLD_INSERT_LIBRARIES'] = ':'.join(p for p in env.get('DYLD_INSERT_LIBRARIES', '').split(':')
                if p and 'libMainThreadChecker' not in p and 'libRPAC' not in p)
            for name in list(env):
                if name.startswith('PERFC_'):
                    del env[name]
            env.update(DISPATCH_TESTING='1', DISPATCH_BENCHMARK_OUTPUT=str(folder),
                       DISPATCH_BENCHMARK_SECONDS=str(seconds))
            if ssh:
                env['DISPATCH_BENCHMARK_SSH'] = ssh['mode']
                if ssh_profile:
                    env['DISPATCH_BENCHMARK_SSH_PROFILE'] = str(ssh_profile)
    # Preserve __TESTROOT__ relative to the original products, not the report directory.
    modified = plan.parent / 'benchmark-run.xctestrun'
    modified.write_bytes(plistlib.dumps(data))
    result = folder / 'tests.xcresult'
    command(['xcodebuild', '-xctestrun', str(modified), '-destination', 'platform=macOS',
             '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result),
             '-only-testing:' + selection, 'test-without-building'], folder / 'test.log')
    summary = json.loads(capture('xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)))
    write_json(folder / 'test-summary.json', summary)
    total = summary.get('totalTestCount', 0)
    if total <= 0 or summary.get('passedTests') != total or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0:
        raise ValueError('Benchmark tests failed, skipped, or did not execute')
    method = selection.split('/')[-1]
    if method in EXPECTED:
        actual = {json.loads(p.read_text())['name'] for p in (folder / 'ui').glob('*.json')}
        expected = {name for name in EXPECTED[method] if not (ssh and ssh['mode'] == 'skipped' and name.startswith('ssh-'))}
        if actual != expected:
            raise ValueError(f'Incomplete workload reports: {method}')
    elif method == 'testRepeatedSettingsLifecycle':
        if not (folder / 'settings/settings-lifecycle.json').is_file():
            raise ValueError('Missing settings report')
    elif method == 'testDenseAgenticHistoryPaging':
        if {p.name for p in (folder / 'dense').glob('*.json')} != {'dense-10.json', 'dense-20.json'}:
            raise ValueError('Incomplete dense history reports')
    return ui_reports(folder)


def run(args):
    if args.suite != 'core' and not args.desktop:
        raise ValueError('UI suites require --desktop and an idle unlocked desktop. Run inside your test VM or on a dedicated Mac.')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with (OUTPUT / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        folder = OUTPUT / args.label
        folder.mkdir()  # Never overwrite an earlier baseline, including a failed one.
        report = {'schema': VERSION, 'workload_version': VERSION, 'suite': args.suite,
                  'status': 'running', 'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'repeats': args.runs, 'duration_seconds': args.duration if args.suite == 'soak' else 5,
                  'configuration': 'Release -O; runtime checkers disabled for UI', 'runs': []}
        write_json(folder / 'report.json', report)
        try:
            report.update(environment=environment(args.environment), source=source_identity())
            if args.suite != 'core':
                report['environment']['desktop'] = desktop_environment()
            ssh, ssh_profile = ssh_backend(folder) if args.suite in ('full', 'soak') else (None, None)
            report['ssh_backend'] = ssh
            if ssh:
                print('ssh workload: ' + {'lima': 'Lima VM ' + ssh.get('server', ''), 'loopback': 'loopback sshd through sudo',
                                          'skipped': 'skipped (' + ssh.get('reason', '') + ')'}[ssh['mode']], flush=True)
            write_json(folder / 'report.json', report)
            binary = folder / 'core-benchmark'
            command(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-module-cache-path', str(folder / 'modules'),
                     'Dispatch/Herdr/HerdrLineBuffer.swift', 'Dispatch/Tmux/TmuxProtocol.swift',
                     'Dispatch/Tmux/TmuxOutputFilter.swift', 'scripts/benchmarks/CoreBenchmark.swift',
                     '-o', str(binary)], folder / 'core-build.log')
            plan = None
            if args.suite != 'core':
                products = OUTPUT / 'products'
                command(['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch',
                         '-configuration', 'Release', '-derivedDataPath', str(products),
                         '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
                         'ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                         'PRODUCT_BUNDLE_IDENTIFIER=dev.dispatch.benchmark.$(PRODUCT_NAME:rfc1034identifier)',
                         'build-for-testing'], folder / 'ui-build.log')
                plans = list((products / 'Build/Products').glob('Dispatch_*.xctestrun'))
                if len(plans) != 1:
                    raise ValueError('Expected exactly one built XCTest plan')
                plan = plans[0]
            for index in range(args.runs):
                repetition = folder / f'run-{index + 1}'
                repetition.mkdir()
                raw = subprocess.check_output([str(binary)], cwd=ROOT, text=True)
                values = json.loads(raw)
                write_json(repetition / 'core.json', values)
                metrics = []
                for value in values:
                    metrics.append(metric(value['name'] + '/latency', 'ms', [x * 1000 for x in value['seconds']]))
                    metrics.append(metric(value['name'] + '/throughput', 'MiB/s',
                                          [value['bytesPerSample'] / 2**20 / x for x in value['seconds']], 'higher'))
                if plan:
                    selections = [UI + name for name in (QUICK if args.suite == 'quick' else FULL)]
                    if args.suite in ('full', 'soak'):
                        selections += ['DispatchTests/UISettingsBenchmarkTests/testRepeatedSettingsLifecycle',
                                       'DispatchTests/ChatScrollBenchmarkTests/testDenseAgenticHistoryPaging']
                    for selection in selections:
                        metrics += run_ui(plan, selection, repetition / selection.split('/')[-1], report['duration_seconds'],
                                          ssh, ssh_profile)
                names = [m['name'] for m in metrics]
                if len(names) != len(set(names)):
                    raise ValueError('Duplicate workload metrics')
                report['runs'].append(metrics)
                write_json(folder / 'report.json', report)
            if source_identity() != report['source']:
                raise ValueError('Sources changed during the benchmark; results cannot be compared')
            report['status'] = 'complete'
        except BaseException as error:
            report.update(status='failed', error=str(error))
            raise
        finally:
            write_json(folder / 'report.json', report)
        print(f'Completed: {folder / "report.json"}')


def read_report(value):
    path = Path(value)
    if not path.exists():
        path = OUTPUT / value
    if path.is_dir():
        path /= 'report.json'
    report = json.loads(path.read_text())
    if report.get('schema') != VERSION or report.get('status') != 'complete':
        raise ValueError(f'Not a completed supported benchmark: {path}')
    if not report['runs'] or len(report['runs']) != report['repeats']:
        raise ValueError('Incomplete repetitions')
    return report


def summarize(report):
    workloads = {}
    expected = None
    for run in report['runs']:
        names = [m['name'] for m in run]
        if not names or len(names) != len(set(names)) or (expected is not None and set(names) != expected):
            raise ValueError('Workloads differ between repetitions')
        expected = set(names)
        for item in run:
            metric(**item)
            entry = workloads.setdefault(item['name'], {'unit': item['unit'], 'direction': item['direction'],
                                                       'sampling': item.get('sampling', 'fixed'), 'runs': []})
            if any(entry[key] != item.get(key, 'fixed') for key in ('unit', 'direction', 'sampling')):
                raise ValueError('Inconsistent metric units or direction')
            entry['runs'].append(item['samples'])
    for item in workloads.values():
        values = sorted(x for run in item['runs'] for x in run)
        medians = [statistics.median(run) for run in item['runs']]
        item.update(median=statistics.median(medians), run_medians=medians,
                    minimum=min(medians), maximum=max(medians), samples=len(values))
        if len(values) >= 20:
            item['p95'] = values[math.ceil(len(values) * .95) - 1]
        if len(values) >= 1000:
            item['p99'] = values[math.ceil(len(values) * .99) - 1]
    return workloads


def compare(before, after):
    for key in ('schema', 'workload_version', 'suite', 'environment', 'configuration', 'duration_seconds', 'repeats'):
        if before[key] != after[key]:
            raise ValueError(f'Incompatible runs: {key} differs')
    # Lima, loopback and skipped ssh workloads measure different things.
    if ssh_mode(before) != ssh_mode(after):
        raise ValueError('Incompatible runs: ssh backend differs')
    a, b = summarize(before), summarize(after)
    if set(a) != set(b):
        raise ValueError('Incompatible workload sets')
    changes = {}
    for name in sorted(a):
        left, right = a[name], b[name]
        if any(left[key] != right[key] for key in ('unit', 'direction', 'sampling')) or (left['sampling'] == 'fixed' and
                [len(r) for r in left['runs']] != [len(r) for r in right['runs']]):
            raise ValueError(f'Incompatible metric: {name}')
        baseline = left['median']
        changes[name] = {'before': left, 'after': right,
                         'delta': right['median'] - baseline,
                         'percent': (right['median'] / baseline - 1) * 100 if baseline > 0 else None}
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    execute = sub.add_parser('run', help='Run serially; requires prepared offline build dependencies')
    execute.add_argument('--suite', choices=['core', 'quick', 'full', 'soak'], default='core')
    execute.add_argument('--label', required=True)
    execute.add_argument('--runs', type=int, default=3)
    execute.add_argument('--desktop', action='store_true', help='Use the current unlocked desktop for UI suites')
    execute.add_argument('--environment', choices=['hardware', 'vm'], required=True)
    execute.add_argument('--duration', type=int, default=300, help='Seconds per idle/mixed phase for soak')
    diff = sub.add_parser('compare', help='Report changes without enforcing uncalibrated regression thresholds')
    diff.add_argument('before')
    diff.add_argument('after')
    diff.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'run':
            if not re.fullmatch(r'[A-Za-z0-9_-]+', args.label) or not 1 <= args.runs <= 20 or not 5 <= args.duration <= 3600:
                parser.error('Use an alphanumeric/hyphen/underscore label, 1–20 runs, and 5–3600 seconds')
            run(args)
        else:
            changes = compare(read_report(args.before), read_report(args.after))
            print('| Metric | Unit | Before median | After median | Change |')
            print('|---|---|---:|---:|---:|')
            for name, value in changes.items():
                percent = f'{value["percent"]:+.1f}%' if value['percent'] is not None else 'n/a'
                print(f'| {name} | {value["before"]["unit"]} | {value["before"]["median"]:.3f} | {value["after"]["median"]:.3f} | {percent} |')
            if args.output:
                with args.output.open('x') as stream:
                    json.dump(changes, stream, indent=2, allow_nan=False)
                    stream.write('\n')
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Benchmark: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
