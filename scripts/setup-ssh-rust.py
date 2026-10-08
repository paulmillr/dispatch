#!/usr/bin/env python3
"""Provision the pinned SSH helper toolchain as build/rust.

A complete toolchain of the pinned version already on PATH (rustc, cargo, rustfmt, clippy,
rust-lld and every helper target) is linked rather than downloaded. Otherwise the pinned
packages are verified against the versioned upstream manifest, downloaded in parallel and
unpacked into a staging directory that replaces build/rust only when complete.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
from setup_consent import LOCK, confirm, load_script

VERSION = LOCK['rust']['version']
MANIFEST_SHA256 = LOCK['rust']['manifest']['sha256']
tools = load_script('setup-build-tools')
ROOT = Path(__file__).resolve().parent.parent
PREFIX = ROOT / "build/rust"
TARGETS = ("aarch64-apple-darwin", "x86_64-apple-darwin",
           "aarch64-unknown-linux-musl", "x86_64-unknown-linux-musl")
BINARIES = ("rustc", "cargo", "rustfmt", "cargo-clippy")


def host():
    triple = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    return triple + ("-apple-darwin" if platform.system() == "Darwin" else "-unknown-linux-gnu")


def problems(sysroot):
    """What keeps this toolchain from building the helpers; empty when it is usable."""
    missing = [f"bin/{name}" for name in BINARIES if not (sysroot / "bin" / name).is_file()]
    if not (sysroot / "lib/rustlib" / host() / "bin/rust-lld").is_file():
        missing.append("rust-lld")
    missing += [f"target {target}" for target in TARGETS
                if not any((sysroot / "lib/rustlib" / target / "lib").glob("libstd-*.rlib"))]
    if missing:
        return missing
    for name, prefix in (("rustc", "rustc "), ("cargo", "cargo ")):
        try:
            version = subprocess.run([str(sysroot / "bin" / name), "--version"], capture_output=True,
                                     text=True, timeout=20).stdout
        except (OSError, subprocess.TimeoutExpired):
            version = ""
        if not version.startswith(prefix + VERSION + " "):
            missing.append(f"{name} {VERSION} (found {version.strip() or 'none'})")
    return missing


def path_toolchain():
    """(sysroot, problems) for the rustc on PATH, or (None, None) when there is none."""
    rustc = shutil.which("rustc")
    if rustc is None:
        return None, None
    # Ask a rustup proxy for exactly the pinned toolchain, and never let it install one.
    environment = dict(os.environ, RUSTUP_TOOLCHAIN=VERSION, RUSTUP_AUTO_INSTALL="0")
    try:
        result = subprocess.run([rustc, "--print", "sysroot"], capture_output=True, text=True,
                                timeout=20, env=environment)
    except (OSError, subprocess.TimeoutExpired):
        return None, None
    if result.returncode != 0 or not result.stdout.strip():
        return None, None
    sysroot = Path(result.stdout.strip()).resolve()
    return sysroot, problems(sysroot)


def ready():
    if not PREFIX.exists():
        return False
    if not PREFIX.is_symlink():
        stamp = PREFIX / "dispatch-toolchain"
        if not (stamp.is_file() and stamp.read_text() == VERSION + "\n"):
            return False
    return not problems(PREFIX)


def available():
    """Ready now, or ready by linking the PATH toolchain (no download needed)."""
    if ready():
        return True
    sysroot, missing = path_toolchain()
    return sysroot is not None and not missing


def publish(source):
    """Atomically make `source` (a staged directory or a symlink) the toolchain at PREFIX."""
    PREFIX.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rust-old-", dir=PREFIX.parent) as trash:
        if PREFIX.is_symlink() or PREFIX.exists():
            PREFIX.rename(Path(trash) / "rust")
        source.rename(PREFIX)


def link(sysroot):
    with tempfile.TemporaryDirectory(prefix=".rust-link-", dir=PREFIX.parent) as directory:
        staged = Path(directory) / "rust"
        staged.symlink_to(sysroot, target_is_directory=True)
        publish(staged)


def download():
    confirm(['rust'])
    cache = ROOT / "build/rust-downloads"
    cache.mkdir(parents=True, exist_ok=True)
    manifest = tools.download(dict(LOCK['rust']['manifest'], sha256=MANIFEST_SHA256), cache).read_text()
    packages = [(name, host()) for name in ("rustc", "cargo", "rustfmt-preview", "clippy-preview")]
    packages += [("rust-std", target) for target in dict.fromkeys((host(),) + TARGETS)]
    records = []
    for name, target in packages:
        match = re.search(r"\[pkg\." + re.escape(name) + r"\.target\." + re.escape(target) + r"\]\n([^\[]+)", manifest)
        if not match:
            raise SystemExit(f"Pinned toolchain does not provide {name} for {target}")
        fields = dict(re.findall(r'^(\w+) = "([^"]+)"$', match[1], re.M))
        if not fields["xz_url"].startswith("https://static.rust-lang.org/dist/"):
            raise SystemExit("Unexpected toolchain download origin")
        records.append({'url': fields["xz_url"], 'sha256': fields["xz_hash"]})
    PREFIX.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rust-", dir=PREFIX.parent) as directory:
        stage = Path(directory) / "rust"
        stage.mkdir()

        def unpack(record):
            archive = tools.download(record, cache, quiet=True)
            # Each package is <package>/<component>/<files>, which rust-installer's install.sh
            # copies into the prefix; its manifest.in only lists those same files. bsdtar
            # refuses absolute and parent-relative member paths.
            subprocess.run(["tar", "-xJf", str(archive), "-C", str(stage), "--strip-components", "2",
                            "--exclude", "*/manifest.in"], check=True)

        # Downloads are latency-bound per connection: fetch and unpack every package at once.
        with ThreadPoolExecutor(max_workers=len(records)) as pool:
            for future in [pool.submit(unpack, record) for record in records]:
                future.result()
        if problems(stage):
            raise SystemExit("Pinned Rust packages are incomplete: " + ", ".join(problems(stage)))
        (stage / "dispatch-toolchain").write_text(VERSION + "\n")
        publish(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    if ready():
        return
    sysroot, missing = path_toolchain()
    if sysroot is not None and not missing:
        # Linking needs no network, so offline setup may use it too.
        link(sysroot)
        print(f"      Using Rust {VERSION} from PATH: {sysroot}", flush=True)
        return
    if args.offline or os.environ.get("DISPATCH_SETUP_OFFLINE") == "1":
        raise SystemExit(f"Rust {VERSION} is missing. Run python3 scripts/setup-ssh-rust.py explicitly.")
    if sysroot is not None:
        print(f"      Rust on PATH ({sysroot}) lacks: {', '.join(missing)}; downloading the pinned toolchain.\n"
              f"      With rustup: rustup toolchain install {VERSION} --component rustfmt,clippy "
              f"--target {','.join(TARGETS)}", flush=True)
    download()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
