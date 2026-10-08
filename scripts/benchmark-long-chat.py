#!/usr/bin/env python3
"""Reproducible large-transcript benchmark, without a CLI, network, or personal data.

Streams synthetic JSONL to disk; runs the optimized native reader and chat view.
Use --profile for a separate macOS sample run (its timings are diagnostic only).
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/long-chat-benchmark'
SESSION = '11111111-1111-4111-8111-111111111111'


def fixture(shape, mib):
    path = OUTPUT / f'{shape}-{mib}MiB.jsonl'
    if path.exists():
        return path
    temporary = path.with_suffix('.tmp')
    with temporary.open('wb') as stream:
        def line(kind, **payload):
            stream.write(json.dumps({'type': kind, 'timestamp': '2000-01-01T00:00:00.000Z',
                                     'payload': payload}, separators=(',', ':')).encode() + b'\n')
        line('session_meta', id=SESSION, cli_version='0.154.0')
        line('turn_context', turn_id='turn-0', model='synthetic-model', effort='high')
        # Legacy records omit IDs inside one long, unfinished agent turn.
        if shape == 'legacy':
            line('event_msg', type='task_started', turn_id='turn-0')
        index = 0
        output = ('Sources/Example.swift:42: synthetic output with Unicode café 日本語 🙂\n' * 220)
        while stream.tell() < mib * 1024 * 1024:
            turn = f'turn-{index}' if shape == 'modern' else 'turn-0'
            context = {'turn_id': turn} if shape == 'modern' else {}
            if shape == 'modern':
                line('event_msg', type='task_started', **context)
                line('turn_context', model='synthetic-model', effort='high', **context)
            line('event_msg', type='user_message', message=f'Investigate change {index}', **context)
            for step in range(4):
                call = f'call-{index}-{step}'
                line('response_item', type='function_call', call_id=call, name='exec_command',
                     arguments=json.dumps({'cmd': f'rg example-{index}-{step} Sources'}), **context)
                line('response_item', type='function_call_output', call_id=call,
                     output=f'Result {index}/{step}\n' + output, **context)
            line('event_msg', type='agent_message', message=f'Change **{index}** checked.\n\n```swift\nlet result = {index}\n```', **context)
            if shape == 'modern':
                line('event_msg', type='task_complete', **context)
            index += 1
    temporary.replace(path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--shape', choices=['modern', 'legacy'], default='modern')
    parser.add_argument('--mib', type=int, default=500)
    parser.add_argument('--pages', type=int, default=12, help='Older pages retained in the session before scrolling')
    parser.add_argument('--scan-all', action='store_true', help='Then stream all remaining pages without retaining them')
    parser.add_argument('--measure-history-rows', action='store_true', help='Measure row preparation after each history merge; warms row caches before mounting the view')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--duration', type=float, default=5)
    parser.add_argument('--live-pages', action='store_true', help='Load older pages while scrolling upward; requires --foreground')
    parser.add_argument('--speed', type=float, default=2400, help='Requested scroll speed in points per second')
    parser.add_argument('--reconnect-overlay', action='store_true', help='Show the disconnected SSH control during scrolling')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--profile', action='store_true', help='Separate 30-second CPU stack sample')
    parser.add_argument('--foreground', action='store_true', help='Activate the isolated test app through Launch Services (required for UI measurements)')
    args = parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.label):
        parser.error('Use an alphanumeric label, optionally with hyphens/underscores')
    if not 1 <= args.mib <= 2048 or not 0 <= args.pages <= 1000 or not 1 <= args.runs <= 20 or not 1 <= args.duration <= 60:
        parser.error('Use 1–2048 MiB, 0–1000 pages, 1–20 runs and 1–60 seconds')
    if not 1 <= args.speed <= 60000 or (args.live_pages and (not args.foreground or args.scan_all)):
        parser.error('Use speed 1–60000; live pages require --foreground and cannot use --scan-all')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with (OUTPUT / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        source = fixture(args.shape, args.mib)
        with source.open('rb') as stream:
            expected_records = sum(block.count(b'\n') for block in iter(lambda: stream.read(1024 * 1024), b''))
        def run(command, name):
            with (OUTPUT / (name + '.log')).open('w') as log:
                print(name, flush=True)
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        if not args.no_build:
            run(['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch', '-configuration', 'Release',
                 '-derivedDataPath', 'build/long-chat-products', '-destination', 'platform=macOS',
                 '-parallel-testing-enabled', 'NO', 'ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                 'PRODUCT_BUNDLE_IDENTIFIER=dev.dispatch.long-benchmark.$(PRODUCT_NAME:rfc1034identifier)',
                 'build-for-testing'], 'build')
            (OUTPUT / 'build-sources.json').write_text(json.dumps({str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((ROOT / 'Dispatch').rglob('*.swift'))}, indent=2))
        products = ROOT / 'build/long-chat-products/Build/Products'
        plan = plistlib.loads(next(products.glob('Dispatch_*.xctestrun')).read_bytes())
        target = plan['DispatchTests']
        for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
            env = target.setdefault(key, {})
            env['DYLD_INSERT_LIBRARIES'] = ':'.join(p for p in env.get('DYLD_INSERT_LIBRARIES', '').split(':')
                if p and 'libMainThreadChecker' not in p and 'libRPAC' not in p)
            for name in list(env):
                if name.startswith('PERFC_'):
                    del env[name]
        testplan = products / 'long-benchmark.xctestrun'
        testplan.write_bytes(plistlib.dumps(plan))
        execute = ['xcodebuild', '-xctestrun', str(testplan), '-destination', 'platform=macOS',
                   '-parallel-testing-enabled', 'NO', '-only-testing:DispatchTests/ChatScrollBenchmarkTests/testLargeSyntheticConversation',
                   '-collect-test-diagnostics', 'never', 'test-without-building']
        config, ready = OUTPUT / 'input.json', OUTPUT / 'ready.json'
        try:
            for index in range(args.runs):
                label = f'{args.label}-{index + 1}'
                report = OUTPUT / (label + '.json')
                if report.exists():
                    raise RuntimeError(f'Refusing to overwrite {report}')
                ready.unlink(missing_ok=True)
                metadata = {'arguments': vars(args), 'fixtureBytes': source.stat().st_size,
                    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                    'hardware': subprocess.check_output(['sysctl', '-n', 'hw.model', 'hw.memsize', 'hw.ncpu'], text=True).strip(),
                    'sourceHashes': json.loads((OUTPUT / 'build-sources.json').read_text()),
                    'note': 'Warm filesystem cache; isolated Release process; runtime checkers disabled. sample profiles are diagnostic, not comparison timings.'}
                (OUTPUT / (label + '-environment.json')).write_text(json.dumps(metadata, indent=2))
                config.write_text(json.dumps({'path': str(source), 'session': SESSION, 'label': label,
                    'measureHistoryRows': args.measure_history_rows,
                    'livePages': args.live_pages, 'speed': args.speed, 'reconnectOverlay': args.reconnect_overlay,
                    'pages': args.pages, 'expectedRecords': expected_records, 'scanAll': args.scan_all, 'duration': args.duration, 'profile': args.profile}))
                if args.profile or args.foreground:
                    with (OUTPUT / (label + '.log')).open('w') as log:
                        test = subprocess.Popen(execute, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                        try:
                            deadline = time.monotonic() + 90
                            while test.poll() is None and time.monotonic() < deadline and not ready.exists():
                                time.sleep(0.1)
                            if not ready.exists():
                                raise RuntimeError('Benchmark did not become ready')
                            pid = json.loads(ready.read_text())['pid']
                            if args.foreground:
                                run(['open', '-a', str(products / 'Release/Dispatch.app')], label + '-activate')
                            if args.profile:
                                run(['sample', str(pid), '30', '1', '-file', str(OUTPUT / (label + '.sample.txt'))], label + '-profile')
                            if test.wait(timeout=600):
                                raise RuntimeError('Benchmark failed; see its test log')
                        finally:
                            if test.poll() is None:
                                test.terminate()
                else:
                    run(execute, label)
                result = json.loads(report.read_text())
                if args.foreground and result['scroll'].get('foregroundVerified') is not True:
                    raise RuntimeError('Foreground scrolling was not measured; check that the desktop is unlocked')
                print(json.dumps({k: v for k, v in result.items() if k != 'scroll'}, indent=2), flush=True)
        finally:
            config.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
