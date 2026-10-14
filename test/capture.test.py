#!/usr/bin/env python3
"""Collection contracts exercised with an existing, unmodified native capture."""
import bz2
import fcntl
import importlib.util
import json
import os
import platform
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('capture', Path(__file__).with_name('capture.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class Collection(unittest.TestCase):
    def setUp(self):
        root=Path(__file__).resolve().parent.parent
        self.fixture = Path(os.environ.get('DISPATCH_CAPTURE_TEST_SOURCE', root/'test/fixtures/helper-login/capture.jsonl'))
        temporary=Path(os.environ.get('TMPDIR',root/'build/capture-tests'))
        temporary.mkdir(parents=True,exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=temporary)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.source = self.remote / 'helper-17-1.rpl.bz2'
        shutil.copyfile(self.fixture, self.source)
        self.target = self.root / 'download'

    def snapshot(self):
        """The fixture as a running helper's snapshot: its first bzip2 member (the startup checkpoint)."""
        original = self.fixture.read_bytes()
        member = bz2.BZ2Decompressor()
        member.decompress(original)
        return original[:len(original) - len(member.unused_data)]

    def test_verified_download_acknowledges_but_retains_source(self):
        original = self.source.read_bytes()
        capture.collect(['/bin/sh', '-c'], str(self.remote), self.target)
        self.assertEqual((self.target / capture.digest(self.fixture) / self.source.name).read_bytes(), original)
        self.assertEqual(self.source.read_bytes(),original)
        self.assertEqual(json.loads((self.remote/'.acknowledged.json').read_text()),
                         {self.source.name:capture.digest(self.fixture)})

    def test_conflicting_download_never_acknowledges_source(self):
        self.target.mkdir()
        destination = self.target/capture.digest(self.fixture)/self.source.name
        destination.parent.mkdir()
        destination.write_bytes(b'conflicting destination')
        with self.assertRaises((OSError, ValueError)):
            capture.collect(['/bin/sh', '-c'], str(self.remote), self.target)
        self.assertEqual(self.source.read_bytes(), self.fixture.read_bytes())
        self.assertEqual(destination.read_bytes(), b'conflicting destination')

    def test_failed_transfer_never_deletes_source(self):
        with self.assertRaises(Exception):
            capture.collect(['/bin/false'], str(self.remote), self.target)
        self.assertEqual(self.source.read_bytes(), self.fixture.read_bytes())

    def test_changed_source_survives_acknowledgement(self):
        run = subprocess.run
        def invoke(command, **options):
            result = run(command, **options)
            if command[-1].endswith(' export'):
                with self.source.open('ab') as stream: stream.write(b'\n')
            return result
        with patch.object(capture.subprocess, 'run', invoke), self.assertRaises(ValueError):
            capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.assertEqual(self.source.read_bytes(),self.fixture.read_bytes()+b'\n')
        self.assertEqual((self.target/capture.digest(self.fixture)/self.source.name).read_bytes(),self.fixture.read_bytes())

    def test_corrupt_download_is_not_acknowledged(self):
        copy = shutil.copyfileobj
        def corrupt(source, output):
            copy(source,output)
            output.write(b'corrupted transport')
        with patch.object(capture.shutil,'copyfileobj',corrupt), self.assertRaises(ValueError):
            capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.assertEqual(self.source.read_bytes(),self.fixture.read_bytes())

    def test_growing_lifetime_keeps_each_distinct_snapshot(self):
        original=self.fixture.read_bytes()
        prefix=self.snapshot()
        self.source.write_bytes(prefix)
        first=capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.source.write_bytes(original)
        second=capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
        self.assertEqual([(self.target/p).read_bytes() for p in first+second],[prefix,original])
        self.assertEqual(capture.collect(['/bin/sh','-c'],str(self.remote),self.target),[])
        self.assertEqual(self.source.read_bytes(),original)

    def test_running_helper_is_collected_once_it_ends(self):
        # A helper still writing (its test just closed its connection) holds its capture locked.
        self.source.write_bytes(self.snapshot())
        with self.source.open('rb+') as writer:
            fcntl.flock(writer,fcntl.LOCK_EX)
            def end():
                writer.seek(0);writer.write(self.fixture.read_bytes());writer.flush()
                fcntl.flock(writer,fcntl.LOCK_UN)
            ending=threading.Timer(0.3,end);ending.start()
            collected=capture.collect(['/bin/sh','-c'],str(self.remote),self.target)
            ending.join()
        self.assertEqual([(self.target/p).read_bytes() for p in collected],[self.fixture.read_bytes()])

    def test_empty_selection_file_cannot_expand_to_full_suite(self):
        source = self.root/'tests.json'
        source.write_text('[]')
        result = subprocess.run([sys.executable,str(Path(__file__).with_name('xcode.py')),
                                 '--tests-from',str(source),'--list'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('non-empty JSON array',result.stderr)

if __name__ == '__main__': unittest.main()
