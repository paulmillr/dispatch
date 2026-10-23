#!/usr/bin/env python3
"""Run Dispatch for iPhone and iPad's unit tests (DispatchMobileTests) on an iOS simulator, or Apple Watch's on a
watch one.

usage: test/run.sh --platform ios|watch [TESTS...] [--suite fast|full|exhaustive] [--simulator NAME] [--list]

The simulator is an iPhone by default (iPhone Air); --simulator or DISPATCH_IOS_SIMULATOR names another, an iPad for
the iPad run (`DISPATCH_IOS_SIMULATOR="iPad Pro 11-inch (M5)" test/run.sh --platform ios`). The same cases run on
both: those that only mean something on one of them skip on the other (XCTSkip), so a run reports them as skipped.

Selection follows test/suites.json like the Mac runner: its DispatchMobileTests/<Class>/<test> entries classify the
iPhone cases, unclassified cases run in full and exhaustive only, and the default suite is fast. The release tooling's
Python unit tests (test/ios-release.test.py: signing, the release check, device discovery) run first, on the Mac, as
DispatchMobileScripts/<Class>/<test> entries. The run fails when
a selected case did not run (a stale manifest entry or selector) or a case ran that the manifest does not know in a
fast run. Needs no desktop and takes no focus: the simulator runs headless.

--platform watch runs Dispatch for Apple Watch's (DispatchWatchTests, docs/watch.md) the same way, classified as
DispatchWatchTests/<Class>/<test>: no Python cases, no SSH engine, and the watch needs no paired phone.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from ios_simulator import find_simulator  # noqa: E402
TARGET = 'DispatchMobileTests'
SCRIPTS = 'DispatchMobileScripts'
SCRIPT_TESTS = ROOT / 'test/ios-release.test.py'
SUITES = ('fast', 'full', 'exhaustive')
# --platform: (XCTest bundle, Python cases or None, scheme, simctl platform, simulator variable, its default, name)
PLATFORMS = {
    'ios': (TARGET, SCRIPTS, 'DispatchMobile', 'iOS', 'DISPATCH_IOS_SIMULATOR', 'iPhone Air', 'iOS'),
    'watch': ('DispatchWatchTests', None, 'DispatchWatch', 'watchOS', 'DISPATCH_WATCH_SIMULATOR',
              'Apple Watch Series 12 (46mm)', 'Apple Watch'),
}


def manifest():
    data = json.loads((ROOT / 'test/suites.json').read_text())
    cases = {case: tier for case, tier in data['cases'].items() if case.split('/')[0] in (TARGET, SCRIPTS)}
    for case, tier in cases.items():
        if tier not in SUITES or len(case.split('/')) != 3:
            raise SystemExit('Invalid suite manifest entry: ' + case)
    return cases


def normalize(selector):
    parts = selector.removesuffix('()').split('/')
    if parts[0] not in (TARGET, SCRIPTS):
        parts.insert(0, TARGET)
    if not 1 <= len(parts) <= 3 or any(not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', part) for part in parts):
        raise SystemExit('Invalid XCTest identifier: ' + selector)
    return '/'.join(parts)


def script_tests():
    """{DispatchMobileScripts/<Class>/<test>: test} of the release tooling's unittest module."""
    spec = importlib.util.spec_from_file_location('ios_release_tests', SCRIPT_TESTS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    found = {}
    pending = [unittest.defaultTestLoader.loadTestsFromModule(module)]
    while pending:
        for test in pending.pop():
            if isinstance(test, unittest.TestSuite):
                pending.append(test)
            else:
                found[f'{SCRIPTS}/{type(test).__name__}/{test._testMethodName}'] = test
    return found


def run_script_tests(selectors, everything):
    """Runs the selected script tests in this process: {case: passed|failed}."""
    tests = script_tests()
    chosen = {case: test for case, test in tests.items()
              if everything or any(case == selector or case.startswith(selector + '/') for selector in selectors)}
    ran = {}
    for case, test in sorted(chosen.items()):
        result = unittest.TestResult()
        test.run(result)
        ran[case] = 'passed' if result.wasSuccessful() else 'failed'
        for _, trace in result.failures + result.errors:
            print(f'{case}:\n{trace}')
    return ran


def main():
    global TARGET, SCRIPTS
    parser = argparse.ArgumentParser(prog='test/run.sh', description=__doc__.split('\n\n')[0])
    parser.add_argument('--platform', choices=PLATFORMS, default='ios',
                        help="ios (default), or watch for Dispatch for Apple Watch's DispatchWatchTests")
    parser.add_argument('tests', nargs='*', help='Explicit Class or Class/testMethod identifiers (cannot combine with --suite)')
    parser.add_argument('--suite', choices=SUITES, help='Default: fast')
    parser.add_argument('--simulator', metavar='NAME',
                        help='Name or UDID; a booted one, then the newest runtime, when several share the name '
                             '(default: DISPATCH_IOS_SIMULATOR or iPhone Air, an iPhone or an iPad; '
                             'DISPATCH_WATCH_SIMULATOR or Apple Watch Series 12 (46mm) for watch)')
    parser.add_argument('--list', action='store_true', help='Show the selection without building')
    parser.add_argument('--derived-data', default='build/ios', metavar='PATH',
                        help="xcodebuild's DerivedData (default: build/ios, ./run.sh --ios's); another keeps parallel runs "
                             'apart')
    args = parser.parse_args()
    platform = args.platform
    TARGET, SCRIPTS, scheme, simulator_platform, variable, default, name = PLATFORMS[platform]
    args.simulator = args.simulator or os.environ.get(variable, default)
    if args.suite and args.tests:
        parser.error('Choose explicit test identifiers or --suite, not both')
    cases = manifest()
    suite = 'explicit' if args.tests else args.suite or 'fast'
    if args.tests:
        selectors = [normalize(test) for test in args.tests]
    elif suite == 'fast':
        selectors = sorted(case for case, tier in cases.items() if tier == 'fast')
    else:
        # Every case in the bundle: classified ones up to this suite are what must have run.
        selectors = []
    allowed = {case for case, tier in cases.items() if SUITES.index(tier) <= SUITES.index(suite)} if suite in SUITES else set()
    print(f'{name} XCTest suite: {suite}; selected: {len(selectors) or "whole bundle"}; simulator: {args.simulator}',
          flush=True)
    if args.list:
        for selector in selectors:
            print(selector)
        return 0
    if not selectors and suite == 'fast':
        raise SystemExit(f'No fast {name} cases in test/suites.json')
    xctest = [selector for selector in selectors if selector.split('/')[0] == TARGET]
    scripts = [selector for selector in selectors if selector.split('/')[0] == SCRIPTS]
    script_started = time.monotonic()
    ran = run_script_tests(scripts, everything=suite in ('full', 'exhaustive')) if SCRIPTS else {}
    if ran:
        failed_scripts = sum(result == 'failed' for result in ran.values())
        print(f'Release tooling (Python): {len(ran)} cases, {failed_scripts} failed in '
              f'{time.monotonic() - script_started:.1f}s', flush=True)
    if (args.tests or suite == 'fast') and not xctest:
        return finish(ran, selectors, allowed, cases, suite, 0, None, '', name=name)

    if platform == 'ios':
        # The Rust toolchain's iOS targets and the SSH engine's XCFramework (SwiftPM needs it before any build script).
        subprocess.run(['python3', 'scripts/setup_mobile.py'], cwd=ROOT, check=True)
    subprocess.run(['python3', 'scripts/generate-project.py'], cwd=ROOT, check=True)
    udid, description = find_simulator(args.simulator, platform=simulator_platform)
    print(f'Simulator: {description} {udid}', flush=True)
    log = ROOT / 'build/logs' / f'{platform}-test-{time.strftime("%Y%m%d-%H%M%S")}.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    command = ['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', scheme, '-configuration', 'Debug',
               '-destination', f'platform={simulator_platform} Simulator,id={udid}',
               # ./run.sh --ios's DerivedData: not the Mac's build/, whose build database one build at a time holds.
               '-derivedDataPath', args.derived_data,
               # A failure otherwise has xcodebuild gather a simulator sysdiagnose, which waits out its 600 s timeout.
               '-collect-test-diagnostics', 'never', 'test']
    command += [f'-only-testing:{selector}' for selector in xctest]
    started = time.monotonic()
    with log.open('w') as stream:
        status = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT).returncode
    text = log.read_text(errors='replace')
    outcome = re.compile(r"Test Case '-\[" + TARGET + r"\.(\w+) (\w+)\]' (passed|failed|skipped)")
    for match in outcome.finditer(text):
        ran[f'{TARGET}/{match[1]}/{match[2]}'] = match[3]
    return finish(ran, selectors, allowed, cases, suite, status, log, text, started, name)


def finish(ran, selectors, allowed, cases, suite, status, log, text, started=None, name='iPhone'):
    failed = sorted(case for case, result in ran.items() if result == 'failed')
    problems = []
    for selector in selectors:
        if not any(case == selector or case.startswith(selector + '/') for case in ran):
            problems.append('selected but did not run: ' + selector)
    if suite in ('full', 'exhaustive'):
        problems += ['classified but did not run: ' + case for case in sorted(allowed - set(ran))]
    unclassified = sorted(set(ran) - set(cases))
    if suite == 'fast':
        problems += ['ran but is not in test/suites.json: ' + case for case in unclassified]
    for line in failed:
        print('FAILED ' + line)
    for problem in problems:
        print(problem)
    counts = {result: list(ran.values()).count(result) for result in ('passed', 'failed', 'skipped')}
    python = sum(case.split('/')[0] == SCRIPTS for case in ran)
    timing = f' in {time.monotonic() - started:.0f}s' if started is not None else ''
    print(f"{name} tests: {len(ran)} cases ({len(ran) - python} XCTest, {python} Python), {counts['passed']} passed, "
          f"{counts['failed']} failed, {counts['skipped']} skipped{timing}"
          + (f'; {len(unclassified)} unclassified' if unclassified else ''), flush=True)
    if log is not None:
        print(f'Log: {os.path.relpath(log)}')
    if status and not ran:
        for line in text.splitlines()[-15:]:
            print('  ' + line)
    return 1 if status or failed or problems else 0


if __name__ == '__main__':
    sys.exit(main())
