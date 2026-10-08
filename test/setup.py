#!/usr/bin/env python3
"""Offline tests for pinned, project-local build dependencies and entry points."""
import importlib.util
import hashlib
import copy
import gzip
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
import io
import json
import tempfile
import shutil
import select
import signal
import time
import tarfile
import zipfile
from unittest.mock import Mock, call, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
import setup_consent as consent
import run as launcher

spec = importlib.util.spec_from_file_location('setup_tools', Path(__file__).resolve().parent.parent / 'scripts/setup-build-tools.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.downloads, self.executions = [], []
        self.payloads, self.lock, self.contents = {}, {}, {}
        for name, version, suffix, output in [('tool', '0.16.0', '.tar.gz', '0.16.0'),
                                              ('xcodegen', '2.46.0', '.zip', 'Version: 2.46.0')]:
            binary = 'package/bin/' + name
            content = ('#!/bin/sh\nprintf \'%s\\n\' \'' + output + '\'\n').encode()
            self.contents[name] = content
            payload = self.archive(suffix, binary, content)
            url = 'https://example.invalid/' + name + suffix
            self.payloads[url] = payload
            artifact = {'url': url, 'sha256': hashlib.sha256(payload).hexdigest(), 'binary': binary}
            self.lock[name] = {'version': version, 'check': ['version' if name == 'tool' else '--version'],
                               'banner': output.replace(version, '{version}'),
                               'archives': {'arm64': artifact, 'x86_64': artifact}}
        run = subprocess.run
        def invoke(command, **kwargs):
            if command[0] == 'curl':
                url = next(arg for arg in command if arg.startswith('https://'))
                self.downloads.append(url)
                Path(command[command.index('-o') + 1]).write_bytes(self.payloads[url])
                return subprocess.CompletedProcess(command, 0)
            executable = Path(command[0])
            if not executable.is_relative_to(self.root / 'build/tools'):
                raise AssertionError('Setup tried to execute an external tool: ' + str(command))
            self.executions.append((executable.name, executable.read_bytes()))
            return run(command, **kwargs)
        for patcher in (patch.dict(os.environ, {}, clear=True),
                        patch.object(setup, 'ROOT', self.root, create=True),
                        patch.object(setup, 'LOCK', self.lock, create=True),
                        patch.object(setup.platform, 'machine', return_value='arm64'),
                        patch.object(setup, 'confirm'),
                        patch.object(setup.subprocess, 'run', side_effect=invoke)):
            patcher.start(); self.addCleanup(patcher.stop)

    def archive(self, suffix, name, content):
        stream = io.BytesIO()
        if suffix == '.zip':
            with zipfile.ZipFile(stream, 'w') as bundle:
                member = zipfile.ZipInfo(name)
                member.external_attr = 0o100755 << 16
                bundle.writestr(member, content)
            return stream.getvalue()
        with tarfile.open(fileobj=stream, mode='w') as bundle:
            member = tarfile.TarInfo(name)
            member.mode, member.size = 0o755, len(content)
            bundle.addfile(member, io.BytesIO(content))
        return gzip.compress(stream.getvalue(), mtime=0)

    def files(self):
        return sorted(str(path.relative_to(self.root)) for path in self.root.rglob('*') if path.is_file())

    def testOfflineMissingToolNeverInstalls(self):
        for name in self.lock:
            with self.assertRaisesRegex(RuntimeError, 'Missing compatible'):
                setup.resolve(name, offline=True)
        self.assertEqual((self.downloads, self.executions, self.files()), ([], [], []))

    def testVerifiedToolsAreInstalledLocallyAndReusedOffline(self):
        for name in self.lock:
            artifact = self.lock[name]['archives']['arm64']
            expected = self.root / 'build/tools' / name / artifact['sha256'] / artifact['binary']
            self.assertEqual(setup.resolve(name), expected)
            self.assertEqual(setup.resolve(name, offline=True), expected)
            self.assertEqual(expected.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.downloads, [self.lock[name]['archives']['arm64']['url'] for name in self.lock])
        self.assertEqual(self.executions, [(name, self.contents[name]) for name in self.lock for _ in range(2)])

    def testChecksumMismatchNeverExtractsOrExecutes(self):
        for name in self.lock:
            artifact = self.lock[name]['archives']['arm64']
            self.payloads[artifact['url']] = b'corrupt archive'
            with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
                setup.resolve(name)
        self.assertEqual((self.executions, self.files()), ([], []))

    def testSourceBuildsPublishOnlyVerifiedExecutables(self):
        for failure in (True, False):
            with self.subTest(failure=failure):
                content = ('#!' + sys.executable + '\nimport sys\nfrom pathlib import Path\n'
                           'root = Path(sys.argv[1])\n(root / "bin").mkdir()\n'
                           '(root / "bin/tool").write_bytes((root / "payload").read_bytes())\n'
                           '(root / "bin/tool").chmod(0o755)\n'
                           'raise SystemExit(' + str(int(failure)) + ')\n').encode()
                artifact = self.lock['tool']['archives']['arm64']
                payload = self.archive('.tar.gz', 'builder', content)
                self.payloads[artifact['url']] = payload
                artifact.update(sha256=hashlib.sha256(payload).hexdigest(), binary='bin/tool')
                extra = self.archive('.zip', 'payload', self.contents['tool'])
                url = 'https://example.invalid/source.zip'
                self.payloads[url] = extra
                self.lock['tool']['sources'] = [{'url': url, 'sha256': hashlib.sha256(extra).hexdigest()}]
                self.lock['tool']['build'] = [{'directory': '.', 'commands': [['{stage}/builder', '{stage}']]}]
                if failure:
                    with self.assertRaises(subprocess.CalledProcessError):
                        setup.resolve('tool')
                    self.assertEqual(list((self.root / 'build/tools/tool').iterdir()), [])
                else:
                    binary = setup.resolve('tool')
                    self.assertEqual((binary.read_bytes(), setup.resolve('tool', offline=True)),
                                     (self.contents['tool'], binary))
                    self.lock['tool']['sources'][0]['sha256'] = '0' * 64
                    with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
                        setup.resolve('tool')

    def testInterruptedDownloadsAreNotPublished(self):
        def interrupted(command, **kwargs):
            Path(command[command.index('-o') + 1]).write_bytes(b'partial')
            raise subprocess.CalledProcessError(28, command)
        with patch.object(setup.subprocess, 'run', side_effect=interrupted):
            with self.assertRaises(subprocess.CalledProcessError):
                setup.resolve('tool')
        self.assertEqual((self.executions, self.files()), ([], []))

    def testSourceBuildWorkerCountUsesCpuCountOrExplicitOverride(self):
        invoke = setup.subprocess.run.side_effect
        builds = []
        def run(command, **kwargs):
            if command[0] == '/usr/bin/make':
                builds.append(command)
                return subprocess.CompletedProcess(command, 0)
            return invoke(command, **kwargs)
        self.lock['tool']['build'] = [{'directory': '.', 'commands': [['/usr/bin/make', '-j{jobs}']]}]
        for index, (cpus, override, expected) in enumerate([(8, None, '8'), (None, None, '1'), (8, '3', '3')]):
            environment = {} if override is None else {'DISPATCH_BUILD_JOBS': override}
            with self.subTest(cpus=cpus, override=override), \
                    patch.object(setup, 'ROOT', self.root / 'build/tools' / str(index)), \
                    patch.object(setup.os, 'cpu_count', return_value=cpus), \
                    patch.dict(os.environ, environment, clear=True), \
                    patch.object(setup.subprocess, 'run', side_effect=run):
                self.assertTrue(setup.resolve('tool').is_file())
                self.assertEqual(builds[-1], ['/usr/bin/make', '-j' + expected])

    def testDownloadIndicatorIsCompactAndUpdatesBeforeCompletion(self):
        staged = self.root / ('long-package-name-' * 4 + '.tar.gz')
        staged.write_bytes(b'x' * 1048576)
        output = io.StringIO()
        with patch.dict(os.environ, DISPATCH_SETUP_TTY='1'), patch.object(setup.sys, 'stderr', output):
            with setup.download_progress(staged):
                deadline = time.monotonic() + 2
                while '\r' not in output.getvalue() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertIn('1.0 MB', output.getvalue())
                self.assertNotIn('✓', output.getvalue())
        self.assertIn('✓ 1.0 MB', output.getvalue())
        self.assertNotIn('#', output.getvalue())
        self.assertTrue(all(len(line) <= 52 for line in output.getvalue().splitlines()))

    def testDownloadFailurePreservesCurlDiagnostic(self):
        error = subprocess.CalledProcessError(28, ['curl'], stderr='curl: transfer timed out\n')
        output = io.StringIO()
        with patch.object(setup.subprocess, 'run', side_effect=error), \
                patch.object(setup.sys, 'stderr', output):
            with self.assertRaises(subprocess.CalledProcessError):
                setup.resolve('tool')
        self.assertIn('✗', output.getvalue())
        self.assertIn('curl: transfer timed out', output.getvalue())
        self.assertEqual(self.files(), [])

    def testGlobalOverridesCannotBypassPinnedTools(self):
        for name in self.lock:
            with patch.dict(os.environ, {name.upper(): '/global/bin/' + name}):
                with self.assertRaisesRegex(RuntimeError, 'project-local'):
                    setup.resolve(name)
        self.assertEqual((self.downloads, self.executions, self.files()), ([], [], []))
        # Every tmux session exports $TMUX (its socket); it is not a tmux binary override.
        self.lock['tmux'] = self.lock['tool']
        with patch.dict(os.environ, {'TMUX': '/private/tmp/tmux-501/default,123,0'}):
            self.assertTrue(setup.resolve('tmux').is_file())

    def testUnsupportedArchitectureNeverDownloads(self):
        with patch.object(setup.platform, 'machine', return_value='unsupported'):
            with self.assertRaisesRegex(RuntimeError, 'Unsupported'):
                setup.resolve('tool')
        self.assertEqual((self.downloads, self.executions, self.files()), ([], [], []))

    def testCachedArchivesAreRecheckedAndOfflineNeverDownloads(self):
        artifact = self.lock['tool']['archives']['arm64']
        cache = self.root / 'cache'
        archive = setup.download(artifact, cache)
        self.assertEqual(setup.download(artifact, cache, offline=True), archive)
        archive.write_bytes(b'corrupt cache')
        with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
            setup.download(artifact, cache, offline=True)
        with self.assertRaisesRegex(RuntimeError, 'Offline'):
            setup.download(self.lock['xcodegen']['archives']['arm64'], cache, offline=True)
        self.assertEqual(self.downloads, [artifact['url']])

    def testCompatibilityChecksActualVersionAndExitCode(self):
        for name, correct in [('tool', '0.16.0'), ('xcodegen', 'Version: 2.46.0')]:
            for output, code, expected in [(correct + '\n', 0, True), ('wrong\n', 0, False), (correct, 1, False)]:
                with self.subTest(name=name, output=output, code=code), patch.object(setup.subprocess, 'run',
                        return_value=subprocess.CompletedProcess([], code, stdout=output)):
                    self.assertEqual(setup.compatible('/tool', name), expected)

    def testExtractionRejectsTraversalBeforeWritingFiles(self):
        for suffix in ('.zip', '.tar.gz'):
            archive = self.root / ('unsafe' + suffix)
            archive.write_bytes(self.archive(suffix, '../outside', b'escape'))
            destination = self.root / 'extracted'
            destination.mkdir(exist_ok=True)
            with self.assertRaisesRegex(RuntimeError, 'archive member'):
                setup.extract(archive, destination)
            self.assertEqual((list(destination.iterdir()), (self.root / 'outside').exists()), ([], False))

    def testExtractionPreservesSourceTimestampsAndModes(self):
        for suffix, expected in [('.tar.gz', 0), ('.zip', time.mktime((1980, 1, 1, 0, 0, 0, 0, 0, -1)))]:
            archive = self.root / ('source' + suffix)
            archive.write_bytes(self.archive(suffix, 'generated', b'fixture'))
            destination = self.root / ('extracted' + suffix)
            destination.mkdir()
            setup.extract(archive, destination)
            info = (destination / 'generated').stat()
            self.assertEqual((info.st_mtime, info.st_mode & 0o777), (expected, 0o755))

    def testExtractionPreservesContainedSymlinks(self):
        for suffix in ('.zip', '.tar'):
            archive = self.root / ('contained' + suffix)
            if suffix == '.zip':
                with zipfile.ZipFile(archive, 'w') as bundle:
                    link = zipfile.ZipInfo('link')
                    link.external_attr = 0o120777 << 16
                    bundle.writestr(link, 'target')
                    bundle.writestr('target', 'fixture')
            else:
                with tarfile.open(archive, 'w') as bundle:
                    link = tarfile.TarInfo('link')
                    link.type, link.linkname = tarfile.SYMTYPE, 'target'
                    bundle.addfile(link)
                    member = tarfile.TarInfo('target')
                    member.size = 7
                    bundle.addfile(member, io.BytesIO(b'fixture'))
            destination = self.root / ('extracted' + suffix)
            destination.mkdir()
            setup.extract(archive, destination)
            self.assertEqual({p.name: (p.is_symlink(), p.read_text()) for p in destination.iterdir()},
                             {'link': (True, 'fixture'), 'target': (False, 'fixture')})

    def testExtractionRejectsEscapingLinksAndSpecialFiles(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE):
            archive = self.root / 'unsafe.tar'
            with tarfile.open(archive, 'w') as bundle:
                member = tarfile.TarInfo('link')
                member.type, member.linkname = kind, '../outside'
                bundle.addfile(member)
            destination = self.root / 'extracted'
            destination.mkdir(exist_ok=True)
            with self.assertRaisesRegex(RuntimeError, 'archive member'):
                setup.extract(archive, destination)
            self.assertEqual(list(destination.iterdir()), [])

    def testDeclinedSetupDoesNotDownloadOrWrite(self):
        setup.confirm.side_effect = RuntimeError('cancelled')
        with self.assertRaisesRegex(RuntimeError, 'cancelled'):
            setup.resolve('tool')
        self.assertEqual((self.downloads, self.executions, self.files()), ([], [], []))

    def testCustomLockInstallsArchivesAndRawBinariesWithOneApproval(self):
        installer = consent.load_script('setup-test-tools')
        lock = copy.deepcopy(self.lock)
        artifact = lock['tool']['archives']['arm64']
        artifact['format'] = 'binary'
        self.payloads[artifact['url']] = self.contents['tool']
        artifact['sha256'] = hashlib.sha256(self.contents['tool']).hexdigest()
        with patch.object(installer, 'ROOT', self.root), patch.object(installer, 'LOCK', lock), \
                patch.object(installer, 'tools', setup), \
                patch.object(sys, 'stdin', io.StringIO('yes\n')), \
                patch.object(installer, 'show_consent') as prompt:
            installer.prepare()
            first = list(self.downloads)
            links = self.root / 'build/test-tools/bin'
            self.assertEqual({p.name: (p.is_symlink(), p.read_bytes()) for p in links.iterdir()},
                             {name: (True, body) for name, body in self.contents.items()})
            self.assertTrue(all(not os.path.isabs(os.readlink(p)) for p in links.iterdir()))
            installer.prepare(offline=True)
            self.assertEqual(self.downloads, first)
            self.assertEqual(len(first), 2)
            self.assertEqual(sum('[y/N]' in call.args[0] for call in prompt.call_args_list), 1)
        setup.confirm.assert_not_called()

    def testTestToolsDeclineAndOfflineNeverDownloadOrPublish(self):
        installer = consent.load_script('setup-test-tools')
        with patch.object(installer, 'ROOT', self.root), patch.object(installer, 'LOCK', self.lock), \
                patch.object(installer, 'tools', setup), patch.object(installer, 'show_consent'):
            for answer, offline, message in [('no\n', False, 'cancelled'), ('yes\n', True, './run.sh --test')]:
                with self.subTest(offline=offline), patch.object(sys, 'stdin', io.StringIO(answer)):
                    with self.assertRaisesRegex(RuntimeError, message):
                        installer.prepare(offline=offline)
                    self.assertEqual((self.downloads, self.executions, self.files()), ([], [], []))

    def testTestToolsDryRunDescribesActionsWithoutRunningOrWriting(self):
        installer = consent.load_script('setup-test-tools')
        with patch.object(installer, 'ROOT', self.root), patch.object(installer, 'LOCK', self.lock), \
                patch.object(installer, 'tools', setup), patch.object(sys, 'stdout', io.StringIO()) as output, \
                patch.object(sys, 'stdin', io.StringIO('')):
            installer.prepare(dry_run=True)
        expected = []
        for name, record in self.lock.items():
            expected += [f'Download {record["archives"]["arm64"]["url"]} (SHA-256 {record["archives"]["arm64"]["sha256"]})',
                         f'Install {name} {record["version"]} under {self.root / "build/tools" / name}',
                         f'Link {self.root / "build/test-tools/bin" / name} to the installed binary']
        self.assertEqual((output.getvalue().splitlines(), self.downloads, self.executions, self.files()),
                         (expected, [], [], []))

    def testRawBinaryChecksumAndVersionFailuresAreNotPublished(self):
        lock = copy.deepcopy(self.lock)
        artifact = lock['tool']['archives']['arm64']
        artifact['format'] = 'binary'
        self.payloads[artifact['url']] = self.contents['tool']
        approve = Mock()
        with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
            setup.resolve('tool', lock=lock, approve=approve)
        self.assertEqual(self.executions, [])
        artifact['sha256'] = hashlib.sha256(self.contents['tool']).hexdigest()
        lock['tool']['version'] = 'wrong'
        with self.assertRaisesRegex(RuntimeError, 'Pinned archive did not provide'):
            setup.resolve('tool', lock=lock, approve=approve)
        self.assertEqual(list((self.root / 'build/tools/tool').iterdir()), [])


class BuildEntryPointTests(unittest.TestCase):
    """Exercise real shell entry points with no builds, installs or app restarts."""
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        source = Path(__file__).resolve().parent.parent / 'scripts'
        for name in ('build.sh', 'run.py', 'generate-project.py', 'build-ssh-helper.sh', 'setup_consent.py', 'build.lock.json'):
            shutil.copyfile(source / name, scripts / name)
        shutil.copyfile(source.parent / 'run.sh', self.root / 'run.sh')
        self.log = self.root / 'calls'
        (scripts / 'setup.sh').write_text(
            'echo "setup ${DISPATCH_SETUP_OFFLINE:-unset}" >> "$CALLS"\nexit "${SETUP_EXIT:-0}"\n')
        (scripts / 'build-ssh-helper.py').write_text(
            'import os\nfrom pathlib import Path\n'
            'with Path(os.environ["CALLS"]).open("a") as log: log.write("helper\\n")\n'
            'raise SystemExit(int(os.environ.get("HELPER_EXIT", "0")))\n')
        binaries = self.root / 'bin'
        binaries.mkdir()
        stubs = {
            'python3': 'if [[ "$1" == scripts/setup-build-tools.py ]]; then echo "$STUB_BIN/xcodegen"; '
                       'else exec "$REAL_PYTHON" "$@"; fi',
            'xcodegen': 'echo generate >> "$CALLS"',
            'xcodebuild': 'echo "build $*" >> "$CALLS"; '
                          'for setting in "$@"; do case "$setting" in '
                          'DISPATCH_HELPER_BUILD_COMPLETE=*) export "$setting";; esac; done; '
                          'bash scripts/build-ssh-helper.sh || exit $?; echo "compiler detail"; '
                          'echo "compiler diagnostic" >&2; exit "${BUILD_EXIT:-0}"',
            'pkill': 'echo stop >> "$CALLS"; exit 1',
            'pgrep': 'exit "${APP_RUNNING:-1}"',
            'open': 'echo "open $*" >> "$CALLS"',
        }
        for name, body in stubs.items():
            binary = binaries / name
            binary.write_text('#!/bin/bash\n' + body + '\n')
            binary.chmod(0o755)
        self.env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                        CALLS=str(self.log), STUB_BIN=str(binaries), REAL_PYTHON=sys.executable)
        self.env.pop('DISPATCH_SETUP_OFFLINE', None)
        self.env.pop('CONFIGURATION', None)

    def invoke(self, name, *args, input_text=None, **environment):
        self.log.write_text('')
        entry = self.root / ('run.sh' if name == 'root' else 'scripts/' + name)
        self.result = subprocess.run(['bash', str(entry), *args], cwd=self.root.parent,
                                     env=dict(self.env, **environment), capture_output=True, text=True,
                                     input=input_text)
        return self.result.returncode, self.log.read_text().splitlines()

    def testEntryPointsPrepareOnceWithTheirExpectedDownloadPolicy(self):
        for name, args, offline in [('root', (), '0'), ('root', ('--prod',), '0'), ('build.sh', (), '1')]:
            with self.subTest(name=name, args=args):
                code, calls = self.invoke(name, *args)
                self.assertEqual(code, 0)
                self.assertEqual([line for line in calls if line.startswith('setup ')], ['setup ' + offline])
                self.assertEqual(sum(line.startswith('build ') for line in calls), 1)
                configuration = 'Release' if args == ('--prod',) else 'Debug'
                self.assertTrue(any(f'-configuration {configuration}' in line for line in calls))
                self.assertEqual(any(line.startswith('open ') for line in calls), name == 'root')

    def testLauncherDoesNotWritePythonCachesOutsideProject(self):
        cache = self.root.parent / (self.root.name + '-bytecode')
        self.addCleanup(lambda: shutil.rmtree(cache, ignore_errors=True))
        # Apple Python uses a user cache prefix; reproduce that on every host.
        self.env.pop('PYTHONDONTWRITEBYTECODE', None)
        code, _ = self.invoke('root', '--help', PYTHONPYCACHEPREFIX=str(cache))
        self.assertEqual((code, cache.exists()), (0, False))

    def testExplicitTestModeForwardsSelectionAndExitStatusWithoutLaunching(self):
        tests = self.root / 'test'
        tests.mkdir()
        (tests / 'run.sh').write_text('echo "tests ${DISPATCH_TEST_SETUP:-unset} $*" >> "$CALLS"\nexit 7\n')
        for args in [(), ('--suite', 'full'), ('--help',), ('--list',), ('ChatTests', '--skip', 'OtherTests')]:
            with self.subTest(args=args):
                code, calls = self.invoke('root', '--test', *args)
                self.assertEqual((code, calls), (7, ['tests 1 ' + ' '.join(args)]))
                self.assertFalse((self.root / 'build').exists())

    def testTestRunnerValidatesSelectionBeforePreparingTools(self):
        tests = self.root / 'test'
        tests.mkdir()
        source = Path(__file__).resolve().parent
        shutil.copyfile(source / 'run.sh', tests / 'run.sh')
        (tests / 'xcode.py').write_text(
            'import os, sys\nfrom pathlib import Path\n'
            'with Path(os.environ["CALLS"]).open("a") as log: log.write("tests " + " ".join(sys.argv[1:]) + "\\n")\n'
            'raise SystemExit(2 if "invalid" in sys.argv else 0)\n')
        (self.root / 'scripts/setup-test-tools.py').write_text(
            'import os\nfrom pathlib import Path\n'
            'with Path(os.environ["CALLS"]).open("a") as log: log.write("tools\\n")\n'
            'raise SystemExit(int(os.environ.get("TOOLS_EXIT", "0")))\n')
        for option, status in [('--help', 0), ('--list', 0), ('invalid', 2)]:
            code, calls = self.invoke('root', '--test', option)
            expected = ['tests --list ' + option] + (['tests ' + option] if status == 0 else [])
            self.assertEqual((code, calls, (self.root / 'build').exists()), (status, expected, False))
        code, calls = self.invoke('root', '--test', 'ChatTests')
        self.assertEqual((code, calls), (0, ['tests --list ChatTests', 'setup unset', 'tools', 'generate', 'tests ChatTests']))
        code, calls = self.invoke('root', '--test', 'ChatTests', TOOLS_EXIT='9')
        self.assertEqual((code, calls), (9, ['tests --list ChatTests', 'setup unset', 'tools']))
        code, calls = self.invoke('root', '--test', 'ChatTests', DISPATCH_SETUP_OFFLINE='1')
        self.assertEqual((code, calls), (0, ['tests --list ChatTests', 'setup 1', 'tools', 'generate', 'tests ChatTests']))

    def testOfflineOverrideIsPreservedInBothModes(self):
        for args in ((), ('--prod',)):
            code, calls = self.invoke('root', *args, DISPATCH_SETUP_OFFLINE='1')
            self.assertEqual(code, 0)
            self.assertEqual(calls[0], 'setup 1')

    def testHelperAndAppHaveSeparateStagesInOneBuild(self):
        code, calls = self.invoke('root', '--just-build')
        self.assertEqual(code, 0, self.result.stderr)
        self.assertEqual(calls.count('helper'), 1)
        self.assertEqual(sum(line.startswith('build ') for line in calls), 1)
        helper = self.result.stdout.index('✓ Building dsptch helper for SSH')
        app = self.result.stdout.index('✓ Building Dispatch macOS app')
        self.assertLess(helper, app)
        self.assertFalse(list((self.root / 'build/logs').glob('.progress-*')))

    def testBuildFailuresReportTheCurrentStage(self):
        for failure, stage in [('HELPER_EXIT', 'Building dsptch helper for SSH'),
                               ('BUILD_EXIT', 'Building Dispatch macOS app')]:
            with self.subTest(failure=failure):
                code, calls = self.invoke('root', **{failure: '7'})
                self.assertEqual(code, 7)
                self.assertIn('✗ ' + stage, self.result.stdout)
                self.assertNotIn('stop', calls)
                self.assertFalse(any(line.startswith('open ') for line in calls))
                if failure == 'HELPER_EXIT':
                    self.assertNotIn('Building Dispatch macOS app', self.result.stdout)
                self.assertFalse(list((self.root / 'build/logs').glob('.progress-*')))

    def testSetupAndBuildFailureLeaveRunningAppAlone(self):
        for failure in ('SETUP_EXIT', 'BUILD_EXIT'):
            code, calls = self.invoke('root', **{failure: '7'})
            self.assertEqual(code, 7)
            self.assertNotIn('stop', calls)
            self.assertFalse(any(line.startswith('open ') for line in calls))
            if failure == 'SETUP_EXIT':
                self.assertEqual(calls, ['setup 0'])

    def testConfigurationFlagsBuildAndLaunchTheirConfiguration(self):
        for flags, configuration in [((), 'Debug'), (('--prod',), 'Release'), (('--production',), 'Release'),
                                     (('-p',), 'Release'), (('--debug',), 'Debug'), (('-d',), 'Debug')]:
            with self.subTest(flags=flags):
                environment = {'CONFIGURATION': 'Release' if configuration == 'Debug' else 'Debug'}
                code, calls = self.invoke('root', *flags, **(environment if flags else {}))
                self.assertEqual(code, 0, self.result.stderr)
                self.assertTrue(any(f'-configuration {configuration}' in line for line in calls))
                self.assertNotIn('stop', calls)
                self.assertEqual(calls[-1], f'open {self.root.resolve()}/build/Build/Products/{configuration}/Dispatch.app')
        code, _ = self.invoke('root', '--debug', '--prod')
        self.assertEqual(code, 2)

    def testRunningAppIsNeverStoppedOrReopened(self):
        code, calls = self.invoke('root', APP_RUNNING='0')
        self.assertEqual(code, 0, self.result.stderr)
        self.assertNotIn('stop', calls)
        self.assertFalse(any(line.startswith('open ') for line in calls))
        self.assertIn('already running', self.result.stdout)

    def testJustBuildLeavesRunningAppAloneInBothConfigurations(self):
        for args, configuration in [(('--just-build',), 'Debug'),
                                    (('--prod', '--just-build'), 'Release'),
                                    (('--just-build', '--production'), 'Release'),
                                    (('-d', '--just-build'), 'Debug')]:
            with self.subTest(args=args):
                code, calls = self.invoke('root', *args)
                self.assertEqual(code, 0, self.result.stderr)
                self.assertTrue(any(f'-configuration {configuration}' in line for line in calls))
                self.assertNotIn('stop', calls)
                self.assertFalse(any(line.startswith('open ') for line in calls))

    def testSuccessfulOutputIsCompactAndFullLogsAreRetained(self):
        for _ in range(2):
            code, _ = self.invoke('root', '-p')
            self.assertEqual(code, 0, self.result.stderr)
            self.assertNotIn('compiler detail', self.result.stdout)
            self.assertNotIn('compiler diagnostic', self.result.stderr)
            self.assertNotIn('\033', self.result.stdout)
            self.assertIn('Ready', self.result.stdout)
        logs = self.root / 'build/logs'
        self.assertEqual(len(list(logs.glob('20*.log'))), 2)
        self.assertTrue((logs / 'latest.log').is_symlink())
        contents = (logs / 'latest.log').read_text()
        self.assertIn('compiler detail', contents)
        self.assertIn('compiler diagnostic', contents)

    def testFailureReportsDiagnosticAndLog(self):
        code, _ = self.invoke('root', BUILD_EXIT='7')
        self.assertEqual(code, 7)
        self.assertIn('compiler diagnostic', self.result.stderr)
        self.assertIn('Full log:', self.result.stderr)
        self.assertNotIn('Ready', self.result.stdout)

    def testLongCompilerCommandsDoNotFloodFailureOutput(self):
        binary = self.root / 'bin/xcodebuild'
        binary.write_text('#!/bin/bash\nprintf "%02000d\\n" 0\nexit 7\n')
        code, _ = self.invoke('root', '-p')
        self.assertEqual(code, 7)
        self.assertLess(len(self.result.stderr), 1000)
        self.assertIn('0' * 2000, (self.root / 'build/logs/latest.log').read_text())

    def testHelpAndInvalidArgumentsNeverBuild(self):
        for arguments, expected in [(('--help',), 0), (('--unknown',), 2)]:
            code, calls = self.invoke('root', *arguments)
            self.assertEqual(code, expected)
            self.assertEqual(calls, [])
            self.assertFalse((self.root / 'build').exists())
            if arguments == ('--help',):
                for flag in ('--prod', '--production', '-p', '--just-build'):
                    self.assertIn(flag, self.result.stdout)

    def testCleanRemovesGeneratedFilesThenBuildsWithSelectedOptions(self):
        for relative in launcher.CLEAN_PATHS:
            target = self.root / relative
            target.mkdir(parents=True)
            (target / 'old-cache').write_text('old cache')
        source = self.root / 'Dispatch/main.swift'
        source.parent.mkdir()
        source.write_text('source stays')
        project = self.root / 'Dispatch.xcodeproj/project.pbxproj'
        project.parent.mkdir()
        project.write_text('tracked project stays')
        code, calls = self.invoke('root', '--clean', '--prod', '--just-build')
        self.assertEqual(code, 0, self.result.stderr)
        self.assertEqual(source.read_text(), 'source stays')
        self.assertEqual(project.read_text(), 'tracked project stays')
        self.assertFalse(list(self.root.rglob('old-cache')))
        self.assertTrue((self.root / 'build/logs/latest.log').is_file())
        self.assertEqual(calls[0], 'setup 0')
        self.assertTrue(any('-configuration Release' in line for line in calls))
        self.assertFalse(any(line.startswith('open ') for line in calls))
        self.assertIn('Clean complete', self.result.stdout)

    def testCleanUnlinksCacheSymlinkWithoutDeletingItsDestination(self):
        with tempfile.TemporaryDirectory() as external:
            destination = Path(external)
            (destination / 'keep').write_text('external cache')
            (self.root / 'build').symlink_to(destination, target_is_directory=True)
            code, _ = self.invoke('root', '--clean', '--just-build')
            self.assertEqual(code, 0, self.result.stderr)
            self.assertEqual((destination / 'keep').read_text(), 'external cache')
            self.assertFalse((self.root / 'build').is_symlink())

    def testCleanRejectsExternalParentBeforeDeletingAnyCache(self):
        with tempfile.TemporaryDirectory() as external:
            (self.root / 'Helpers').symlink_to(external, target_is_directory=True)
            cache = self.root / 'build/keep'
            cache.parent.mkdir()
            cache.write_text('cache')
            code, calls = self.invoke('root', '--clean')
            self.assertEqual(code, 1)
            self.assertEqual(calls, [])
            self.assertEqual(cache.read_text(), 'cache')
            self.assertIn('Refusing to clean', self.result.stderr)

    def testCleanWithHelpDoesNotRemoveCaches(self):
        cache = self.root / 'build/keep'
        cache.parent.mkdir()
        cache.write_text('cache')
        code, calls = self.invoke('root', '--clean', '--help')
        self.assertEqual((code, calls), (0, []))
        self.assertEqual(cache.read_text(), 'cache')
        self.assertIn('--clean', self.result.stdout)

    def testConfigurationOverrideStillLaunchesMatchingApp(self):
        code, calls = self.invoke('root', CONFIGURATION='Release')
        self.assertEqual(code, 0)
        self.assertTrue(any('-configuration Release' in line for line in calls))
        self.assertTrue(any('Release/Dispatch.app' in line for line in calls if line.startswith('open ')))

    def testSetupPromptRemainsVisibleAndReadsOriginalStdin(self):
        source = Path(__file__).resolve().parent.parent / 'scripts'
        for name in ('setup_consent.py', 'build.lock.json'):
            shutil.copyfile(source / name, self.root / 'scripts' / name)
        (self.root / 'scripts/setup.sh').write_text(
            'set -e\ncd "$(dirname "$0")/.."\n'
            'python3 -c \'import sys; sys.path.insert(0, "scripts"); '
            'from setup_consent import confirm; confirm(["rust"])\'\n'
            'echo "Installing dependencies"\n'
            'echo "Download progress" >&2\n')
        for answer, expected in [('yes\n', 0), ('no\n', 1), ('', 1)]:
            code, calls = self.invoke('root', '-p', input_text=answer)
            self.assertEqual(code, expected, self.result.stderr)
            self.assertIn('Install/download ALL dependencies listed above? [y/N]', self.result.stdout)
            self.assertEqual(self.result.stdout.count('Install/download ALL dependencies listed above? [y/N]'), 1)
            for message in ('Installing dependencies', 'Download progress'):
                self.assertEqual(message in self.result.stdout, expected == 0)
                self.assertEqual(message in (self.root / 'build/logs/latest.log').read_text(), expected == 0)
            self.assertEqual(any(line.startswith('build ') for line in calls), expected == 0)

    def testSetupProgressIsVisibleBeforeProcessFinishes(self):
        (self.root / 'scripts/setup.sh').write_text(
            'python3 -c \'import sys; print("Installing Rust", end=""); '
            'sys.stderr.write("Downloading 50%\\r"); sys.stdin.readline()\'\n')
        process = subprocess.Popen(['bash', str(self.root / 'run.sh'), '--just-build'],
                                   cwd=self.root, env=self.env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output = b''
        try:
            deadline = time.monotonic() + 10
            while b'Downloading 50%\r' not in output:
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0, output)
                self.assertTrue(select.select([process.stdout], [], [], remaining)[0], output)
                chunk = os.read(process.stdout.fileno(), 65536)
                self.assertTrue(chunk, output)
                output += chunk
            self.assertIn(b'Installing Rust', output)
            self.assertIsNone(process.poll())
            _, errors = process.communicate(b'\n', timeout=10)
            self.assertEqual(process.returncode, 0, errors)
            log = (self.root / 'build/logs/latest.log').read_bytes()
            self.assertIn(b'Installing RustDownloading 50%\r', log)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def testSetupCompilationReusesOneTerminalLine(self):
        output = io.StringIO()
        with patch.object(launcher.sys, 'stdout', output):
            display = launcher.SetupOutput(terminal=True)
            for character in 'Install dependencies? [y/N] ':
                display.write(character)
            self.assertEqual(output.getvalue(), 'Install dependencies? [y/N] ')
            display.write('\n')
            start = len(output.getvalue())
            for character in '    … Compiling renderer\n':
                display.write(character)
            for number in range(100):
                display.write(f'Compiling source {number}\n')
            display.write('compiler command ' + 'x' * 300)
            display.finish()
        activity = output.getvalue()[start:]
        self.assertNotIn('\n', activity)
        self.assertIn('Compiling source 99', activity)
        self.assertNotIn('x' * 100, activity)
        self.assertTrue(activity.endswith('\r\033[2K'))

    def testSetupCompilerDetailsStayInLogWhenOutputIsRedirected(self):
        (self.root / 'scripts/setup.sh').write_text(
            'echo "    … Compiling renderer"\n'
            'for i in {1..100}; do echo "compiler detail $i"; done\n'
            'echo "    ✓ Compiling renderer"\n')
        code, _ = self.invoke('root', '--just-build')
        self.assertEqual(code, 0, self.result.stderr)
        self.assertIn('… Compiling renderer', self.result.stdout)
        self.assertIn('✓ Compiling renderer', self.result.stdout)
        self.assertNotIn('compiler detail', self.result.stdout)
        log = (self.root / 'build/logs/latest.log').read_text()
        for number in range(1, 101):
            self.assertIn(f'compiler detail {number}\n', log)

    def testCancellationSignalsOnlyItsOwnLiveChild(self):
        """Cancelling a step stops its child without Popen's wait lock, and never signals a PID its child
        gave up. An interrupt inside Popen.poll can leave that lock held (CPython): the child must still
        stop; one ignoring SIGTERM gets SIGKILL after 3 s. An interrupt right after poll reaped the
        child: its PID may already be another process's, so nothing may be signaled. Simulated through
        CPython's private Popen._waitpid_lock and a recording os.kill / os.killpg (which only really
        signals while the child is alive)."""
        driver = '\n'.join([
            'import json, os, signal, subprocess, sys',
            f'sys.path.insert(0, {str(Path(__file__).resolve().parent.parent / "scripts")!r})',
            'import run',
            'scenario, interactive = sys.argv[1], sys.argv[2] == "1"',
            'real_poll, children, signals = subprocess.Popen.poll, [], []',
            'def poll(self):',
            '    children.append(self.pid)',
            '    if scenario != "reaped":',
            '        scenario == "locked" and self._waitpid_lock.acquire()',
            '        raise KeyboardInterrupt',
            '    if real_poll(self) is not None:',
            '        raise KeyboardInterrupt',
            'def recording(real):',
            '    return lambda pid, sig: (signals.append(sig), scenario != "reaped" and real(pid, sig))',
            'subprocess.Popen.poll, os.kill, os.killpg = poll, recording(os.kill), recording(os.killpg)',
            'signal.signal(signal.SIGTERM, signal.SIG_IGN if scenario == "stubborn" else signal.SIG_DFL)   # inherited by the child',
            'try:',
            '    run.BuildUI(open(os.devnull, "w")).step("build", ["true"] if scenario == "reaped" else ["sleep", "30"], dict(os.environ), interactive=interactive)',
            'except KeyboardInterrupt:',
            '    pass',
            'try:',
            '    os.getpgid(children[0])   # no process left under that PID: stopped and reaped',
            '    alive = True',
            'except ProcessLookupError:',
            '    alive = False',
            'print(json.dumps({"signaled": bool(signals), "alive": alive}))'])
        for scenario, interactive in [('locked', '0'), ('locked', '1'), ('stubborn', '0'), ('reaped', '0'), ('reaped', '1')]:
            with self.subTest(scenario=scenario, interactive=interactive):
                result = subprocess.run([sys.executable, '-c', driver, scenario, interactive], capture_output=True, text=True,
                                        timeout=10, stdin=subprocess.DEVNULL)
                self.assertEqual(json.loads(result.stdout.splitlines()[-1]),
                                 {'signaled': scenario != 'reaped', 'alive': False}, result.stderr)

    def testCancellationStopsBuildChildrenAndDoesNotLaunch(self):
        pid_file = self.root / 'child.pid'
        (self.root / 'bin/xcodebuild').write_text(
            '#!/bin/bash\nexec "$REAL_PYTHON" -c \'import os, subprocess, time; '
            'from pathlib import Path; child = subprocess.Popen(["sleep", "30"]); '
            'Path(os.environ["CHILD_PID"]).write_text(str(child.pid)); time.sleep(30)\'\n')
        for interrupt, expected in [(signal.SIGINT, 130), (signal.SIGTERM, 143)]:
            self.log.write_text('')
            pid_file.unlink(missing_ok=True)
            process = subprocess.Popen(['bash', str(self.root / 'run.sh')], cwd=self.root,
                                       env=dict(self.env, CHILD_PID=str(pid_file)),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(lambda process=process: process.kill() if process.poll() is None else None)
            deadline = time.monotonic() + 10
            while not pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pid_file.exists(), 'Build did not start')
            child = int(pid_file.read_text())
            process.send_signal(interrupt)
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, expected)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                os.kill(child, signal.SIGKILL)
                self.fail('Build child survived cancellation')
            self.assertNotIn('stop', self.log.read_text())
            self.assertNotIn('open ', self.log.read_text())


class SourceRulesTests(unittest.TestCase):
    def testAppStoresPersistOnlyThroughTheAppDefaults(self):
        # The test host is the app itself (same bundle identifier): a store reaching
        # UserDefaults.standard directly writes the user's own defaults from tests.
        pattern = re.compile(r'UserDefaults\.standard|UserDefaults\??\s*=\s*\.standard|@AppStorage\(')
        found = [f'{path.relative_to(consent.ROOT)}:{number}' for path in sorted((consent.ROOT / 'Dispatch').rglob('*.swift'))
                 for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]
        self.assertEqual(found, [], 'use UserDefaults.app (nil while testing)')

    def testAppFilesLiveUnderTheAppHome(self):
        # The same for files: Dispatch's own and the agent homes it installs hooks into.
        pattern = re.compile(r'applicationSupportDirectory|NSHomeDirectory\(\)\)?\s*\+\s*"/'
                             r'|ProcessInfo\.processInfo\.environment\["(CODEX_HOME|CLAUDE_CONFIG_DIR|PI_CODING_AGENT_DIR)"\]')
        found = [f'{path.relative_to(consent.ROOT)}:{number}' for path in sorted((consent.ROOT / 'Dispatch').rglob('*.swift'))
                 for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]
        self.assertEqual(found, [], 'use Home (a fresh home while testing)')

    def testOnlyHomeMovesTheChildrenHome(self):
        # Children inherit this process's environment: only Home changes where their homes are.
        pattern = re.compile(r'\b(setenv|unsetenv)\("(HOME|CODEX_HOME|CLAUDE_CONFIG_DIR|PI_CODING_AGENT_DIR)"')
        files = sorted((consent.ROOT / 'Dispatch').rglob('*.swift'))
        found = [f'{path.relative_to(consent.ROOT)}:{number}' for path in files if 'enum Home {' not in path.read_text()
                 for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]
        self.assertEqual(found, [], 'only Home sets the environment children inherit their home from')


class ConsentTests(unittest.TestCase):
    def setUp(self):
        patcher = patch.dict(os.environ, {}, clear=True)
        patcher.start(); self.addCleanup(patcher.stop)

    def testOnePromptListsEntirePlanBeforeReadingAnswer(self):
        output = io.StringIO()
        components = ['xcodegen', 'rust']
        def answer():
            for component in components:
                self.assertIn(consent.describe(component), output.getvalue())
            return 'yes\n'
        with patch.object(consent.sys, 'stderr', output), patch.object(consent.sys, 'stdin') as stdin:
            stdin.readline.side_effect = answer
            consent.confirm(components)
            stdin.readline.assert_called_once()
        self.assertEqual(output.getvalue().count('[y/N]'), 1)

    def testDeclineBlankAndEOFStop(self):
        for answer in ('no\n', '\n', '', 'sure\n'):
            with self.subTest(answer=answer), patch.object(consent.sys, 'stdin', io.StringIO(answer)), \
                    patch.object(consent.sys, 'stderr', io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                    consent.confirm(['rust'])

    def testLauncherMirrorsConsentToConsoleAndLog(self):
        with tempfile.TemporaryFile() as console, \
                patch.dict(os.environ, {'DISPATCH_SETUP_UI_FD': str(console.fileno())}), \
                patch.object(consent.sys, 'stdin', io.StringIO('yes\n')), \
                patch.object(consent.sys, 'stderr', io.StringIO()) as log:
            consent.confirm(['rust'])
            console.seek(0)
            self.assertEqual(console.read().decode(), log.getvalue())
            self.assertIn('[y/N]', log.getvalue())

    def testApprovedChildrenDoNotPromptAgain(self):
        with patch.dict(os.environ, {consent.APPROVAL: 'rust'}), \
                patch.object(consent.sys, 'stdin') as stdin:
            for component in ('rust',):
                consent.confirm([component])
            stdin.readline.assert_not_called()
            with self.assertRaisesRegex(RuntimeError, 'requirements changed'):
                consent.confirm(['xcodegen'])

    def testOfflineOrPreparedSetupDoesNotPrompt(self):
        with patch.object(consent.sys, 'stdin') as stdin:
            consent.confirm([])
            with patch.dict(os.environ, {'DISPATCH_SETUP_OFFLINE': '1', consent.APPROVAL: 'rust'}):
                with self.assertRaisesRegex(RuntimeError, 'Offline setup'):
                    consent.confirm(['rust'])
            stdin.readline.assert_not_called()

    def testFreshPlanIsLocalOnly(self):
        tools = Mock()
        tools.resolve.side_effect = RuntimeError('Missing compatible tool')
        rust = Mock()
        rust.available.return_value = False
        with patch.object(consent, 'load_script', side_effect=[tools, rust]):
            self.assertEqual(consent.plan(), ['xcodegen', 'rust'])
            for call in tools.resolve.call_args_list:
                self.assertTrue(call.kwargs['offline'])

    def testWarmPlanHasNothingToApprove(self):
        tools, rust = Mock(), Mock()
        rust.available.return_value = True
        with patch.object(consent, 'load_script', side_effect=[tools, rust]):
            self.assertEqual(consent.plan(), [])
            self.assertEqual(tools.resolve.call_args_list, [call('xcodegen', offline=True)])

    def testStandaloneToolDeclinePreventsDownloads(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(setup, 'ROOT', Path(directory), create=True), \
                patch.object(setup.platform, 'machine', return_value='arm64'), \
                patch.object(setup, 'download', create=True) as download, \
                patch.object(consent.sys, 'stdin', io.StringIO('no\n')), \
                patch.object(consent.sys, 'stderr', io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                setup.resolve('xcodegen')
            download.assert_not_called()

    def testRustChecksManifestAndArchiveBeforeExtraction(self):
        rust = consent.load_script('setup-ssh-rust')
        packages = [(name, 'aarch64-apple-darwin') for name in ('rustc', 'cargo', 'rustfmt-preview', 'clippy-preview')]
        packages += [('rust-std', target) for target in rust.TARGETS]
        urls = [f'https://static.rust-lang.org/dist/{name}-{target}.tar.xz' for name, target in packages]
        manifest = ''.join(f'[pkg.{name}.target.{target}]\nxz_url = "{url}"\nxz_hash = "{index:064x}"\n'
                           for index, ((name, target), url) in enumerate(zip(packages, urls))).encode()
        for corrupt in ('manifest', 'archive'):
            with self.subTest(corrupt=corrupt), tempfile.TemporaryDirectory() as directory:
                downloads = []
                def invoke(command, **kwargs):
                    self.assertEqual(command[0], 'curl')
                    address = next(arg for arg in command if arg.startswith('https://'))
                    downloads.append(address)
                    data = manifest if address.endswith('.toml') and corrupt == 'archive' else b'tampered'
                    Path(command[command.index('-o') + 1]).write_bytes(data)
                    return subprocess.CompletedProcess(command, 0)
                with patch.object(rust, 'ROOT', Path(directory)), \
                        patch.object(rust, 'PREFIX', Path(directory) / 'build/rust'), \
                        patch.object(rust, 'ready', return_value=False), patch.object(rust, 'confirm'), \
                        patch.object(rust, 'path_toolchain', return_value=(None, None)), \
                        patch.object(rust, 'MANIFEST_SHA256', hashlib.sha256(manifest).hexdigest()), \
                        patch.object(sys, 'argv', ['setup-ssh-rust.py']), \
                        patch.object(rust.platform, 'machine', return_value='arm64'), \
                        patch.object(rust.platform, 'system', return_value='Darwin'), \
                        patch.object(rust.subprocess, 'run', side_effect=invoke):
                    # invoke rejects every command but curl, so nothing is unpacked.
                    with self.assertRaisesRegex(RuntimeError, 'Checksum mismatch'):
                        rust.main()
                self.assertEqual(downloads[0], f'https://static.rust-lang.org/dist/channel-rust-{rust.VERSION}.toml')
                self.assertEqual(sorted(downloads[1:]), sorted(urls) if corrupt == 'archive' else [])
                self.assertFalse((Path(directory) / 'build/rust').exists())

    def testStandaloneRustDeclineNeverDownloads(self):
        rust = consent.load_script('setup-ssh-rust')
        with patch.object(rust, 'ready', return_value=False), \
                patch.object(rust, 'path_toolchain', return_value=(None, None)), \
                patch.object(sys, 'argv', ['setup-ssh-rust.py']), \
                patch.object(consent.sys, 'stdin', io.StringIO('no\n')), \
                patch.object(consent.sys, 'stderr', io.StringIO()), \
                patch.object(rust.subprocess, 'run') as download:
            with self.assertRaisesRegex(RuntimeError, 'cancelled'):
                rust.main()
            download.assert_not_called()


def pinned_xcodegen(test):
    """The pinned XcodeGen, or the test skipped."""
    try:
        return subprocess.check_output([sys.executable, str(consent.ROOT / 'scripts/setup-build-tools.py'), 'xcodegen', '--offline'],
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        test.skipTest('Pinned XcodeGen is not installed')


class TerminalBuildTests(unittest.TestCase):
    """The terminal libraries build optimized and whole-module in every configuration: unoptimized
    (Debug before) they drain output 18-80x slower, compiled file by file ~3x slower on Unicode.
    Checked on the settings Xcode resolves for a project generated from the spec, whatever setup
    produced: sources the spec names that the checkout lacks exist empty in a mirror of the
    checkout the spec is generated against."""
    def testTerminalLibrariesBuildOptimizedWholeModule(self):
        xcodegen = pinned_xcodegen(self)
        if not shutil.which('xcodebuild'):
            self.skipTest('xcodebuild is not installed')

        def link(directory, into):
            into.mkdir()
            for child in directory.iterdir():
                (into / child.name).symlink_to(child)

        with tempfile.TemporaryDirectory() as directory:
            for spec in ('project.yml',):
                parsed = json.loads(subprocess.check_output([xcodegen, 'dump', '--spec', spec, '--type', 'parsed-json'], cwd=consent.ROOT, text=True))
                root, output = Path(directory) / spec, Path(directory) / (spec + '.project')
                link(consent.ROOT, root)
                output.mkdir()
                for source in {s['path'] for target in parsed['targets'].values() for s in target['sources']}:
                    if (consent.ROOT / source).exists():
                        continue
                    here = root
                    for part in Path(source).parts:
                        here = here / part
                        if here.is_symlink():   # a real directory: its entries as links, the missing one added
                            real = here.resolve()
                            here.unlink()
                            link(real, here)
                        elif not here.exists():
                            here.mkdir()
                subprocess.run([xcodegen, 'generate', '--spec', spec, '--project-root', str(root), '--project', str(output), '--quiet'],
                               cwd=consent.ROOT, check=True, capture_output=True)
                for configuration in ('Debug', 'Release'):
                    with self.subTest(spec=spec, configuration=configuration):
                        found = json.loads(subprocess.check_output(['xcodebuild', '-project', str(output / 'Dispatch.xcodeproj'), '-configuration', configuration,
                                                                    '-target', 'Term', '-target', 'TermApple', '-showBuildSettings', '-json'],
                                                                   text=True, stderr=subprocess.DEVNULL))
                        self.assertEqual({t['target']: (t['buildSettings']['SWIFT_OPTIMIZATION_LEVEL'], t['buildSettings']['SWIFT_COMPILATION_MODE']) for t in found},
                                         {'Term': ('-O', 'wholemodule'), 'TermApple': ('-O', 'wholemodule')})

if __name__ == '__main__':
    unittest.main()
