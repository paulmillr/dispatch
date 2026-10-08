#!/usr/bin/env python3
"""Download and verify pinned build tools inside the project."""
import argparse
import contextlib
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import zipfile
from setup_consent import LOCK, ROOT, confirm, environment


def checksum(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


@contextmanager
def download_progress(path):
    """Keep transfer feedback compact, including when launched through run.py."""
    terminal = os.environ.get('DISPATCH_SETUP_TTY') == '1' or (
        'DISPATCH_SETUP_TTY' not in os.environ and sys.stderr.isatty()
        and os.environ.get('TERM') != 'dumb')
    started = time.monotonic()
    stopped = threading.Event()
    frames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    def detail():
        size = path.stat().st_size if path.exists() else 0
        amount = (f'{size / 1048576:.1f} MB' if size >= 1048576 else
                  f'{size / 1024:.0f} KB' if size >= 1024 else f'{size} B')
        return f'{amount} · {time.monotonic() - started:.0f}s'

    def render(marker, final=False):
        line = f'        {marker} {detail()}'
        # Pad only this small indicator so a change of units leaves no stale text.
        print('\r' + line.ljust(32) if terminal else line,
              end='\n' if final or not terminal else '', file=sys.stderr, flush=True)

    def refresh():
        frame = 0
        while not stopped.wait(0.2 if terminal else 5):
            marker = frames[frame % len(frames)] if terminal else '↓'
            render(marker)
            frame += 1

    name = path.name if len(path.name) <= 44 else path.name[:41] + '…'
    print(f'      ↓ {name}', file=sys.stderr, flush=True)
    worker = threading.Thread(target=refresh, daemon=True)
    worker.start()
    success = False
    try:
        yield
        success = True
    finally:
        stopped.set()
        worker.join()
        render('✓' if success else '✗', final=True)


def download(record, cache, offline=False, quiet=False):
    """The verified archive; quiet prints one line when done (for concurrent downloads)."""
    url, expected = record['url'], record['sha256']
    if not url.startswith('https://') or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise RuntimeError('Downloads require an HTTPS URL and pinned SHA-256.')
    name = record.get('filename', url.rsplit('/', 1)[1])
    if not name or name in ('.', '..') or Path(name).name != name:
        raise RuntimeError('Unexpected archive filename: ' + name)
    archive = cache / expected / name
    if archive.is_file():
        if checksum(archive) != expected:
            raise RuntimeError('Checksum mismatch: ' + str(archive))
        return archive
    if offline or os.environ.get('DISPATCH_SETUP_OFFLINE') == '1':
        raise RuntimeError('Offline setup is missing: ' + url)
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.download-', dir=archive.parent) as directory:
        staged = Path(directory) / name
        started = time.monotonic()
        try:
            with (contextlib.nullcontext() if quiet else download_progress(staged)):
                subprocess.run(['curl', '-q', '--fail', '--location', '--silent', '--show-error',
                                '--proto', '=https', '--proto-redir', '=https',
                                '--connect-timeout', '20', '--max-time', '300', url, '-o', str(staged)],
                               check=True, stdout=sys.stderr, stderr=subprocess.PIPE, text=True)
                if checksum(staged) != expected:
                    raise RuntimeError('Checksum mismatch: ' + url)
        except subprocess.CalledProcessError as error:
            if error.stderr:
                print(error.stderr.rstrip(), file=sys.stderr, flush=True)
            if quiet:
                print(f'      ✗ {name}', file=sys.stderr, flush=True)
            raise
        staged.replace(archive)
        if quiet:
            print(f'      ↓ {name}  {archive.stat().st_size / 1048576:.1f} MB · {time.monotonic() - started:.0f}s',
                  file=sys.stderr, flush=True)
    return archive


def extract(archive, destination):
    # Validate every member before writing anything, including on Python 3.9.
    zipped = zipfile.is_zipfile(archive)
    with (zipfile.ZipFile(archive) if zipped else tarfile.open(archive)) as bundle:
        if zipped:
            members = [(member, member.filename, member.is_dir(), member.external_attr >> 16,
                        stat.S_IFMT(member.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK),
                        bundle.read(member).decode() if stat.S_ISLNK(member.external_attr >> 16) else None,
                        time.mktime((*member.date_time, 0, 0, -1)))
                       for member in bundle.infolist()]
        else:
            members = [(member, member.name, member.isdir(), member.mode,
                        member.isfile() or member.isdir() or member.issym(),
                        member.linkname if member.issym() else None, member.mtime)
                       for member in bundle.getmembers()]
        for _, name, _, _, valid, link, _ in members:
            path = Path(name)
            if (path.is_absolute() or '..' in path.parts or not valid or
                    link is not None and (not link or Path(link).is_absolute() or '..' in Path(link).parts)):
                raise RuntimeError('Unexpected archive member: ' + name)
        for member, name, directory, mode, _, link, _ in members:
            path = destination / name
            if link is not None:
                continue
            elif directory:
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with (bundle.open(member) if zipped else bundle.extractfile(member)) as source, path.open('wb') as target:
                    shutil.copyfileobj(source, target)
                path.chmod(mode & 0o777 or 0o644)
        for _, name, _, _, _, link, _ in members:
            if link is not None:
                path = destination / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(link)
        for _, name, _, _, _, _, modified in reversed(members):
            os.utime(destination / name, (modified, modified), follow_symlinks=False)

def compatible(path, name, lock=None):
    if not path:
        return False
    try:
        record = (LOCK if lock is None else lock)[name]
        result = subprocess.run([str(path), *record['check']],
                                capture_output=True, text=True, timeout=10)
        expected = record['banner'].format(version=record['version'])
        return result.returncode == 0 and result.stdout.splitlines()[:1] == [expected]
    except (OSError, subprocess.TimeoutExpired):
        return False


def resolve(name, offline=False, *, lock=None, approve=None, quiet=False):
    """The pinned tool, prepared if needed. quiet (for concurrent preparation) keeps download
    progress to one line and writes build output to build/logs/tool-<name>.log."""
    record = (LOCK if lock is None else lock)[name]
    artifact = record['archives'].get(platform.machine())
    if artifact is None:
        raise RuntimeError('Unsupported build architecture: ' + platform.machine())
    identity = artifact['sha256']
    if 'build' in record:
        recipe = {'sources': record.get('sources', []), 'build': record['build']}
        identity += '-' + hashlib.sha256(json.dumps(recipe, sort_keys=True).encode()).hexdigest()
    directory = ROOT / 'build/tools' / name / identity
    binary = directory / artifact['binary']
    # tmux exports $TMUX (its socket) in every session; it never names a tmux binary.
    override = None if name == 'tmux' else os.environ.get(name.upper())
    if override and Path(shutil.which(override) or override).resolve() != binary.resolve():
        raise RuntimeError(f'{name.upper()} must use the pinned project-local tool: {binary}')
    if directory.exists():
        if compatible(binary, name, lock):
            return binary
        raise RuntimeError('Invalid project-local tool; remove its directory and rerun setup: ' + str(directory))
    if offline or os.environ.get('DISPATCH_SETUP_OFFLINE') == '1':
        raise RuntimeError(f'Missing compatible {name}. Run ./run.sh to prepare project-local tools.')
    (confirm if approve is None else approve)([name])
    archive = download(artifact, ROOT / 'build/downloads', quiet=quiet)
    directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.tool-', dir=directory.parent) as temporary:
        stage = Path(temporary) / 'content'
        stage.mkdir()
        if artifact.get('format') == 'binary':
            target = stage / artifact['binary']
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, target)
            target.chmod(0o755)
        else:
            extract(archive, stage)
        for source in record.get('sources', []):
            extract(download(source, ROOT / 'build/downloads', quiet=quiet), stage)
        if 'build' in record:
            values = {'stage': str(stage), 'jobs': os.environ.get('DISPATCH_BUILD_JOBS', str(os.cpu_count() or 1))}
            log = ROOT / 'build/logs' / f'tool-{name}.log'
            if quiet:
                log.parent.mkdir(parents=True, exist_ok=True)
            with (log.open('w') if quiet else contextlib.nullcontext(sys.stderr)) as output:
                for group in record['build']:
                    for command in group['commands']:
                        try:
                            subprocess.run([argument.format(**values) for argument in command],
                                           cwd=stage / group['directory'],
                                           env=dict(environment(), TMPDIR=temporary, CC='/usr/bin/clang', LC_ALL='C'),
                                           check=True, stdout=output, stderr=output if quiet else None)
                        except subprocess.CalledProcessError:
                            if quiet:
                                print(f'      ✗ building {name}; full output: {log}', file=sys.stderr, flush=True)
                            raise
        if not compatible(stage / artifact['binary'], name, lock):
            raise RuntimeError(f'Pinned archive did not provide {name} {record["version"]}.')
        stage.rename(directory)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tool', choices=['xcodegen'])
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Dispatch builds require macOS and full Xcode')
    print(resolve(args.tool, args.offline))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
