"""Runner admission tests; no native interaction captures are invented here."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import timings
import shards
import xcode


class Corpus(unittest.TestCase):
    def test_runs_replay_the_corpus_and_capture_runs_store_their_passed_tests_after_xctest(self):
        parent = Path(__file__).resolve().parent.parent / 'build/runner-tests'
        parent.mkdir(parents=True, exist_ok=True)
        selection = {'selected': ['DispatchTests/Example/test'], 'suite': 'full'}
        timing = dict(complete=False, missing_identifiers=selection['selected'], unexpected_identifiers=[], duplicate_identifiers=[])
        for mode in ('default', 'capture', 'live', 'replay'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir=parent) as directory:
                root = Path(directory)
                events, environments = [], []

                def run(command, **kwargs):
                    if command[0] == 'xcodebuild':
                        events.append('xctest')
                        environments.append(kwargs['env'])
                    elif command[1:3] == ['capture', 'store']:
                        events.append('store')
                        return subprocess.CompletedProcess(command, 0, stdout='stored 1 new captures\n')
                    elif command[-1].endswith('release.py'):
                        events.append('release')
                    return subprocess.CompletedProcess(command, 0)

                # The runner's fixed journal root (/tmp/dt-journal) is the Mac's; this test keeps its own.
                with patch.object(xcode, 'ensure_build', side_effect=lambda *a, **k: events.append('build') or root / 'plan'), \
                     patch.object(xcode, 'JOURNAL', str(root / 'dt')), \
                     patch.object(xcode.subprocess, 'run', side_effect=run), \
                     patch.object(xcode.subprocess, 'check_output', return_value='Xcode'), \
                     patch.object(xcode.platform, 'platform', return_value='macOS'), \
                     patch.object(xcode.codex_fixture, 'resources', return_value={}), \
                     patch.object(xcode, 'fingerprint', return_value='inputs'), \
                     patch.object(xcode, 'report', return_value=timing):
                    xcode.execute(root, selection['selected'], selection=selection, capture_run='captured' if mode == 'capture' else None,
                                  replays=root / 'scratch' if mode == 'replay' else None, required=mode == 'replay', live=mode == 'live')
                variables = {key: environments[0].get('TEST_RUNNER_DISPATCH_' + key) for key in ('REPLAYS', 'LIVE', 'REPLAY_REQUIRED', 'TEST_CAPTURE')}
                # Tests see the checkout through the root's link: recorded paths are the same on every Mac.
                self.assertEqual(variables, {'REPLAYS': str(root / 'dt/checkout' / ('scratch' if mode == 'replay' else 'replays')),
                                             'LIVE': '1' if mode == 'live' else None, 'REPLAY_REQUIRED': '1' if mode == 'replay' else None,
                                             'TEST_CAPTURE': '1' if mode == 'capture' else None})
                self.assertEqual(events, ['build', 'xctest'] + (['store'] if mode == 'capture' else []) + (['release'] if mode != 'replay' else []))


class Machine(unittest.TestCase):
    def test_machine_facts_read_outside_system_stop_the_run_before_building(self):
        parent = Path(__file__).resolve().parent.parent / 'build/runner-tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            root = Path(directory)
            sources = {'Dispatch/Helper/System.swift': 'let home = NSHomeDirectory()\n',
                       'Dispatch/Helper/AppReplay.swift': 'let all = ProcessInfo.processInfo.environment\n',
                       'Dispatch/Views/Card.swift': 'let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")\n'
                                                    'let path = Bundle.main.bundlePath\n'
                                                    'gethostname(&name, 255)\n'
                                                    'let limit = ProcessInfo.processInfo.physicalMemory / 64\n'
                                                    'let host = ProcessInfo.processInfo.hostName\n',
                       'DispatchTests/Fixture.swift': 'func f(file: StaticString = #filePath) {}\n'
                                                      'let t = FileManager.default.temporaryDirectory\n'
                                                      'let r = URL(fileURLWithPath: #filePath).deletingLastPathComponent()\n'
                                                      'let u = NSUserName() + NSTemporaryDirectory()\n'
                                                      'let x = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()\n'
                                                      'let m = Launch.Machine.current\n',
                       'Vendor/Term/Sources/TermApple/Session.swift': 'let options = HandlerOptions()\n'
                                                                     'gethostname(&name, 255)\n',
                       'Vendor/Term/Sources/TermApple/Launch.swift': 'getpwuid_r(getuid(), &pw, buf, count, &result)\n',
                       'Vendor/Term/Sources/TermApple/Theme.swift': 'return getpwuid(getuid()).map { $0.pointee.pw_dir }\n',
                       'Vendor/Term/Sources/TermApple/TerminalView.swift': 'directory: NSHomeDirectory(), machine: .current\n'}
            for name, text in sources.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            found = ['Dispatch/Views/Card.swift:2', 'Dispatch/Views/Card.swift:3', 'Dispatch/Views/Card.swift:4',
                     'Dispatch/Views/Card.swift:5', 'DispatchTests/Fixture.swift:2', 'DispatchTests/Fixture.swift:3',
                     'DispatchTests/Fixture.swift:4', 'DispatchTests/Fixture.swift:5', 'DispatchTests/Fixture.swift:6',
                     'Vendor/Term/Sources/TermApple/Session.swift:2']
            self.assertEqual(xcode.machine(root), found)
            events = []
            with patch.object(xcode, 'ensure_build', side_effect=lambda *a, **k: events.append('build')), \
                 patch.object(xcode, 'JOURNAL', str(root / 'dt')):
                with self.assertRaises(ValueError) as raised:
                    xcode.execute(root, ['DispatchTests/Example/test'])
            self.assertEqual((str(raised.exception), events), (
                'Machine facts come from System (docs/replay.md); read directly at:\n  ' + '\n  '.join(found), []))


class Processes(unittest.TestCase):
    def test_processes_a_test_runs_itself_stop_the_run_before_building(self):
        parent = Path(__file__).resolve().parent.parent / 'build/runner-tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            root = Path(directory)
            sources = {'DispatchTests/TestSupport.swift': 'try process.run(); process.waitUntilExit()\n',
                       'Dispatch/Helper/System.swift': 'try process.run()\n',
                       'DispatchTests/Fixture.swift': 'let exit = try System.run(process)\n'
                                                      'try process.run()\n'
                                                      'send(herdr.launch())\n'
                                                      'child.waitUntilExit()\n'}
            for name, text in sources.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(text)
            self.assertEqual(xcode.processes(root), ['DispatchTests/Fixture.swift:2', 'DispatchTests/Fixture.swift:4'])
            events = []
            with patch.object(xcode, 'ensure_build', side_effect=lambda *a, **k: events.append('build')), \
                 patch.object(xcode, 'JOURNAL', str(root / 'dt')):
                with self.assertRaises(ValueError) as raised:
                    xcode.execute(root, ['DispatchTests/Example/test'])
            self.assertEqual((str(raised.exception), events), (
                'Test processes run through TestSupport.live or start (docs/replay.md); run directly at:\n'
                '  DispatchTests/Fixture.swift:2\n  DispatchTests/Fixture.swift:4', []))


class Results(unittest.TestCase):
    def test_missing_failure_timing_preserves_all_outcomes(self):
        nodes = [dict(nodeType='Test Case', nodeIdentifier='Example/testPass()', result='Passed', durationInSeconds=1.5),
                 dict(nodeType='Test Case', nodeIdentifier='Example/testCrash()', result='Failed')]
        expected = [dict(identifier='DispatchTests/Example/testPass', seconds=1.5, outcome='Passed'),
                    dict(identifier='DispatchTests/Example/testCrash', seconds=None, outcome='Failed')]
        self.assertEqual(timings.cases_from_result(dict(testNodes=nodes)), expected)
        selected = dict(selected=[x['identifier'] for x in expected], excluded=[], suite='full')
        result = timings.report(selected, expected, 'source', {}, [])
        self.assertTrue(result['complete'])
        self.assertEqual(result['missing_duration_identifiers'], ['DispatchTests/Example/testCrash'])
        self.assertEqual(result['slowest_classes'], [dict(identifier='DispatchTests/Example', seconds=1.5)])
        merged = shards.merge_timings(selected, [result])
        self.assertEqual(merged['cases'], expected)
        self.assertEqual(merged['slowest_cases'], expected[:1])
        self.assertEqual(merged['missing_duration_identifiers'], ['DispatchTests/Example/testCrash'])
        for invalid in (None, -1, float('nan')):
            nodes[0]['durationInSeconds'] = invalid
            with self.assertRaises(ValueError):
                timings.cases_from_result(dict(testNodes=nodes))


if __name__ == '__main__':
    unittest.main()
