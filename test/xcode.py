#!/usr/bin/env python3
"""Build when inputs change, execute XCTest every time, and validate its result."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from profile import Profile
from timings import cases_from_result, report, compare
from selection import resolve, describe, add_arguments, scan
import shards

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import codex_fixture
INPUTS = ("Dispatch", "DispatchTests", "helper", "Vendor", "ThirdPartyLicenses", "extras", "scripts", "test",
          "project.yml",
          "Dispatch.xcodeproj/project.pbxproj", "Dispatch.xcodeproj/xcshareddata")
IGNORED = {"target", "__pycache__", "LocalToolAudit", ".git", "xcuserdata", ".DS_Store"}
# The tests' private root: short (macOS sun_path), and fixed, since journals record its paths.
JOURNAL = '/tmp/dt-journal'

# Machine facts (home, temp dir, the bundle and checkout, the account, the machine's name and memory, variables) come
# from System: read anywhere else they name this Mac in recorded requests, or meet recorded values with live ones, which
# then replay nowhere else (docs/replay.md). The terminal engine gets them from the app; only its standalone parts (the
# passwd entry, the HOME fallback, its own view) and its live Kitty media file access (the temp dir) read them itself.
MACHINE = re.compile(r'ProcessInfo\.processInfo\.environment|NSHomeDirectory\(|homeDirectoryForCurrentUser|temporaryDirectory|resolvingSymlinksInPath'
                     r'|NSTemporaryDirectory\(|NSUserName\(|Bundle\.main\.(?!object\(|bundleIdentifier)|fileURLWithPath: #filePath'
                     r'|gethostname\(|physicalMemory|processInfo\.hostName|getpwuid|Machine\.current')
SYSTEM = {'Dispatch/Helper/System.swift', 'Dispatch/Helper/AppReplay.swift', 'Vendor/Term/Sources/TermApple/Launch.swift',
          'Vendor/Term/Sources/TermApple/Theme.swift', 'Vendor/Term/Sources/TermApple/TerminalView.swift',
          'Vendor/Term/Sources/TermApple/KittyMedia.swift'}
# A process a test runs or waits for itself: replay neither records it nor sees it run (its watchdog calls the app
# idle meanwhile). Tests run processes through TestSupport.live (to its end) or start (beside the test).
PROCESS = re.compile(r'\.run\(\)|\.waitUntilExit\(\)')


def direct(root, pattern, folders, exempt):
    """Lines of the folders' sources outside the exempt files that match the pattern, as file:line."""
    return [f'{path.relative_to(root)}:{number}' for folder in folders
            for path in sorted((root / folder).rglob('*.swift')) if str(path.relative_to(root)) not in exempt
            for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]


def machine(root):
    """Lines of app and test sources outside System that read a machine fact, as file:line."""
    return direct(root, MACHINE, ('Dispatch', 'DispatchTests', 'Vendor/Term/Sources'), SYSTEM)


def processes(root):
    """Lines of test sources outside TestSupport that run or wait for a process themselves, as file:line."""
    return direct(root, PROCESS, ('DispatchTests',), {'DispatchTests/TestSupport.swift'})


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


def corpus(root, stage, replays, helper, failed=False):
    """A run's passed tests into the replay corpus (the helper's capture tool: helper replays on that helper and
    app<->helper checks first); `failed`: its failed tests too, as recorded (a run's own replay reproduces them).
    Prints what it did not store. False: a passed test was not stored."""
    stored = subprocess.run([str(helper), 'capture', 'store', str(stage), str(replays)] + (['--failed'] if failed else []),
                            stdout=subprocess.PIPE, text=True)
    for line in stored.stdout.splitlines():
        if not line.startswith('pass\t'):
            print(line, flush=True)
    return stored.returncode == 0


def corpus_missing(root):
    """None, or why the corpus in replays/ (a git submodule) is absent: without it every test would run live, unnoticed."""
    replays = root / 'replays'
    if next(replays.rglob('*.rpl.bz2'), None):
        return None
    return ('The replay corpus is not checked out (' + str(replays) + ' has no recordings): run '
            '`git submodule update --init replays`, or pass --live to run every test live')


def execute(root, tests, skips=(), recheck=False, benchmarks=False, selection=None, capture=False,
            replays=None, required=False, live=False, output=None, replay=False):
    if found := machine(root):
        raise ValueError('Machine facts come from System (docs/replay.md); read directly at:\n  ' + '\n  '.join(found))
    if found := processes(root):
        raise ValueError('Test processes run through TestSupport.live or start (docs/replay.md); run directly at:\n  '
                         + '\n  '.join(found))
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
    # Unix sockets under the per-user temporary directory (/var/folders/…/T/) overrun macOS's
    # 104-byte sun_path: the helper's hook sockets (in DISPATCH_TEST_ROOT, else the test HOME
    # there) and fixture sockets in TMPDIR. One short private root per run holds both; it also
    # keeps test hook senders out of the account's real helper registry.
    # Recorded inputs name this root's paths (fixture environments, the test home): every run records or replays.
    # Tests see the checkout through its link there (System.checkout): paths in recordings are the same on every Mac.
    test_root = JOURNAL
    shutil.rmtree(test_root, ignore_errors=True)
    os.mkdir(test_root, 0o700)
    os.mkdir(os.path.join(test_root, 'tmp'), 0o700)
    checkout = Path(test_root) / 'checkout'
    checkout.symlink_to(root.resolve())
    linked = lambda path: str(checkout / Path(path).resolve().relative_to(root.resolve()))
    try:
        # The old SSH helper's portable preflight went with it; the helper builds in the Xcode phase.
        plan = ensure_build(root, profile, force=recheck)
        if replay:
            # Replaying the capture in build/captures: its tests into a corpus of their own (failed ones too: they
            # reproduce their failure), stored by the helper this build just bundled, then nothing but replay.
            replays, required = root / 'build/app-replay' / str(uuid.uuid4()), True
            replays.mkdir(parents=True)
            if not corpus(root, root / 'build/captures', replays,
                          root / 'build/Build/Products/Debug/Dispatch.app/Contents/Resources/dispatch-helper', failed=True):
                print('Some passed tests of the capture were not stored; they fail without a journal', file=sys.stderr)
            print('App replay corpus: ' + str(replays), flush=True)
        # The account's locale stays out (its languages, its region in CoreFoundation's variable, its terminal's LC_*):
        # every recorded environment holds it (the helper's, each command's). One basic locale is set with TZ below.
        environment = {key: value for key, value in os.environ.items() if key != 'LANGUAGE' and not key.startswith('LC_')}
        environment.setdefault('TEST_RUNNER_DISPATCH_TEST_ROOT', test_root)
        environment.setdefault('TEST_RUNNER_TMPDIR', os.path.join(test_root, 'tmp') + '/')
        # Set and dictionary order is random per process; recorded app outputs must not depend on it.
        environment['TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING'] = '1'
        # A test with a journal in the corpus replays it; one without runs live (recorded with --capture).
        environment['TEST_RUNNER_DISPATCH_REPLAYS'] = linked(replays or root / 'replays')
        # A diverging replay writes what it expected and got here, never into the corpus.
        (build / 'replay-diagnostics').mkdir(exist_ok=True)
        environment['TEST_RUNNER_DISPATCH_APP_DIAGNOSTICS'] = linked(build / 'replay-diagnostics')
        if required:
            environment['TEST_RUNNER_DISPATCH_REPLAY_REQUIRED'] = '1'
        if live:
            environment['TEST_RUNNER_DISPATCH_LIVE'] = '1'
        if capture:
            # One staging root, at the same path in every run (recordings hold it): each case writes <TestFile>/<test>/
            # in it, as in replays/, failed cases too. The tests find a class's file in tests.json.
            recording = root / 'build/captures'
            if recording.exists() and any(recording.iterdir()):
                raise ValueError('build/captures holds an earlier capture: move it away to keep it, or delete it')
            recording.mkdir(parents=True, exist_ok=True, mode=0o700)
            (recording / 'tests.json').write_text(json.dumps(scan(root)[1], indent=1, sort_keys=True) + '\n')
            environment.update(TEST_RUNNER_DISPATCH_TEST_CAPTURE='1', TEST_RUNNER_DISPATCH_CAPTURE=linked(recording) + '/helper-%p.rpl.bz2')
        command = ["xcodebuild", "-xctestrun", str(plan), "-destination", "platform=macOS",
                   "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result), "test-without-building"]
        command += ["-only-testing:" + test for test in tests]
        with profile.stage("xctest") as stage:
            try:
                status = subprocess.run(command, cwd=root,
                    # SWIFTUI_VIEW_DEBUG makes SwiftUI record the view-debug tree that text assertions read;
                    # 3 = view types and values only. The loopback SSH fixture must match the helper build.
                    env={**environment, 'TEST_RUNNER_DISPATCH_TEST_FIXTURES': linked(fixtures),
                         'TEST_RUNNER_SWIFTUI_VIEW_DEBUG': '3',
                         # The machine's time zone is private: agents write it into what tests record (Codex's context).
                         'TEST_RUNNER_TZ': 'UTC',
                         **{prefix + key: value for prefix in ('', 'TEST_RUNNER_')
                            for key, value in {'LANG': 'en_US.UTF-8', '__CF_USER_TEXT_ENCODING': '0x%X:0x0:0x0' % os.getuid()}.items()},
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
    shutil.rmtree(test_root, ignore_errors=True)
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
        # The corpus keeps the run's passed tests (each replays on this helper, its ends agree).
        if not corpus(root, recording, replays or root / 'replays', root / 'build/Build/Products/Debug/Dispatch.app/Contents/Resources/dispatch-helper'):
            status = status or 1
            runner_error = (runner_error + '; ' if runner_error else '') + 'Some passed tests were not stored in the corpus'
    # A secondary VM shard leaves the one release launch to the primary.
    if (not required and selection['suite'] in ('full', 'exhaustive') and runner_error is None
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


def arguments(description=__doc__):
    """The runner's arguments (test/leak.py takes the same)."""
    parser = argparse.ArgumentParser(description=description)
    add_arguments(parser)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--capture', action='store_true', help='Record live tests in build/captures/<TestFile>/<test>/ (failed ones too); store the passed ones in replays/')
    mode.add_argument('--replay', action='store_true', help='Replay only: the tests of build/captures, each from its own journal, failed ones included (they reproduce their failure; a test without a journal fails)')
    parser.add_argument('--live', action='store_true', help='Run every test live, ignoring the corpus in replays/')
    parser.add_argument('--tests-from', type=Path, help='Additional selectors from a non-empty JSON array')
    return parser


def main():
    args = arguments().parse_args()
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
        if not args.live and not args.replay and (missing := corpus_missing(ROOT)):
            raise ValueError(missing)
        return execute(ROOT, args.tests, args.skip,
                       recheck=args.recheck or os.environ.get("DISPATCH_TEST_RECHECK") == "1",
                       benchmarks=benchmarks, selection=selection, capture=args.capture, replay=args.replay,
                       live=args.live)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("Test runner: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
