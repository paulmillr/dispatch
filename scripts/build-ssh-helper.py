#!/usr/bin/env python3
"""Build the pinned Rust helper offline for all supported platforms, and install the helper's
three binaries into the app.

Xcode runs the build in its own target, in parallel with the terminal frameworks, and the
app target only installs the finished binaries (--install-only)."""
import argparse
from contextlib import nullcontext
import fcntl
import gzip
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
NAMES = ("darwin-arm64", "linux-aarch64", "linux-x86_64")
ARTIFACTS = (*NAMES, "version", "protocol-version")
# Bundled gzipped in the Mac app (Dispatch/SSH/SSHHelperArchive.swift): only uploaded, and a host with gzip expands
# them itself. darwin-arm64 is also the app's own helper, kept as is. The iPhone app gzips all three (GzipMember):
# App Store Connect refuses a Mach-O file that is not a bundle's executable.
COMPRESSED = ("linux-aarch64", "linux-x86_64")
# Remote helpers bundled for SSH hosts: protocol marker the app checks (helper: its generated wire schema
# version).
HELPERS = {
    "helper": {"protocol": None, "codec": ROOT / "Dispatch/Helper/HelperBinary.swift"},
}
# What a helper build reads besides the crate itself, Cargo's caches and the pinned toolchain.
INPUTS = ("Vendor/Zstd", "scripts/build-ssh-helper.py", "scripts/setup-ssh-rust.py")
# The wire registry: the build appends to it (helper/core/build/schema.rs `registered`), so it may differ after a build.
REGISTRY = "helper/core/src/wire/registry.txt"
# The last corpus replay that passed (verify): the helper and corpus it passed on.
REPLAY_STAMP = "replay-verified.json"


def run(*arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree(*tops, skip=()):
    """Every file under `tops` (relative to ROOT), sorted by relative path; `skip`: relative directories left out."""
    paths = []
    for top in tops:
        top = ROOT / top
        if top.is_file() or top.is_symlink():
            paths.append(top)
            continue
        for directory, names, files in os.walk(top):
            names[:] = [name for name in names if name not in ("__pycache__", ".git")
                        and str((Path(directory) / name).relative_to(ROOT)) not in skip]
            paths += [Path(directory) / name for name in files if name not in (".DS_Store", ".git")]
    return sorted((str(path.relative_to(ROOT)), path) for path in paths)


def sources(helper, codec):
    """The build's inputs by content, not mtime: a VM given the same sources computes the same digests, so it
    reuses a helper the host built (test/vm.py syncs it) instead of building and replaying the corpus again."""
    inputs = (helper, *INPUTS) + ((str(codec.relative_to(ROOT)),) if codec else ())
    return {name: "link:" + os.readlink(path) if path.is_symlink() else digest_file(path)
            for name, path in tree(*inputs, skip=(helper + "/target",))}


def inputs_key(parameters, files):
    return hashlib.sha256(json.dumps([parameters, files], sort_keys=True).encode()).hexdigest() + "\n"


def corpus_state(corpus, migrations, version, content):
    """The corpus replay's inputs: the helper's version, the corpus and its migrations. `content` hashes every file
    (~1 s for the whole corpus); otherwise path, size, mtime, ctime and inode stand for it (ctime: a tool that
    restores mtimes still changes it)."""
    digest = hashlib.sha256(version.encode())
    for name, path in tree(corpus.relative_to(ROOT), migrations.relative_to(ROOT)):
        if content:
            value = digest_file(path)
        else:
            status = path.stat()
            value = f"{status.st_size} {status.st_mtime_ns} {status.st_ctime_ns} {status.st_ino}"
        digest.update(f"{name}\0{value}\n".encode())
    return digest.hexdigest()


def replace_if_changed(source, destination, compress=False):
    """Publish complete files and preserve unchanged output timestamps. `compress`: gzip it on the way (level 9, no
    name or time, so the same helper always gives the same bytes)."""
    content = gzip.compress(source.read_bytes(), compresslevel=9, mtime=0) if compress else None
    if destination.is_file() and (content if compress else source.read_bytes()) == destination.read_bytes():
        if source.stat().st_mode & 0o777 == destination.stat().st_mode & 0o777:
            return
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".helper-", delete=False) as stream:
        temporary = Path(stream.name)
    try:
        if compress:
            temporary.write_bytes(content)
        else:
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


def build(profile, target_dir, helper="helper", dry_run=False, capture=None):
    settings = HELPERS[helper]
    capture = default_capture() if capture is None else capture
    toolchain = ROOT / "build/rust"
    # Validate every required target without installing or fetching anything.
    if not dry_run:
        run("python3", str(ROOT / "scripts/setup-ssh-rust.py"), "--offline")
    target_dir = target_dir.resolve()
    # Helpers without the capture feature keep their own Cargo cache, so switching between Debug and
    # Release reuses each fully optimized link instead of redoing it. Both publish to target_dir/bin.
    cache = target_dir if capture else target_dir / "without-capture"
    if not dry_run:
        cache.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PATH=str(toolchain / "bin") + os.pathsep + os.environ.get("PATH", ""),
               CARGO_HOME=str(ROOT / "build/cargo"), CARGO_TARGET_DIR=str(cache),
               MACOSX_DEPLOYMENT_TARGET="14.0",
               DYLD_FALLBACK_LIBRARY_PATH=str(toolchain / "lib") +
               (os.pathsep + os.environ["DYLD_FALLBACK_LIBRARY_PATH"] if os.environ.get("DYLD_FALLBACK_LIBRARY_PATH") else ""))
    crate = ROOT / helper
    binary = "dispatch-" + helper
    protocol = settings["protocol"]
    cargo = str(toolchain / "bin/cargo")
    with nullcontext() if dry_run else (target_dir / ".build.lock").open("a") as lock:
        if lock is not None:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Waiting for another SSH helper build: " + str(target_dir), flush=True)
                fcntl.flock(lock, fcntl.LOCK_EX)
        rustc = subprocess.check_output([str(toolchain / "bin/rustc"), "-vV"], env=env, text=True)
        host = next(line.removeprefix("host: ") for line in rustc.splitlines() if line.startswith("host: "))
        # Apple silicon only: the app and every macOS SSH host it sets up (an Intel Mac falls back to plain SSH).
        darwin = ["aarch64-apple-darwin"]
        print(("Planning " if dry_run else "Building ") + helper +
              " (" + profile + (", capture" if capture else ", without capture") +
              f", {len(darwin) + 2} targets in parallel)", flush=True)
        linker = toolchain / "lib/rustlib" / host / "bin/rust-lld"
        linux_flags = ["-C", "linker=" + str(linker), "-C", "linker-flavor=ld.lld", "-C", "target-feature=+crt-static"]
        # One Cargo scheduler shares host dependencies and the CPU job budget
        # across all targets. Separate Cargo processes would lock this cache.
        command = [cargo, "build", "--offline", "--frozen", "--profile", profile, "--message-format=json-render-diagnostics"]
        if capture:
            command += ["--features", "dispatch-" + helper + "/capture"]
        # Global rustflags override target-specific flags. Preserve caller flags
        # for macOS while keeping the existing static Linux linker configuration.
        encoded_flags = env.pop("CARGO_ENCODED_RUSTFLAGS", None)
        rustflags = env.pop("RUSTFLAGS", None)
        if encoded_flags is not None:
            mac_flags = encoded_flags.split("\x1f") if encoded_flags else []
        else:
            mac_flags = rustflags.split() if rustflags is not None else None
        for target in darwin:
            command += ["--target", target]
            if mac_flags is not None:
                command += ["--config", "target." + target + ".rustflags=" + json.dumps(mac_flags)]
        for arch in ("aarch64", "x86_64"):
            target = arch + "-unknown-linux-musl"
            command += ["--target", target, "--config", "target." + target + ".rustflags=" + json.dumps(linux_flags)]
        output = target_dir / "bin"
        if dry_run:
            print(json.dumps(dict(command=command, cwd=str(crate),
                                  setup=["python3", str(ROOT / "scripts/setup-ssh-rust.py"), "--offline"],
                                  outputs=[str(output / name) for name in NAMES]), indent=2))
            return
        # Each variant keeps its last build, published to bin/ from there: switching between Debug and Release, or
        # building unchanged sources (a Swift edit, a VM given the host's build), runs no Cargo.
        variant = target_dir / "variants" / (profile + ("-capture" if capture else ""))
        stamp = variant / "inputs"
        parameters = [helper, profile, capture, darwin, mac_flags, rustc]
        before = sources(helper, settings.get("codec"))
        if (stamp.is_file() and stamp.read_text() == inputs_key(parameters, before)
                and all((variant / name).is_file() for name in ARTIFACTS)):
            print("Reusing the " + variant.name + " helper build: its inputs are unchanged", flush=True)
            publish(variant, output)
            return
        stamp.unlink(missing_ok=True)
        messages = run(*command, cwd=crate, env=env, stdout=subprocess.PIPE, text=True).stdout
        if settings.get("codec"):
            protocol = codec(messages, settings["codec"])
        variant.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="package-", dir=target_dir) as directory:
            stage = Path(directory)
            native = stage / "darwin-arm64"
            shutil.copyfile(cache / darwin[0] / profile / binary, native)
            run("codesign", "--force", "--sign", "-", "--identifier", "yachts.dispatch." + helper, str(native))
            for arch in ("aarch64", "x86_64"):
                shutil.copyfile(cache / (arch + "-unknown-linux-musl") / profile / binary, stage / ("linux-" + arch))
            for name in NAMES:
                (stage / name).chmod(0o755)
                replace_if_changed(stage / name, variant / name)
            version = hashlib.sha256(b"".join(hashlib.sha256((variant / name).read_bytes()).digest() for name in NAMES)).hexdigest()
            write_if_changed(variant / "version", version + "\n")
            write_if_changed(variant / "protocol-version", protocol)
        publish(variant, output)
        # Sources edited during the build may not be in it; only the registry's own appends are.
        after = sources(helper, settings.get("codec"))
        changed = sorted(name for name in before.keys() | after.keys() if before.get(name) != after.get(name))
        if set(changed) <= {REGISTRY}:
            write_if_changed(stamp, inputs_key(parameters, after))
        else:
            print("Helper inputs changed during the build (" + ", ".join(changed[:3]) + "): the next build runs Cargo again", flush=True)


def publish(variant, output):
    output.mkdir(parents=True, exist_ok=True)
    for name in ARTIFACTS:
        replace_if_changed(variant / name, output / name)


def install(target_dir, helper="helper"):
    """Copy built binaries into the portable-test cache and the app's resources."""
    output = target_dir.resolve() / "bin"
    if not all((output / name).is_file() for name in ARTIFACTS):
        raise SystemExit(f"{helper} is not built: {output}. Run scripts/build-ssh-helper.sh first.")
    # Retain portable-test cache names; Cargo owns its incremental output.
    compatibility = ROOT / "build" / helper
    destination = Path(os.environ.get("TARGET_BUILD_DIR", ROOT / "build")) / os.environ.get(
        "UNLOCALIZED_RESOURCES_FOLDER_PATH", "ssh-helper-resources") / helper
    # The iPhone app runs no helper itself: all three are gzipped resources it expands to upload to hosts.
    phone = os.environ.get("PLATFORM_NAME", "").startswith("iphone")
    compressed = NAMES if phone else COMPRESSED
    for directory in (compatibility, destination):
        directory.mkdir(parents=True, exist_ok=True)
        for name in ARTIFACTS:
            # The Mac app's darwin-arm64 links to the one signed dispatch-helper (scripts/bundle-helper.sh).
            if directory == destination and name == "darwin-arm64" and not phone:
                continue
            if directory == destination and name in compressed:
                replace_if_changed(output / name, directory / (name + ".gz"), compress=True)
                (directory / name).unlink(missing_ok=True)
                continue
            replace_if_changed(output / name, directory / name)


def verify(target_dir):
    """The helper just built replays every helper capture in replays/ (the corpus) or the build fails:
    a capture either replays on the latest helper or is dropped (`capture prune`), never silently."""
    corpus = ROOT / "replays"
    if not any(corpus.rglob("*.rpl.zst")):
        # The corpus is its own repository; a checkout without it builds, unchecked.
        print("warning: no replay corpus in " + str(corpus) + "; the helper is not checked against it", flush=True)
        return
    output = target_dir / ("replay-results-" + str(os.getpid()))
    helper = target_dir / "bin/darwin-arm64"
    # The corpus first comes up to the code (docs/replay.md, Migrations): what a change did to recordings ships as a
    # migration in test/replay-migrations, applied here once; the corpus's own git status shows it, ledger included.
    migrations = ROOT / "test/replay-migrations"
    # The same helper on the same corpus replays alike: a build that changed neither (a Swift edit) skips the replay.
    # A VM gets the host's stamp with its helper (test/vm.py) and matches it by content.
    stamp = target_dir / REPLAY_STAMP
    version = (target_dir / "bin/version").read_text()
    try:
        passed = json.loads(stamp.read_text())
    except (OSError, ValueError):
        passed = {}
    state = corpus_state(corpus, migrations, version, content=False)
    if passed.get("state") != state and passed.get("content"):
        if passed["content"] == corpus_state(corpus, migrations, version, content=True):
            passed["state"] = state
            write_if_changed(stamp, json.dumps(passed) + "\n")
    if passed.get("state") == state:
        print("Corpus replay skipped: neither the helper nor replays/ changed since it passed (" + passed.get("summary", "") + ")", flush=True)
        return
    stamp.unlink(missing_ok=True)
    if migrations.is_dir():
        migrated = subprocess.run([str(helper), "capture", "migrate", str(corpus), str(migrations)], stdout=subprocess.PIPE, text=True)
        for line in migrated.stdout.splitlines():
            if line.startswith(("migration\t", "rerecord\t", "error\t")):
                print("replay corpus " + line.replace("\t", ": ", 1), flush=True)
        if migrated.returncode != 0:
            raise SystemExit("A replay migration did not apply (" + str(migrations) + "): fix it before the corpus replays")
    state = corpus_state(corpus, migrations, version, content=False)
    # The per-capture timeout catches a hung replay, not a slow one: the large herdr session
    # (HerdrTests/testLargeSession…) replays in 20-23 s of CPU here, past the tool's 20 s default.
    result = subprocess.run([str(helper), "capture", "replay", str(corpus), "--completion", "required", "--timeout", "60",
                             "--output", str(output)], stdout=subprocess.PIPE, text=True)
    lines = result.stdout.splitlines()
    for line in lines[:-1]:
        if not line.startswith("pass\t"):
            print("error: corpus capture does not replay on this helper: " + line, flush=True)
    print(lines[-1] if lines else "corpus replay printed nothing", flush=True)
    if result.returncode != 0:
        raise SystemExit("The helper does not replay the corpus (results: " + str(output) + "); fix it, or drop what no longer applies: " + str(helper) + " capture prune " + str(corpus))
    shutil.rmtree(output)
    # A corpus edited during the replay passed only in part.
    if corpus_state(corpus, migrations, version, content=False) == state:
        summary = lines[-1].split("; report:")[0] if lines else ""
        write_if_changed(stamp, json.dumps(dict(state=state, summary=summary,
                                                content=corpus_state(corpus, migrations, version, content=True))) + "\n")


def default_capture():
    # The capture feature is a test instrument (DISPATCH_CAPTURE writes all helper IO to disk unredacted;
    # DISPATCH_REPLAY runs a trace; `dispatch-helper capture` is the tool for captures). Debug builds and
    # direct runs keep it for the test runners; Xcode Release builds and archives leave it out.
    return os.environ.get("CONFIGURATION") != "Release" and os.environ.get("ACTION") != "install"


def default_profile():
    # The fully optimized helper (fat LTO, no incremental builds) takes ~35s to rebuild after any edit,
    # so it is reserved for archives and explicit requests (`./run.sh --prod`); other builds use `local`.
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
                        help="Default: release for Xcode archives or DISPATCH_HELPER_PROFILE=release, local otherwise")
    parser.add_argument("--target-dir", type=Path, default=ROOT / "build/helper-rust",
                        help="Cargo output directory; override for isolated cold-build measurements")
    parser.add_argument("--dry-run", action="store_true", help="Print build commands and outputs without writing files")
    args = parser.parse_args()
    if args.profile not in ("local", "release"):
        parser.error("DISPATCH_HELPER_PROFILE must be local or release")
    if args.install_only and args.dry_run:
        parser.error("--install-only cannot be combined with --dry-run")
    if not args.install_only:
        build(args.profile, args.target_dir, dry_run=args.dry_run)
    # Debug builds (the capture feature) check the helper against the corpus right after building it.
    if args.build_only and default_capture() and not args.dry_run:
        verify(args.target_dir.resolve())
    # Dry runs never touch the app's helper resources.
    if not (args.build_only or args.dry_run):
        install(args.target_dir)
