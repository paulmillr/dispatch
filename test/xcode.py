#!/usr/bin/env python3
"""Build when inputs change, execute XCTest every time, and validate its result."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import uuid
from profile import Profile
from timings import cases_from_result, report, compare
from selection import resolve, describe, add_arguments
import shards
import capture
import replay

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import codex_fixture
INPUTS = ("Dispatch", "DispatchTests", "Helpers", "Vendor", "ThirdPartyLicenses", "extras", "scripts", "test",
          "project.yml",
          "Dispatch.xcodeproj/project.pbxproj", "Dispatch.xcodeproj/xcshareddata")
IGNORED = {"target", "__pycache__", "LocalToolAudit", ".git", "xcuserdata", ".DS_Store"}


def files(path):
    """Do not follow directory links or include private/generated test inputs."""
    if path.is_symlink() or path.is_file():
        yield path
    elif path.is_dir():
        for directory, folders, names in os.walk(path):
            folders[:] = sorted(name for name in folders if name not in IGNORED)
            for name in list(folders):
                child = Path(directory) / name
                if child.is_symlink():
                    folders.remove(name)
                    yield child
            for name in sorted(names):
                if name not in IGNORED and not name.startswith("rollout-") and not name.endswith((".pyc", ".pyo")):
                    yield Path(directory) / name


def fingerprint(root, paths):
    digest = hashlib.sha256()
    for source in sorted(paths):
        path = root / source
        # Missing files/directories are part of the fingerprint, including a
        # deleted source or resource. File contents detect restored mtimes.
        digest.update(json.dumps([str(source), path.exists(), path.is_symlink()]).encode())
        for item in files(path):
            metadata = item.lstat()
            digest.update(json.dumps([str(item.relative_to(root)), metadata.st_mode]).encode())
            if item.is_symlink():
                digest.update(os.readlink(item).encode())
            else:
                with item.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
            digest.update(b"\0")
    return digest.hexdigest()


def build_key(root):
    # Runtime fixture/selection flags do not change compilation. Retain all
    # other environment values so custom compiler/signing settings invalidate.
    volatile = {"_", "PWD", "OLDPWD", "SHLVL", "TERM", "TERM_SESSION_ID", "TERM_PROGRAM",
                "TERM_PROGRAM_VERSION", "SSH_AUTH_SOCK", "SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY"}
    environment = {key: value for key, value in os.environ.items()
                   if key not in volatile and not key.startswith("DISPATCH_TEST_")}
    override = os.environ.get("XCODE_XCCONFIG_FILE")
    # build/rust may link a matching toolchain from PATH; fingerprint what it points to.
    rust = (root / "build/rust").resolve()
    toolchain = [str(rust)]
    for path in files(rust):
        info = path.stat()
        toolchain.append((str(path.relative_to(rust)), info.st_size, info.st_mtime_ns,
                          info.st_ctime_ns, info.st_ino, info.st_mode))
    state = {"inputs": fingerprint(root, INPUTS), "environment": environment,
             "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True),
             "os": platform.platform(), "machine": platform.machine(),
             "rust_toolchain": toolchain,
             "xcconfig": hashlib.sha256(Path(override).read_bytes()).hexdigest() if override else None}
    return hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()


def products(root):
    base = root / "build/Build/Products"
    plans = sorted(base.glob("Dispatch_*.xctestrun"))
    app = base / "Debug/Dispatch.app"
    tests = base / "Debug/DispatchTests.xctest"
    if len(plans) != 1 or not app.is_dir() or not (tests.is_dir() or any(app.rglob("DispatchTests.xctest"))):
        return None
    paths = [str(app.relative_to(root)), str(plans[0].relative_to(root))]
    # Some Xcode configurations put the test bundle beside its host app.
    if tests.exists():
        paths.append(str(tests.relative_to(root)))
    return {"plan": str(plans[0].relative_to(root)), "digest": fingerprint(root, paths)}


def load_receipt(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def ensure_build(root, profile, force=False):
    receipt = root / "build/test-tools/xcode-build.json"
    with profile.stage("test_build_fingerprint"):
        key = build_key(root)
        current = products(root)
        saved = load_receipt(receipt)
    if not force and current and saved.get("key") == key and saved.get("products") == current:
        print("Test build: verified unchanged inputs and products; reusing build.", flush=True)
        return root / current["plan"]
    receipt.unlink(missing_ok=True)
    with profile.stage("test_build"):
        subprocess.run(["xcodebuild", "-project", "Dispatch.xcodeproj", "-scheme", "Dispatch",
                        "-configuration", "Debug", "-derivedDataPath", "build",
                        "-destination", "platform=macOS", "build-for-testing"], cwd=root, check=True)
    current = products(root)
    if current is None:
        raise RuntimeError("Build did not produce exactly one Dispatch test plan and test bundle")
    # Do not authorize reuse if sources changed during compilation.
    if build_key(root) != key:
        raise RuntimeError("Build inputs changed during compilation; rerun the tests")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    temporary = receipt.with_suffix(".tmp")
    temporary.write_text(json.dumps({"key": key, "products": current}, indent=2) + "\n")
    temporary.replace(receipt)
    return root / current["plan"]


def validate_summary(summary):
    value = json.loads(summary.read_text())
    if not isinstance(value, dict):
        raise ValueError("Invalid XCTest summary")
    counts = [value.get(name) for name in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
    if any(type(number) is not int or number < 0 for number in counts):
        raise ValueError("Invalid XCTest result counts")
    total, passed, failed, skipped = counts
    print(f"XCTest: {passed} passed, {failed} failed, {skipped} skipped", flush=True)
    return total > 0 and passed == total and failed == 0 and skipped == 0


def execute(root, tests, skips=(), recheck=False, benchmarks=False, selection=None, capture_run=None,
            replay_run=None, replay_index=None, output=None, replay_settings=None):
    selection = selection or resolve(tests, skips, benchmarks=benchmarks, root=root)
    tests = selection["selected"]
    build = output or root / "build"
    build.mkdir(parents=True, exist_ok=True)
    result = build / "TestResults.xcresult"
    summary = build / "TestSummary.json"
    fixtures = build / "TestFixtures.jsonl"
    fixtures.write_text('')
    shutil.rmtree(result, ignore_errors=True)
    summary.unlink(missing_ok=True)
    timings_path = build / "TestTimings.json"
    tree_path = build / "TestCases.json"
    timings_path.unlink(missing_ok=True)
    tree_path.unlink(missing_ok=True)
    profile = Profile(build / "TestProfile.json")
    previous = load_receipt(profile.path)
    # Keep preparation stages from this guest invocation, never timing stages
    # from an earlier direct xcode.py run.
    if previous and not any(stage.get('name') in {'test_build_fingerprint', 'test_build', 'xctest', 'results'}
                            for stage in previous.get('stages', [])):
        profile.data = previous
    runner_error = None
    status = 1
    recording = None
    try:
        # The old SSH helper's portable preflight went with it; helper4 builds in the Xcode phase.
        plan = ensure_build(root, profile, force=recheck)
        if not replay_run and any((root / "captures").rglob("manifest.json")):
            with profile.stage('helper_replay'):
                subprocess.run([sys.executable, str(root / 'scripts/build-ssh-helper.py'),
                                '--replay-tools', '--build-only'], cwd=root, check=True)
                resources = root / 'build/Build/Products/Debug/Dispatch.app/Contents/Resources'
                tools = root / 'build/helper4-rust/bin/replay'
                settings = {'helper': {'macos': resources / 'dispatch-helper',
                                       'linux': resources / 'helper4/linux-x86_64'},
                            'tool': {'macos': tools / 'darwin-universal', 'linux': tools / 'linux-x86_64'},
                            'ssh': {}}
                if (root / 'build/linux-ssh.json').is_file():
                    settings['ssh']['linux'] = root / 'build/linux-ssh.json'
                for name, values in (replay_settings or {}).items():
                    settings[name].update(replay.mappings(values))
                arguments = [str(root / 'captures'), '--require-same']
                for name, values in settings.items():
                    for system, path in values.items():
                        arguments += ['--' + name, system + '=' + str(path)]
                if replay.main(arguments):
                    raise RuntimeError('Helper replay preflight failed; live tests were not started.')
        environment = dict(os.environ)
        if capture_run:
            resources = root / 'build/Build/Products/Debug/Dispatch.app/Contents/Resources'
            paths = [(resources / 'dispatch-helper', 'macos')]
            paths += [(resources / 'helper4' / name, system) for name, system in
                      [('darwin-universal','macos'),('linux-aarch64','linux'),('linux-x86_64','linux')]]
            helpers = [{'path':str(path),'platform':system} for path,system in paths if path.is_file()]
            if not helpers: raise RuntimeError('Capture requires the built original helper binaries')
            recording = capture.begin(root, capture_run, helpers)
            manifest = json.loads((recording/'manifest.json').read_text())
            manifest['platform'] = 'macos'
            manifest['source']['build_key'] = load_receipt(root/'build/test-tools/xcode-build.json').get('key')
            capture.write(recording/'manifest.json',manifest)
            environment.update(TEST_RUNNER_DISPATCH_TEST_CAPTURE='1',
                               TEST_RUNNER_DISPATCH_CAPTURE=str(recording/'raw/helper-%p.jsonl'),
                               TEST_RUNNER_DISPATCH_APP_CAPTURE=str(recording/'app'))
        if replay_run:
            environment.update(TEST_RUNNER_DISPATCH_TEST_REPLAY='1',
                               TEST_RUNNER_DISPATCH_APP_REPLAY=str(replay_run/'app'),
                               TEST_RUNNER_DISPATCH_APP_REPLAY_INDEX=str(replay_index))
        command = ["xcodebuild", "-xctestrun", str(plan), "-destination", "platform=macOS",
                   "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result), "test-without-building"]
        command += ["-only-testing:" + test for test in tests]
        with profile.stage("xctest") as stage:
            try:
                status = subprocess.run(command, cwd=root,
                    # SWIFTUI_VIEW_DEBUG makes SwiftUI record the view-debug tree that text assertions read;
                    # 3 = view types and values only. The loopback SSH fixture must match the helper build.
                    env={**environment, 'TEST_RUNNER_DISPATCH_TEST_FIXTURES': str(fixtures),
                         'TEST_RUNNER_SWIFTUI_VIEW_DEBUG': '3',
                         'TEST_RUNNER_DISPATCH_UNPRIVILEGED_SSHD': os.environ.get('DISPATCH_UNPRIVILEGED_SSHD', '')}).returncode
            except KeyboardInterrupt:
                status = 130
            stage["exit_code"] = status
            if status:
                stage["status"] = "failed"
    except KeyboardInterrupt:
        status = 130
        runner_error = 'Interrupted during test preparation'
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        status = error.returncode if isinstance(error, subprocess.CalledProcessError) else 1
        runner_error = str(error)
    try:
        with profile.stage('fixture_cleanup') as stage:
            homes = list(dict.fromkeys(json.loads(line) for line in fixtures.read_text().splitlines()))
            resources = codex_fixture.resources(homes)
            (build / 'TestFixtureResources.json').write_text(json.dumps(resources, indent=2) + '\n')
            if any(resources.values()):
                stage['status'] = 'failed'
                status = status or 1
                print('Fixture resources remain; see build/TestFixtureResources.json', file=sys.stderr)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        status = status or 1
        runner_error = (runner_error + '; ' if runner_error else '') + 'Fixture audit failed: ' + str(error)
    cases = []
    export_error = None
    try:
        if result.exists():
            with profile.stage("results"):
                for kind, path in [("summary", summary), ("tests", tree_path)]:
                    with path.open("w") as output:
                        subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", str(result)],
                                       cwd=root, stdout=output, check=True)
                cases = cases_from_result(json.loads(tree_path.read_text()))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        export_error = str(error)
    if recording:
        try:
            manifest = capture.index(recording, cases)
            if manifest['collection_errors']:
                raise ValueError('Capture collection is incomplete; see '+str(recording/'manifest.json'))
            retained = capture.retain(recording, root / 'captures' / capture_run)
            print('Retained successful captures: ' + json.dumps(retained['retained']), flush=True)
        except (OSError, ValueError, KeyError) as error:
            status = status or 1
            runner_error = (runner_error + '; ' if runner_error else '') + 'Capture indexing failed: ' + str(error)
    # A secondary VM shard leaves the one release launch to the primary.
    if (not replay_run and selection['suite'] in ('full', 'exhaustive') and runner_error is None
            and os.environ.get('DISPATCH_TEST_SHARD_PRIMARY', '1') == '1'):
        with profile.stage('release_launch') as stage:
            launch = subprocess.run([sys.executable, str(root / 'test/release.py')], cwd=root).returncode
            stage['exit_code'] = launch
            if launch:
                stage['status'] = 'failed'
                status = status or launch
    timing = report(selection, cases, fingerprint(root, INPUTS),
                    {"xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
                     "python": platform.python_version(), "os": platform.platform()}, profile.data['stages'])
    if runner_error:
        timing['runner_error'] = runner_error
        print('Test runner: ' + runner_error, file=sys.stderr)
    if export_error:
        timing['export_error'] = export_error
    baseline = root / 'test/baseline-timings.json'
    if baseline.exists():
        timing['baseline_comparison'] = compare(timing, json.loads(baseline.read_text()))
    timings_path.write_text(json.dumps(timing, indent=2) + "\n")
    # Export failure artifacts before validation, including partial/empty results.
    valid = validate_summary(summary) if summary.exists() and not export_error else False
    if not timing['complete']:
        print(f"Incomplete selection: {len(timing['missing_identifiers'])} missing, "
              f"{len(timing['unexpected_identifiers'])} unexpected, "
              f"{len(timing['duplicate_identifiers'])} repeated", file=sys.stderr)
    if export_error:
        print('Result export failed: ' + export_error, file=sys.stderr)
    count_matches = summary.exists() and not export_error and json.loads(summary.read_text())["totalTestCount"] == len(cases)
    outcomes_passed = all(case['outcome'] == 'Passed' for case in cases)
    return status or (0 if valid and timing['complete'] and count_matches and outcomes_passed else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_arguments(parser)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--capture', metavar='RUN', help='Stage captures in build/captures/RUN and retain successful cases in captures/RUN')
    mode.add_argument('--replay', metavar='RUN', help='Replay recorded app I/O from captures/RUN')
    parser.add_argument('--tests-from', type=Path, help='Additional selectors from a non-empty JSON array')
    for name in ('helper', 'tool', 'ssh'):
        parser.add_argument('--replay-' + name, action='append', default=[], metavar='PLATFORM=PATH',
                            help='Override a mandatory helper replay preflight ' + name)
    args = parser.parse_args()
    # Runs on a developer Mac need no sudo: the loopback SSH fixture starts sshd
    # as the current user, matched by a Debug helper built to accept it. The VM
    # guest (test/vm-guest.sh) sets 0 to keep testing the root sshd monitor.
    # Set before the build key so switching modes rebuilds the helper.
    os.environ.setdefault("DISPATCH_UNPRIVILEGED_SSHD", "1")
    try:
        if args.tests_from:
            selected = json.loads(args.tests_from.read_text())
            if not isinstance(selected,list) or not selected or any(not isinstance(x,str) or not x for x in selected):
                raise ValueError('--tests-from requires a non-empty JSON array of test selectors')
            args.tests += selected
        rounds = None
        if args.replay:
            corpus = Path(args.replay).resolve()
            if not corpus.is_dir(): corpus = ROOT/'captures'/args.replay
            rounds = capture.replay_rounds(corpus)
            if not args.tests and not args.suite:
                args.tests = list(dict.fromkeys(case for row in rounds for case in row))
        benchmarks = args.benchmarks or os.environ.get("DISPATCH_TEST_BENCHMARKS") == "1"
        selection = resolve(args.tests, args.skip, args.suite, benchmarks, ROOT)
        if os.environ.get("DISPATCH_TEST_SHARD"):
            selection = shards.restrict(selection, os.environ["DISPATCH_TEST_SHARD"].split(","))
        describe(selection, args.list)
        if args.list:
            return 0
        if not args.replay and any(case.endswith('/testLargeSessionSkipsIdleInvalidationAndPreservesChangedIdentities')
                                   for case in selection['selected']):
            limit = subprocess.run(['sysctl', '-n', 'kern.tty.ptmx_max'], capture_output=True, text=True)
            if limit.returncode == 0 and limit.stdout.strip().isdigit() and int(limit.stdout) < 999:
                print(f"Warning: kern.tty.ptmx_max={limit.stdout.strip()}. The large Herdr test creates 500 PTYs, "
                      "plus launcher/helper terminals; other processes share this limit. "
                      "Recommended setting: 999. An administrator can raise it for this boot with: "
                      "sudo sysctl -w kern.tty.ptmx_max=999. No setting was changed.", file=sys.stderr, flush=True)
        if rounds is not None:
            selected = set(selection['selected'])
            recorded = {case for row in rounds for case in row}
            if selected-recorded: raise ValueError('Missing app journal for: '+', '.join(sorted(selected-recorded)))
            output = ROOT/'build/app-replay'/str(uuid.uuid4())
            status = 0
            for number, row in enumerate(rounds):
                entries = {case:path for case,path in row.items() if case in selected}
                if not entries: continue
                directory = output/str(number+1)
                directory.mkdir(parents=True)
                index = directory/'journals.json'
                capture.write(index,entries)
                result = execute(ROOT,list(entries),recheck=args.recheck and number==0,
                                 benchmarks=benchmarks,selection=resolve(list(entries),(),benchmarks=benchmarks,root=ROOT),
                                 replay_run=corpus,replay_index=index,output=directory)
                status = status or result
            print('App replay results: '+str(output),flush=True)
            return status
        return execute(ROOT, args.tests, args.skip,
                       recheck=args.recheck or os.environ.get("DISPATCH_TEST_RECHECK") == "1",
                       benchmarks=benchmarks, selection=selection, capture_run=args.capture, replay_run=args.replay,
                       replay_settings={name: getattr(args, 'replay_' + name) for name in ('helper', 'tool', 'ssh')})
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Test runner: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
