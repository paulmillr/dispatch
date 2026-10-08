#!/usr/bin/env python3
"""Build the pinned Rust helper or replay tool offline for all supported platforms, and install
the helper's three binaries into the app.

Xcode runs the build in its own target, in parallel with the terminal frameworks, and the
app target only installs the finished binaries (--install-only)."""
import argparse
from contextlib import nullcontext
import fcntl
import hashlib
import json
import re
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(os.environ.get("SRCROOT", Path(__file__).resolve().parent.parent))
NAMES = ("darwin-universal", "linux-aarch64", "linux-x86_64")
# Remote helpers bundled for SSH hosts: protocol marker the app checks (helper4: its generated wire schema
# version) and a fixed Cargo profile when the workspace defines only one.
HELPERS = {
    "helper4": {"protocol": None, "profile": "release", "codec": ROOT / "Dispatch/Helper/HelperBinary.swift"},
}


def run(*arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def replace_if_changed(source, destination):
    """Publish complete files and preserve unchanged output timestamps."""
    if destination.is_file() and source.read_bytes() == destination.read_bytes():
        if source.stat().st_mode & 0o777 == destination.stat().st_mode & 0o777:
            return
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".helper-", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        shutil.copyfile(source, temporary)
        temporary.chmod(source.stat().st_mode & 0o777)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def write_if_changed(destination, text):
    if destination.is_file() and destination.read_text() == text:
        return
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, prefix=".helper-", delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(text)
    try:
        temporary.chmod(0o644)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def codec(messages, committed):
    """The app compiles the helper's generated binary body codec (HelperBinary.swift); return its schema
    version. A different generated codec replaces the app's copy and stops the build, so an app never
    ships a codec that does not match the helper it bundles. The codec comes from the build script
    output directories Cargo reports for this build (`messages`: its JSON lines), never from a
    search of the cache, where older builds leave stale codecs."""
    outputs = (Path(message["out_dir"]) / "HelperBinary.swift" for message in map(json.loads, messages.splitlines())
               if message.get("reason") == "build-script-executed")
    texts = {path.read_text() for path in outputs if path.is_file()}
    if len(texts) != 1:
        sys.exit(f"expected one generated HelperBinary.swift in this helper build, found {len(texts)}")
    text = texts.pop()
    if not committed.is_file() or committed.read_text() != text:
        committed.write_text(text)
        sys.exit(f"{committed} updated from the helper build: rebuild and commit it")
    return re.search(r"static let version: UInt64 = (\d+)", text).group(1) + "\n"


def build(profile, target_dir, helper="helper4", replay_tools=False, dry_run=False, capture=None):
    settings = HELPERS[helper]
    profile = settings.get("profile", profile)
    capture = default_capture() if capture is None else capture
    toolchain = ROOT / "build/rust"
    # Validate every required target without installing or fetching anything.
    if not dry_run:
        run("python3", str(ROOT / "scripts/setup-ssh-rust.py"), "--offline")
    target_dir = target_dir.resolve()
    # Helpers without the capture feature keep their own Cargo cache, so switching between Debug and
    # Release reuses each fully optimized link instead of redoing it. Both publish to target_dir/bin.
    cache = target_dir if capture or replay_tools else target_dir / "without-capture"
    if not dry_run:
        cache.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PATH=str(toolchain / "bin") + os.pathsep + os.environ.get("PATH", ""),
               CARGO_HOME=str(ROOT / "build/cargo"), CARGO_TARGET_DIR=str(cache),
               MACOSX_DEPLOYMENT_TARGET="14.0",
               DYLD_FALLBACK_LIBRARY_PATH=str(toolchain / "lib") +
               (os.pathsep + os.environ["DYLD_FALLBACK_LIBRARY_PATH"] if os.environ.get("DYLD_FALLBACK_LIBRARY_PATH") else ""))
    crate = ROOT / "Helpers" / helper
    binary = "examples/capture-redact" if replay_tools else "dispatch-" + helper
    protocol = settings["protocol"]
    cargo = str(toolchain / "bin/cargo")
    with nullcontext() if dry_run else (target_dir / ".build.lock").open("a") as lock:
        if lock is not None:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Waiting for another SSH helper build: " + str(target_dir), flush=True)
                fcntl.flock(lock, fcntl.LOCK_EX)
        print(("Planning " if dry_run else "Building ") + ("capture-redact" if replay_tools else helper) +
              " (" + profile + ("" if replay_tools else ", capture" if capture else ", without capture") +
              ", four targets in parallel)", flush=True)
        host = next(line.removeprefix("host: ") for line in
                    subprocess.check_output([str(toolchain / "bin/rustc"), "-vV"], env=env, text=True).splitlines()
                    if line.startswith("host: "))
        linker = toolchain / "lib/rustlib" / host / "bin/rust-lld"
        linux_flags = ["-C", "linker=" + str(linker), "-C", "linker-flavor=ld.lld", "-C", "target-feature=+crt-static"]
        # One Cargo scheduler shares host dependencies and the CPU job budget
        # across all four targets. Separate Cargo processes would lock this cache.
        command = [cargo, "build", "--offline", "--frozen", "--profile", profile, "--message-format=json-render-diagnostics"]
        if replay_tools:
            command += ["--package", "dispatch-helper4-core", "--example", "capture-redact"]
        elif capture:
            command += ["--features", "dispatch-" + helper + "/capture"]
        # Global rustflags override target-specific flags. Preserve caller flags
        # for macOS while keeping the existing static Linux linker configuration.
        encoded_flags = env.pop("CARGO_ENCODED_RUSTFLAGS", None)
        rustflags = env.pop("RUSTFLAGS", None)
        if encoded_flags is not None:
            mac_flags = encoded_flags.split("\x1f") if encoded_flags else []
        else:
            mac_flags = rustflags.split() if rustflags is not None else None
        for target in ("aarch64-apple-darwin", "x86_64-apple-darwin"):
            command += ["--target", target]
            if mac_flags is not None:
                command += ["--config", "target." + target + ".rustflags=" + json.dumps(mac_flags)]
        for arch in ("aarch64", "x86_64"):
            target = arch + "-unknown-linux-musl"
            command += ["--target", target, "--config", "target." + target + ".rustflags=" + json.dumps(linux_flags)]
        output = target_dir / "bin" / "replay" if replay_tools else target_dir / "bin"
        if dry_run:
            print(json.dumps(dict(command=command, cwd=str(crate),
                                  setup=["python3", str(ROOT / "scripts/setup-ssh-rust.py"), "--offline"],
                                  outputs=[str(output / name) for name in NAMES]), indent=2))
            return
        messages = run(*command, cwd=crate, env=env, stdout=subprocess.PIPE, text=True).stdout
        if settings.get("codec") and not replay_tools:
            protocol = codec(messages, settings["codec"])
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="package-", dir=target_dir) as directory:
            stage = Path(directory)
            native = stage / "darwin-universal"
            run("xcrun", "lipo", "-create", str(cache / "aarch64-apple-darwin" / profile / binary),
                str(cache / "x86_64-apple-darwin" / profile / binary), "-output", str(native))
            run("codesign", "--force", "--sign", "-", "--identifier", "dev.dispatch." + helper, str(native))
            for arch in ("aarch64", "x86_64"):
                shutil.copyfile(cache / (arch + "-unknown-linux-musl") / profile / binary, stage / ("linux-" + arch))
            for name in NAMES:
                (stage / name).chmod(0o755)
                replace_if_changed(stage / name, output / name)
            if replay_tools:
                return
            version = hashlib.sha256(b"".join(hashlib.sha256((output / name).read_bytes()).digest() for name in NAMES)).hexdigest()
            write_if_changed(output / "version", version + "\n")
            write_if_changed(output / "protocol-version", protocol)


def install(target_dir, helper="helper4"):
    """Copy built binaries into the portable-test cache and the app's resources."""
    output = target_dir.resolve() / "bin"
    if not all((output / name).is_file() for name in (*NAMES, "version", "protocol-version")):
        raise SystemExit(f"{helper} is not built: {output}. Run scripts/build-ssh-helper.sh first.")
    # Retain portable-test cache names; Cargo owns its incremental output.
    compatibility = ROOT / "build" / helper
    destination = Path(os.environ.get("TARGET_BUILD_DIR", ROOT / "build")) / os.environ.get(
        "UNLOCALIZED_RESOURCES_FOLDER_PATH", "ssh-helper-resources") / helper
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    for directory in (compatibility, destination):
        directory.mkdir(parents=True, exist_ok=True)
        for name in (*NAMES, "version", "protocol-version"):
            source = output / name
            if directory == destination and name == "darwin-universal" and identity != "-":
                with tempfile.TemporaryDirectory(prefix="sign-", dir=target_dir.resolve()) as temporary:
                    source = Path(temporary) / name
                    shutil.copy2(output / name, source)
                    run("codesign", "--force", "--sign", identity, "--identifier", "dev.dispatch." + helper, str(source))
                    replace_if_changed(source, directory / name)
                continue
            replace_if_changed(source, directory / name)


def default_capture():
    # The capture feature is a test instrument (DISPATCH_CAPTURE writes all helper IO to disk unredacted;
    # DISPATCH_REPLAY runs a trace). Debug builds and direct runs keep it for the test runners;
    # Xcode Release builds and archives leave it out.
    return os.environ.get("CONFIGURATION") != "Release" and os.environ.get("ACTION") != "install"


def default_profile():
    # The fully optimized helper (fat LTO, one codegen unit) costs ~4x the compile time, so it is
    # reserved for archives and explicit requests; local Debug and Release builds use `local`.
    requested = os.environ.get("DISPATCH_HELPER_PROFILE")
    if requested:
        return requested
    return "release" if os.environ.get("ACTION") == "install" else "local"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true", help="Build artifacts without copying them into app resources")
    mode.add_argument("--install-only", action="store_true", help="Install already built artifacts without running Cargo")
    parser.add_argument("--profile", choices=("local", "release"), default=default_profile(),
                        help="Default: release for Xcode archives or DISPATCH_HELPER_PROFILE=release, local otherwise; "
                             "a helper whose workspace defines one profile always builds that one")
    parser.add_argument("--target-dir", type=Path, default=ROOT / "build/helper4-rust",
                        help="Cargo output directory; override for isolated cold-build measurements")
    parser.add_argument("--replay-tools", action="store_true",
                        help="Build capture-redact examples into bin/replay without changing app helper resources")
    parser.add_argument("--dry-run", action="store_true", help="Print build commands and outputs without writing files")
    args = parser.parse_args()
    if args.profile not in ("local", "release"):
        parser.error("DISPATCH_HELPER_PROFILE must be local or release")
    if args.install_only and (args.replay_tools or args.dry_run):
        parser.error("--install-only cannot be combined with --replay-tools or --dry-run")
    if not args.install_only:
        build(args.profile, args.target_dir, replay_tools=args.replay_tools, dry_run=args.dry_run)
    # Replay tools and dry runs never touch the app's helper resources.
    if not (args.build_only or args.replay_tools or args.dry_run):
        install(args.target_dir)
