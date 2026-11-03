#!/usr/bin/env python3
"""The patched russh the iPhone SSH engine builds against: the published crate, checked against its crates.io SHA-256,
with Dispatch's patch (Mobile/Transport/Core/russh.patch) applied, in build/mobile-ssh/russh (Mobile/Transport/Core's
Cargo.toml depends on it by path). Only the library is staged: the manifest without its examples, tests, benchmarks and
dev-dependencies, and src/.

The patch makes every key exchange after the first (a rekey) call `Handler::check_server_key` with the server's host
key before the exchange's keys are used, failing with `Error::UnknownKey` on false; the published crate checks the
first exchange only (docs/security.md, Dispatch for iPhone, host keys).

    python3 scripts/vendor-russh.py            # stage it (downloads the crate once into build/downloads)
    python3 scripts/vendor-russh.py --offline  # stage it from the cached crate only
    python3 scripts/vendor-russh.py --check    # verify the staged copy is the published crate plus the patch

scripts/build-mobile-ssh.py stages it before every build (offline) and before --fetch (online). The stage is redone
when the crate, the patch or this script change (build/mobile-ssh/russh/.stamp). An upgrade: set VERSION and SHA256
(crates.io's checksum of the crate), rebase the patch, run the engine's tests."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "0.65.0"
SHA256 = "3bb77a4b259312b2abbc541bca1c13cb4e9b61c560a7fd894068c3b92e0c9dc3"
ROOT = Path(__file__).resolve().parent.parent
PATCH = ROOT / "Mobile/Transport/Core/russh.patch"
TARGET = ROOT / "build/mobile-ssh/russh"
DOWNLOAD = ROOT / "build/downloads" / SHA256
# Manifest sections the library build does not need (their files are not staged).
DROPPED = ("[[example]]", "[[test]]", "[[bench]]", "[dev-dependencies")


def crate(offline):
    """The crate's bytes: build/downloads, else cargo's cache, else crates.io (kept in build/downloads)."""
    name = f"russh-{VERSION}.crate"
    for path in [DOWNLOAD, *sorted((ROOT / "build/cargo/registry/cache").glob(f"*/{name}"))]:
        if path.is_file() and hashlib.sha256(data := path.read_bytes()).hexdigest() == SHA256:
            return data
    if offline:
        raise SystemExit(f"{name} is not downloaded: run python3 scripts/build-mobile-ssh.py --fetch online once.")
    data = urllib.request.urlopen(f"https://static.crates.io/crates/russh/{name}", timeout=60).read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SHA256:
        raise SystemExit(f"{name}: SHA-256 {digest}, expected {SHA256}")
    DOWNLOAD.parent.mkdir(parents=True, exist_ok=True)
    partial = DOWNLOAD.with_suffix(".partial")
    partial.write_bytes(data)
    os.replace(partial, DOWNLOAD)
    return data


def manifest(text):
    """The published manifest without the sections in DROPPED, its readme (not staged) and its resolver; its own
    workspace, and upstream's warnings allowed (Xcode shows a build script's warnings)."""
    kept, dropping = [], False
    for line in text.splitlines():
        if line.startswith("["):
            header = line.strip()
            dropping = header.startswith(DROPPED) or (header.startswith("[target.") and ".dev-dependencies" in header)
        if not dropping and not line.startswith(("readme = ", "resolver = ")):
            kept.append(line)
    kept += ["", "[lints.rust]", 'warnings = "allow"', "", "[workspace]"]
    return "\n".join(kept).rstrip() + "\n"


def stamp():
    return hashlib.sha256(SHA256.encode() + PATCH.read_bytes() + Path(__file__).read_bytes()).hexdigest()


def stage(directory, offline):
    archive = directory / "crate.tar.gz"
    archive.write_bytes(crate(offline))
    with tarfile.open(archive) as tar:
        # Plain files and folders inside the archive's own folder only (Python 3.9 has no extraction filters).
        for member in tar.getmembers():
            parts = Path(member.name).parts
            if not (member.isfile() or member.isdir()) or member.name.startswith("/") or ".." in parts \
                    or parts[0] != f"russh-{VERSION}":
                raise SystemExit(f"unexpected archive member {member.name}")
        tar.extractall(directory)
    published = directory / f"russh-{VERSION}"
    staged = directory / "russh"
    staged.mkdir()
    shutil.copytree(published / "src", staged / "src")
    (staged / "Cargo.toml").write_text(manifest((published / "Cargo.toml").read_text()))
    subprocess.run(["/usr/bin/patch", "-p1", "-s", "-N", "--batch", "-d", str(staged), "-i", str(PATCH)], check=True)
    for leftover in [*staged.rglob("*.orig"), *staged.rglob("*.rej")]:
        raise SystemExit(f"the patch left {leftover.relative_to(staged)}")
    return staged


def ready():
    marker = TARGET / ".stamp"
    return marker.is_file() and marker.read_text() == stamp()


def ensure(offline=False):
    """Stages the patched crate unless the current stage is already there."""
    if ready():
        return
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".russh-", dir=TARGET.parent) as directory:
        staged = stage(Path(directory), offline)
        (staged / ".stamp").write_text(stamp())
        if TARGET.exists():
            shutil.rmtree(TARGET)
        staged.rename(TARGET)


def files(tree):
    return {path.relative_to(tree): path.read_bytes() for path in sorted(tree.rglob("*"))
            if path.is_file() and path.name != ".stamp"}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="Compare the staged copy instead of writing it")
    parser.add_argument("--offline", action="store_true", help="Use the cached crate only")
    args = parser.parse_args()
    if not args.check:
        ensure(args.offline)
        print(f"russh {VERSION} with {PATCH.name} in {TARGET.relative_to(ROOT)}")
        return
    with tempfile.TemporaryDirectory(prefix="vendor-russh-") as directory:
        expected = files(stage(Path(directory), args.offline))
        actual = files(TARGET) if TARGET.is_dir() else {}
        differing = sorted(path for path in expected.keys() | actual.keys() if expected.get(path) != actual.get(path))
        for path in differing:
            print(f"differs: {path}", file=sys.stderr)
        sys.exit(1 if differing else 0)


if __name__ == "__main__":
    main()
