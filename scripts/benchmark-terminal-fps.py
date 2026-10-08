#!/usr/bin/env python3
"""Measure distinct composited terminal frames on the current unlocked display.

Uses an isolated Release XCTest host, a real PTY producer, and own-window capture.
Results are compositor throughput (including capture overhead), not panel scanout.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/terminal-fps-benchmark'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--duration', type=float, default=10)
    parser.add_argument('--modes', nargs='+', choices=['palette', 'unique'], default=['palette', 'unique'])
    parser.add_argument('--no-build', action='store_true')
    args = parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.label):
        parser.error('Use a simple alphanumeric label')
    if not 1 <= args.runs <= 20 or not 3 <= args.duration <= 120:
        parser.error('Use 1–20 runs and 3–120 seconds per pass')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with (OUTPUT / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def run(command, name):
            path = OUTPUT / (name + '.log')
            print(f'{name}: {path}', flush=True)
            with path.open('w') as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)

        if not args.no_build:
            run(['python3', str(ROOT / 'scripts/generate-project.py')], 'generate')
            run(['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch',
                 '-configuration', 'Release', '-derivedDataPath', 'build/terminal-fps-products',
                 '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO',
                 'ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                 'PRODUCT_BUNDLE_IDENTIFIER=dev.dispatch.fps-benchmark.$(PRODUCT_NAME:rfc1034identifier)',
                 '-only-testing:DispatchTests/TerminalFPSBenchmarkTests', 'build-for-testing'], 'build')
        products = ROOT / 'build/terminal-fps-products/Build/Products'
        plan = next(products.glob('Dispatch_*.xctestrun'))
        data = plistlib.loads(plan.read_bytes())
        for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
            env = data['DispatchTests'][key]
            env['DYLD_INSERT_LIBRARIES'] = ':'.join(p for p in env.get('DYLD_INSERT_LIBRARIES', '').split(':')
                if p and 'libMainThreadChecker' not in p and 'libRPAC' not in p)
            for name in list(env):
                if name.startswith('PERFC_'):
                    del env[name]
        benchmark_plan = products / 'fps-benchmark.xctestrun'
        benchmark_plan.write_bytes(plistlib.dumps(data))
        metadata_path = OUTPUT / f'{args.label}-environment.json'
        if metadata_path.exists():
            parser.error('This label already has measurements; choose a new label')
        def output(*command):
            return subprocess.check_output(command, cwd=ROOT, text=True).strip()
        sources = ['DispatchTests/TerminalFPSBenchmarkTests.swift', 'test/fixtures/terminal_fps.py',
                   'Vendor/Term/Sources/TermApple/Shaders.swift']
        metadata_path.write_text(json.dumps({
            'time': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'configuration': 'Release',
            'os': output('sw_vers'), 'hardware': output('system_profiler', 'SPDisplaysDataType'),
            'power': output('pmset', '-g', 'batt'), 'xcode': output('xcodebuild', '-version'),
            'revision': output('git', 'rev-parse', 'HEAD'), 'status': output('git', 'status', '--short'),
            'sha256': {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources},
            'arguments': vars(args),
            'measurement': 'Distinct checksummed frame numbers in ScreenCaptureKit own-window BGRA pixels; '
                           '120 Hz requested capture; native pixel size; includes capture overhead; not panel scanout.',
        }, indent=2))
        config = OUTPUT / 'input.json'
        try:
            for index in range(args.runs):
                label = f'{args.label}-{index + 1}'
                expected = [OUTPUT / f'{label}-{mode}-{state}.json' for mode in args.modes for state in ['off', 'on']]
                if any(path.exists() for path in expected):
                    parser.error(f'Refusing to overwrite measurements for {label}')
                config.write_text(json.dumps({'label': label, 'duration': args.duration, 'modes': args.modes,
                                             'reverse': index % 2 == 1, 'python': sys.executable}))
                run(['xcodebuild', '-xctestrun', str(benchmark_plan), '-destination', 'platform=macOS',
                     '-parallel-testing-enabled', 'NO', '-only-testing:DispatchTests/TerminalFPSBenchmarkTests',
                     '-collect-test-diagnostics', 'never', 'test-without-building'], label)
                for path in expected:
                    report = json.loads(path.read_text())
                    print(json.dumps({k: v for k, v in report.items() if k != 'samples'}), flush=True)
        finally:
            config.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
