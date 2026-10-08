#!/usr/bin/env python3
"""Prepare pinned native test tools without changing the system installation."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import tempfile
from setup_consent import ROOT, environment, load_script, show_consent

LOCK = json.loads((ROOT / 'scripts/test-tools.lock.json').read_text())
tools = load_script('setup-build-tools')


def resolve(name, **options):
    """The pinned tool; with DISPATCH_TEST_ANY_TOOL_VERSION=1 a missing pin falls back to the newest other
    installed build of that tool, so an offline Mac can test against the versions it has."""
    try:
        return tools.resolve(name, lock=LOCK, **options)
    except RuntimeError as error:
        if os.environ.get('DISPATCH_TEST_ANY_TOOL_VERSION') != '1' or not str(error).startswith('Missing compatible '):
            raise
        binary = LOCK[name]['archives'][platform.machine()]['binary']
        builds = sorted((ROOT / 'build/tools' / name).glob('*/' + binary), key=lambda p: p.stat().st_mtime, reverse=True)
        if not builds:
            raise
        found = subprocess.run([str(builds[0]), *LOCK[name]['check']], capture_output=True, text=True, timeout=10)
        print(f'Test tools: {name} {LOCK[name]["version"]} is not installed; using {found.stdout.strip()} '
              f'from {builds[0]} (DISPATCH_TEST_ANY_TOOL_VERSION=1)', file=sys.stderr, flush=True)
        return builds[0]


def prepare(offline=False, dry_run=False):
    if dry_run:
        for name, record in LOCK.items():
            artifact = record['archives'].get(platform.machine())
            if artifact is None:
                raise RuntimeError('Unsupported build architecture: ' + platform.machine())
            for source in [artifact, *record.get('sources', [])]:
                print(f'Download {source["url"]} (SHA-256 {source["sha256"]})')
            print(f'Install {name} {record["version"]} under {ROOT / "build/tools" / name}')
            for group in record.get('build', []):
                for command in group['commands']:
                    print(f'  In staging/{group["directory"]}: {shlex.join(command)}')
            print(f'Link {ROOT / "build/test-tools/bin" / name} to the installed binary')
        return
    missing = []
    for name in LOCK:
        try:
            resolve(name, offline=True)
        except RuntimeError as error:
            if not str(error).startswith('Missing compatible '):
                raise
            if offline or os.environ.get('DISPATCH_SETUP_OFFLINE') == '1':
                raise RuntimeError(f'Missing compatible {name}. Run ./run.sh --test online to prepare test tools.') from None
            missing.append(name)
    if missing:
        show_consent('Install SHA-256-verified test tools inside this checkout:')
        for name in missing:
            show_consent(f'  - {name} {LOCK[name]["version"]} (build/tools)')
            for source in LOCK[name].get('sources', []):
                show_consent(f'    with {source["name"]} {source["version"]} built from verified source')
        show_consent('Downloads, builds and tool state stay under build/. No system tools or settings are changed.\n'
                     'Install/download these test dependencies? [y/N] ', end='')
        if sys.stdin.readline().strip().lower() not in ('y', 'yes'):
            raise RuntimeError('Setup cancelled; no test dependencies were downloaded or installed.')

    def approve(names):
        if set(names) - set(missing):
            raise RuntimeError('Test dependencies changed after confirmation. Rerun setup.')

    # Downloads are latency-bound and tmux builds from source: prepare every tool at once.
    with ThreadPoolExecutor(max_workers=len(LOCK)) as pool:
        futures = {name: pool.submit(resolve, name, offline=offline, approve=approve, quiet=True) for name in LOCK}
        binaries = {name: future.result() for name, future in futures.items()}
    directory = ROOT / 'build/test-tools/bin'
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.links-', dir=directory.parent) as temporary:
        for name, binary in binaries.items():
            link = Path(temporary) / name
            link.symlink_to(os.path.relpath(binary, directory))
            link.replace(directory / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--dry-run', action='store_true', help='show pinned downloads, builds and links without changing files')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Dispatch test tools require macOS and full Xcode')
    if args.dry_run:
        prepare(dry_run=True)
        return
    os.environ.update(environment())
    home = ROOT / 'build/test-tools/home'
    os.environ.update(HOME=str(home), CODEX_HOME=str(home / '.codex'),
                      CLAUDE_CONFIG_DIR=str(home / '.claude'), PI_CODING_AGENT_DIR=str(home / '.pi/agent'),
                      DISABLE_AUTOUPDATER='1', PI_OFFLINE='1', PI_TELEMETRY='0')
    home.mkdir(parents=True, exist_ok=True)
    Path(os.environ['TMPDIR']).mkdir(parents=True, exist_ok=True)
    prepare(args.offline)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
