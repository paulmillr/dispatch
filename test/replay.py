#!/usr/bin/env python3
"""Compare every recorded helper version and emit targeted XCTest selections.

Example: python3 test/replay.py captures --helper macos=build/helper --tool macos=build/capture-redact
Add --helper linux=PATH --tool linux=PATH --ssh linux=build/linux-ssh.json for Linux SSH recordings.
No original capture or earlier comparison is overwritten. App replay uses test/xcode.py --replay.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

from capture import digest, write

ROOT = Path(__file__).resolve().parent.parent


def mappings(values):
    result = {}
    for value in values:
        key, separator, path = value.partition('=')
        if not separator or not key or not path or key in result:
            raise ValueError('Expected one PLATFORM=PATH per platform: ' + value)
        result[key] = Path(path).resolve()
    return result


def plan(corpus, helpers, tools, remotes, require_same=False):
    groups, unsupported, verified = defaultdict(list), [], set()
    manifests = [corpus] if corpus.is_file() else sorted(corpus.rglob('manifest.json'))
    if not manifests:
        raise ValueError('No capture manifests found: ' + str(corpus))
    native = {'Darwin': 'macos', 'Linux': 'linux'}.get(platform.system(), platform.system().lower())
    for file in manifests:
        manifest = json.loads(file.read_text())
        if manifest.get('version') != 1:
            raise ValueError('Unsupported capture manifest: ' + str(file))
        for error in manifest.get('collection_errors', []):
            unsupported.append(dict(run=manifest['run'], manifest=str(file), case=None,
                                    status='unverified', reason='capture collection failed', detail=error))
        for entry in manifest['captures']:
            item = dict(entry, run=manifest['run'], manifest=str(file))
            system, sha = entry.get('platform'), entry.get('helper_sha256')
            originals = [h for h in manifest['helpers'] if h['sha256'] == sha]
            reason = ('retained capture outcome is not passed' if require_same and str(entry.get('outcome')).lower() != 'passed' else
                      'case identity missing' if not entry.get('case') else
                      'original helper identity missing' if not originals else
                      'platform worker missing' if system != native and system not in remotes else
                      'candidate helper missing' if system not in helpers or not helpers[system].is_file() else
                      'batch tool missing' if system not in tools or not tools[system].is_file() else None)
            if reason:
                unsupported.append(dict(item, status='unverified', reason=reason))
                continue
            original = originals[0]
            try:
                for record in (entry, original):
                    path = (file.parent / record['path']).resolve(strict=True)
                    identity = (path, record['sha256'])
                    if identity not in verified:
                        if file.parent.resolve() not in path.parents or digest(path) != record['sha256']:
                            raise ValueError('Capture/helper checksum or path mismatch: ' + str(path))
                        verified.add(identity)
            except (OSError, ValueError, KeyError) as error:
                unsupported.append(dict(item, status='unverified', reason=str(error)))
                continue
            groups[(str(file), system, original['path'], entry.get('image'))].append(item)
    return groups, unsupported


def regressions(rows):
    return [row for row in rows if row['status'] == 'changed'
            and str(row.get('outcome')).lower() == 'passed']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('corpus', type=Path, nargs='?', default=ROOT / 'captures')
    parser.add_argument('--build', action='store_true',
                        help='Build helpers and replay tools offline, then strictly verify the retained corpus')
    for name in ('helper', 'tool', 'ssh'):
        parser.add_argument('--' + name, action='append', default=[], metavar='PLATFORM=PATH')
    parser.add_argument('--output', type=Path, help='New report directory; defaults to build/replay/<timestamp>')
    parser.add_argument('--timeout', type=int, default=8)
    parser.add_argument('--budget', type=int, default=1800)
    parser.add_argument('--memory', type=int, default=4096)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--require-same', action='store_true',
                        help='Refuse unless every retained variant has a passed outcome and verified identical replay')
    args = parser.parse_args(argv)
    if min(args.timeout, args.budget, args.memory) <= 0:
        parser.error('Limits must be positive')
    helpers, tools, remotes = (mappings(getattr(args, name)) for name in ('helper', 'tool', 'ssh'))
    if args.build:
        environment = dict(os.environ)
        environment.setdefault('CARGO_BUILD_JOBS', str(min(8, os.cpu_count() or 1)))
        environment['DISPATCH_SETUP_OFFLINE'] = '1'
        for extra in ([], ['--replay-tools']):
            command = [sys.executable, str(ROOT / 'scripts/build-ssh-helper.py'), '--build-only', *extra]
            if args.dry_run:
                command.append('--dry-run')
            subprocess.run(command, cwd=ROOT, env=environment, check=True, timeout=args.budget)
        if args.dry_run:
            return 0
        binaries = ROOT / 'build/helper4-rust/bin'
        names = {'macos': 'darwin-universal', 'linux': 'linux-x86_64'}
        helpers = {**{system: binaries / name for system, name in names.items()}, **helpers}
        tools = {**{system: binaries / 'replay' / name for system, name in names.items()}, **tools}
        profile = ROOT / 'build/linux-ssh.json'
        if profile.is_file():
            remotes.setdefault('linux', profile)
        args.require_same = True
    groups, rows = plan(args.corpus.resolve(), helpers, tools, remotes, args.require_same)
    if args.dry_run:
        print(json.dumps({'groups': [{'manifest': k[0], 'platform': k[1], 'captures': len(v)}
                                    for k, v in groups.items()], 'unverified': rows}, indent=2))
        return 1 if args.require_same else 0
    output = (args.output or ROOT / 'build/replay' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    for number, ((manifest, system, original, image), entries) in enumerate(groups.items()):
        corpus = Path(manifest).parent
        destination = output / f'{number:04d}'
        paths = [entry['path'] for entry in entries]
        listing = output / f'{number:04d}.json'
        write(listing, paths)
        limits = dict(timeout=args.timeout, budget=args.budget, memory=args.memory)
        try:
            if system in remotes:
                from replay_remote import run
                remote = run(json.loads(remotes[system].read_text()), corpus, paths, corpus / original,
                             helpers[system], tools[system], image, destination, limits)
                if not remote['success']:
                    raise ValueError('Remote replay worker failed; see ' + remote['diagnostics'])
            else:
                source = corpus / original
                # Original legacy helpers may observe their actual executable path.
                if image:
                    try:
                        if digest(Path(image)) == digest(source):
                            source = Path(image)
                    except OSError:
                        pass
                command = [sys.executable, str(ROOT / 'test/replay_worker.py'), '--captures', str(corpus),
                           '--list', str(listing), '--original', str(source), '--helper', str(helpers[system]),
                           '--tool', str(tools[system]), '--output', str(destination)]
                if image:
                    command += ['--image', image]
                for name, value in limits.items():
                    command += ['--' + name, str(value)]
                subprocess.run(command, check=True, timeout=args.budget + 15)
            result = json.loads((destination / 'comparison.json').read_text())
            results = {row['capture']: row for row in result}
            if len(results) != len(result) or set(results) - set(paths):
                raise ValueError('Duplicate or unexpected captures in worker comparison')
            for entry in entries:
                row = results.get(entry['path'])
                if row is None:
                    row = dict(status='unverified', reason='worker comparison result missing')
                elif row.get('status') not in ('same', 'changed', 'unverified'):
                    row = dict(status='unverified', reason='invalid worker comparison status')
                rows.append(dict(entry, evidence=str(destination),
                                 **{k: v for k, v in row.items() if k != 'capture'}))
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            rows.extend(dict(entry, status='unverified', reason=str(error)) for entry in entries)
        write(output / 'report.json', rows)
    affected = regressions(rows)
    write(output / 'passing-changed.json', affected)
    write(output / 'passing-changed-tests.json', sorted({
        'DispatchTests/' + row['case'].replace('.', '/', 1) for row in affected}))
    cases = defaultdict(set)
    for row in rows:
        if row.get('case'):
            cases[row['case']].add(row['status'])
    selections = {'changed': sorted(case for case, states in cases.items() if 'changed' in states),
                  'unverified': sorted(case for case, states in cases.items() if 'unverified' in states)}
    for name, selected in selections.items():
        write(output / (name + '-tests.json'), ['DispatchTests/' + case.replace('.', '/', 1) for case in selected])
    write(output / 'rerun-tests.json', sorted(set(json.loads((output / 'changed-tests.json').read_text())) |
                                              set(json.loads((output / 'unverified-tests.json').read_text()))))
    write(output / 'report.json', rows)
    blocked = [row for row in rows if row['status'] != 'same']
    passed = bool(rows) and not blocked
    write(output / 'gate.json', dict(passed=passed, captures=len(rows), blocked=blocked))
    if args.require_same:
        if not rows:
            print('Replay preflight blocked: no retained capture variants', file=sys.stdout)
        for row in blocked:
            fixture = str(Path(row['manifest']).parent / row['path']) if row.get('path') else row['manifest']
            print(f"Replay preflight blocked: {row.get('case') or '<unknown case>'}: {fixture}: "
                  f"{row.get('reason') or row['status']}")
    print(json.dumps({'captures': dict(Counter(row['status'] for row in rows)),
                      'cases': {key: len(value) for key, value in selections.items()},
                      'previously_passing_changed': len({row['case'] for row in affected}), 'report': str(output)}, indent=2))

    return 1 if args.require_same and not passed else 0


if __name__ == '__main__':
    sys.exit(main())
