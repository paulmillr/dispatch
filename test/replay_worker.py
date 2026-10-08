#!/usr/bin/env python3
"""Bounded native replay on the capture's platform; no live external operations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time


def compare(original, candidate, expected=None):
    results = []
    names = original.keys() | candidate.keys()
    expected = names if expected is None else set(expected)
    for name in sorted(names | expected):
        before, after = original.get(name), candidate.get(name)
        reason = ('unexpected capture result' if name not in expected else
                  'original result missing' if before is None else
                  'original replay incomplete' if not before['complete'] else
                  'candidate result missing' if after is None else
                  'candidate replay incomplete' if not after['complete'] else
                  'exit differs' if before['exit'] != after['exit'] else
                  'completion differs' if before.get('completion') != after.get('completion') else None)
        status = ('same' if reason is None else 'changed' if reason in
                  ('candidate replay incomplete', 'exit differs', 'completion differs') else 'unverified')
        row = dict(capture=name, status=status, reason=reason,
                   original_exit=before and before['exit'], candidate_exit=after and after['exit'])
        if (before and 'completion' in before) or (after and 'completion' in after):
            row.update(original_completion=before and before.get('completion'),
                       candidate_completion=after and after.get('completion'))
        results.append(row)
    return results


def read(directory):
    result = {}
    for index, line in enumerate((directory / 'report.jsonl').read_text().splitlines()):
        row = json.loads(line)
        receipt = directory / f'{index:06}.complete'
        info = receipt.lstat() if receipt.exists() else None
        complete = (info is not None and stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
                    and row['exit'] is not None and row['status'] not in ('timeout', 'skip'))
        if row['capture'] in result:
            raise ValueError('Duplicate capture in replay report: ' + row['capture'])
        boundary = None
        if complete:
            try:
                mismatch = directory / f'{index:06}.mismatch' / 'mismatch.json'
                if row.get('mismatch') or mismatch.exists() or mismatch.is_symlink():
                    raise ValueError('Replay reported an I/O mismatch')
                if info.st_size > 4096: raise ValueError('Completion receipt exceeds bound')
                body = receipt.read_bytes()
                if body:
                    boundary = json.loads(body)
                    if boundary == {'kind':'handoff'}:
                        status = 0
                    elif (isinstance(boundary,dict) and set(boundary)=={'kind','status'} and
                          boundary['kind']=='return' and type(boundary['status']) is int):
                        # POSIX exposes the low eight bits of a normal process return.
                        status = boundary['status'] & 255
                    elif (isinstance(boundary,dict) and set(boundary)=={'kind','signal'} and
                          boundary['kind']=='signal' and type(boundary['signal']) is int and
                          0 < boundary['signal'] < 32):
                        status = 128 + boundary['signal']
                    else:
                        raise ValueError('Unknown completion boundary')
                    if row['exit'] != status:
                        raise ValueError('Process exit differs from completion boundary')
                if 'completion' in row and row['completion'] != boundary:
                    raise ValueError('Completion report differs from receipt')
            except (OSError,ValueError) as error:
                complete = False
                boundary = None
                row['completion_error'] = str(error)
        result[row['capture']] = dict(row, complete=complete, completion=boundary)
    return result


def batch(command, environment, log, deadline, memory):
    with log.open('xb') as stream:
        child = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            for _ in iter(int, 1):
                if child.poll() is not None:
                    return child.returncode
                sample = subprocess.run(['ps', '-axo', 'pgid=,rss='], capture_output=True, text=True,
                                        timeout=5, check=True)
                rss = sum(int(values[1]) for line in sample.stdout.splitlines()
                          if len(values := line.split()) == 2 and int(values[0]) == child.pid)
                if rss > memory * 1024 or time.monotonic() >= deadline:
                    raise RuntimeError('Replay memory/time limit reached; partial reports retained')
                time.sleep(.2)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('captures', 'list', 'original', 'helper', 'tool', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--image', help='Independently verified original absolute image for legacy recordings')
    parser.add_argument('--timeout', type=int, default=8, help='Seconds per capture')
    parser.add_argument('--budget', type=int, default=1800, help='Total seconds')
    parser.add_argument('--memory', type=int, default=4096, help='MiB for the replay process group')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if min(args.timeout, args.budget, args.memory) <= 0 or (args.image and not Path(args.image).is_absolute()):
        parser.error('Limits must be positive and image must be absolute')
    commands = [[str(args.tool.resolve()), '--replay-batch', str(args.captures.resolve()), str(helper.resolve()),
                 '--list', str(args.list.resolve()), '--output', str((args.output / name).resolve()),
                 '--timeout', str(args.timeout), '--completion', 'required']
                for name, helper in [('original', args.original), ('candidate', args.helper)]]
    if args.dry_run:
        print(json.dumps(commands, indent=2))
        return
    os.umask(0o077)
    args.output.mkdir(parents=True, exist_ok=False)
    identities = {}
    for name in ('original', 'helper', 'tool'):
        digest = hashlib.sha256()
        with getattr(args, name).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        identities[name] = digest.hexdigest()
    (args.output / 'inputs.json').write_text(json.dumps(dict(sha256=identities, commands=commands, image=args.image), indent=2))
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('DISPATCH_REPLAY', 'DISPATCH_CAPTURE'))}
    deadline = time.monotonic() + args.budget
    for name, command in zip(('original', 'candidate'), commands):
        # The old original may predate this control; run it from its verified image where available.
        if args.image:
            environment['DISPATCH_REPLAY_IMAGE'] = args.image
        batch(command, environment, args.output / (name + '.log'), deadline, args.memory)
    rows = compare(read(args.output / 'original'), read(args.output / 'candidate'),
                   json.loads(args.list.read_text()))
    (args.output / 'comparison.json').write_text(json.dumps(rows, indent=2))
    print(json.dumps({status: sum(row['status'] == status for row in rows)
                      for status in ('same', 'changed', 'unverified')}))


if __name__ == '__main__':
    main()
