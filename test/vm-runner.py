#!/usr/bin/env python3
"""Fast local checks for test-cache invalidation and incremental source transfer."""
import importlib.util
import hashlib
import json
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from profile import Profile
import xcode
from selection import normalize, failed_tests, resolve, inventory, BENCHMARKS, matches
from timings import cases_from_result, report, compare
import sys
from concurrent.futures import ThreadPoolExecutor
import threading
import shards


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vm = load('vm')


class SynchronizationTests(unittest.TestCase):
    def testHostBinariesTheGuestCannotLoadAreRejectedBeforeCopying(self):
        with tempfile.TemporaryDirectory(prefix='dispatch-portable-') as temporary:
            root = Path(temporary)
            source = root / 'main.c'; source.write_text('int main(void) { return 0; }\n')
            library = root / 'libhost.c'; library.write_text('int host(void) { return 1; }\n')
            def build(name, *flags):
                subprocess.run(['/usr/bin/clang', '-arch', 'arm64', *flags, '-o', str(root / name)], check=True, capture_output=True)
                return root / name
            portable = build('portable', '-mmacosx-version-min=13.0', str(source))
            future = build('future', '-mmacosx-version-min=99.0', str(source))
            dylib = build('libhost.dylib', '-dynamiclib', '-install_name', str(root / 'libhost.dylib'), str(library))
            linked = build('linked', '-mmacosx-version-min=13.0', str(source), str(dylib))
            vm._GUEST_MACOS.pop('test-vm', None)
            guest = subprocess.CompletedProcess([], 0, stdout='26.6.2\n')
            with patch.object(vm, 'guest', return_value=guest):
                vm.check_portable('test-vm', portable)
                with self.assertRaisesRegex(RuntimeError, 'requires macOS 99.0, but test-vm runs 26.6.2'):
                    vm.check_portable('test-vm', future)
                with self.assertRaisesRegex(RuntimeError, 'links host libraries'):
                    vm.check_portable('test-vm', linked)
            vm._GUEST_MACOS.pop('test-vm', None)

    def testCodeModeCompanionIsSynchronizedEvenWhenMainBinaryMatches(self):
        with tempfile.TemporaryDirectory(prefix='dispatch-codex-sync-') as temporary:
            binary = Path(temporary) / 'codex'
            binary.write_bytes(b'main binary')
            companion = binary.with_name('codex-code-mode-host')
            companion.write_bytes(b'code mode host')
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            current = subprocess.CompletedProcess([], 0, stdout=digest + ' codex\ncodex-cli current\n')
            with patch.object(vm, 'CODEX', binary), patch.object(vm, 'synchronize') as copy, patch.object(vm, 'guest', return_value=current):
                vm.sync_codex('test-vm')
                copy.assert_called_once_with('test-vm', [str(companion)], str(companion))

    def testCodexUpgradesAreCopiedAndVerifiedWhileMatchingBinaryIsReused(self):
        with tempfile.TemporaryDirectory(prefix='dispatch-codex-sync-') as temporary:
            binary = Path(temporary) / 'codex'
            binary.write_bytes(b'new binary')
            expected = hashlib.sha256(binary.read_bytes()).hexdigest()
            current = subprocess.CompletedProcess([], 0, stdout=expected + ' codex\ncodex-cli current\n')
            old = subprocess.CompletedProcess([], 0, stdout='old-hash codex\ncodex-cli old\n')
            with patch.object(vm, 'CODEX', binary), patch.object(vm, 'synchronize') as copy:
                with patch.object(vm, 'guest', return_value=current):
                    self.assertIn('codex-cli current', vm.sync_codex('test-vm'))
                    copy.assert_not_called()
                with patch.object(vm, 'guest', side_effect=[old, current]):
                    self.assertIn(expected, vm.sync_codex('test-vm'))
                    self.assertEqual(copy.call_count, 1)
                with patch.object(vm, 'guest', return_value=old):
                    with self.assertRaisesRegex(RuntimeError, 'does not match'):
                        vm.sync_codex('test-vm')

    def testChecksumsDeletionSymlinksAndUnchangedBuildTimestamps(self):
        with tempfile.TemporaryDirectory(prefix='dispatch-sync-') as temporary:
            base = Path(temporary)
            source, destination = base / 'source with spaces', base / 'guest'
            for directory in [source / 'Dispatch', source / 'helper/target', destination / 'build',
                              source / 'DispatchTests/LocalToolAudit', source / 'DispatchTests/Fixtures',
                              source / 'docs', destination / 'DispatchTests/LocalToolAudit', destination / 'docs']:
                directory.mkdir(parents=True)
            file = source / 'Dispatch/file with spaces.swift'
            file.write_text('old!')
            (source / 'Dispatch/link').symlink_to(file.name)
            (source / 'helper/target/generated').write_text('omit')
            (destination / 'build/keep').write_text('artifact')
            (source / 'DispatchTests/LocalToolAudit/private.jsonl').write_text('private conversation')
            (source / 'DispatchTests/Fixtures/rollout-private.jsonl').write_text('raw conversation')
            (source / 'DispatchTests/Fixtures/synthetic.jsonl').write_text('reviewed fixture')
            (source / 'docs/STEPS.md').write_text('private prompts')
            (destination / 'DispatchTests/LocalToolAudit/stale.jsonl').write_text('previous copy')
            (destination / 'docs/STEPS.md').write_text('previous prompts')
            original_run = subprocess.run

            def local_run(*command, **kwargs):
                command = list(command)
                index = command.index('-e')
                del command[index:index + 2]
                command[-1] = command[-1].split(':', 1)[1]
                return original_run(command, check=True, **kwargs)

            with patch.object(vm, 'ROOT', source), patch.object(vm, 'run', side_effect=local_run):
                def sync():
                    return vm.synchronize('test-vm', ['Dispatch', 'DispatchTests', 'helper', 'docs'], str(destination) + '/', relative=True)
                sync()
                copied = destination / 'Dispatch' / file.name
                self.assertEqual(copied.read_text(), 'old!')
                self.assertTrue((destination / 'Dispatch/link').is_symlink())
                self.assertFalse((destination / 'helper/target').exists())
                self.assertFalse((destination / 'DispatchTests/LocalToolAudit').exists())
                self.assertFalse((destination / 'DispatchTests/Fixtures/rollout-private.jsonl').exists())
                self.assertFalse((destination / 'docs/STEPS.md').exists())
                self.assertEqual((destination / 'DispatchTests/Fixtures/synthetic.jsonl').read_text(), 'reviewed fixture')
                before = copied.stat().st_mtime_ns
                sync()
                self.assertEqual(copied.stat().st_mtime_ns, before)
                metadata = file.stat()
                file.write_text('new!')
                os.utime(file, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
                os.utime(copied, (1, 1))
                sync()
                self.assertEqual(copied.read_text(), 'new!')
                self.assertGreater(copied.stat().st_mtime, 1)
                file.unlink()
                sync()
                self.assertFalse(copied.exists())
                self.assertEqual((destination / 'build/keep').read_text(), 'artifact')


class LinuxPairingTests(unittest.TestCase):
    def testProcessStatisticsUsesLinuxPairingOnlyForLinuxSelections(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(vm, 'ROOT', root), patch.object(vm, 'test_guest') as guest:
                mac = ['DispatchTests/SSHProcessStatisticsIntegrationTests/testMacOSFullProfileProcessRowsAndTerminalTraffic']
                vm.test('desktop', mac)
                guest.assert_called_once_with('desktop', mac, recheck=False, benchmarks=False)
                for selection in ['DispatchTests/SSHProcessStatisticsIntegrationTests',
                                  'DispatchTests/SSHProcessStatisticsIntegrationTests/testLinuxProcessRowsAndTerminalTraffic']:
                    with self.assertRaisesRegex(RuntimeError, 'Configure the existing Linux test server'):
                        vm.test('desktop', [selection])
                configuration = root / 'build/vm-tests/desktop-linux.json'
                configuration.parent.mkdir(parents=True)
                configuration.write_text(json.dumps({'provider': 'lima', 'server': 'linux-fixture', 'tools': {}}))
                with patch.object(vm, 'linux_connection') as connect:
                    vm.test('desktop', [selection])
                    connect.assert_called_once_with('desktop', 'linux-fixture', {})
                    guest.assert_called_with('desktop', [selection], linux=True, recheck=False, benchmarks=False, host_run={})

    def testLinuxWallTimingIncludesPairingAndCleanupEvenWhenTestsFail(self):
        for status, cleanup_failure in [(0, False), (65, False), (0, True)]:
            with self.subTest(status=status, cleanup_failure=cleanup_failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                config = root / 'build/vm-tests/desktop-linux.json'
                config.parent.mkdir(parents=True)
                config.write_text(json.dumps({'provider': 'lima', 'server': 'linux-fixture'}))
                clock = [0]
                output = root / 'run'
                (output / 'build').mkdir(parents=True)

                @contextmanager
                def connect(*args):
                    clock[0] = 3
                    try:
                        yield
                    finally:
                        clock[0] = 10
                        if cleanup_failure:
                            raise RuntimeError('relay cleanup failed')

                def guest(*args, host_run, **kwargs):
                    profile = Profile(root / 'profile/host.json')
                    profile.data.update(elapsed_seconds=5, exit_code=status)
                    profile.save()
                    host_run.update(profile=profile, output=output, started=3)
                    (output / 'build/TestTimings.json').write_text(json.dumps({'wall_seconds': 5, 'exit_code': status}))
                    clock[0] = 8
                    return status

                with patch.object(vm, 'ROOT', root), patch.object(vm, 'linux_connection', side_effect=connect), \
                        patch.object(vm, 'test_guest', side_effect=guest), patch.object(vm.time, 'perf_counter', side_effect=lambda: clock[0]):
                    if cleanup_failure:
                        with self.assertRaisesRegex(RuntimeError, 'relay cleanup failed'):
                            vm.test('desktop', ['SSHLinuxIntegrationTests'])
                    else:
                        self.assertEqual(vm.test('desktop', ['SSHLinuxIntegrationTests']), status)
                timing = json.loads((output / 'build/TestTimings.json').read_text())
                self.assertEqual(timing['wall_seconds'], 10)
                self.assertEqual(timing['guest_workflow_seconds'], 5)
                self.assertEqual(timing['exit_code'], 1 if cleanup_failure else status)
                self.assertEqual(timing['host_stages'], [
                    {'name': 'linux_preparation', 'status': 'passed', 'seconds': 3},
                    {'name': 'linux_cleanup', 'status': 'failed' if cleanup_failure else 'passed', 'seconds': 2}])
                self.assertEqual(json.loads((root / 'profile/TestTimings.json').read_text()), timing)

    def testManualVMIsRejectedBeforeAnyLaunch(self):
        with patch.object(vm, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'manual testing'):
                with vm.linux_connection('desktop', 'dispatch-manual-ssh'):
                    self.fail('The user VM must not be paired')
            run.assert_not_called()

    def testConfiguredManualVMIsRejectedBeforeAnyLaunch(self):
        with patch.object(vm, 'LOCAL_ENVIRONMENT', {'manual_ssh_vm': 'personal-ssh'}), \
                patch.object(vm, 'run') as run, \
                patch.object(vm.subprocess, 'check_output') as inspect:
            with self.assertRaisesRegex(RuntimeError, 'Reserve personal-ssh'):
                with vm.linux_connection('desktop', 'personal-ssh'):
                    self.fail('The configured user VM must not be paired')
            run.assert_not_called()
            inspect.assert_not_called()

    def testOldTartConfigurationRequiresExplicitMigration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            configuration = root / 'build/vm-tests/desktop-linux.json'
            configuration.parent.mkdir(parents=True)
            configuration.write_text(json.dumps({'server': 'old-tart'}))
            with patch.object(vm, 'ROOT', root), patch.object(vm, 'linux_connection') as connect:
                with self.assertRaisesRegex(RuntimeError, 'Re-pair'):
                    vm.test('desktop', [])
                connect.assert_not_called()

    def testFailedPairingRemovesExpiredProfilesAndClosesRelay(self):
        endpoint = {'name': 'agent-linux', 'sshConfigFile': '/fixture/config',
                    'hostname': 'fixture', 'sshAddress': '127.0.0.1', 'sshLocalPort': 12345}
        events = []

        @contextmanager
        def bridge(*args):
            events.append(('open', args))
            try:
                yield '192.0.2.1', 54321
            finally:
                events.append(('close',))

        with patch.object(vm, 'run') as run, patch.object(vm, 'start'), \
                patch.object(vm.subprocess, 'check_output', return_value=json.dumps(endpoint)), \
                patch.object(vm, 'ssh_bridge', side_effect=bridge), \
                patch.object(vm, 'linux_profile', side_effect=RuntimeError('missing tool')), \
                patch.object(vm, 'guest') as guest:
            with self.assertRaisesRegex(RuntimeError, 'missing tool'):
                with vm.linux_connection('desktop', 'agent-linux'):
                    self.fail('Missing dependencies must not run app tests')
            self.assertEqual(run.call_args.args[-1], 'agent-linux')
            self.assertTrue(run.call_args.args[-2].endswith('/scripts/ssh-vm.py'))
            guest.assert_called_once_with('desktop', '/bin/rm', '-f',
                vm.GUEST + '/linux-ssh.json', vm.GUEST + '/host-linux-ssh.json')
            self.assertEqual(events, [('open', ('desktop', '127.0.0.1', 12345)), ('close',)])


class BuildReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dispatch-build-cache-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        app = self.root / 'build/Build/Products/Debug/Dispatch.app'
        self.bundle = app / 'Contents/PlugIns/DispatchTests.xctest/test'
        self.bundle.parent.mkdir(parents=True)
        self.bundle.write_bytes(b'test binary')
        (self.root / 'build/Build/Products/Dispatch_macosx-arm64.xctestrun').write_text('plan')
        self.profile = Profile(self.root / 'build/profile.json')
        self.receipt = self.root / 'build/test-tools/xcode-build.json'

    def testVerifiedBuildReusedButChangedSourcesProductsModesAndRecheckRebuild(self):
        with patch.object(xcode, 'build_key', return_value='a') as key, patch.object(xcode.subprocess, 'run') as run:
            xcode.ensure_build(self.root, self.profile)
            xcode.ensure_build(self.root, self.profile)
            self.assertEqual(run.call_count, 1)
            key.return_value = 'b'
            xcode.ensure_build(self.root, self.profile)
            self.assertEqual(run.call_count, 2)
            self.bundle.write_bytes(b'changed binary')
            xcode.ensure_build(self.root, self.profile)
            self.assertEqual(run.call_count, 3)
            self.bundle.chmod(0o700)
            xcode.ensure_build(self.root, self.profile)
            self.assertEqual(run.call_count, 4)
            xcode.ensure_build(self.root, self.profile, force=True)
            self.assertEqual(run.call_count, 5)
            self.receipt.write_text('[]')
            xcode.ensure_build(self.root, self.profile)
            self.assertEqual(run.call_count, 6)

    def testFailedOrChangingBuildCannotLeaveReusableReceipt(self):
        with patch.object(xcode, 'build_key', return_value='a'), patch.object(xcode.subprocess, 'run'):
            xcode.ensure_build(self.root, self.profile)
        with patch.object(xcode, 'build_key', return_value='b'), \
                patch.object(xcode.subprocess, 'run', side_effect=subprocess.CalledProcessError(65, 'build')):
            with self.assertRaises(subprocess.CalledProcessError):
                xcode.ensure_build(self.root, self.profile)
        self.assertFalse(self.receipt.exists())
        with patch.object(xcode, 'build_key', side_effect=['before', 'after']), patch.object(xcode.subprocess, 'run'):
            with self.assertRaisesRegex(RuntimeError, 'changed during'):
                xcode.ensure_build(self.root, self.profile)
        self.assertFalse(self.receipt.exists())

    def testMovedTestScriptsAreTransferredAndInvalidateBuilds(self):
        self.assertIn('test', vm.SOURCES)
        source = self.root / 'test/ssh-helper.py'
        source.parent.mkdir()
        source.write_text('old!')
        before = xcode.fingerprint(self.root, xcode.INPUTS)
        metadata = source.stat()
        source.write_text('new!')
        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        self.assertNotEqual(before, xcode.fingerprint(self.root, xcode.INPUTS))

    def testFingerprintReadsContentsDeletionLinksAndResourceNames(self):
        source = self.root / 'Dispatch/source.swift'
        source.parent.mkdir()
        source.write_text('aaaa')
        key = lambda: xcode.fingerprint(self.root, ['Dispatch'])
        first, metadata = key(), source.stat()
        source.write_text('bbbb')
        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        self.assertNotEqual(first, key())
        first = key()
        source.rename(source.with_name('renamed.swift'))
        self.assertNotEqual(first, key())
        (source.parent / 'link').symlink_to('renamed.swift')
        first = key()
        (source.parent / 'link').unlink()
        self.assertNotEqual(first, key())
        first = key()
        source.with_name('renamed.swift').unlink()
        self.assertNotEqual(first, key())

    def testMissingProductsAndAmbiguousPlanCannotBeReused(self):
        self.bundle.unlink()
        self.bundle.parent.rmdir()
        self.assertIsNone(xcode.products(self.root))
        self.bundle.parent.mkdir()
        self.bundle.write_text('restored')
        (self.root / 'build/Build/Products/Dispatch_other.xctestrun').write_text('other')
        self.assertIsNone(xcode.products(self.root))

    def testEmptySkippedFailedAndMalformedSummariesAreRejected(self):
        summary = self.root / 'summary.json'
        for total, passed, failed, skipped, expected in [(1, 1, 0, 0, True), (0, 0, 0, 0, False),
                                                       (1, 0, 0, 1, False), (1, 0, 1, 0, False)]:
            summary.write_text(json.dumps(dict(totalTestCount=total, passedTests=passed, failedTests=failed, skippedTests=skipped)))
            self.assertEqual(xcode.validate_summary(summary), expected)
        for malformed in ['{}', '[]', 'null']:
            summary.write_text(malformed)
            with self.assertRaises(ValueError):
                xcode.validate_summary(summary)


class SelectionTests(unittest.TestCase):
    def testInventoryIgnoresCommentsAndQuotedFixtureDeclarations(self):
        source = '''
final class RealTests: XCTestCase {
    // func testLineComment() {}
    /* outer comment
    /* nested */
    func testBlockComment() {}
    */
    let text = "/* not a comment */"
    func testAfterQuotedComment() {}
    let fixture = #"""
class FakeTests: XCTestCase {
    func testString() {}
}
"""#
    func testAfterRawString() {}
}
/* class WrongTests: XCTestCase {} */
extension RealTests {
    func testExtension() {}
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'DispatchTests').mkdir()
            (root / 'DispatchTests/RealTests.swift').write_text(source)
            self.assertEqual(inventory(root), ['DispatchTests/RealTests/testAfterQuotedComment',
                                              'DispatchTests/RealTests/testAfterRawString',
                                              'DispatchTests/RealTests/testExtension'])

    def testBenchmarksAreOptInForNamedSuitesAndExactForExplicitTarget(self):
        correctness = resolve(suite='full')['selected']
        self.assertFalse(any(matches(case, BENCHMARKS) for case in correctness))
        with_benchmarks = resolve(benchmarks=True)['selected']
        self.assertTrue(any(matches(case, BENCHMARKS) for case in with_benchmarks))
        explicit = resolve(['DispatchTests'])['selected']
        self.assertEqual(explicit, inventory())
        for name in ['UIBenchmarkTests', 'TerminalFPSBenchmarkTests']:
            with self.subTest(benchmark=name):
                selected_benchmark = resolve([name])['selected']
                self.assertTrue(selected_benchmark)
                self.assertTrue(all(matches(case, ['DispatchTests/' + name]) for case in selected_benchmark))
                self.assertEqual(set(selected_benchmark) & set(correctness), set())
                self.assertLessEqual(set(selected_benchmark), set(with_benchmarks))

    def testShortSelectorsPreserveExactCasesAndDeduplicate(self):
        self.assertEqual(normalize(['ChatTests', 'DispatchTests/ChatTests', 'ChatTests/testOne()']),
                         ['DispatchTests/ChatTests', 'DispatchTests/ChatTests/testOne'])
        for value in ['--help', 'ChatTests/', '../outside', 'a/b/c/d']:
            with self.assertRaises(ValueError):
                normalize([value])

    def testFailedSelectionRejectsEmptyAndIncompleteFailures(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'TestSummary.json'
            path.write_text(json.dumps({'testFailures': [{'targetName': 'DispatchTests',
                                                        'testIdentifierString': 'ChatTests/testOne()'}]}))
            self.assertEqual(failed_tests(root), ['DispatchTests/ChatTests/testOne'])
            path.write_text(json.dumps({'testFailures': []}))
            with self.assertRaisesRegex(ValueError, 'no failed'):
                failed_tests(path)
            path.write_text(json.dumps({'testFailures': [{'targetName': 'Other'}]}))
            with self.assertRaises(ValueError):
                failed_tests(path)


class SuiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'DispatchTests').mkdir()
        (self.root / 'test').mkdir()
        (self.root / 'DispatchTests/MixedTests.swift').write_text("""
@MainActor final class MixedTests: XCTestCase {
    func testComponent() {}
    func testLive() {}
    func testStress() {}
    func testNew() {}
}
final class UIBenchmarkTests: XCTestCase {
    func testMeasurement() {}
}
""")
        self.component = 'DispatchTests/MixedTests/testComponent'
        self.live = 'DispatchTests/MixedTests/testLive'
        self.stress = 'DispatchTests/MixedTests/testStress'
        self.new = 'DispatchTests/MixedTests/testNew'
        self.measurement = 'DispatchTests/UIBenchmarkTests/testMeasurement'
        self.manifest = {'version': 1, 'cases': {self.component: 'fast', self.live: 'full', self.stress: 'exhaustive'}}
        (self.root / 'test/suites.json').write_text(json.dumps(self.manifest))

    def select(self, *args, **kwargs):
        return resolve(*args, **kwargs, root=self.root)

    def testDefaultFastAndUnclassifiedCasesStayInFullAndExhaustive(self):
        self.assertEqual(self.select()['selected'], [self.component])
        self.assertEqual(self.select(suite='full')['selected'], [self.component, self.live, self.new])
        self.assertEqual(self.select(suite='exhaustive')['selected'], sorted([self.component, self.live, self.new, self.stress]))
        self.assertIn(self.new, self.select()['unclassified'])
        self.assertEqual(self.select(benchmarks=True)['suite'], 'full')
        self.assertIn(self.measurement, self.select(benchmarks=True)['selected'])

    def testExplicitSelectionIsExactIncludingBenchmarksAndStress(self):
        self.assertEqual(self.select(['MixedTests/testStress'])['selected'], [self.stress])
        self.assertEqual(self.select(['UIBenchmarkTests'])['selected'], [self.measurement])
        self.assertEqual(self.select(['DispatchTests'])['selected'], inventory(self.root))
        self.assertEqual(self.select(['MixedTests'], skips=['MixedTests/testNew'])['selected'],
                         sorted([self.component, self.live, self.stress]))

    def testConflictingUnknownEmptyAndStaleSelectionsFailClosed(self):
        for kwargs in [dict(tests=['MixedTests'], suite='full'), dict(suite='fast', benchmarks=True),
                       dict(tests=['MixedTests/testTypo']), dict(skips=['Typo']),
                       dict(skips=['MixedTests']), dict(suite='unknown')]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.select(**kwargs)
        self.manifest['cases']['DispatchTests/DeletedTests/testOld'] = 'fast'
        (self.root / 'test/suites.json').write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'Stale'):
            self.select()

    def testAllEntrypointsListTheSameSelectionWithoutDependencies(self):
        root = Path(__file__).resolve().parent.parent
        outputs = []
        for entry in [[sys.executable, 'test/xcode.py'], [sys.executable, 'test/vm.py', 'test'],
                      ['/bin/bash', 'test/run.sh'], ['/bin/bash', 'test/vm-guest.sh']]:
            result = subprocess.run(entry + ['--list'], cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs.append(result.stdout)
        self.assertTrue(all(output == outputs[0] for output in outputs))
        result = subprocess.run([sys.executable, 'test/vm.py', 'test', '--failed', 'unused', '--suite', 'fast'],
                                cwd=root, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--failed cannot be combined', result.stderr)

    def testCurrentInventoryMatchesEverySavedBaselineCaseAndBenchmarks(self):
        root = Path(__file__).resolve().parent.parent
        baseline = json.loads((root / 'test/baseline-timings.json').read_text())
        current = inventory(root)
        self.assertTrue({case['identifier'] for case in baseline['cases']} <= set(current))
        exhaustive = set(resolve(suite='exhaustive')['selected'])
        self.assertTrue({case['identifier'] for case in baseline['cases']} <= exhaustive)
        # Baseline failures remain in full; none is hidden by classification.
        full = resolve(suite='full')['selected']
        for case in baseline['cases']:
            if case['outcome'] != 'Passed':
                self.assertIn(case['identifier'], full)

    def testFastVMSelectionDoesNotPairLinux(self):
        selection = self.select()
        with patch.object(vm, 'ROOT', self.root), patch.object(vm, 'test_guest', return_value=0) as guest, \
                patch.object(vm, 'linux_connection') as linux:
            self.assertEqual(vm.test('desktop', [], selection=selection), 0)
            linux.assert_not_called()
            guest.assert_called_once_with('desktop', [], recheck=False, benchmarks=False, selection=selection)

    def testFastSourcePreparationDoesNotSynchronizeAgentCLI(self):
        profile = Profile(self.root / 'profile.json')
        with patch.object(vm, 'synchronize', return_value='copied') as source, patch.object(vm, 'sync_codex') as cli:
            vm.prepare_test_inputs('desktop', profile, needs_codex=False)
            source.assert_called_once()
            cli.assert_not_called()

    def testFailedAndIncompleteResultsStillExportTimingsAndNeverPass(self):
        selection = self.select()
        for outcome, identifier, status, expected in [('Passed', self.component, 0, 0),
                ('Failed', self.component, 65, 65), ('Passed', self.live, 0, 1),
                ('Skipped', self.component, 0, 1), (None, None, 65, 65), (None, None, 0, 1)]:
            def run(command, **kwargs):
                if command[0] == 'xcodebuild':
                    if identifier is not None:
                        (self.root / 'build/TestResults.xcresult').mkdir()
                    return subprocess.CompletedProcess(command, status)
                if command[4] == 'summary':
                    value = dict(totalTestCount=1, passedTests=int(outcome == 'Passed'),
                                 failedTests=int(outcome == 'Failed'), skippedTests=int(outcome == 'Skipped'))
                else:
                    value = {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': identifier,
                                           'durationInSeconds': 1.5, 'result': outcome}]}
                json.dump(value, kwargs['stdout'])
                return subprocess.CompletedProcess(command, 0)
            with self.subTest(outcome=outcome, identifier=identifier), \
                    patch.object(xcode, 'ensure_build', return_value=self.root / 'test.xctestrun') as build, \
                    patch.object(xcode, 'fingerprint', return_value='source'), \
                    patch.object(xcode.platform, 'platform', return_value='fixture OS'), \
                    patch.object(xcode.subprocess, 'check_output', return_value='Xcode fixture'), \
                    patch.object(xcode.subprocess, 'run', side_effect=run):
                self.assertEqual(xcode.execute(self.root, [], selection=selection), expected)
                build.assert_called_once_with(self.root, unittest.mock.ANY, force=False)
                timing = json.loads((self.root / 'build/TestTimings.json').read_text())
                if outcome is None:
                    self.assertEqual(timing['cases'], [])
                else:
                    self.assertEqual(timing['cases'][0]['outcome'], outcome)
                self.assertEqual(timing['complete'], identifier == self.component)
                self.assertEqual(sum(stage['name'] == 'xctest' for stage in timing['stages']), 1)

    def testBuildFailureStillWritesTimingsWithoutStartingXCTest(self):
        selection = self.select()
        with patch.object(xcode, 'ensure_build', side_effect=subprocess.CalledProcessError(65, ['xcodebuild'])), \
                patch.object(xcode, 'fingerprint', return_value='source'), \
                patch.object(xcode.platform, 'platform', return_value='fixture OS'), \
                patch.object(xcode.subprocess, 'check_output', return_value='Xcode fixture'), \
                patch.object(xcode.subprocess, 'run') as run:
            self.assertEqual(xcode.execute(self.root, [], selection=selection), 65)
            run.assert_not_called()
        timing = json.loads((self.root / 'build/TestTimings.json').read_text())
        self.assertFalse(timing['complete'])
        self.assertEqual(timing['cases'], [])
        self.assertEqual(timing['missing_identifiers'], [self.component])
        self.assertIn('65', timing['runner_error'])

    def testFixtureLeaksFailAnOtherwisePassingSuiteAndKeepResults(self):
        for resources in [dict(processes={}, packages=[]),
                          dict(processes={}, packages=['owned/packages']),
                          dict(processes={123: 'owned/packages/codex'}, packages=['owned/packages'])]:
            with self.subTest(resources=resources):
                home = self.root / 'owned/codex-home'
                def run(command, **kwargs):
                    if command[0] == 'xcodebuild':
                        ledger = Path(kwargs['env']['TEST_RUNNER_DISPATCH_TEST_FIXTURES'])
                        self.assertEqual(ledger.read_text(), '')
                        ledger.write_text(json.dumps(str(home)) + '\n' + json.dumps(str(home)) + '\n')
                        (self.root / 'build/TestResults.xcresult').mkdir()
                    else:
                        value = (dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
                                 if command[4] == 'summary' else {'testNodes': [{'nodeType': 'Test Case',
                                     'nodeIdentifier': self.component, 'durationInSeconds': 1, 'result': 'Passed'}]})
                        json.dump(value, kwargs['stdout'])
                    return subprocess.CompletedProcess(command, 0)
                with patch.object(xcode, 'ensure_build', return_value=self.root / 'test.xctestrun'), \
                        patch.object(xcode, 'fingerprint', return_value='source'), \
                        patch.object(xcode.subprocess, 'check_output', return_value='Xcode fixture'), \
                        patch.object(xcode.platform, 'platform', return_value='fixture OS'), \
                        patch.object(xcode.subprocess, 'run', side_effect=run), \
                        patch.object(xcode.codex_fixture, 'resources', return_value=resources) as audit:
                    self.assertEqual(xcode.execute(self.root, [], selection=self.select()),
                                     int(any(resources.values())))
                audit.assert_called_once_with([str(home)])
                self.assertEqual(json.loads((self.root / 'build/TestFixtureResources.json').read_text()),
                                 json.loads(json.dumps(resources)))
                timing = json.loads((self.root / 'build/TestTimings.json').read_text())
                self.assertTrue(timing['complete'])
                self.assertEqual(timing['cases'][0]['outcome'], 'Passed')

    def testTimingCompletenessRejectsMissingRepeatedAndUnexpectedCases(self):
        selection = self.select()
        case = {'identifier': self.component, 'seconds': 1, 'outcome': 'Passed'}
        for cases in [[], [case, case], [{**case, 'identifier': self.live}]]:
            self.assertFalse(report(selection, cases, 'source', {}, [])['complete'])
        with self.assertRaises(ValueError):
            cases_from_result({})
        base = {'suite': 'baseline', 'cases': [case]}
        current = {'suite': 'full', 'cases': [case, {**case, 'identifier': self.live}]}
        comparison = compare(current, base)
        self.assertFalse(comparison['same_selection'])
        self.assertEqual(comparison['added_identifiers'], [self.live])


class PreparationTests(unittest.TestCase):
    def testIndependentTransfersOverlapAndBothFinishBeforeFailureEscapes(self):
        with tempfile.TemporaryDirectory() as root:
            profile = Profile(Path(root) / 'profile.json')
            barrier = threading.Barrier(2, timeout=3)
            finished = threading.Event()
            def source(*args, **kwargs):
                barrier.wait()
                raise RuntimeError('source failed')
            def cli(*args):
                barrier.wait()
                finished.set()
                return 'version'
            with patch.object(vm, 'synchronize', side_effect=source), patch.object(vm, 'sync_codex', side_effect=cli):
                with self.assertRaisesRegex(RuntimeError, 'source failed'):
                    vm.prepare_test_inputs('test-vm', profile)
            self.assertTrue(finished.is_set())
            result = json.loads(profile.path.read_text())
            self.assertEqual({s['name']: s['status'] for s in result['stages']},
                             {'source_sync': 'failed', 'codex_sync': 'passed'})

    def testParallelProfilesRemainCompleteAndPreserveExplicitFailure(self):
        with tempfile.TemporaryDirectory() as root:
            profile = Profile(Path(root) / 'profile.json')
            def work(index):
                with profile.stage(str(index)) as stage:
                    if index == 0:
                        stage['status'] = 'failed'
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(work, range(24)))
            saved = json.loads(profile.path.read_text())
            self.assertEqual(len(saved['stages']), 24)
            self.assertEqual(sum(s['status'] == 'failed' for s in saved['stages']), 1)


class ShardTests(unittest.TestCase):
    CASES = ['DispatchTests/A/testOne', 'DispatchTests/A/testTwo', 'DispatchTests/B/testOne',
             'DispatchTests/C/testOne', 'DispatchTests/SSHLinuxIntegrationTests/testLinux',
             'DispatchTests/SSHProcessStatisticsIntegrationTests/testLocal']

    def testPlanKeepsClassesWholeCoversEveryCaseAndPinsLinuxToPrimary(self):
        durations = {'DispatchTests/A/testOne': 50, 'DispatchTests/A/testTwo': 50, 'DispatchTests/B/testOne': 60,
                     'DispatchTests/C/testOne': 40, 'DispatchTests/SSHLinuxIntegrationTests/testLinux': 30}
        groups, loads = shards.plan(self.CASES, 2, durations, primary_overhead=20)
        self.assertEqual(groups, shards.plan(list(reversed(self.CASES)), 2, durations, primary_overhead=20)[0])
        self.assertEqual(sorted(name for group in groups for name in group),
                         sorted({shards.class_of(case) for case in self.CASES}))
        self.assertIn('DispatchTests/SSHLinuxIntegrationTests', groups[0])
        self.assertIn('DispatchTests/SSHProcessStatisticsIntegrationTests', groups[0])
        # Primary starts at 20 + 30 + 50 (median fallback); A then C fill the second VM.
        self.assertEqual(groups, [['DispatchTests/B', 'DispatchTests/SSHLinuxIntegrationTests',
                                   'DispatchTests/SSHProcessStatisticsIntegrationTests'],
                                  ['DispatchTests/A', 'DispatchTests/C']])
        self.assertEqual(loads, [160, 140])

    def testRestrictedSelectionKeepsSuiteAndExcludesOtherShard(self):
        selection = {'suite': 'full', 'selected': self.CASES, 'excluded': {'DispatchTests/D/testSlow': 'exhaustive coverage'},
                     'unclassified': ['DispatchTests/B/testOne', 'DispatchTests/C/testOne']}
        restricted = shards.restrict(selection, ['DispatchTests/A', 'DispatchTests/C'])
        self.assertEqual(restricted['suite'], 'full')
        self.assertEqual(restricted['selected'], ['DispatchTests/A/testOne', 'DispatchTests/A/testTwo', 'DispatchTests/C/testOne'])
        self.assertEqual(restricted['excluded']['DispatchTests/B/testOne'], shards.EXCLUDED)
        self.assertEqual(restricted['excluded']['DispatchTests/D/testSlow'], 'exhaustive coverage')
        self.assertEqual(restricted['unclassified'], ['DispatchTests/C/testOne'])
        for classes in [[], ['DispatchTests/Missing'], ['A'], ['DispatchTests/A/testOne']]:
            with self.subTest(classes=classes), self.assertRaises(ValueError):
                shards.restrict(selection, classes)

    def testMergedResultsRejectMissingOrRepeatedCasesAndKeepFailuresSelectable(self):
        selection = {'suite': 'full', 'selected': self.CASES[:3], 'excluded': {}}
        first = {'complete': True, 'cases': [{'identifier': case, 'seconds': 1, 'outcome': 'Passed'} for case in self.CASES[:2]]}
        second = {'complete': True, 'cases': [{'identifier': self.CASES[2], 'seconds': 1, 'outcome': 'Failed'}]}
        self.assertTrue(shards.merge_timings(selection, [first, second])['complete'])
        self.assertEqual(shards.merge_timings(selection, [first])['missing_identifiers'], [self.CASES[2]])
        self.assertFalse(shards.merge_timings(selection, [first, second, second])['complete'])
        self.assertFalse(shards.merge_timings(selection, [first, {**second, 'complete': False}])['complete'])
        summaries = [{'totalTestCount': 2, 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0, 'result': 'Passed',
                      'testFailures': [], 'startTime': 5, 'finishTime': 9},
                     {'totalTestCount': 1, 'passedTests': 0, 'failedTests': 1, 'skippedTests': 0, 'result': 'Failed',
                      'testFailures': [{'targetName': 'DispatchTests', 'testIdentifierString': 'B/testOne()'}],
                      'startTime': 4, 'finishTime': 12}]
        merged = shards.merge_summaries(summaries)
        self.assertEqual((merged['totalTestCount'], merged['failedTests'], merged['result']), (3, 1, 'Failed'))
        self.assertEqual((merged['startTime'], merged['finishTime']), (4, 12))
        with tempfile.TemporaryDirectory() as root:
            (Path(root) / 'TestSummary.json').write_text(json.dumps(merged))
            self.assertEqual(failed_tests(root), ['DispatchTests/B/testOne'])

    def testGuestSelectionHonorsShardEnvironmentWithoutInvalidatingBuilds(self):
        with patch.dict(os.environ, {'DISPATCH_TEST_SHARD': 'DispatchTests/ChatTests'}), \
                patch.object(sys, 'argv', ['xcode.py', '--suite', 'full', '--list']), \
                patch('builtins.print') as output:
            self.assertEqual(xcode.main(), 0)
        listed = [call.args[0] for call in output.call_args_list if call.args and call.args[0].startswith('DispatchTests/')]
        self.assertTrue(listed)
        self.assertTrue(all(case.startswith('DispatchTests/ChatTests/') for case in listed))
        with patch.object(xcode.subprocess, 'check_output', return_value='Xcode'), \
                patch.object(xcode, 'fingerprint', return_value='inputs'), patch.object(xcode, 'files', return_value=[]), \
                patch.object(xcode.platform, 'platform', return_value='macOS'):
            unsharded = xcode.build_key(xcode.ROOT)
            with patch.dict(os.environ, {'DISPATCH_TEST_SHARD': 'DispatchTests/ChatTests', 'DISPATCH_TEST_SHARD_PRIMARY': '0'}):
                self.assertEqual(xcode.build_key(xcode.ROOT), unsharded)

    def testChildRunnersReceiveTheParentSelectionAndDisjointRoles(self):
        commands = []

        class Process:
            def __init__(self, command, **kwargs):
                commands.append(command)
                self.stdout = iter(['done\n'])
            def wait(self):
                return 0

        selection = resolve([], [], 'full', False, vm.ROOT)
        args = type('Args', (), {'selection': selection, 'tests': [], 'suite': 'full', 'skip': ['DispatchTests/ChatTests'],
                                 'recheck': True, 'benchmarks': False})()
        with tempfile.TemporaryDirectory() as root, patch.object(vm, 'ROOT', Path(root)), \
                patch.object(vm, 'run'), \
                patch.object(vm, 'host_lock', side_effect=lambda *a, **k: contextmanager(lambda: (yield))()), \
                patch.object(vm.shards, 'history', return_value=({}, None)), \
                patch.object(vm.subprocess, 'Popen', side_effect=Process), patch('builtins.print'):
            groups, loads = vm.shard_plan('first', selection)
            self.assertEqual(vm.test_sharded('first', 'second', args, groups, loads), 1)  # No shard results were written.
        self.assertEqual([command[command.index('--vm') + 1] for command in commands], ['first', 'second'])
        self.assertEqual([command[command.index('--shard-role') + 1] for command in commands], ['primary', 'secondary'])
        for command in commands:
            self.assertEqual(command[command.index('--suite') + 1], 'full')
            self.assertEqual(command[command.index('--skip') + 1], 'DispatchTests/ChatTests')
            self.assertIn('--recheck', command)
            self.assertIn('--host-ready', command)
        groups = [set(command[command.index('--shard-classes') + 1].split(',')) for command in commands]
        self.assertFalse(groups[0] & groups[1])
        self.assertEqual(groups[0] | groups[1], {shards.class_of(case) for case in selection['selected']})



class ShardCapacityTests(unittest.TestCase):
    GB = shards.GIB
    PRIMARY, SHARD, LINUX = ('dispatch-tests', 8 * GB, 4), ('dispatch-tests-2', 8 * GB, 4), ('linux', 1 * GB, 1)

    def testHostsKeepAReserveAndCountFullVMAllocations(self):
        cases = [
            # (RAM, free now, CPUs, running, starting, safe)
            (64, 40, 18, [self.PRIMARY, self.LINUX], [self.SHARD], True),
            (64, 60, 18, [], [self.PRIMARY, self.SHARD, self.LINUX], True),
            (64, 60, 18, [self.PRIMARY, self.SHARD, self.LINUX], [], True),  # Already running: nothing to boot.
            (64, 10, 18, [self.PRIMARY, self.LINUX], [self.SHARD], False),  # Busy host: too little free now.
            (64, 60, 18, [self.PRIMARY, self.LINUX, ('other', 32 * self.GB, 4)], [self.SHARD], False),
            (32, 20, 12, [self.PRIMARY, self.LINUX], [self.SHARD], True),
            (24, 20, 12, [self.PRIMARY, self.LINUX], [self.SHARD], False),
            (16, 16, 10, [self.PRIMARY, self.LINUX], [self.SHARD], False),  # Lazy VM memory looks free; still refused.
            (16, 16, 10, [], [self.PRIMARY, self.SHARD], False),
            (32, 30, 8, [self.PRIMARY, self.LINUX], [self.SHARD], False),  # 9 VM CPUs on 8 cores.
        ]
        for total, free, cpus, running, starting, safe in cases:
            with self.subTest(total=total, free=free, cpus=cpus, running=running, starting=starting):
                reason = shards.capacity(total * self.GB, free * self.GB, cpus, running, starting)
                self.assertEqual(reason is None, safe, reason)
        self.assertEqual(shards.host_reserve(16 * self.GB), 8 * self.GB)
        self.assertEqual(shards.host_reserve(64 * self.GB), 16 * self.GB)

    def testOnlyWorthwhileSelectionsShardAutomatically(self):
        self.assertTrue(shards.worthwhile([['A'], ['B']], [600, 590]))
        self.assertFalse(shards.worthwhile([['A'], ['B']], [600, 60]))
        self.assertFalse(shards.worthwhile([['A'], []], [600, 0]))

    def decide(self, total, required=False, exists=True, cases=None, free=None, seconds=300):
        """Run choose_shards against a simulated host with both VMs defined, primary running."""
        cases = cases or [f'DispatchTests/Class{index}/testCase' for index in range(8)]
        selection = {'suite': 'full', 'selected': cases, 'excluded': {}, 'unclassified': []}
        listed = [{'Name': 'first', 'Running': True}, {'Name': 'second', 'Running': False}]
        def fake_run(*command, **kwargs):
            if command[:2] == ('tart', 'list'):
                return subprocess.CompletedProcess(command, 0, stdout=json.dumps(listed))
            if command[:2] == ('tart', 'get'):
                return subprocess.CompletedProcess(command, 0, stdout=json.dumps({'Memory': 8192, 'CPU': 4}))
            if command[0] == '/usr/sbin/sysctl':
                value = {'hw.memsize': total * self.GB, 'hw.ncpu': 12,
                         'kern.memorystatus_level': 95 if free is None else free}[command[-1]]
                return subprocess.CompletedProcess(command, 0, stdout=str(value) + '\n')
            raise AssertionError(command)
        durations = {case: seconds for case in cases}
        with patch.object(vm, 'run', side_effect=fake_run), patch.object(vm.shutil, 'which', side_effect=lambda name: name == 'tart'), \
                patch.object(vm, 'info', side_effect=lambda name: {'Running': name == 'first'} if exists or name == 'first' else None), \
                patch.object(vm.shards, 'history', return_value=(durations, None)), \
                patch.object(vm, 'host_lock', side_effect=lambda *a, **k: contextmanager(lambda: (yield))()):
            return vm.choose_shards('first', 'second', selection, required=required)

    def testAutomaticDecisionUsesTwoVMsOnlyWhenSafeAndUseful(self):
        groups, loads, reason = self.decide(64)
        self.assertIsNone(reason)
        self.assertTrue(all(groups))
        self.assertEqual(self.decide(16)[:2], (None, None))
        self.assertIn('reserving 8 GB of 16 GB', self.decide(16)[2])
        self.assertIn('is free', self.decide(64, free=15)[2])  # About 10 GB free: another app holds memory.
        self.assertIn('does not exist', self.decide(64, exists=False)[2])
        self.assertIn('too small', self.decide(64, cases=['DispatchTests/A/testOne', 'DispatchTests/B/testOne'], seconds=30)[2])
        self.assertIn('fits one VM', self.decide(64, cases=['DispatchTests/A/testOne'])[2])

    def testRequiredShardingFailsInsteadOfOvercommitting(self):
        with self.assertRaisesRegex(RuntimeError, 'Cannot run --shards 2: .*16 GB'):
            self.decide(16, required=True)
        groups, _, reason = self.decide(64, required=True, cases=['DispatchTests/A/testOne', 'DispatchTests/B/testOne'], seconds=30)
        self.assertIsNone(reason)  # An explicit request skips only the benefit threshold.
        self.assertEqual(len(groups), 2)


if __name__ == '__main__':
    unittest.main()
