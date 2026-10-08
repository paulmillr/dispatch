#!/usr/bin/env python3
"""Run Dispatch's desktop tests in a dedicated Tart VM, without a host viewer."""

import argparse
import datetime
import fcntl
import hashlib
import json
import ipaddress
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import select
import socket
import socketserver
import sys
import tempfile
import time
import threading
from profile import Profile
from selection import normalize, failed_tests, resolve, describe, add_arguments
from environment import load as load_test_environment
import shards


ROOT = Path(__file__).resolve().parent.parent
LOCAL_ENVIRONMENT = load_test_environment()
GUEST = "/Users/admin/dispatch-tests"
CODEX = Path("/opt/homebrew/lib/node_modules/@openai/codex/node_modules/"
             "@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex")
# OpenAI's quick start uses this image registry. Pin the image for reproducibility.
IMAGE = ("ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:"
         "e0721ddeae3c7c037b764c1aebd0b2d245495c16622413f5a567d7110d18d863")
SOURCES = ["Dispatch", "DispatchTests", "Helpers", "Vendor", "ThirdPartyLicenses", "scripts", "test", "extras",
           "project.yml", "run.sh"]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def guest(vm, *args, **kwargs):
    return run("tart", "exec", vm, *args, **kwargs)


def shell(vm, script, *args, **kwargs):
    return guest(vm, "/bin/bash", "-c", script, "dispatch-vm", *args, **kwargs)


def info(vm):
    result = run("tart", "list", "--source", "local", "--format", "json",
                 capture_output=True, text=True)
    return next((item for item in json.loads(result.stdout) if item["Name"] == vm), None)


def start(vm):
    state = info(vm)
    if state is None:
        raise RuntimeError("VM is missing. Run python3 test/vm.py setup first.")
    booted = not state["Running"]
    if booted:
        logs = ROOT / "build" / "vm-tests"
        logs.mkdir(parents=True, exist_ok=True)
        with (logs / (vm + "-boot.log")).open("ab") as log:
            subprocess.Popen(["tart", "run", vm, "--no-graphics", "--no-clipboard",
                              "--no-audio"], stdin=subprocess.DEVNULL, stdout=log,
                             stderr=subprocess.STDOUT, start_new_session=True)
    print(("Starting " if booted else "Reusing running ") + vm + "; checking the guest agent...", flush=True)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            guest(vm, "/usr/bin/true", capture_output=True, timeout=10)
            if booted:
                # No process from the previous boot can still own this lock.
                guest(vm, "/bin/rm", "-rf", GUEST + "/test.lock")
            return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            time.sleep(2)
    raise RuntimeError("Guest agent did not become ready. See build/vm-tests/" + vm + "-boot.log")


def copy_archive(vm, archive, destination):
    guest(vm, "/bin/mkdir", "-p", destination)
    with archive.open("rb") as stream:
        run("tart", "exec", "-i", vm, "/usr/bin/tar", "-xf", "-", "-C", destination,
            stdin=stream)


def archive(path, directory, members):
    run("/usr/bin/tar", "-cf", str(path), "--exclude=__pycache__", "--exclude=.DS_Store",
        "-C", str(directory), *members, env={**os.environ, "COPYFILE_DISABLE": "1"})


def setup(vm, image):
    binaries = {"herdr": Path("/opt/homebrew/bin/herdr"), "codex": CODEX}
    for source in binaries.values():
        if not source.is_file():
            raise RuntimeError("Missing host test dependency: " + str(source))
    if info(vm) is None:
        print("Downloading the Xcode VM (about 69 GB on the first run)...", flush=True)
        run("tart", "clone", image, vm, env={**os.environ, "TART_NO_AUTO_PRUNE": "1"})
    if not info(vm)["Running"]:
        run("tart", "set", vm, "--cpu", "4", "--memory", "8192",
            "--display", "1280x832pt", "--no-display-refit")
    start(vm)
    shell(vm, r'''
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
[[ "$(id -un)" == admin ]] || { echo 'Expected the admin guest desktop session.' >&2; exit 1; }
xcodebuild -version
HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen tmux
defaults -currentHost write com.apple.screensaver idleTime -int 0
mkdir -p /Users/admin/dispatch-tests
''')
    # Match the versions used by this checkout. Only executable files are copied;
    # the fixture supplies its own Codex home and local HTTP endpoint.
    with tempfile.TemporaryDirectory(prefix="dispatch-vm-tools-") as temporary:
        staging = Path(temporary)
        for name, source in binaries.items():
            shutil.copy2(source, staging / name)
        tools_archive = staging / "tools.tar"
        archive(tools_archive, staging, list(binaries))
        copy_archive(vm, tools_archive, GUEST + "/tools")
    shell(vm, r'''
set -euo pipefail
install -m 755 /Users/admin/dispatch-tests/tools/herdr /opt/homebrew/bin/herdr
mkdir -p "$(dirname "$1")"
install -m 755 /Users/admin/dispatch-tests/tools/codex "$1"
ln -sf "$1" /opt/homebrew/bin/codex
"$1" --version
/opt/homebrew/bin/herdr --version
/opt/homebrew/bin/tmux -V
''', str(CODEX))
    provision_rust(vm)
    provision_xcodegen(vm)
    print("VM ready. Run python3 test/vm.py test", flush=True)


def provision_xcodegen(vm):
    """Copy the host's pinned XcodeGen; the guest's offline setup cannot download it."""
    binary = Path(run(sys.executable, str(ROOT / "scripts/setup-build-tools.py"), "xcodegen", "--offline",
                      capture_output=True, text=True).stdout.strip())
    tools = ROOT / "build/tools/xcodegen"
    source = tools / binary.relative_to(tools).parts[0]
    destination = GUEST + "/workspace/build/tools/xcodegen/" + source.name
    guest(vm, "/bin/mkdir", "-p", destination)
    synchronize(vm, [str(source) + "/"], destination + "/")
    guest(vm, destination + "/" + str(binary.relative_to(source)), "--version")


def provision_rust(vm):
    """Explicitly copy the prepared, pinned host toolchain; never download it."""
    run(sys.executable, str(ROOT / "scripts/setup-ssh-rust.py"), "--offline")
    source = ROOT / "build/rust"
    expected = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            expected[str(path.relative_to(source))] = {"link": os.readlink(path)}
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            expected[str(path.relative_to(source))] = {
                "sha256": digest.hexdigest(), "mode": path.stat().st_mode & 0o777}
    start(vm)
    shell(vm, 'test ! -e "$1/test.lock" || { echo "Wait for the current VM test before provisioning Rust." >&2; exit 1; }', GUEST)
    destination = GUEST + "/workspace/build/rust"
    guest(vm, "/bin/mkdir", "-p", destination)
    print(synchronize(vm, [str(source) + "/"], destination + "/"), flush=True)
    verifier = '''
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected = json.load(sys.stdin)
actual = {}
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        actual[str(path.relative_to(root))] = {'link': os.readlink(path)}
    elif path.is_file():
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        actual[str(path.relative_to(root))] = {'sha256': digest.hexdigest(), 'mode': path.stat().st_mode & 0o777}
if actual != expected:
    raise SystemExit('Guest Rust toolchain differs from the pinned host installation')
print('Verified Rust toolchain: ' + str(len(actual)) + ' files and links')
'''
    run("tart", "exec", "-i", vm, "/usr/bin/python3", "-c", verifier, destination,
        input=json.dumps(expected), text=True)
    # Do not depend on source synchronization having happened yet.
    guest(vm, destination + "/bin/rustc", "--version")
    print("Pinned Rust toolchain provisioned. Normal tests and builds stay offline.", flush=True)


def inspect_binary(vm, binary):
    return guest(vm, "/usr/bin/python3", "-c", '''
import hashlib, os, subprocess, sys
binary = sys.argv[1]
if os.access(binary, os.X_OK):
    digest = hashlib.sha256()
    with open(binary, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    print(digest.hexdigest(), flush=True)
    subprocess.run([binary, '--version'], check=True, timeout=10)
''', str(binary), capture_output=True, text=True).stdout.splitlines()


def inspect_codex(vm):
    return inspect_binary(vm, CODEX)


def sync_claude(vm):
    source = shutil.which('claude')
    if not source:
        raise RuntimeError('Claude Code is required for Claude Chat integration tests; install it explicitly first')
    source = Path(source).resolve()
    destination = GUEST + '/test-tools/claude'
    digest = hashlib.sha256()
    with source.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    inspected = inspect_binary(vm, destination)
    if len(inspected) >= 2 and inspected[0] == digest.hexdigest():
        return inspected[-1]
    check_portable(vm, source)
    guest(vm, '/bin/mkdir', '-p', GUEST + '/test-tools')
    synchronize(vm, [str(source)], destination)
    checked = inspect_binary(vm, destination)
    if len(checked) < 2 or checked[0] != digest.hexdigest() or 'Claude Code' not in checked[-1]:
        raise RuntimeError('Guest Claude does not match the installed host native CLI')
    return checked[-1]


def sync_nanocodex(vm):
    """Copy an explicitly linked local nanocodex build; its test skips without one."""
    link = ROOT / 'build/test-tools/bin/nanocodex'
    if not link.exists():
        return None
    source = link.resolve()
    digest = hashlib.sha256()
    with source.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    destination = GUEST + '/test-tools/nanocodex'
    inspected = inspect_binary(vm, destination)
    if len(inspected) < 2 or inspected[0] != digest.hexdigest():
        check_portable(vm, source)
        guest(vm, '/bin/mkdir', '-p', GUEST + '/test-tools')
        synchronize(vm, [str(source)], destination)
        inspected = inspect_binary(vm, destination)
        if len(inspected) < 2 or inspected[0] != digest.hexdigest():
            raise RuntimeError('Guest nanocodex does not match the linked host build')
    version = next((line for line in inspected if 'Version' in line), inspected[-1])
    return version + ' (linked host build SHA-256 ' + digest.hexdigest() + ')'


def pinned_tool(name):
    """A SHA-verified project-local test tool. Never downloads; ./run.sh --test prepares it."""
    if str(ROOT / 'scripts') not in sys.path:
        sys.path.append(str(ROOT / 'scripts'))
    from setup_consent import load_script
    lock = json.loads((ROOT / 'scripts/test-tools.lock.json').read_text())
    try:
        return load_script('setup-build-tools').resolve(name, offline=True, lock=lock)
    except RuntimeError as error:
        raise RuntimeError(f'{error} Prepare it with ./run.sh --test (downloads stay under build/).') from None


_GUEST_MACOS = {}


def guest_macos(vm):
    if vm not in _GUEST_MACOS:
        text = guest(vm, '/usr/bin/sw_vers', '-productVersion', capture_output=True, text=True, timeout=20).stdout.strip()
        _GUEST_MACOS[vm] = tuple(int(part) for part in text.split('.'))
    return _GUEST_MACOS[vm]


def minimum_macos(binary):
    """The deployment target recorded in the binary's load commands."""
    for arguments in (['-arch', 'arm64'], []):
        result = subprocess.run(['/usr/bin/otool', *arguments, '-l', str(binary)], capture_output=True, text=True)
        if result.returncode != 0:
            continue
        lines = [line.split() for line in result.stdout.splitlines()]
        for index, words in enumerate(lines):
            if words[:2] == ['cmd', 'LC_BUILD_VERSION']:
                version = next((w[1] for w in lines[index + 1:index + 6] if w[:1] == ['minos']), None)
            elif words[:2] == ['cmd', 'LC_VERSION_MIN_MACOSX']:
                version = next((w[1] for w in lines[index + 1:index + 4] if w[:1] == ['version']), None)
            else:
                continue
            if version:
                return tuple(int(part) for part in version.split('.'))
    return None


def check_portable(vm, binary):
    """Fail before copying a host binary the guest cannot load. Host package
    managers build for the host OS; a newer host silently breaks older VMs."""
    required = minimum_macos(binary)
    available = guest_macos(vm) if required else None
    if required and required > available:
        raise RuntimeError(f'{binary} requires macOS {".".join(map(str, required))}, but {vm} runs '
                           f'{".".join(map(str, available))}. Use a pinned project-local tool (./run.sh --test).')
    libraries = subprocess.run(['/usr/bin/otool', '-L', str(binary)], capture_output=True, text=True).stdout.splitlines()[1:]
    foreign = [line.strip().split(' (', 1)[0] for line in libraries
               if line.strip().startswith('/') and not line.strip().startswith(('/usr/lib/', '/System/'))]
    if foreign:
        raise RuntimeError(f'{binary} links host libraries the VM does not have: {", ".join(foreign)}. '
                           'Use a pinned project-local tool (./run.sh --test).')


def stage_unexecuted(source, staging):
    """Copy a tool with plain reads into files the host never executes.
    Pi's release appends its bundle after signing. Once the host runs it
    (resolution checks --version), macOS kills any process that maps those
    pages, including openrsync. Shard runners share one staged copy."""
    marker = staging / '.source'
    with host_lock('dispatch-pi-test-runtime', blocking=True):
        if not marker.is_file() or marker.read_text() != str(source):
            shutil.rmtree(staging, ignore_errors=True)
            for path in sorted(source.rglob('*')):
                target = staging / path.relative_to(source)
                if path.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with path.open('rb') as reader, target.open('wb') as writer:
                    shutil.copyfileobj(reader, writer, 1 << 20)
                target.chmod(path.stat().st_mode & 0o777)
            marker.write_text(str(source))
    return staging


def sync_pi(vm):
    """Copy the pinned standalone Pi release. Unlike an npm install, it bundles
    its runtime and links only system libraries, so it runs on older guests."""
    binary = pinned_tool('pi')
    check_portable(vm, binary)
    staging = stage_unexecuted(binary.parent, ROOT / 'build' / 'pi-test-runtime')
    tools = GUEST + '/test-tools'
    guest(vm, '/bin/mkdir', '-p', tools + '/pi-standalone')
    synchronize(vm, [str(staging) + '/'], tools + '/pi-standalone/')
    # A wrapper keeps the executable beside its bundled assets; exec preserves
    # the process identity Chat discovery inspects.
    script = '#!/bin/sh\nexec ' + shlex.quote(tools + '/pi-standalone/' + binary.name) + ' "$@"\n'
    guest(vm, '/usr/bin/python3', '-c', 'import os, pathlib, sys; p = pathlib.Path(sys.argv[1]); p.write_text(sys.argv[2]); os.chmod(p, 0o755)', tools + '/pi', script)
    # Remove the previous host Node copy; nothing uses it any more.
    guest(vm, '/bin/rm', '-rf', tools + '/pi-runtime', tools + '/pi-coding-agent')
    expected = json.loads((ROOT / 'scripts/test-tools.lock.json').read_text())['pi']['version']
    actual = guest(vm, tools + '/pi', '--version', capture_output=True, text=True, timeout=20).stdout.strip()
    if actual != expected:
        raise RuntimeError('Guest Pi does not match the pinned release: ' + actual)
    return 'Pi ' + actual + ' (pinned standalone release)'


def sync_codex(vm):
    """Test the installed host CLI, even when the VM predates an upgrade."""
    # Code-mode tools execute in a companion process. A matching main binary
    # alone is insufficient for fixtures that invoke tools through exec.
    companion = CODEX.with_name("codex-code-mode-host")
    if companion.is_file():
        synchronize(vm, [str(companion)], str(companion))
    digest = hashlib.sha256()
    with CODEX.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    # Compare SHA-256 before invoking rsync: an unchanged 223 MB binary does
    # not need a second checksum pass and an rsync protocol exchange.
    inspected = inspect_codex(vm)
    if inspected and inspected[0].split()[0] == digest.hexdigest():
        return inspected[-1] + " (host binary SHA-256 " + digest.hexdigest() + ")\n"
    check_portable(vm, CODEX)
    synchronize(vm, [str(CODEX)], str(CODEX))
    checked = inspect_codex(vm)
    if len(checked) < 2:
        raise RuntimeError("Guest Codex executable is missing after synchronization")
    actual, version = checked[0].split()[0], checked[-1]
    if actual != digest.hexdigest():
        raise RuntimeError("Guest Codex does not match the host test binary")
    return version + " (host binary SHA-256 " + actual + ")\n"


def synchronize(vm, sources, destination, relative=False):
    # Checksums detect same-size edits with restored mtimes. Unchanged files keep
    # their guest timestamps; changed files get fresh timestamps for Xcode.
    command = ["/usr/bin/rsync", "--archive", "--no-times", "--checksum", "--delete",
               "--delete-excluded", "--exclude=__pycache__", "--exclude=.DS_Store",
               "--exclude=LocalToolAudit/", "--exclude=rollout-*.jsonl", "--exclude=STEPS.md",
               "--exclude=/Helpers/ssh-helper/target/", "--stats", "--rsync-path=/usr/bin/rsync",
               "-e", shlex.join([sys.executable, str(ROOT / "scripts/tart-rsync.py")])]
    if relative:
        command.append("--relative")
    return run(*command, *sources, vm + ":" + destination, cwd=ROOT,
               capture_output=True, text=True).stdout


def test(vm, tests, recheck=False, benchmarks=False, selection=None, **shard):
    selected = selection['selected'] if selection else tests
    extra = {'selection': selection, **shard} if selection else shard
    configuration = ROOT / "build" / "vm-tests" / (vm + "-linux.json")
    linux_suites = {"SSHLinuxIntegrationTests", "SSHHostIsolationIntegrationTests", "HostLinuxIntegrationTests", "SSHLinuxClaudeIntegrationTests", "SSHLinuxPiIntegrationTests"}
    explicit_linux = any(set(test.split("/")) & linux_suites for test in selected)
    explicit_linux |= any(test.endswith("SSHProcessStatisticsIntegrationTests")
                          or test.endswith("SSHProcessStatisticsIntegrationTests/testLinuxProcessRowsAndTerminalTraffic")
                          for test in selected)
    needs_linux = not selected or explicit_linux or "DispatchTests" in selected
    if explicit_linux and not configuration.exists():
        raise RuntimeError("Configure the existing Linux test server with python3 test/vm.py linux first.")
    if configuration.exists() and needs_linux:
        saved = json.loads(configuration.read_text())
        if saved.get("provider") != "lima":
            raise RuntimeError("Re-pair the archived Linux SSH VM with python3 test/vm.py linux --server dispatch-rust-ssh-validation; the older Tart pairing is no longer used.")
        server = saved["server"]
        started = time.perf_counter()
        host_run = {}
        prepared = None
        completed = False
        try:
            with linux_connection(vm, server, saved.get("tools", {})):
                prepared = time.perf_counter()
                result = test_guest(vm, tests, linux=True, recheck=recheck, benchmarks=benchmarks,
                                    host_run=host_run, **extra)
            completed = True
            return result
        finally:
            if host_run:
                finish_linux_timing(host_run, started, prepared, completed)
    return test_guest(vm, tests, recheck=recheck, benchmarks=benchmarks, **extra)


def prepare_test_inputs(vm, profile, needs_codex=True):
    def sync_sources():
        with profile.stage("source_sync") as stage:
            stage["statistics"] = synchronize(vm, SOURCES, GUEST + "/workspace/", relative=True)

    def sync_cli():
        with profile.stage("codex_sync"):
            return sync_codex(vm)

    if not needs_codex:
        sync_sources()
        return 'Fast component checks; agent CLI synchronization not required.\n'

    # Disjoint paths; join both even after a failure before releasing the VM lock.
    with ThreadPoolExecutor(max_workers=2) as executor:
        jobs = [executor.submit(sync_sources), executor.submit(sync_cli)]
        results, errors = [], []
        for job in jobs:
            try:
                results.append(job.result())
            except BaseException as error:
                errors.append(error)
        if errors:
            raise errors[0]
        return results[1]


def finish_linux_timing(host_run, started, prepared, completed):
    """Include pairing and relay cleanup, which surround the guest workflow."""
    finished = time.perf_counter()
    profile, output = host_run['profile'], host_run['output']
    guest_seconds = profile.data['elapsed_seconds']
    profile.data['stages'].insert(0, {'name': 'linux_preparation', 'status': 'passed',
                                      'seconds': prepared - started})
    profile.data['stages'].append({'name': 'linux_cleanup', 'status': 'passed' if completed else 'failed',
                                   'seconds': max(0, finished - host_run['started'] - guest_seconds)})
    profile.data.update(elapsed_seconds=finished - started, guest_workflow_seconds=guest_seconds)
    if not completed:
        profile.data['exit_code'] = profile.data.get('exit_code') or 1
    profile.save()
    path = output / 'build/TestTimings.json'
    if path.exists():
        timing = json.loads(path.read_text())
        timing.update(host_stages=profile.data['stages'], wall_seconds=profile.data['elapsed_seconds'],
                      guest_workflow_seconds=guest_seconds, wall_scope='linux preparation through relay cleanup',
                      exit_code=profile.data['exit_code'])
        if not completed:
            timing['runner_error'] = 'Linux test workflow or cleanup did not complete'
        path.write_text(json.dumps(timing, indent=2) + '\n')
        shutil.copy2(path, profile.path.parent / 'TestTimings.json')


def run_stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid())


def test_guest(vm, tests, linux=False, recheck=False, benchmarks=False, selection=None, host_run=None,
               stamp=None, shard_classes=None, primary=True, host_ready=False):
    fast = selection is not None and selection['suite'] == 'fast'
    selected = selection['selected'] if selection else tests
    if not fast and not CODEX.is_file():
        raise RuntimeError("Missing host test dependency: " + str(CODEX))
    started = time.perf_counter()
    stamp = stamp or run_stamp()
    output = ROOT / "build" / "vm-tests" / stamp
    output.mkdir(parents=True)
    profile = Profile(ROOT / "tmp/profiling/test-runs" / stamp / "host.json")
    profile.data.update(vm=vm, tests=selected, suite=selection["suite"] if selection else "explicit", log=str(output / "test.log"))
    if shard_classes:
        profile.data.update(shard_classes=shard_classes, shard_primary=primary)
    # Fail before booting if the framework hasn't been built on the host yet.
    # A sharded parent verifies this once before starting its VM runners.
    if not host_ready:
        with profile.stage("host_dependencies"):
            run("/bin/bash", "scripts/setup.sh", cwd=ROOT,
                env={**os.environ, "DISPATCH_SETUP_OFFLINE": "1"})
    with profile.stage("guest_start"):
        start(vm)
    # One desktop can only run one UI suite. Keep this lock on interruption, since
    # a disconnected guest process may still be finishing. 'stop' clears it.
    try:
        shell(vm, 'mkdir -p "$1/workspace" && mkdir "$1/test.lock"', GUEST)
    except subprocess.CalledProcessError:
        raise RuntimeError("This VM has an active or interrupted test run. Wait for it, or run "
                           "python3 test/vm.py stop before retrying.") from None
    command_started = False
    completed = False
    result = None
    try:
        version = prepare_test_inputs(vm, profile, needs_codex=not fast)
        profile.data['tool_versions'] = {} if fast else {'codex': version.strip()}
        if not fast and (not selected or 'DispatchTests' in selected or any('Claude' in test for test in selected)):
            with profile.stage('claude_sync'):
                profile.data['tool_versions']['claude'] = sync_claude(vm)
                print('Testing ' + profile.data['tool_versions']['claude'], flush=True)
        if not fast and (not selected or 'DispatchTests' in selected or any('/Pi' in test or '/SSHPi' in test or '/SSHLinuxPi' in test for test in selected)):
            with profile.stage('pi_sync'):
                profile.data['tool_versions']['pi'] = sync_pi(vm)
                print('Testing ' + profile.data['tool_versions']['pi'], flush=True)
        if not fast and (not selected or 'DispatchTests' in selected or any('/Nanocodex' in test for test in selected)):
            with profile.stage('nanocodex_sync'):
                nanocodex = sync_nanocodex(vm)
                if nanocodex:
                    profile.data['tool_versions']['nanocodex'] = nanocodex
                    print('Testing ' + nanocodex, flush=True)
        print("Running tests inside " + vm + "; log: " + str(output / "test.log"), flush=True)
        print("Testing " + version.strip(), flush=True)
        arguments = list(tests)
        if selection:
            if selection['suite'] == 'explicit':
                arguments = selection['selected']
            else:
                arguments = ['--suite', selection['suite']]
                for case, reason in selection['excluded'].items():
                    if reason == 'explicit skip':
                        arguments += ['--skip', case]
        with (output / "test.log").open("wb") as log:
            log.write(version.encode())
            log.flush()
            try:
                command_started = True
                with profile.stage("guest_tests"):
                    shell(vm, r'''
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export DISPATCH_TEST_LINUX_SSH="$1"
export DISPATCH_TEST_RECHECK="$2"
export DISPATCH_TEST_BENCHMARKS="$3"
export DISPATCH_TEST_SKIP_PREFLIGHT="$4"
export DISPATCH_TEST_SHARD="$5"
export DISPATCH_TEST_SHARD_PRIMARY="$6"
shift 6
cd /Users/admin/dispatch-tests/workspace
exec caffeinate -di /bin/bash test/vm-guest.sh "$@"
''', "1" if linux else "0", "1" if recheck else "0",
                          "1" if benchmarks else "0",
                          # The primary shard runs the shared portable checks once.
                          os.environ.get("DISPATCH_TEST_SKIP_PREFLIGHT", "0") if primary else "1",
                          ",".join(shard_classes or []), "1" if primary else "0", *arguments, stdout=log, stderr=subprocess.STDOUT)
                result = 0
            except subprocess.CalledProcessError as error:
                result = error.returncode
        completed = True
        with profile.stage("artifacts"):
            with (output / "artifacts.tar").open("wb") as stream:
                shell(vm, r'''
set -euo pipefail
cd /Users/admin/dispatch-tests/workspace
set --
for item in build/TestResults.xcresult build/TestSummary.json build/TestProfile.json build/TestTimings.json build/TestCases.json build/TestPreflight.json build/*audit* build/*validation*; do
    [[ ! -e "$item" ]] || set -- "$@" "$item"
done
COPYFILE_DISABLE=1 tar -cf - --files-from /dev/null "$@"
''', stdout=stream)
            run("/usr/bin/tar", "-xf", str(output / "artifacts.tar"), "-C", str(output))
            (output / "artifacts.tar").unlink()
            for name in ["TestProfile.json", "TestPreflight.json", "TestSummary.json", "TestTimings.json", "TestCases.json"]:
                source = output / "build" / name
                if source.exists():
                    shutil.copy2(source, profile.path.parent / name)
        print("Tests " + ("passed" if result == 0 else "failed") + ". Results: " + str(output))
        print("VM left running for the next test. Stop with: python3 test/vm.py --vm " + vm + " stop")
        return result
    finally:
        profile.data.update(elapsed_seconds=time.perf_counter() - started, exit_code=result)
        profile.save()
        if host_run is not None:
            host_run.update(profile=profile, output=output, started=started)
        timing_path = output / 'build/TestTimings.json'
        if timing_path.exists():
            timing = json.loads(timing_path.read_text())
            timing['host_stages'] = profile.data['stages']
            timing['wall_seconds'] = profile.data['elapsed_seconds']
            timing['exit_code'] = result
            timing['tool_versions'].update(profile.data.get('tool_versions', {}))
            timing_path.write_text(json.dumps(timing, indent=2) + '\n')
            shutil.copy2(timing_path, profile.path.parent / 'TestTimings.json')
        if (output / "test.log").exists():
            shutil.copy2(output / "test.log", profile.path.parent / "test.log")
        if completed or not command_started:
            guest(vm, "/bin/rmdir", GUEST + "/test.lock")


@contextmanager
def linux_connection(vm, server, tools=None):
    """Pair the desktop with an archived Lima SSH VM for this run only."""
    if server in {"dispatch-manual-ssh", LOCAL_ENVIRONMENT.get("manual_ssh_vm", "dispatch-manual-ssh")}:
        raise RuntimeError(f"Reserve {server} for the user's manual testing.")
    run(sys.executable, str(ROOT / "scripts/ssh-vm.py"), server)
    entries = subprocess.check_output(["limactl", "list", "--json"], text=True).splitlines()
    endpoint = next((value for line in entries if line.strip()
                     for value in [json.loads(line)] if value["name"] == server), None)
    if endpoint is None:
        raise RuntimeError("The dedicated Linux SSH VM did not become available.")

    def remote(*command, **kwargs):
        return run("ssh", "-F", endpoint["sshConfigFile"], "-o", "BatchMode=yes",
                   endpoint["hostname"], shlex.join(command), **kwargs)

    start(vm)
    with ssh_bridge(vm, endpoint["sshAddress"], endpoint["sshLocalPort"]) as (gateway, port):
        try:
            linux_profile(vm, remote, gateway, port, tools or {})
            yield
        finally:
            # The relay's ephemeral port must never survive as a usable profile.
            guest(vm, "/bin/rm", "-f", GUEST + "/linux-ssh.json", GUEST + "/host-linux-ssh.json")


@contextmanager
def ssh_bridge(vm, address, port):
    """Expose one encrypted test SSH endpoint only to the client VM."""
    ipaddress.ip_address(address)
    client_address = subprocess.check_output(["tart", "ip", vm], text=True).strip()
    route = guest(vm, "/sbin/route", "-n", "get", "default", capture_output=True, text=True).stdout
    gateway = next(line.split(":", 1)[1].strip() for line in route.splitlines() if line.strip().startswith("gateway:"))
    ipaddress.ip_address(gateway)
    stopping = threading.Event()
    active, lock = set(), threading.Lock()
    slots = threading.BoundedSemaphore(16)

    class Relay(socketserver.BaseRequestHandler):
        def handle(self):
            if self.client_address[0] != client_address or not slots.acquire(blocking=False):
                return
            target = None
            try:
                target = socket.create_connection((address, port), timeout=5)
                self.request.settimeout(5)
                with lock:
                    active.update((self.request, target))
                peers = {self.request: target, target: self.request}
                while peers and not stopping.is_set():
                    for source in select.select(list(peers), [], [], 1)[0]:
                        data = source.recv(65536)
                        if data:
                            peers[source].sendall(data)
                        else:
                            peers.pop(source).shutdown(socket.SHUT_WR)
            except OSError:
                pass
            finally:
                with lock:
                    active.discard(self.request); active.discard(target)
                if target:
                    target.close()
                slots.release()

    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True

    with Server((gateway, 0), Relay) as relay:
        thread = threading.Thread(target=relay.serve_forever, daemon=True)
        thread.start()
        try:
            yield gateway, relay.server_address[1]
        finally:
            stopping.set(); relay.shutdown()
            with lock:
                for connection in active:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
            thread.join()


def linux_profile(vm, remote, gateway, port, tools):
    remote("/bin/sh", "-c", "command -v herdr && command -v tmux && command -v python3 && (systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket)")
    resolved = json.loads(remote("/usr/bin/python3", "-c", '''
import json, os, shutil, sys
requested = json.loads(sys.argv[1])
agent = requested.get('agent', 'codex')
if agent not in ('codex', 'claude', 'pi'): sys.exit('Unsupported Linux test agent')
tools = {agent: requested.get(agent) or shutil.which(agent),
         'supportedTmux': requested.get('supportedTmux') or (shutil.which('tmux') if agent in ('claude', 'pi') else '/opt/dispatch-test-tools/tmux/bin/tmux')}
for other in ('codex', 'claude', 'pi'):
    if requested.get(other): tools[other] = requested[other]
for name, path in tools.items():
    if not path or not os.path.isabs(path) or not os.path.isfile(path) or not os.access(path, os.X_OK):
        sys.exit('Missing installed Linux test tool: ' + name + '. Supply its existing absolute path when pairing.')
print(json.dumps(tools))
''', json.dumps(tools), capture_output=True, text=True).stdout)
    for agent in ("codex", "claude", "pi"):
        if agent in resolved:
            remote(resolved[agent], "--version")
    remote(resolved["supportedTmux"], "-V")
    client = GUEST + "/linux-ssh"
    shell(vm, 'umask 077; mkdir -p "$1"; test -f "$1/key" || ssh-keygen -q -t ed25519 -N "" -f "$1/key"', client)
    public = guest(vm, "/bin/cat", client + "/key.pub", capture_output=True, text=True).stdout.strip()
    # Only public material crosses from the client VM into the server VM.
    remote("/usr/bin/python3", "-c", '''
import os,sys
from pathlib import Path
directory = Path.home() / '.ssh'
directory.mkdir(mode=0o700, exist_ok=True)
path = directory / 'authorized_keys'
lines = path.read_text().splitlines() if path.exists() else []
if sys.argv[1] not in lines:
    with path.open('a') as file: file.write(('\\n' if lines else '') + sys.argv[1] + '\\n')
os.chmod(path, 0o600)
''', public)
    host_key = remote("/bin/cat", "/etc/ssh/ssh_host_ed25519_key.pub", capture_output=True, text=True).stdout.strip()
    user = remote("/usr/bin/id", "-un", capture_output=True, text=True).stdout.strip()
    options = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
               "-o", "UserKnownHostsFile=" + client + "/known_hosts", "-o", "IdentitiesOnly=yes", "-i", client + "/key",
               "-o", "HostName=" + gateway, "-o", "HostKeyAlias=dispatch-linux-test-server", "-o", "ConnectTimeout=5", "-p", str(port)]
    profile = {"destination": user + "@dispatch-linux-test-server", "options": options, **resolved}
    guest(vm, "/usr/bin/python3", "-c", '''
import os,sys
from pathlib import Path
os.umask(0o077)
Path(sys.argv[1] + '/known_hosts').write_text(sys.argv[2] + '\\n')
Path(sys.argv[1] + '.json').write_text(sys.argv[3])
Path(sys.argv[1]).with_name('host-linux-ssh.json').write_text(sys.argv[3])
''', client, "dispatch-linux-test-server " + host_key, json.dumps(profile))
    guest(vm, "/usr/bin/ssh", *options, profile["destination"], "uname -s; herdr --version; tmux -V; " + shlex.join([resolved[tools.get("agent", "codex")], "--version"]))


def linux(vm, server, tools=None):
    """Pair the macOS client with the dedicated archived Linux SSH VM."""
    with linux_connection(vm, server, tools):
        configuration = ROOT / "build" / "vm-tests" / (vm + "-linux.json")
        configuration.parent.mkdir(parents=True, exist_ok=True)
        configuration.write_text(json.dumps({"provider": "lima", "server": server, "tools": tools or {}}))
    suite = {"claude": "SSHLinuxClaudeIntegrationTests", "pi": "SSHLinuxPiIntegrationTests"}.get((tools or {}).get("agent"), "SSHLinuxIntegrationTests")
    print("Linux SSH tests configured. Run python3 test/vm.py test DispatchTests/" + suite, flush=True)


@contextmanager
def host_lock(name, blocking=False):
    """A host-wide lock that also serializes runners across git worktrees."""
    path = Path(tempfile.gettempdir()) / (name + ".lock")
    with path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            raise RuntimeError("Another VM runner is active for " + name.removeprefix("dispatch-vm-")) from None
        yield


def host_resources():
    values = []
    for name in ("hw.memsize", "hw.ncpu", "kern.memorystatus_level"):
        try:
            values.append(int(run("/usr/sbin/sysctl", "-n", name, capture_output=True, text=True).stdout))
        except (OSError, ValueError, subprocess.CalledProcessError):
            values.append(0)  # Unknown free memory never admits a VM boot.
    total, cpus, level = values
    return total, total * level // 100, cpus


def allocation(name):
    value = json.loads(run("tart", "get", name, "--format", "json", capture_output=True, text=True).stdout)
    return name, int(value["Memory"]) * 1024 * 1024, int(value["CPU"])


def lima_instances():
    if not shutil.which("limactl"):
        return {}
    lines = run("limactl", "list", "--json", capture_output=True, text=True).stdout.splitlines()
    return {item["name"]: item for item in map(json.loads, filter(str.strip, lines))}


def shard_capacity(vm, shard_vm, linux_server=None, planned=None):
    """Check the host can run both macOS VMs beside every other running VM.

    planned sizes a shard VM that has not been cloned yet.
    """
    listed = json.loads(run("tart", "list", "--source", "local", "--format", "json",
                            capture_output=True, text=True).stdout)
    running = [allocation(item["Name"]) for item in listed if item["Running"]]
    active = {name for name, _, _ in running}
    starting = [planned if planned and name == planned[0] else allocation(name)
                for name in (vm, shard_vm) if name not in active]
    for name, item in lima_instances().items():
        entry = (name, int(item.get("memory") or 0), int(item.get("cpus") or 0))
        if item.get("status") == "Running":
            running.append(entry)
        elif name == linux_server:
            starting.append(entry)
    total, available, cpus = host_resources()
    return shards.capacity(total, available, cpus, running, starting)


def clone_shard(vm, shard_vm):
    """Copy the prepared test VM, including its caches and desktop settings."""
    if info(shard_vm) is not None:
        raise RuntimeError(shard_vm + " already exists. Remove it with tart delete " + shard_vm + " to clone again.")
    state = info(vm)
    if state is None:
        raise RuntimeError("VM is missing. Run python3 test/vm.py setup first.")
    # The clone inherits the source's allocation; refuse hosts that cannot run both.
    _, memory, cpu = allocation(vm)
    reason = shard_capacity(vm, shard_vm, planned=(shard_vm, memory, cpu))
    if reason:
        raise RuntimeError("This host cannot run a second test VM safely: " + reason
                           + ". Tests keep using " + vm + " alone.")
    if state["Running"]:
        shell(vm, 'test ! -e "$1/test.lock" || { echo "Wait for the current VM test before cloning." >&2; exit 1; }', GUEST)
        # A running guest's disk can change mid-copy; clone only a stopped VM.
        print("Stopping " + vm + " to clone a consistent disk...", flush=True)
        run("tart", "stop", vm)
    # APFS copy-on-write: the clone uses new space only as its disk diverges.
    # Tart assigns the clone a new MAC address because the source keeps its own.
    run("tart", "clone", vm, shard_vm)
    start(vm)
    start(shard_vm)
    print("Shard VM ready. Large test runs now use both VMs when it saves time and memory allows.", flush=True)


def linux_server(vm):
    configuration = ROOT / "build/vm-tests" / (vm + "-linux.json")
    try:
        return json.loads(configuration.read_text()).get("server")
    except (OSError, ValueError):
        return None


def choose_shards(vm, shard_vm, selection, required=False, probe_locks=True):
    """Return (groups, loads, None) to shard, or (None, None, reason) for one VM."""
    def decline(reason):
        if required:
            raise RuntimeError("Cannot run --shards 2: " + reason)
        return None, None, reason

    if not shutil.which("tart"):
        return decline("Tart is not installed")
    if info(shard_vm) is None:
        return decline(shard_vm + " does not exist (create it with python3 test/vm.py --vm " + vm + " clone-shard)")
    groups, loads = shard_plan(vm, selection)
    if not all(groups):
        return decline("the selection fits one VM")
    if not required and not shards.worthwhile(groups, loads):
        return decline(f"the selection is too small to benefit (~{sum(loads) / 60:.0f} min planned)")
    linux = any(name in shards.PRIMARY_ONLY for name in groups[0])
    reason = shard_capacity(vm, shard_vm, linux_server(vm) if linux else None)
    if reason:
        return decline(reason)
    if probe_locks:
        try:
            with host_lock("dispatch-vm-" + shard_vm):
                pass
        except RuntimeError:
            return decline(shard_vm + " is running another test")
    return groups, loads, None


def shard_plan(vm, selection):
    durations, pairing = shards.history(ROOT)
    linux = any(shards.class_of(case) in shards.PRIMARY_ONLY for case in selection['selected'])
    overhead = (pairing or 0.0) if linux and (ROOT / "build/vm-tests" / (vm + "-linux.json")).exists() else 0.0
    return shards.plan(selection['selected'], 2, durations, primary_overhead=overhead)


def describe_plan(names, groups, loads, selection):
    for name, group, load in zip(names, groups, loads):
        count = sum(shards.class_of(case) in group for case in selection['selected'])
        print(f"Shard {name}: {len(group)} classes, {count} cases, ~{load / 60:.0f} min planned", flush=True)


def test_sharded(vm, shard_vm, args, groups, loads):
    """Run disjoint class sets in two VMs at once, then merge their results."""
    selection = args.selection
    names = [vm, shard_vm]
    for name in names:
        with host_lock("dispatch-vm-" + name):
            pass  # Fail before starting either runner if one VM is busy.
    describe_plan(names, groups, loads, selection)
    started = time.perf_counter()
    run("/bin/bash", "scripts/setup.sh", cwd=ROOT, env={**os.environ, "DISPATCH_SETUP_OFFLINE": "1"})
    stamp = run_stamp()
    runs = [stamp + "-shard" + str(index + 1) for index in range(len(names))]
    processes = []
    for index, (name, group, run_id) in enumerate(zip(names, groups, runs)):
        command = [sys.executable, str(Path(__file__).resolve()), "--vm", name, "test", *args.tests]
        command += ["--suite", args.suite] if args.suite else []
        for skip in args.skip:
            command += ["--skip", skip]
        command += ["--recheck"] if args.recheck else []
        command += ["--benchmarks"] if args.benchmarks else []
        command += ["--shard-classes", ",".join(group), "--shard-role", "primary" if index == 0 else "secondary",
                    "--run-id", run_id, "--host-ready"]
        # Same process group: Ctrl-C reaches each runner exactly as it would unsharded.
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        relay = threading.Thread(target=lambda stream, label: [print(f"[{label}] {line}", end="", flush=True) for line in stream],
                                 args=(process.stdout, name), daemon=True)
        relay.start()
        processes.append((process, relay))
    codes = []
    try:
        for process, relay in processes:
            codes.append(process.wait())
            relay.join()
    except KeyboardInterrupt:
        for process, _ in processes:
            process.wait()
        print("\nInterrupted. Stop the VMs before starting another test run.", file=sys.stderr)
        return 130
    output = ROOT / "build/vm-tests" / stamp
    output.mkdir(parents=True)
    summaries, timings, missing = [], [], []
    for run_id in runs:
        build = ROOT / "build/vm-tests" / run_id / "build"
        try:
            summaries.append(json.loads((build / "TestSummary.json").read_text()))
            timings.append(json.loads((build / "TestTimings.json").read_text()))
        except (OSError, ValueError):
            missing.append(run_id)
    merged = shards.merge_timings(selection, timings)
    merged.update(wall_seconds=time.perf_counter() - started, exit_codes=codes, missing_shard_results=missing,
                  shards=[{"vm": name, "run": run_id, "exit_code": code, "classes": group, "planned_seconds": load}
                          for name, run_id, code, group, load in zip(names, runs, codes, groups, loads)])
    (output / "TestTimings.json").write_text(json.dumps(merged, indent=2) + "\n")
    if summaries:
        summary = shards.merge_summaries(summaries)
        (output / "TestSummary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"XCTest (all shards): {summary['passedTests']} passed, {summary['failedTests']} failed, "
              f"{summary['skippedTests']} skipped", flush=True)
    for name, run_id, code in zip(names, runs, codes):
        print(f"Shard {name}: {'passed' if code == 0 else 'failed'}; results: build/vm-tests/{run_id}", flush=True)
    if missing:
        print("Missing shard results: " + ", ".join(missing), file=sys.stderr)
    if not merged["complete"]:
        print(f"Incomplete sharded selection: {len(merged['missing_identifiers'])} missing, "
              f"{len(merged['unexpected_identifiers'])} unexpected, "
              f"{len(merged['duplicate_identifiers'])} repeated", file=sys.stderr)
    result = next((code for code in codes if code), 0) or (0 if merged["complete"] and not missing else 1)
    print(f"Sharded run {'passed' if result == 0 else 'failed'} in {merged['wall_seconds'] / 60:.1f} min. "
          f"Merged results: {output}", flush=True)
    if summaries and summary["failedTests"]:
        print("Rerun failures: python3 test/vm.py test --failed " + stamp, flush=True)
    return result


def stop(vm):
    state = info(vm)
    if state and state["Running"]:
        run("tart", "stop", vm)
    print("VM stopped. An interrupted test lock will be cleared on the next boot.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vm", default=os.environ.get("DISPATCH_VM", LOCAL_ENVIRONMENT.get("macos_vm", "dispatch-tests")))
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("setup", help="Create the VM and install its test dependencies")
    prepare.add_argument("--image", default=IMAGE)
    commands.add_parser("rust", help="Copy and verify the prepared host Rust toolchain into the existing test VM (no downloads)")
    tests = commands.add_parser("test", help="Run fast checks by default, a named suite, or explicit XCTest cases")
    add_arguments(tests)
    tests.add_argument("--failed", help="Rerun only failures from a run ID, directory, or TestSummary.json")
    tests.add_argument("--shards", choices=["auto", "1", "2"],
                       help="Split XCTest classes across this VM and --shard-vm (macOS allows two macOS guests). "
                            "Default auto: only when the shard VM exists, host memory and CPUs allow it, and it saves time")
    tests.add_argument("--shard-vm", help="Second macOS VM for --shards 2 (default: VM name + -2)")
    # Internal: one runner of a sharded parent.
    tests.add_argument("--shard-classes", help=argparse.SUPPRESS)
    tests.add_argument("--shard-role", choices=["primary", "secondary"], default="primary", help=argparse.SUPPRESS)
    tests.add_argument("--run-id", help=argparse.SUPPRESS)
    tests.add_argument("--host-ready", action="store_true", help=argparse.SUPPRESS)
    cloning = commands.add_parser("clone-shard", help="Clone the prepared VM as the second VM for --shards 2 (stops it briefly)")
    cloning.add_argument("--shard-vm", help="Name of the new VM (default: VM name + -2)")
    remote = commands.add_parser("linux", help="Pair an archived Linux SSH VM with the macOS test client, without downloading images")
    remote.add_argument("--server", default=LOCAL_ENVIRONMENT.get("linux_test_vm", "dispatch-rust-ssh-validation"))
    remote.add_argument("--agent", choices=["codex", "claude", "pi"], default="codex", help="Agent required by the Linux test profile")
    remote.add_argument("--claude", help="Existing absolute Linux Claude executable path (no install/download)")
    remote.add_argument("--codex", help="Existing absolute Linux Codex executable path (no install/download)")
    remote.add_argument("--pi", help="Existing absolute Linux Pi executable path (no install/download)")
    remote.add_argument("--tmux", help="Existing absolute Linux tmux with verified Chat submission support")
    commands.add_parser("stop", help="Stop the VM and release its CPU/RAM")
    args = parser.parse_args()
    if args.command in ("test", "clone-shard"):
        args.shard_vm = args.shard_vm or LOCAL_ENVIRONMENT.get("macos_shard_vm", args.vm + "-2")
        if args.shard_vm == args.vm:
            parser.error("--shard-vm must name a second VM")
    if args.command == "test":
        try:
            if args.failed and (args.tests or args.suite):
                parser.error("--failed cannot be combined with selectors or --suite")
            path = Path(args.failed) if args.failed else None
            if path is not None and not path.exists():
                path = ROOT / "build/vm-tests" / args.failed
            args.tests = failed_tests(path) if path is not None else normalize(args.tests)
            args.benchmarks = args.benchmarks or os.environ.get('DISPATCH_TEST_BENCHMARKS') == '1'
            args.selection = resolve(args.tests, args.skip, args.suite, args.benchmarks, ROOT)
            if args.shard_classes:
                args.selection = shards.restrict(args.selection, args.shard_classes.split(","))
            describe(args.selection, args.list)
            if args.list:
                # Keep the default listing identical to the other entry points.
                if args.shards in ("auto", "2") and not args.shard_classes:
                    groups, loads, reason = choose_shards(args.vm, args.shard_vm, args.selection,
                                                          required=args.shards == "2", probe_locks=False)
                    if groups:
                        describe_plan([args.vm, args.shard_vm], groups, loads, args.selection)
                    else:
                        print("VM shards: 1 (" + reason + ")")
                return 0
        except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
            parser.error(str(error))
    names = [args.vm] + ([args.server] if args.command == "linux" else [])
    names += [args.shard_vm] if args.command in ("test", "clone-shard") else []
    if any(not name or not name[0].isalnum() or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name) for name in names):
        parser.error("Use a simple local VM name (letters, digits, dots, underscores, hyphens).")
    if not shutil.which("tart"):
        parser.error("Install Tart first: brew install openai/tools/tart")
    try:
        if args.command == "stop":
            stop(args.vm)
            return 0
        if args.command == "test" and args.shards != "1" and not args.shard_classes:
            groups, loads, reason = choose_shards(args.vm, args.shard_vm, args.selection, required=args.shards == "2")
            if groups:
                # Each shard runner takes its own VM lock.
                return test_sharded(args.vm, args.shard_vm, args, groups, loads)
            if info(args.shard_vm) is not None:
                print("VM shards: 1 (" + reason + ")", flush=True)
        # A host lock also serializes source transfer/setup across git worktrees.
        with host_lock("dispatch-vm-" + args.vm):
            if args.command == "clone-shard":
                with host_lock("dispatch-vm-" + args.shard_vm):
                    clone_shard(args.vm, args.shard_vm)
            elif args.command == "setup":
                setup(args.vm, args.image)
            elif args.command == "rust":
                provision_rust(args.vm)
            elif args.command == "linux":
                linux(args.vm, args.server, {key: value for key, value in
                      (("agent", args.agent), ("claude", args.claude), ("codex", args.codex), ("pi", args.pi), ("supportedTmux", args.tmux)) if value})
            else:
                shard = {"stamp": args.run_id, "host_ready": args.host_ready}
                if args.shard_classes:
                    shard.update(shard_classes=args.shard_classes.split(","), primary=args.shard_role == "primary")
                return test(args.vm, args.tests, recheck=args.recheck, benchmarks=args.benchmarks,
                            selection=args.selection, **shard)
    except (RuntimeError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print("VM runner: " + str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nInterrupted. Stop the VM before starting another test run.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
