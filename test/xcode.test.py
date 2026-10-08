"""Runner admission tests; no native interaction captures are invented here."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import replay
import timings
import shards
import xcode


class Admission(unittest.TestCase):
    def test_live_run_requires_replay_before_xctest_and_capture(self):
        parent = Path(__file__).resolve().parent.parent / 'build/runner-tests'
        parent.mkdir(parents=True, exist_ok=True)
        for blocked in (True, False):
            with self.subTest(blocked=blocked), tempfile.TemporaryDirectory(dir=parent) as directory:
                root = Path(directory)
                events = []
                selection = {'selected': ['DispatchTests/Example/test'], 'suite': 'full'}
                timing = dict(complete=False, missing_identifiers=selection['selected'],
                              unexpected_identifiers=[], duplicate_identifiers=[])

                def run(command, **kwargs):
                    if command[0] == 'xcodebuild':
                        events.append('xctest')
                    elif command[-1].endswith('release.py'):
                        events.append('release')
                    else:
                        events.append('tools')
                    return subprocess.CompletedProcess(command, 0)

                def gate(arguments):
                    events.append('replay')
                    self.assertIn('--require-same', arguments)
                    self.assertEqual(arguments[0], str(root / 'captures'))
                    return int(blocked)

                with patch.object(xcode, 'ensure_build', side_effect=lambda *a, **k: events.append('build') or root / 'plan'), \
                     patch.object(replay, 'main', side_effect=gate), \
                     patch.object(xcode.subprocess, 'run', side_effect=run), \
                     patch.object(xcode.subprocess, 'check_output', return_value='Xcode'), \
                     patch.object(xcode.codex_fixture, 'resources', return_value={}), \
                     patch.object(xcode, 'fingerprint', return_value='inputs'), \
                     patch.object(xcode, 'report', return_value=timing), \
                     patch.object(xcode.capture, 'begin', side_effect=AssertionError('capture began before admission')) as begin:
                    status = xcode.execute(root, selection['selected'], selection=selection,
                                           capture_run='captured' if blocked else None)
                # No result bundle is produced by this orchestration-only test.
                self.assertEqual(status, 1)
                self.assertEqual(events, ['build', 'tools', 'replay'] if blocked else
                                 ['build', 'tools', 'replay', 'xctest', 'release'])
                begin.assert_not_called()


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
