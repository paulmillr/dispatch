"""Remote transport checks using a real native capture and helper binaries."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import replay_remote


class Transport(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = Path(os.environ['DISPATCH_CAPTURE_TEST_SOURCE']).resolve()
        self.original = Path(os.environ['DISPATCH_REPLAY_TEST_ORIGINAL']).resolve()
        self.helper = Path(os.environ['DISPATCH_REPLAY_TEST_HELPER']).resolve()
        self.tool = Path(os.environ['DISPATCH_REPLAY_TEST_TOOL']).resolve()
        self.execute = subprocess.run

    def invoke(self, command, **options):
        self.assertEqual(command[:2], ['ssh', 'fixture'])
        return self.execute(['/bin/sh', '-c', command[-1]],
                            env=dict(os.environ, HOME=str(self.root)), **options)

    def run_remote(self):
        return replay_remote.run({'destination': 'fixture', 'options': []}, self.source.parent,
                                 [self.source.name], self.original, self.helper, self.tool,
                                 str(self.original), self.root/'output',
                                 {'timeout': 5, 'budget': 30, 'memory': 512})

    def test_real_capture_roundtrip_retains_inputs_and_completion(self):
        with patch.object(replay_remote.subprocess, 'run', self.invoke):
            result = self.run_remote()
        import json
        rows = json.loads((self.root/'output/comparison.json').read_text())
        self.assertEqual(rows, [{'capture': self.source.name, 'status': 'same', 'reason': None,
                                'original_exit': 7, 'candidate_exit': 7}])
        retained = Path(result['remote_directory'])/'captures'/self.source.name
        self.assertEqual(retained.read_bytes(), self.source.read_bytes())
        self.assertTrue((self.root/'output/original/000000.complete').is_file())
        self.assertTrue((self.root/'output/candidate/000000.complete').is_file())

    def test_failed_download_preserves_remote_capture(self):
        def broken(command, **options):
            result = self.invoke(command, **options)
            options['stdout'].write(b'not a tar archive')
            options['stdout'].seek(0)
            options['stdout'].write(b'corrupt')
            return result
        with patch.object(replay_remote.subprocess, 'run', broken), self.assertRaises(Exception):
            self.run_remote()
        retained = list((self.root/'.dispatch-replay').glob('*/captures/'+self.source.name))
        self.assertEqual([p.read_bytes() for p in retained], [self.source.read_bytes()])
        self.assertFalse((self.root/'output/comparison.json').exists())


if __name__ == '__main__': unittest.main()
