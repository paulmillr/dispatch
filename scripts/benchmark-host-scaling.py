#!/usr/bin/env python3
"""Measure host/space scaling on the Mac display using dedicated Linux SSH guests.

Create dispatch-perf-{1,2,3,4} first with scripts/ssh-vm.py (1 CPU/1 GiB each).
Uses isolated Release app identity, a real Thinking indicator and remote protocol
fixture, fixed chat history, fresh process per sample,
and alternating case order. Does not download tools or contact a model service.
"""
import argparse
import fcntl
import json
import os
import signal
import shlex
from pathlib import Path
import plistlib
import subprocess
import time

import benchmark

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/host-scaling-benchmark'
SELECTOR = 'DispatchTests/HostScalingBenchmarkTests/testConnectedHostsAndChatScrolling'
CASES = {1: [2], 2: [2, 1], 3: [2, 2, 2], 4: [3, 3, 3, 3]}


def run(command, log):
    print(log.name, flush=True)
    with log.open('w') as stream:
        subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)


def cleanup_launchers():
    # XCTest exits before some launcher recovery loops finish. Only our isolated
    # app binary and dedicated guests qualify; never touch the user's SSH work.
    executable = str(ROOT / 'build/host-scaling-products/Build/Products/Release/Dispatch.app/Contents/MacOS/Dispatch')
    def owned():
        matches = []
        for line in subprocess.check_output(['ps', '-axo', 'pid=,args='], text=True).splitlines():
            pid, arguments = line.strip().split(None, 1)
            if arguments.startswith(executable + ' --ssh-launch ') and 'HostKeyAlias=dispatch-perf-' in arguments:
                matches.append(int(pid))
        return matches
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        remaining = owned()
        if not remaining:
            break
        for pid in remaining:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        time.sleep(0.2)

    if owned():
        raise RuntimeError('Isolated SSH launchers did not exit')


def profiles():
    inventory = {d['name']: d for line in subprocess.check_output(['limactl', 'list', '--json'], text=True).splitlines()
                 for d in [json.loads(line)]}
    result, machines, keys, guests = [], [], [], []
    known = OUTPUT / 'known_hosts'
    for index in range(1, 5):
        vm = inventory['dispatch-perf-' + str(index)]
        if vm['status'] != 'Running':
            raise RuntimeError('Start the dedicated benchmark guests first')
        ssh = ['ssh', '-F', vm['sshConfigFile'], vm['hostname']]
        guests.append(ssh)
        key = subprocess.check_output(ssh + ['cat /etc/ssh/ssh_host_ed25519_key.pub'], text=True).strip()
        identity = subprocess.check_output(ssh + ['cat /etc/machine-id; uname -sm; free -m; tmux -V'], text=True).strip()
        alias = vm['name']
        keys.append(alias + ' ' + key)
        result.append({'destination': vm['config']['user']['name'] + '@' + alias,
            'options': ['-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                        '-o', 'UserKnownHostsFile=' + str(known), '-o', 'IdentitiesOnly=yes',
                        '-i', vm['IdentityFile'], '-o', 'HostName=' + vm['sshAddress'],
                        '-o', 'HostKeyAlias=' + alias, '-o', 'ConnectTimeout=5', '-p', str(vm['sshLocalPort'])]})
        machines.append({'name': alias, 'cpus': vm['cpus'], 'memory': vm['memory'], 'guest': identity})
    known.write_text('\n'.join(keys) + '\n')
    return result, machines, guests


def cleanup_guests(guests):
    program = """import os, pathlib, shutil, signal, subprocess
for root in pathlib.Path('/tmp').glob('dispatch-host-scaling-*'):
    if not root.is_dir() or not (root / '.fixture').exists():
        continue
    if (root / 'tmux.sock').exists():
        subprocess.run(['/usr/bin/tmux', '-S', str(root / 'tmux.sock'), 'kill-server'], check=False)
    for process in pathlib.Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            if os.readlink(process / 'exe') == str(root / 'codex'):
                os.kill(int(process.name), signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
    shutil.rmtree(root)
"""
    for ssh in guests:
        subprocess.run(ssh + [shlex.join(['python3', '-c', program])], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--duration', type=float, default=15)
    parser.add_argument('--cases', type=int, nargs='+', default=[1, 2, 3, 4], choices=CASES)
    parser.add_argument('--spaces-per-host', type=int, nargs='+', help='Diagnostic custom distribution, e.g. 12')
    parser.add_argument('--profile-phase', choices=['scrolling', 'switching'], default='scrolling')
    parser.add_argument('--backend', choices=['ssh', 'tmux'], default='tmux')
    parser.add_argument('--activity', choices=['thinking', 'idle'], default='thinking')
    parser.add_argument('--variant', choices=['normal', 'sidebar-hidden', 'animation-off'], default='normal')
    parser.add_argument('--no-build', action='store_true')
    parser.add_argument('--profile', action='store_true', help='Separate diagnostic sample; not a comparable timing run')
    args = parser.parse_args()
    if not args.label or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in args.label):
        parser.error('Use a simple label')
    if not 1 <= args.runs <= 10 or not 5 <= args.duration <= 120:
        parser.error('Use 1–10 runs and 5–120 seconds')
    cases = CASES
    if args.spaces_per_host:
        if not 1 <= len(args.spaces_per_host) <= 4 or args.spaces_per_host[0] < 2 or any(n < 1 or n > 12 for n in args.spaces_per_host):
            parser.error('Use 1–4 hosts, 1–12 spaces each, and at least two spaces on the first host')
        args.cases = [len(args.spaces_per_host)]
        cases = {len(args.spaces_per_host): args.spaces_per_host}
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with (OUTPUT / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        cleanup_launchers()
        remote, machines, guests = profiles()
        cleanup_guests(guests)
        metadata = {'hardware': benchmark.environment('hardware'), 'display': benchmark.desktop_environment(),
                    'linux': machines, 'parameters': vars(args), 'source': benchmark.source_identity()}
        (OUTPUT / (args.label + '-metadata.json')).write_text(json.dumps(metadata, indent=2))
        products = ROOT / 'build/host-scaling-products/Build/Products'
        if not args.no_build:
            run(['python3', 'scripts/generate-project.py'], OUTPUT / (args.label + '-generate.log'))
            run(['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch', '-configuration', 'Release',
                 '-derivedDataPath', 'build/host-scaling-products', '-destination', 'platform=macOS',
                 '-parallel-testing-enabled', 'NO', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DISPATCH_BENCHMARK', 'ENABLE_TESTABILITY=YES', 'ENABLE_HARDENED_RUNTIME=NO',
                 'PRODUCT_BUNDLE_IDENTIFIER=dev.dispatch.host-scaling.$(PRODUCT_NAME:rfc1034identifier)',
                 '-only-testing:' + SELECTOR, 'build-for-testing'], OUTPUT / (args.label + '-build.log'))
        build_source = OUTPUT / 'build-source.json'
        current_source = benchmark.source_identity()
        if not args.no_build:
            build_source.write_text(json.dumps(current_source))
        elif not build_source.exists() or json.loads(build_source.read_text()) != current_source:
            raise RuntimeError('Source changed since the benchmark build; omit --no-build')
        metadata['source'] = current_source
        (OUTPUT / (args.label + '-metadata.json')).write_text(json.dumps(metadata, indent=2))
        plan = next(products.glob('Dispatch_*.xctestrun'))
        data = plistlib.loads(plan.read_bytes())
        for target in benchmark.test_targets(data):
            for name in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
                env = target.setdefault(name, {})
                env['DYLD_INSERT_LIBRARIES'] = ':'.join(p for p in env.get('DYLD_INSERT_LIBRARIES', '').split(':')
                    if p and 'libMainThreadChecker' not in p and 'libRPAC' not in p)
                for key in list(env):
                    if key.startswith('PERFC_'):
                        del env[key]
                env['DISPATCH_TESTING'] = '1'
        target = products / 'host-scaling.xctestrun'
        target.write_bytes(plistlib.dumps(data))
        input_path, ready = OUTPUT / 'input.json', OUTPUT / 'ready.json'
        try:
            for repetition in range(args.runs):
                order = ([1, 4, 2, 3], [3, 2, 4, 1], [2, 1, 3, 4])[repetition % 3]
                for case in [c for c in order if c in args.cases]:
                    cleanup_launchers()
                    cleanup_guests(guests)
                    label = f'{args.label}-h{case}-r{repetition + 1}'
                    if (OUTPUT / (label + '.json')).exists():
                        raise RuntimeError('Refusing to overwrite ' + label)
                    input_path.write_text(json.dumps({'label': label, 'spacesPerHost': cases[case], 'profiles': remote,
                        'duration': args.duration, 'variant': args.variant, 'profile': args.profile, 'profilePhase': args.profile_phase, 'thinking': args.activity == 'thinking', 'backend': args.backend}))
                    ready.unlink(missing_ok=True)
                    result = OUTPUT / (label + '.xcresult')
                    command = ['xcodebuild', '-xctestrun', str(target), '-destination', 'platform=macOS',
                        '-parallel-testing-enabled', 'NO', '-only-testing:' + SELECTOR,
                        '-resultBundlePath', str(result), '-collect-test-diagnostics', 'never', 'test-without-building']
                    if args.profile:
                        with (OUTPUT / (label + '.log')).open('w') as log:
                            with subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT) as test:
                                deadline = time.monotonic() + 240
                                while not ready.exists() and test.poll() is None and time.monotonic() < deadline:
                                    time.sleep(0.2)
                                if not ready.exists():
                                    test.terminate()
                                    raise RuntimeError('Did not reach profiling phase')
                                pid = json.loads(ready.read_text())['pid']
                                run(['/usr/bin/sample', str(pid), str(int(args.duration) if args.profile_phase == 'scrolling' else 7), '1', '-file',
                                     str(OUTPUT / (label + '-sample.txt'))], OUTPUT / (label + '-sample.log'))
                                if test.wait() != 0:
                                    raise RuntimeError('Profiled test failed')
                    else:
                        run(command, OUTPUT / (label + '.log'))
                    summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], text=True))
                    if summary.get('passedTests') != 1 or summary.get('skippedTests') != 0 or not (OUTPUT / (label + '.json')).exists():
                        raise RuntimeError('Missing or unsuccessful measurement for ' + label)
                    report = json.loads((OUTPUT / (label + '.json')).read_text())
                    print(label, 'Hz', round(report['scrolling']['callbackHz'], 2),
                          'work p95 ms', round(report['scrolling']['workP95Ms'], 2), flush=True)
            if benchmark.source_identity() != current_source:
                raise RuntimeError('Source changed during measurement')
        finally:
            input_path.unlink(missing_ok=True)
            ready.unlink(missing_ok=True)
            cleanup_launchers()
            cleanup_guests(guests)


if __name__ == '__main__':
    main()
