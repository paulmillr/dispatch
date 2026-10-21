#!/usr/bin/env python3
"""Build the iPhone SSH engine (Mobile/Transport/Core, russh behind a C ABI) offline into
build/mobile-ssh/DispatchMobileSSHCore.xcframework: static libraries for iOS devices, the Apple Silicon
simulator and macOS (the package's `swift test`), with the checked-in C header and module map. Xcode's pre-build
script passes --platform: only the destination's slice is rebuilt, the others stay as last built.

Crates come from Mobile/Transport/Core/Cargo.lock, fetched once into build/cargo with --fetch (network);
every build is --offline --frozen, as the helper's is."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from setup_mobile import current

ROOT = Path(os.environ.get("SRCROOT", Path(__file__).resolve().parent.parent))
CRATE = ROOT / "Mobile/Transport/Core"
OUTPUT = ROOT / "build/mobile-ssh"
FRAMEWORK = OUTPUT / "DispatchMobileSSHCore.xcframework"
LIBRARY = "libdispatch_mobile_ssh.a"
# (Rust target, SDK, deployment variable, minimum OS): the package's platforms (macOS 14, iOS 26).
TARGETS = (
    ("aarch64-apple-ios", "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET", "26.0"),
    ("aarch64-apple-ios-sim", "iphonesimulator", "IPHONEOS_DEPLOYMENT_TARGET", "26.0"),
    ("aarch64-apple-darwin", "macosx", "MACOSX_DEPLOYMENT_TARGET", "14.0"),
)


def environment():
    """A minimal environment, the same in Xcode and in a shell: Xcode's build settings (SDKROOT, ARCHS,
    deployment targets) would point ring's C compiler at the app's SDK, and any difference rebuilds it."""
    toolchain = ROOT / "build/rust"
    env = {key: os.environ[key] for key in ("HOME", "USER", "TMPDIR", "LANG", "DEVELOPER_DIR") if key in os.environ}
    env.update(PATH=str(toolchain / "bin") + os.pathsep + "/usr/bin:/bin:/usr/sbin:/sbin",
               CARGO_HOME=str(ROOT / "build/cargo"), CARGO_TARGET_DIR=str(OUTPUT / "target"))
    return env


def sdk(name):
    return subprocess.run(["xcrun", "--sdk", name, "--show-sdk-path"], check=True, capture_output=True, text=True,
                          env=environment()).stdout.strip()


def run(arguments, env=None):
    print("+ " + " ".join(map(str, arguments)), flush=True)
    subprocess.run([str(a) for a in arguments], check=True, env=env, cwd=CRATE)


def fetch():
    """The one networked step: download the locked crates into build/cargo."""
    run(["cargo", "fetch", "--locked"], environment())


def build(profile, platform=None):
    subprocess.run(["python3", str(ROOT / "scripts/setup-ssh-rust.py"), "--offline"], check=True)
    env = environment()
    for target, name, variable, minimum in TARGETS:
        if platform in (None, name):
            # One cargo run per target: the deployment target differs between iOS and macOS.
            run(["cargo", "build", "--offline", "--frozen", "--profile", profile, "--target", target, "--lib"],
                dict(env, SDKROOT=sdk(name), **{variable: minimum}))
    # Every slice built so far, so a simulator build keeps the device slice (and the reverse).
    libraries = [path for target, *_ in TARGETS if (path := OUTPUT / "target" / target / profile / LIBRARY).is_file()]
    newest = max(path.stat().st_mtime for path in libraries + list((CRATE / "include").iterdir()))
    stamp = FRAMEWORK / "Info.plist"
    # By content too: a checkout's times need not say that the header changed.
    if stamp.is_file() and stamp.stat().st_mtime >= newest and current(FRAMEWORK, CRATE / "include"):
        return
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".xcframework-", dir=OUTPUT) as directory:
        staged = Path(directory) / FRAMEWORK.name
        arguments = ["xcodebuild", "-create-xcframework"]
        for library in libraries:
            arguments += ["-library", str(library), "-headers", str(CRATE / "include")]
        run(arguments + ["-output", str(staged)], env)
        if FRAMEWORK.exists():
            shutil.rmtree(FRAMEWORK)
        staged.rename(FRAMEWORK)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="Download the locked crates into build/cargo, then build")
    parser.add_argument("--profile", choices=("release", "dev"), default="release")
    parser.add_argument("--platform", choices=[name for _, name, *_ in TARGETS],
                        help="Rebuild only this SDK's slice (Xcode's $PLATFORM_NAME); default: all three")
    args = parser.parse_args()
    try:
        if args.fetch:
            fetch()
        build(args.profile, args.platform)
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
