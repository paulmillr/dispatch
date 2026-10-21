#!/usr/bin/env python3
"""What a fresh checkout needs before Xcode resolves the iPhone app's SSH package (docs/ios.md, Building and running):
the pinned Rust with its iOS targets (scripts/setup-ssh-rust.py) and the engine's XCFramework
(scripts/build-mobile-ssh.py, which fetches the locked crates once). SwiftPM resolves the binary target before any
pre-build script runs, so `./run.sh --ios` and `test/run.sh --platform ios` call this first.

Offline-aware like the Mac's setup: with DISPATCH_SETUP_OFFLINE=1 nothing is downloaded; a missing toolchain or
crate cache then fails with the command to run online once."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK = ROOT / 'build/mobile-ssh/DispatchMobileSSHCore.xcframework'
HEADERS = ROOT / 'Mobile/Transport/Core/include'


def current(framework=FRAMEWORK, headers=HEADERS):
    """Whether every slice of the XCFramework carries the checked-in C header and module map. A pull that changes
    them must rebuild it here: the package compiles against it before the app's pre-build script would."""
    slices = [path for path in framework.glob('*/Headers') if path.is_dir()]
    return bool(slices) and all((folder / file.name).is_file() and (folder / file.name).read_bytes() == file.read_bytes()
                                for folder in slices for file in headers.iterdir())


def ensure(offline=None, quiet=False):
    """Prepares what is missing; quick when everything is there."""
    if offline is None:
        offline = os.environ.get('DISPATCH_SETUP_OFFLINE') == '1'
    run = lambda arguments: subprocess.run([sys.executable, *map(str, arguments)], cwd=ROOT, check=True,
                                           stdout=subprocess.DEVNULL if quiet else None)
    # Returns at once when the pinned toolchain (with aarch64-apple-ios and -ios-sim) is ready; links a matching
    # rustup toolchain without the network; downloads only online.
    run([ROOT / 'scripts/setup-ssh-rust.py', *(['--offline'] if offline else [])])
    if current():
        return
    try:
        run([ROOT / 'scripts/build-mobile-ssh.py', *([] if offline else ['--fetch'])])
    except subprocess.CalledProcessError:
        if offline:
            raise SystemExit('The iPhone SSH engine needs its crates: run python3 scripts/build-mobile-ssh.py --fetch '
                             'online once.')
        raise


if __name__ == '__main__':
    ensure(offline='--offline' in sys.argv or None)
