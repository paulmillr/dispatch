#!/usr/bin/env python3
"""Scrubs recordings on their way into the replay corpus, and checks what a push of it adds (docs/replay.md, Scrub
captures). Captures hold unredacted I/O and the corpus is public: no recording enters it, and none leaves this Mac,
without this.

Every value test/leak.py finds on this Mac and its SSH test hosts is a needle or public. Values that change by themselves
(machine, boot and kernel ids, network addresses, time zones, key fingerprints, the SSH agent socket, login banner times)
are needles without a decision. The rest (accounts, host names, names, paths, git identity) take one decision each, kept
in this Mac's private policy file (POLICY, never in the checkout): `needle<TAB>stand-in` (the same byte length) or a
bare `needle` (masked) for a private value, `#public<TAB>value` for a public one. A value with no decision, a host leak.py
could not reach, or a credential-like variable in a recorded environment stops the scrub (fail closed): decide, then run
the store again.

  scrub.py store STAGE REPLAYS      scrub a capture run (test/xcode.py --capture does), then capture store it
  scrub.py tests REPLAYS TEST...    scrub tests already in the corpus, in place (TEST: Class/testName)
  scrub.py check [PATH...]          fail on a capture holding one of this Mac's private values (default: replays/)
  scrub.py hook                     install the corpus's pre-push hook (check on every capture a push adds)
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'test'))
import leak

POLICY = Path(os.environ.get('DISPATCH_SCRUB_POLICY', '~/.config/dispatch/replay-scrub.txt')).expanduser()
HELPER = ROOT / 'build/Build/Products/Debug/Dispatch.app/Contents/Resources/dispatch-helper'
# leak.py's groups whose values change by themselves, or are random: needles with no decision (masked, or leak.py's value).
AUTOMATIC = ('machine, boot and hardware ids', 'network addresses', 'time zone', 'SSH agent socket', 'fingerprints',
             '"Last login" banner times', 'capture run name')
# A recorded environment variable named like this holds a secret nobody listed: stop.
CREDENTIAL = re.compile(r'TOKEN|SECRET|PASSW|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIAL|AUTH', re.I)
# The app's own per-launch values, made from the journal's seed (HerdrLaunch): worthless after the run, needed by replay.
MADE = {'DISPATCH_HERDR_TOKEN'}
CAPTURES = ('*.rpl.zst', '*.rpl.bz2', '*.rpl')


def policy():
    """The policy file: private needles (needle -> stand-in or None) and public values."""
    private, public = {}, set()
    if POLICY.exists():
        for line in POLICY.read_text().splitlines():
            if line.startswith('#public\t'):
                public.add(line.split('\t', 1)[1])
            elif line and not line.startswith('#'):
                needle, _, value = line.partition('\t')
                private[needle] = value or None
    return private, public


def needles(captures=()):
    """The needles file's lines for this Mac now: the policy's private values, then the automatic ones. Raises with what
    has no decision yet. `captures`: directories whose login banners to add."""
    private, public = policy()
    lines, undecided = [n + ('\t' + v if v else '') for n, v in private.items()], []
    for where, title, values, context in leak.collect(captures):
        if 'NOT REACHED' in title:
            undecided.append(f'{where}: {title}')
        if context:
            continue
        for value in values:
            needle = value.split('\t')[0]
            if needle in private or needle in public:
                continue
            if any(kind in title for kind in AUTOMATIC):
                lines.append(value)
            else:
                undecided.append(f'{where}: {title}: {needle!r}')
    if undecided:
        raise SystemExit('Scrub stopped: these values have no decision in ' + str(POLICY) + ' (a private one: `needle` or '
                         '`needle<TAB>stand-in` of the same byte length; a public one: `#public<TAB>value`):\n  '
                         + '\n  '.join(undecided))
    return list(dict.fromkeys(lines))


def write_needles(lines, directory):
    path = Path(directory) / 'needles.txt'
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write('\n'.join(lines) + '\n')
    return path


def files(paths):
    return sorted(file for path in map(Path, paths) for file in ([path] if path.is_file() else
                  [f for pattern in CAPTURES for f in path.rglob(pattern)]))


def expanded(path):
    command = {'.zst': ['zstd', '-dcq', '--long=27'], '.bz2': ['bzip2', '-dc']}.get(path.suffix)
    return subprocess.run(command + [str(path)], capture_output=True, check=True).stdout if command else path.read_bytes()


def environment(helper, directory):
    """The variable names the captures' helpers recorded at startup (capture grep's first section)."""
    output = subprocess.run([str(helper), 'capture', 'grep', str(directory), '--needles', os.devnull, '--limit', '100000'],
                            capture_output=True, text=True).stdout
    names, section = set(), False
    for line in output.splitlines():
        if line.startswith('environment at startup'):
            section = True
        elif section and not line.startswith(' '):
            break
        elif section and (match := re.match(r'^  ([A-Za-z_][A-Za-z0-9_]*): \d+ values?$', line)):
            names.add(match[1])
    return names


def leaks(paths, lines):
    """file -> the needles it holds as literal bytes (the doc's plain check; capture replace already found cut and
    wrapped ones)."""
    kept = {line.split('\t')[0] for line in lines if '\t' in line and line.split('\t')[0] == line.split('\t')[1]}
    plain = [line.split('\t')[0].encode() for line in lines if line and line.split('\t')[0] not in kept]
    found = {}
    for path in files(paths):
        data = expanded(path)
        hits = [needle.decode() for needle in plain if needle in data]
        if hits:
            found[path] = hits
    return found


def scrub(helper, source, output, captures=()):
    """Every capture under `source` into `output` (absent), scrubbed and verified: capture replace (which replays each
    helper capture before and after), then the plain check. Files that are not captures are copied as they are."""
    lines = needles(captures)
    secret = sorted(name for name in environment(helper, source) if CREDENTIAL.search(name) and name not in MADE)
    if secret:
        raise SystemExit('Scrub stopped: recorded environments hold credential-like variables ' + ', '.join(secret)
                         + ': keep them out of the test environment and record again')
    with tempfile.TemporaryDirectory(prefix='scrub-', dir=ROOT / 'build') as work:
        path = write_needles(lines, work)
        result = subprocess.run([str(helper), 'capture', 'replace', str(source), str(output), '--needles', str(path)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode:
            sys.stderr.write(result.stdout)
            raise SystemExit(f'Scrub failed: capture replace exited {result.returncode} ({source})')
        found = leaks([output], lines)
    if found:
        raise SystemExit('Scrub failed: needles left in ' + ', '.join(f'{p} ({len(h)})' for p, h in found.items()))
    for file in Path(source).rglob('*'):
        target = Path(output) / file.relative_to(source)
        if file.is_file() and not any(file.match(pattern) for pattern in CAPTURES) and not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)


def store(stage, replays, helper=HELPER, failed=False):
    """A capture run's tests into the corpus, scrubbed first. Returns capture store's process."""
    output = Path(stage).with_name(Path(stage).name + '-scrubbed')
    shutil.rmtree(output, ignore_errors=True)
    scrub(helper, stage, output, captures=[stage])
    return subprocess.run([str(helper), 'capture', 'store', str(output), str(replays)] + (['--failed'] if failed else []),
                          stdout=subprocess.PIPE, text=True)


def tests(replays, names, helper=HELPER):
    """Tests already in the corpus, scrubbed in place: each test's captures in one run (they stay linked)."""
    with tempfile.TemporaryDirectory(prefix='scrub-tests-', dir=ROOT / 'build') as work:
        source, output = Path(work) / 'in', Path(work) / 'out'
        for name in names:
            shutil.copytree(Path(replays) / name, source / name)
        scrub(helper, source, output)
        for name in names:
            shutil.rmtree(Path(replays) / name)
            shutil.copytree(output / name, Path(replays) / name)
    print(f'scrubbed {len(names)} tests in {replays}')


def check(paths):
    """Fails on a capture holding a needle of this Mac's (its private values as test/leak.py finds them now and the
    policy names them)."""
    lines = needles()
    problems = [f'{p}: holds {", ".join(h)}' for p, h in leaks(paths, lines).items()]
    if problems:
        print('Unscrubbed captures (python3 test/scrub.py tests REPLAYS Class/test):', *problems, sep='\n  ', file=sys.stderr)
        return 1
    print(f'{len(files(paths))} captures checked: scrubbed')
    return 0


def pushed(repository):
    """The captures a push adds (git's pre-push lines on stdin), written to a scratch directory: what goes, not the
    working tree."""
    work = Path(tempfile.mkdtemp(prefix='scrub-push-', dir=ROOT / 'build'))
    zero = '0' * 40
    for line in sys.stdin.read().splitlines():
        _, local, _, remote = line.split()
        if local == zero:
            continue
        known = remote != zero and subprocess.run(['git', '-C', repository, 'cat-file', '-e', remote + '^{commit}']).returncode == 0
        command = ['diff', '--name-only', '--diff-filter=AM', remote, local] if known else ['ls-tree', '-r', '--name-only', local]
        for name in subprocess.run(['git', '-C', repository, *command], capture_output=True, text=True, check=True).stdout.splitlines():
            if any(Path(name).match(pattern) for pattern in CAPTURES):
                target = work / local / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('wb') as stream:
                    subprocess.run(['git', '-C', repository, 'cat-file', 'blob', f'{local}:{name}'], stdout=stream, check=True)
    return work


HOOK = '''#!/bin/sh
# Installed by test/scrub.py hook: refuses to push a capture holding this Mac's private values.
exec python3 "{script}" check --push "$(git rev-parse --show-toplevel)"
'''


def hook():
    for repository in (ROOT / 'replays', ROOT):
        hooks = Path(subprocess.run(['git', '-C', str(repository), 'rev-parse', '--absolute-git-dir'], capture_output=True,
                                    text=True, check=True).stdout.strip()) / 'hooks'
        target = hooks / 'pre-push'
        text = HOOK.format(script=Path(__file__).resolve())
        if target.exists() and target.read_text() != text:
            print(f'{target} exists and is not ours: add `{text.splitlines()[-1]}` to it', file=sys.stderr)
            continue
        hooks.mkdir(exist_ok=True)
        target.write_text(text)
        target.chmod(0o755)
        print(f'installed {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--helper', type=Path, default=HELPER, help='A dispatch-helper with the capture tool (default: the Debug app\'s)')
    commands = parser.add_subparsers(dest='command', required=True)
    command = commands.add_parser('store')
    command.add_argument('stage', type=Path)
    command.add_argument('replays', type=Path)
    command = commands.add_parser('tests')
    command.add_argument('replays', type=Path)
    command.add_argument('names', nargs='+')
    command = commands.add_parser('check')
    command.add_argument('paths', nargs='*', type=Path)
    command.add_argument('--push', metavar='REPOSITORY', help='Check what the pushed commits add (pre-push hook)')
    commands.add_parser('hook')
    args = parser.parse_args()
    if args.command == 'store':
        stored = store(args.stage, args.replays, args.helper)
        sys.stdout.write(stored.stdout)
        return stored.returncode
    if args.command == 'tests':
        tests(args.replays, args.names, args.helper)
        return 0
    if args.command == 'check':
        if args.push:
            work = pushed(args.push)
            try:
                return check([work]) if files([work]) else 0
            finally:
                shutil.rmtree(work, ignore_errors=True)
        return check(args.paths or [ROOT / 'replays'])
    hook()
    return 0


if __name__ == '__main__':
    sys.exit(main())
