#!/usr/bin/env python3
"""Matched Release chat scrolling: composited frames, run-loop work, CPU and RSS.

Use identical copies of this harness in the old and new renderer checkouts.
ScreenCaptureKit measures delivered window pixels, including capture overhead;
the current display limits FPS. A callback is never counted as a presented frame.
"""
import argparse
import fcntl
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time

import benchmark as bench

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/chat-frame-benchmarks'
PHASES = [shape + '-' + str(speed) for shape in ('mixed', 'expanded', 'streaming') for speed in (2400, 6000)]
TEST = 'DispatchTests/ChatScrollingFrameBenchmarkTests/testSustainedScrollingFrameDelivery'


def metrics(folder):
    values = []
    for name in PHASES:
        row = json.loads((folder / (name + '.json')).read_text())
        frames, work = row['presentationIntervals'], row['work']
        if row['uniqueFrames'] < 10 or len(frames) != row['uniqueFrames'] - 1 or not work:
            raise ValueError('Incomplete frame/work samples: ' + name)
        if row['captureSamples'] < row['uniqueFrames']:
            raise ValueError('More presented frames than capture samples: ' + name)
        values += [
            bench.metric(name + '/composited-fps', 'fps', [row['compositedFPS']], 'higher'),
            bench.metric(name + '/presentation-gap', 'ms', [x * 1000 for x in frames], sampling='observed'),
            bench.metric(name + '/main-loop-work', 'ms', [x * 1000 for x in work], sampling='observed'),
            bench.metric(name + '/work-over-120Hz-budget', '%', [100 * row['workOver120Budget'] / len(work)]),
            bench.metric(name + '/cpu', 's', [row['cpuSeconds']]),
            bench.metric(name + '/main-cpu', 's', [row['mainCPUSeconds']]),
            bench.metric(name + '/input-rate', 'Hz', [row['callbackHz']], 'higher'),
            bench.metric(name + '/peak-rss', 'MiB', [row['rssPeak'] / 2**20])]
    return values


def run(args):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # Both runners use build/benchmarks/products; share their lock as well as their build settings.
    bench.OUTPUT.mkdir(parents=True, exist_ok=True)
    with (bench.OUTPUT / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        folder = OUTPUT / args.label
        folder.mkdir()
        bench.command(['python3', 'scripts/generate-project.py'], folder / 'generate.log')
        report = dict(schema=bench.VERSION, workload_version=4, suite='chat-scrolling-frames',
                      status='running', repeats=args.runs, duration_seconds=args.duration,
                      configuration='Release -O; runtime checkers disabled; own-window capture' + ('; profiled' if args.profile else ''),
                      environment=bench.environment('hardware'), source=bench.source_identity(), runs=[])
        report['environment']['desktop'] = bench.desktop_environment()
        report['environment']['input_hz'] = args.input_hz
        report['measurement'] = 'Distinct sampled transcript pixel hashes, captured at up to 120 Hz. Display refresh caps FPS; capture overhead included; no panel-scanout claim.'
        bench.write_json(folder / 'report.json', report)
        try:
            products = ROOT / 'build/benchmarks/products'
            bench.command(['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch',
                           '-configuration', 'Release', '-derivedDataPath', str(products), '-destination', 'platform=macOS',
                           '-parallel-testing-enabled', 'NO', 'ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                           'SWIFT_OPTIMIZATION_LEVEL=-O', 'SWIFT_COMPILATION_MODE=wholemodule',
                           'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DISPATCH_BENCHMARK',
                           'PRODUCT_BUNDLE_IDENTIFIER=yachts.dispatch.benchmark.$(PRODUCT_NAME:rfc1034identifier)',
                           'build-for-testing'], folder / 'build.log')
            plans = list((products / 'Build/Products').glob('Dispatch_*.xctestrun'))
            if len(plans) != 1:
                raise ValueError('Expected exactly one XCTest plan')
            if args.build_only:
                report['status'] = 'built'
                return
            for index in range(args.runs):
                repetition = folder / ('run-' + str(index + 1))
                repetition.mkdir()
                data = plistlib.loads(plans[0].read_bytes())
                for target in bench.test_targets(data):
                    for key in ('EnvironmentVariables', 'TestingEnvironmentVariables'):
                        env = target.setdefault(key, {})
                        env['DYLD_INSERT_LIBRARIES'] = ':'.join(p for p in env.get('DYLD_INSERT_LIBRARIES', '').split(':')
                            if p and 'libMainThreadChecker' not in p and 'libRPAC' not in p)
                        for name in list(env):
                            if name.startswith('PERFC_'):
                                del env[name]
                        env.update(DISPATCH_TESTING='1', DISPATCH_SCROLL_FRAMES_OUTPUT=str(repetition),
                                   DISPATCH_SCROLL_FRAMES_SECONDS=str(args.duration),
                                   DISPATCH_SCROLL_FRAMES_INPUT_HZ=str(args.input_hz),
                                   DISPATCH_SCROLL_FRAMES_PROFILE='1' if args.profile else '0')
                plan = plans[0].parent / 'chat-frames.xctestrun'
                plan.write_bytes(plistlib.dumps(data))
                command = ['xcodebuild', '-xctestrun', str(plan), '-destination', 'platform=macOS',
                           '-parallel-testing-enabled', 'NO', '-only-testing:' + TEST,
                           '-collect-test-diagnostics', 'never', '-resultBundlePath', str(repetition / 'tests.xcresult'),
                           'test-without-building']
                if args.profile:
                    with (repetition / 'test.log').open('w') as log:
                        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                        try:
                            deadline = time.monotonic() + 90
                            while process.poll() is None and time.monotonic() < deadline and not (repetition / 'ready.json').exists():
                                time.sleep(.1)
                            pid = json.loads((repetition / 'ready.json').read_text())['pid']
                            with (repetition / 'profile.log').open('w') as profile_log:
                                profile = subprocess.Popen(['xcrun', 'xctrace', 'record', '--template', args.profile,
                                    '--attach', str(pid), '--time-limit', str(args.duration * 6 + 25) + 's',
                                    '--output', str(repetition / 'scroll.trace')], stdout=profile_log, stderr=subprocess.STDOUT)
                                time.sleep(2)
                                if profile.poll() is not None:
                                    raise ValueError('Profiler could not attach; see profile.log')
                                (repetition / 'go').touch()
                                code = process.wait(timeout=args.duration * 6 + 120)
                                if profile.wait(timeout=90):
                                    raise ValueError('Profiler did not complete; see profile.log')
                                if code:
                                    raise ValueError('Profiled workload failed; see test.log')
                        finally:
                            if process.poll() is None:
                                process.terminate(); process.wait(timeout=15)
                else:
                    bench.command(command, repetition / 'test.log')
                report['runs'].append(metrics(repetition))
                bench.write_json(folder / 'report.json', report)
            if bench.source_identity() != report['source']:
                raise ValueError('Sources changed during measurement')
            report['status'] = 'complete'
        except BaseException as error:
            report.update(status='failed', error=str(error))
            raise
        finally:
            bench.write_json(folder / 'report.json', report)
        print('Completed: ' + str(folder / 'report.json'), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--duration', type=int, default=10, help='Seconds per shape/speed (six phases per run)')
    parser.add_argument('--input-hz', type=int, choices=[60, 120], default=120, help='Requested precise wheel cadence, independent of display-link throttling')
    parser.add_argument('--profile', choices=['Time Profiler', 'Animation Hitches'])
    parser.add_argument('--build-only', action='store_true', help='Prepare products without measuring the desktop')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.label) or not 1 <= args.runs <= 10 or not 5 <= args.duration <= 60:
        parser.error('Use a simple label, 1–10 runs and 5–60 seconds per phase')
    if args.profile and args.runs != 1:
        parser.error('Profiling requires --runs 1; keep diagnostic and comparison runs separate')
    run(args)


if __name__ == '__main__':
    main()
