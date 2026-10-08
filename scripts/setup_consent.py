#!/usr/bin/env python3
"""Offline setup preflight and one consent shared by its child downloaders."""
import importlib.util
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'scripts/build.lock.json').read_text())
APPROVAL = 'DISPATCH_SETUP_APPROVED'


def environment():
    build = ROOT / 'build'
    return dict(os.environ, TMPDIR=str(build / 'tmp'), CFFIXED_USER_HOME=str(build / 'user'),
                XDG_CACHE_HOME=str(build / 'cache'), CARGO_HOME=str(build / 'cargo'),
                CLANG_MODULE_CACHE_PATH=str(build / 'modules'), SWIFT_MODULE_CACHE_PATH=str(build / 'modules'),
                PYTHONDONTWRITEBYTECODE='1')


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def describe(component):
    return {
        'xcodegen': f'XcodeGen   {LOCK["xcodegen"]["version"]}\n'
                    '      Generates the Xcode project · build/tools',
        'rust': f'Rust       {LOCK["rust"]["version"]}\n'
                '      SSH helper compiler and tools; macOS + Linux targets · build/rust',
    }[component]


def show_consent(message, end='\n'):
    print(message, end=end, file=sys.stderr, flush=True)
    # Support callers that capture stderr and supply a separate prompt descriptor.
    descriptor = os.environ.get('DISPATCH_SETUP_UI_FD')
    if descriptor is not None:
        os.write(int(descriptor), (message + end).encode())


def confirm(components):
    components = list(dict.fromkeys(components))
    if not components:
        return
    if os.environ.get('DISPATCH_SETUP_OFFLINE') == '1':
        raise RuntimeError('Offline setup is missing: ' + ', '.join(components) + '. Run bash scripts/setup.sh online once.')
    if APPROVAL in os.environ:
        unexpected = set(components) - set(os.environ[APPROVAL].split(','))
        if unexpected:
            raise RuntimeError('Setup requirements changed after confirmation: ' + ', '.join(sorted(unexpected)) + '. Rerun setup.')
        return
    show_consent('\n    Dependencies to prepare\n'
                 '    Cached downloads are reused.\n')
    for component in components:
        show_consent('    • ' + describe(component) + '\n')
    show_consent('    Downloads are pinned and SHA-256 verified.\n'
                 '    Package versions and sources: scripts/build.lock.json\n'
                 '    Tools, downloads and caches stay inside this checkout.\n\n'
                 '    Install/download ALL dependencies listed above? [y/N] ', end='')
    answer = sys.stdin.readline().strip().lower()
    show_consent('')
    if answer not in ('y', 'yes'):
        raise RuntimeError('Setup cancelled; no dependencies were downloaded or installed.')


@contextmanager
def progress(label):
    started = time.monotonic()
    print(f'\n    … {label}', file=sys.stderr, flush=True)
    try:
        yield
    except BaseException:
        print(f'    ✗ {label}  {time.monotonic() - started:.1f}s', file=sys.stderr, flush=True)
        raise
    else:
        print(f'    ✓ {label}  {time.monotonic() - started:.1f}s', file=sys.stderr, flush=True)


def succeeds(command):
    return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def plan():
    tools = load_script('setup-build-tools')
    rust = load_script('setup-ssh-rust')
    missing = []
    try:
        tools.resolve('xcodegen', offline=True)
    except RuntimeError as error:
        if not str(error).startswith('Missing compatible '):
            raise
        missing.append('xcodegen')
    if not rust.available():
        missing.append('rust')
    return missing


def main():
    if sys.argv[1:] == ['--setup']:
        os.environ.update(environment())
        for key in ('TMPDIR', 'CFFIXED_USER_HOME'):
            Path(os.environ[key]).mkdir(parents=True, exist_ok=True)
        if not (succeeds(['xcodebuild', '-version']) and
                succeeds(['xcrun', '--sdk', 'macosx', '--find', 'swiftc'])):
            raise RuntimeError('Full Xcode is required. Install/select Xcode and complete its first-launch setup.')
        if not succeeds(['xcodebuild', '-checkFirstLaunchStatus']):
            raise RuntimeError('Complete Xcode first-launch setup, then rerun ./run.sh.')
        os.environ.pop(APPROVAL, None)
        components = plan()
        confirm(components)
        os.environ[APPROVAL] = ','.join(components)
        tools = load_script('setup-build-tools')
        with progress(f'XcodeGen {LOCK["xcodegen"]["version"]} · preparing project generator'):
            tools.resolve('xcodegen')
        with progress(f'Rust {LOCK["rust"]["version"]} · preparing SSH helper toolchain'):
            subprocess.run([sys.executable, str(ROOT / 'scripts/setup-ssh-rust.py')], check=True)
        return
    if len(sys.argv) > 1:
        # Shell download sites must be covered by the original approval, even if
        # prerequisites disappear between preflight and execution.
        if APPROVAL not in os.environ:
            raise RuntimeError('Run bash scripts/setup.sh to approve downloads first.')
        confirm(sys.argv[1:])
        return
    components = plan()
    confirm(components)
    # stdout is exclusively the child-process approval scope, never prompt text.
    print(','.join(components))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
