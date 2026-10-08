#!/usr/bin/env python3
"""Benchmark an isolated local tmux/Codex chat on the current macOS display.

Usage: python3 scripts/benchmark-chat-scroll.py SESSION_UUID --label before
Uses an optimized, separately identified app; never resumes the original file.
Results and the temporary opt-in configuration stay under build/.
"""
import argparse
import fcntl
import json
from pathlib import Path
import plistlib
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/chat-scroll-benchmark'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('conversation', help='Codex session UUID or rollout JSONL path')
    parser.add_argument('--label', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--duration', type=float, default=20, help='Seconds per paging/history-cold/history-warm pass')
    parser.add_argument('--no-build', action='store_true', help='Reuse the last optimized benchmark build')
    parser.add_argument('--expanded-tools', action='store_true', help='Open the two latest tools after loading history')
    parser.add_argument('--width', type=float, default=1120, help='Window content width in points')
    parser.add_argument('--profile', choices=['Time Profiler', 'Animation Hitches'], help='Separate diagnostic run; do not compare its timings')
    args = parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.label):
        parser.error('--label must contain only letters, digits, hyphens, and underscores')
    if not 1 <= args.runs <= 20 or not 5 <= args.duration <= 300:
        parser.error('Use 1–20 runs and 5–300 seconds per pass')
    if not 620 <= args.width <= 2400:
        parser.error('Use a window width between 620 and 2400 points')
    source = Path(args.conversation).expanduser()
    if not source.is_file():
        matches = list((Path.home() / '.codex/sessions').rglob(f'rollout-*-{args.conversation}.jsonl'))
        if len(matches) != 1:
            parser.error(f'Expected exactly one transcript, found {len(matches)}')
        source = matches[0]
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with (OUTPUT / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        base = ['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch',
                '-configuration', 'Release', '-derivedDataPath', 'build/chat-scroll-products',
                '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
                'ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                'PRODUCT_BUNDLE_IDENTIFIER=dev.dispatch.scroll-benchmark.$(PRODUCT_NAME:rfc1034identifier)',
                '-only-testing:DispatchTests/ChatScrollBenchmarkTests']

        def run(command, name):
            path = OUTPUT / (name + '.log')
            print(f'{name}: {path}', flush=True)
            with path.open('w') as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)

        if not args.no_build:
            run(['python3', str(ROOT / 'scripts/generate-project.py')], 'generate')
            run(base + ['build-for-testing'], 'build')
        # XCTest normally injects runtime checkers even into a Release build.
        # Keep them in ordinary regression tests, but exclude their overhead
        # from this separately built performance runner.
        products = ROOT / 'build/chat-scroll-products/Build/Products'
        plan = next(products.glob('Dispatch_*.xctestrun'))
        data = plistlib.loads(plan.read_bytes())
        target = data['DispatchTests']
        for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
            env = target[key]
            env['DYLD_INSERT_LIBRARIES'] = ':'.join(p for p in env.get('DYLD_INSERT_LIBRARIES', '').split(':')
                if p and 'libMainThreadChecker' not in p and 'libRPAC' not in p)
            for name in list(env):
                if name.startswith('PERFC_'):
                    del env[name]
        benchmark_plan = products / 'scroll-benchmark.xctestrun'
        benchmark_plan.write_bytes(plistlib.dumps(data))
        execute = ['xcodebuild', '-xctestrun', str(benchmark_plan), '-destination', 'platform=macOS',
                   '-parallel-testing-enabled', 'NO', '-only-testing:DispatchTests/ChatScrollBenchmarkTests',
                   '-collect-test-diagnostics', 'never', 'test-without-building']
        config = OUTPUT / 'input.json'
        try:
            for index in range(args.runs):
                label = f'{args.label}-{index + 1}'
                expected = [OUTPUT / f'{label}-{phase}.json' for phase in ['paging', 'history-cold', 'history-warm']]
                if any(path.exists() for path in expected):
                    parser.error(f'Refusing to overwrite measurements for {label}; choose a new label')
                config.write_text(json.dumps({'transcript': str(source.resolve()), 'label': label, 'duration': args.duration,
                                             'expandedTools': args.expanded_tools, 'width': args.width}))
                if args.profile:
                    ready = OUTPUT / 'ready.json'
                    ready.unlink(missing_ok=True)
                    with (OUTPUT / (label + '.log')).open('w') as log:
                        with subprocess.Popen(execute, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT) as test:
                            deadline = time.monotonic() + 90
                            while test.poll() is None and time.monotonic() < deadline and not ready.exists():
                                time.sleep(0.1)
                            if not ready.exists():
                                test.terminate()
                                raise RuntimeError('Benchmark did not reach the profiling phase')
                            pid = json.loads(ready.read_text())['pid']
                            run(['xcrun', 'xctrace', 'record', '--template', args.profile,
                                 '--attach', str(pid), '--time-limit', f'{int(3000 * args.duration)}ms',
                                 '--output', str(OUTPUT / (label + '.trace'))], label + '-profile')
                            if test.wait() != 0:
                                raise RuntimeError('Profiled benchmark failed')
                else:
                    run(execute, label)
                for path in expected:
                    report = json.loads(path.read_text())
                    print(json.dumps({k: v for k, v in report.items() if k not in ['gaps', 'work', 'positions']}), flush=True)
        finally:
            config.unlink(missing_ok=True)
            (OUTPUT / 'ready.json').unlink(missing_ok=True)


if __name__ == '__main__':
    main()
