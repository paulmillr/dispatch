#!/usr/bin/env python3
"""Measure compilation without launching the app; retain logs and Swift timings."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', default='build')
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
    parser.add_argument('--derived-data', type=Path, default=ROOT / 'build/compilation-profile')
    parser.add_argument('--action', choices=['build', 'build-for-testing'], default='build-for-testing')
    parser.add_argument('--clean', action='store_true', help='Clean the selected DerivedData build products first')
    parser.add_argument('--diagnostics', action='store_true', help='Record Swift function body times (changes compiler flags)')
    parser.add_argument('--cache', action='store_true', help='Opt in to Xcode compiler caching and explicit modules')
    parser.add_argument('build_settings', nargs='*', help='Optional Xcode NAME=VALUE overrides')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', args.label):
        parser.error('Use letters, digits, dots, underscores or hyphens for the label')
    if any('=' not in value or value.startswith('-') for value in args.build_settings):
        parser.error('Build settings must use NAME=VALUE')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    output = ROOT / 'tmp/profiling/compilation' / (stamp + '-' + args.label)
    output.mkdir(parents=True)
    command = ['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'Dispatch',
               '-configuration', args.configuration, '-derivedDataPath', str(args.derived_data.resolve()),
               '-destination', 'platform=macOS', '-showBuildTimingSummary']
    if args.clean:
        command.append('clean')
    command.append(args.action)
    if args.cache:
        command += ['COMPILATION_CACHE_ENABLE_CACHING=YES', 'SWIFT_ENABLE_EXPLICIT_MODULES=YES']
    command += args.build_settings
    if args.diagnostics:
        command.append('OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -debug-time-function-bodies '
                       '-Xfrontend -warn-long-expression-type-checking=100')
    sources = list(ROOT.glob('Dispatch/**/*.swift')) + list(ROOT.glob('DispatchTests/**/*.swift'))
    sources += [ROOT / name for name in ['project.yml', 'Dispatch.xcodeproj/project.pbxproj',
                                       'scripts/build-ssh-helper.sh']]
    record = {'command': command, 'started_at': datetime.datetime.now().astimezone().isoformat(),
              'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
              'source_hashes': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted(sources)}, 'status': 'running'}
    summary = output / 'summary.json'
    summary.write_text(json.dumps(record, indent=2) + '\n')
    print('Compilation log: ' + str(output / 'build.log'), flush=True)
    started = time.perf_counter()
    started_wall = time.time()
    try:
        with (output / 'build.log').open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        record.update(returncode=result.returncode, status='passed' if result.returncode == 0 else 'failed')
    except BaseException:
        record['status'] = 'interrupted'
        raise
    finally:
        record['seconds'] = time.perf_counter() - started
        log = (output / 'build.log').read_text(errors='replace')
        record['tasks'] = [dict(name=name, count=int(count), seconds=float(seconds))
                           for name, count, seconds in re.findall(
                               r'^(.+) \((\d+) tasks?\) \| ([\d.]+) seconds$', log, re.MULTILINE)]
        record['cache'] = [dict(hits=int(hits), cacheable_tasks=int(total))
                           for hits, total in re.findall(r'note: (\d+) hits / (\d+) cacheable tasks', log)]
        bodies = [dict(ms=float(ms), location=location, function=function)
                  for ms, location, function in re.findall(r'^([\d.]+)ms\t(.+?)\t(.+)$', log, re.MULTILINE)]
        record['function_bodies'] = sorted(bodies, key=lambda item: item['ms'], reverse=True)
        summary.write_text(json.dumps(record, indent=2) + '\n')
        activities = [p for p in (args.derived_data / 'Logs/Build').glob('*.xcactivitylog')
                      if p.stat().st_mtime >= started_wall]
        if activities:
            shutil.copy2(max(activities, key=lambda p: p.stat().st_mtime), output / 'build.xcactivitylog')
    print(f"Build {record['status']}: {record['seconds']:.2f}s; profile: {summary}")
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
