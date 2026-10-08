#!/usr/bin/env python3
"""Offline distribution contract tests; no credentials, network or signing required."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('distribute', Path(__file__).resolve().parents[1] / 'scripts/distribute.py')
distribute = importlib.util.module_from_spec(spec)
spec.loader.exec_module(distribute)


class DistributionTests(unittest.TestCase):
    def test_identity_rejects_development_and_ambiguous_names(self):
        digest = 'A' * 40
        with patch.object(distribute, 'run', return_value=f'1) {digest} "Apple Development: Example (TEAM)"'):
            with self.assertRaises(ValueError):
                distribute.identity_hash(digest)
        name = 'Developer ID Application: Example (TEAM)'
        with patch.object(distribute, 'run', return_value=f'1) {digest} "{name}"'):
            self.assertEqual(distribute.identity_hash(digest.lower()), digest)
            self.assertEqual(distribute.identity_hash(name), digest)
            with self.assertRaises(ValueError):
                distribute.identity_hash('Example')

    def test_all_macos_helpers_signed_before_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Dispatch.app'
            resources = app / 'Contents/Resources/helper'
            resources.mkdir(parents=True)
            binary = resources / 'darwin-universal'
            binary.write_bytes(bytes.fromhex('cafebabe') + b'code')
            linux = resources / 'linux-aarch64'
            linux.write_bytes(b'\x7fELFcode')
            alias = resources / 'alias'
            alias.symlink_to(binary)
            nested = app / 'Contents/PlugIns/Test.xpc'
            nested.mkdir(parents=True)
            helper = nested / 'helper'
            helper.write_bytes(bytes.fromhex('cffaedfe') + b'code')
            targets = distribute.signing_targets(app)
            self.assertIn(binary, targets)
            self.assertLess(targets.index(helper), targets.index(nested))
            self.assertNotIn(linux, targets)
            self.assertNotIn(alias, targets)
            self.assertEqual(targets[-1], app)

    def test_rejected_submission_never_staples_or_packages(self):
        with patch.object(distribute, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Invalid'):
                distribute.finish(Path('app'), Path('out'), 'id', 'Invalid')
            run.assert_not_called()

    def test_gatekeeper_failure_never_produces_release_zip(self):
        import subprocess
        def run(*args):
            if args[0] == 'spctl':
                raise subprocess.CalledProcessError(1, args)
            return ''
        with patch.object(distribute, 'run', side_effect=run), patch.object(distribute, 'package') as package:
            with self.assertRaises(subprocess.CalledProcessError):
                distribute.finish(Path('app'), Path('out'), 'id', 'Accepted')
            package.assert_not_called()

    def test_resume_does_not_upload_or_sign(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'notarization.json').write_text(json.dumps({'id': 'existing-id'}))
            with patch.object(distribute, 'run', return_value=json.dumps({'id': 'existing-id', 'status': 'Accepted'})) as run, patch.object(distribute, 'finish') as finish:
                distribute.main(['--resume', '--output', directory, '--keychain-profile', 'profile'])
                run.assert_called_once_with('xcrun', 'notarytool', 'info', 'existing-id', '--keychain-profile', 'profile', '--output-format', 'json')
                finish.assert_called_once()

    def test_pipeline_keeps_source_unchanged_and_records_submission(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'source.app'
            executable = app / 'Contents/MacOS/Dispatch'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(bytes.fromhex('cffaedfe') + b'original')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundlePackageType': 'APPL', 'CFBundleExecutable': 'Dispatch'}))
            output = root / 'release'
            commands = []
            def run(*args):
                commands.append(args)
                if args[0] == 'ditto':
                    if args[1] == '-c':
                        Path(args[-1]).write_bytes(b'archive')
                    else:
                        shutil.copytree(args[1], args[2])
                if args[:3] == ('xcrun', 'notarytool', 'submit'):
                    return json.dumps({'id': 'submission-id', 'status': 'In Progress'})
                if args[:3] == ('xcrun', 'notarytool', 'wait'):
                    self.assertEqual(json.loads((output / 'notarization.json').read_text())['id'], 'submission-id')
                    return json.dumps({'id': 'submission-id', 'status': 'Accepted'})
                return ''
            with patch.object(distribute, 'identity_hash', return_value='A' * 40), patch.object(distribute, 'run', side_effect=run):
                distribute.main(['--app', str(app), '--output', str(output), '--identity', 'identity', '--keychain-profile', 'profile'])
            self.assertEqual(executable.read_bytes(), bytes.fromhex('cffaedfe') + b'original')
            self.assertTrue((output / 'Dispatch.zip').exists())
            self.assertEqual(sum(c[:3] == ('xcrun', 'notarytool', 'submit') for c in commands), 1)
            sign = [c for c in commands if c[:2] == ('codesign', '--force')]
            self.assertEqual(len(sign), 2)
            for command in sign:
                self.assertIn('--timestamp', command)
                self.assertIn('runtime', command)
                self.assertTrue(Path(command[-1]).is_relative_to(output.resolve()))

    def test_signature_and_staple_verified_before_final_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            calls = []
            def run(*args):
                calls.append(args[:3])
                return ''
            def package(app, archive):
                calls.append(('package',))
                archive.write_bytes(b'archive')
            with patch.object(distribute, 'run', side_effect=run), patch.object(distribute, 'package', side_effect=package):
                distribute.finish(output / 'Dispatch.app', output, 'id', 'Accepted')
            self.assertEqual(calls, [('xcrun', 'stapler', 'staple'), ('xcrun', 'stapler', 'validate'), ('codesign', '--verify', '--deep'), ('spctl', '--assess', '--type'), ('package',)])
            self.assertIn('Dispatch.zip', (output / 'SHA256SUMS').read_text())


if __name__ == '__main__':
    unittest.main()
