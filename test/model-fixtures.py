#!/usr/bin/env python3
"""Local HTTP fixture barrier regressions. No agents, desktop, or API account."""
import http.client
import json
import os
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
import codex_fixture
import codex_pty
import claude_fixture


class BarrierChecks:
    fixture = None

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dispatch-model-barriers-')
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.server = self.fixture.FixtureServer(self.state, delay=0)
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01))
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())

    def send(self, identifier=None, prompt=None):
        text = prompt or 'FIXTURE_BARRIER_' + identifier + ' controlled response'
        if self.fixture is codex_fixture:
            path = '/v1/responses'
            body = {'model': 'dispatch-fixture', 'input': [{'role': 'user', 'content': text}], 'stream': True}
            headers = {'Content-Type': 'application/json'}
        else:
            path = '/v1/messages'
            body = {'model': 'dispatch-fixture', 'messages': [{'role': 'user', 'content': text}],
                    'stream': True, 'max_tokens': 1024}
            headers = {'Content-Type': 'application/json', 'x-api-key': claude_fixture.API_KEY}
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        self.addCleanup(client.close)
        client.request('POST', path, json.dumps(body), headers)
        return client

    def response_text(self, response):
        events = [json.loads(line[6:]) for line in response.read().decode().splitlines() if line.startswith('data: ')]
        self.assertEqual(events[-1]['type'], 'response.completed' if self.fixture is codex_fixture else 'message_stop')
        return ''.join(event['delta'] if isinstance(event.get('delta'), str) else event.get('delta', {}).get('text', '')
                       for event in events)

    def wait_record(self, identifier, name):
        path = self.state / 'barriers' / identifier / (name + '.json')
        deadline = time.monotonic() + 3
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, 'Missing ' + str(path))
            threading.Event().wait(0.005)
        return json.loads(path.read_text())

    def signal(self, identifier, name):
        (self.state / 'barriers' / identifier / name).touch()

    def testResponsesWaitForTheirOwnReleaseAndRecordCompletionAfterDelivery(self):
        first, second = uuid.uuid4().hex, uuid.uuid4().hex
        a, b = self.send(first), self.send(second)
        for identifier in [first, second]:
            self.wait_record(identifier, 'accepted')
            self.assertFalse((self.state / 'barriers' / identifier / 'completed.json').exists())
        self.signal(second, 'release')
        response = b.getresponse()
        self.assertEqual(response.status, 200)
        self.assertIn(second, self.response_text(response))
        self.assertEqual(self.wait_record(second, 'completed')['outcome'], 'delivered')
        self.assertFalse((self.state / 'barriers' / first / 'completed.json').exists())
        self.signal(first, 'release')
        self.assertIn(first, self.response_text(a.getresponse()))
        self.assertEqual(self.wait_record(first, 'completed')['outcome'], 'delivered')
        completions = [json.loads(line) for line in (self.state / 'completions.jsonl').read_text().splitlines()]
        self.assertEqual([record['id'] for record in completions], [second, first])

    def testCancelledRequestCannotBecomeDeliveredByLateRelease(self):
        identifier = uuid.uuid4().hex
        client = self.send(identifier)
        self.wait_record(identifier, 'accepted')
        self.signal(identifier, 'cancel')
        self.assertEqual(self.wait_record(identifier, 'completed')['outcome'], 'cancelled')
        self.signal(identifier, 'release')
        with self.assertRaises(http.client.RemoteDisconnected):
            client.getresponse()
        self.assertEqual(self.wait_record(identifier, 'completed')['outcome'], 'cancelled')
        self.assertEqual(self.send(prompt='still usable').getresponse().status, 200)

    def testClientDisconnectUnblocksHandlerWithoutRelease(self):
        identifier = uuid.uuid4().hex
        client = self.send(identifier)
        self.wait_record(identifier, 'accepted')
        client.close()
        self.assertEqual(self.wait_record(identifier, 'completed')['outcome'], 'disconnected')

    def testTimeoutCompletesAndReleasesTheWorker(self):
        self.server.barriers.timeout = 0.05
        identifier = uuid.uuid4().hex
        client = self.send(identifier)
        self.assertEqual(self.wait_record(identifier, 'completed')['outcome'], 'timed_out')
        with self.assertRaises(http.client.RemoteDisconnected):
            client.getresponse()
        response = self.send(prompt='after timeout').getresponse()
        self.assertEqual(response.status, 200)
        response.read()

    def testShutdownCancelsAndJoinsBlockedRequests(self):
        identifier = uuid.uuid4().hex
        client = self.send(identifier)
        self.wait_record(identifier, 'accepted')
        self.server.server_close()
        self.assertEqual(self.wait_record(identifier, 'completed')['outcome'], 'cancelled')
        with self.assertRaises(http.client.RemoteDisconnected):
            client.getresponse()

    def testDuplicateMarkerCannotConsumeAPreviousRelease(self):
        identifier = uuid.uuid4().hex
        first = self.send(identifier)
        self.wait_record(identifier, 'accepted')
        second = self.send(identifier).getresponse()
        self.assertEqual(second.status, 409)
        second.read()
        self.signal(identifier, 'release')
        response = first.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        self.assertEqual(self.wait_record(identifier, 'completed')['outcome'], 'delivered')


class CodexBarrierTests(BarrierChecks, unittest.TestCase):
    fixture = codex_fixture


class ClaudeBarrierTests(BarrierChecks, unittest.TestCase):
    fixture = claude_fixture


class ProcessCleanupTests(unittest.TestCase):
    def testCodexFixtureStopsOwnedPackagesAndPreservesFailureEvidence(self):
        with tempfile.TemporaryDirectory(prefix='dispatch packages ') as temporary:
            root = Path(temporary)
            ledger = root / 'fixtures.jsonl'
            with patch.dict(os.environ, {'DISPATCH_TEST_FIXTURES': str(ledger)}):
                homes = [codex_fixture.prepare(root / name, 1)[0] for name in ['first', 'second']]
            children = []
            try:
                for home in homes:
                    binary = home / 'packages/release/bin/codex'
                    binary.parent.mkdir(parents=True)
                    shutil.copyfile('/bin/sleep', binary); binary.chmod(0o700)
                    children.append(subprocess.Popen([str(binary), '60']))
                    (home / 'evidence.jsonl').write_text('retained transcript\n')
                codex_fixture.stop(homes[0], None)
                self.assertIsNotNone(children[0].wait(timeout=3))
                self.assertIsNone(children[1].poll())
                self.assertEqual([p.exists() for p in [homes[0] / 'packages', homes[1] / 'packages']], [False, True])
                self.assertEqual([ (home / 'evidence.jsonl').read_text() for home in homes], ['retained transcript\n'] * 2)
                self.assertEqual(codex_fixture.resources(homes[:1]), {'processes': {}, 'packages': []})
                self.assertEqual(json.loads((homes[0] / 'app-server-daemon/settings.json').read_text()),
                                 {'updater': {'autoUpdateEnabled': False}})
                self.assertEqual([json.loads(line) for line in ledger.read_text().splitlines()], list(map(str, homes)))
            finally:
                for child in children:
                    if child.poll() is None: child.terminate()
                    child.wait(timeout=3)

    def testCodexReviewAcceptsOldAndNewNativeHints(self):
        # Old hint: HEAD 96897b7 ChatEndToEndTests; new hint: Codex 0.157 native review.
        hints = ('Press enter to view hooks', 'enter details')
        for hint in hints:
            cli = object.__new__(codex_pty.CodexPTY)
            cli.output = '\x1b[1m' + hint + '\x1b[0m'
            with self.subTest(hint=hint), patch.object(cli, 'pump'):
                cli.expect(*hints)
                self.assertEqual(cli.output, '')

    def testCodexFixtureLaunchUsesTheProductWrapperAndCompatibleIsolation(self):
        arguments = ['--no-alt-screen', 'resume', 'session with spaces']
        # A Dispatch terminal (local or a remote helper's) runs the helper's typed launch and never probes Codex.
        for environment in [{'DISPATCH_HELPER4_EXECUTABLE': '/helper path'}, {'DISPATCH_SSH_HELPER': '/helper path'}]:
            with self.subTest(environment=environment), \
                    patch.object(subprocess, 'run', side_effect=subprocess.CalledProcessError(1, [])) as probe:
                self.assertEqual(codex_pty.command('/codex', arguments, environment),
                                 ['/helper path', 'launch', 'codex'] + arguments)
                probe.assert_not_called()
        for supported in [False, True]:
            result = subprocess.CompletedProcess([], 0, stdout=b'options --no-daemon\n' if supported else b'options --no-alt-screen\n')
            with self.subTest(supported=supported), patch.object(subprocess, 'run', return_value=result):
                self.assertEqual(codex_pty.command('/codex', arguments, {}),
                                 ['/codex'] + (['--no-daemon'] if supported else []) + arguments)
        for arguments in [['--remote','unix:///socket'], ['--no-daemon']]:
            with patch.object(subprocess, 'run') as probe:
                self.assertEqual(codex_pty.command('/codex', arguments, {}), ['/codex'] + arguments)
                probe.assert_not_called()

    def testEndpointRemainsCompleteWhileReadinessIsPublished(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary).resolve()
            endpoint = state / 'endpoint.json'
            previous = None
            observed = []
            def write(path, contents, *args, **kwargs):
                with path.open('w', *args, **kwargs) as stream:
                    count = stream.write(contents[:len(contents) // 2])
                    stream.flush()
                    value = json.loads(endpoint.read_text()) if endpoint.exists() else None
                    self.assertEqual(value, previous)
                    observed.append(value)
                    return count + stream.write(contents[len(contents) // 2:])
            for port in (1, 43210):
                with patch.object(Path, 'write_text', write):
                    home, work = codex_fixture.prepare(state, port)
                previous = {'port': port, 'home': str(home), 'work': str(work)}
                self.assertEqual(json.loads(endpoint.read_text()), previous)
            self.assertIn(None, observed)
            self.assertIn(dict(previous, port=1), observed)

    def testCodexStopsOnlyItsOwnDaemonAndReportsCleanupFailure(self):
        script = Path(__file__).resolve().parent.parent / 'scripts/codex_fixture.py'
        for daemon, status in [(False, 0), (True, 0), (True, 7)]:
            with self.subTest(daemon=daemon, status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                state = root / 'state'
                home, _ = codex_fixture.prepare(state, 1)
                if daemon:
                    (home / 'app-server-daemon').mkdir(exist_ok=True)
                    (home / 'app-server-daemon/daemon.pid').write_text('owned fixture marker')
                binary = root / 'codex'
                binary.write_text('#!' + sys.executable + '\nimport json, os, sys\nfrom pathlib import Path\n'
                    'home = Path(os.environ["CODEX_HOME"])\n'
                    '(home / "stopped.json").write_text(json.dumps([str(home), sys.argv[1:]]))\n'
                    'raise SystemExit(' + str(status) + ')\n')
                binary.chmod(0o700)
                process = subprocess.Popen([sys.executable, str(script), 'serve', '--state', str(state),
                                            '--codex', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    line = process.stdout.readline().decode()
                    self.assertTrue(line.startswith('Local Codex endpoint:'), line or process.communicate(timeout=3)[1].decode())
                    client = http.client.HTTPConnection('127.0.0.1', json.loads((state / 'endpoint.json').read_text())['port'], timeout=2)
                    try:
                        client.request('GET', '/health')
                        self.assertEqual(client.getresponse().status, 200)
                    finally:
                        client.close()
                    process.terminate()
                    _, error = process.communicate(timeout=3)
                    self.assertEqual(process.returncode == 0, status == 0, error.decode())
                    stopped = home / 'stopped.json'
                    self.assertEqual(json.loads(stopped.read_text()) if stopped.exists() else None,
                                     [str(home), ['app-server', 'daemon', 'stop']] if daemon else None)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=3)

    def wait_file(self, path, process):
        deadline = time.monotonic() + 3
        while not path.exists():
            self.assertIsNone(process.poll(), 'Fixture exited before readiness')
            self.assertLess(time.monotonic(), deadline, 'Fixture did not signal readiness')
            threading.Event().wait(0.005)
        return json.loads(path.read_text())

    def testServingProcessesRecordCancellationBeforeTerminationCompletes(self):
        scripts = Path(__file__).resolve().parent.parent / 'scripts'
        for agent in ['codex', 'claude']:
            with self.subTest(agent=agent), tempfile.TemporaryDirectory() as temporary:
                state = Path(temporary)
                process = subprocess.Popen([sys.executable, str(scripts / (agent + '_fixture.py')),
                                            'serve', '--state', str(state), '--delay', '0'],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                try:
                    metadata = self.wait_file(state / 'endpoint.json', process)
                    while metadata['port'] == 1:
                        threading.Event().wait(0.005)
                        metadata = self.wait_file(state / 'endpoint.json', process)
                    identifier = uuid.uuid4().hex
                    prompt = 'FIXTURE_BARRIER_' + identifier + ' termination check'
                    body = {'model': 'dispatch-fixture', 'stream': True}
                    if agent == 'codex':
                        body['input'] = [{'role': 'user', 'content': prompt}]
                        path, headers = '/v1/responses', {}
                    else:
                        body.update(messages=[{'role': 'user', 'content': prompt}], max_tokens=1024)
                        path, headers = '/v1/messages', {'x-api-key': claude_fixture.API_KEY}
                    client = http.client.HTTPConnection('127.0.0.1', metadata['port'], timeout=2)
                    try:
                        client.request('POST', path, json.dumps(body), headers)
                        self.wait_file(state / 'barriers' / identifier / 'accepted.json', process)
                        process.terminate()
                        _, error = process.communicate(timeout=3)
                        self.assertEqual(process.returncode, 0, error.decode())
                        record = json.loads((state / 'barriers' / identifier / 'completed.json').read_text())
                        self.assertEqual(record['outcome'], 'cancelled')
                    finally:
                        client.close()
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=3)

    def testShellFIFOWaitsForReleaseAndCancellationIsNotSuccess(self):
        script = Path(__file__).resolve().parent.parent / 'scripts/shell_fixture_barrier.py'
        for cancel in [False, True]:
            with self.subTest(cancel=cancel), tempfile.TemporaryDirectory() as temporary:
                state = Path(temporary)
                os.mkfifo(state / 'release', 0o600)
                process = subprocess.Popen([sys.executable, str(script), str(state)])
                try:
                    record = self.wait_file(state / 'ready.json', process)
                    self.assertEqual(record['pid'], process.pid)
                    self.assertFalse((state / 'completed.json').exists())
                    if cancel:
                        process.terminate()
                    else:
                        fd = os.open(state / 'release', os.O_WRONLY | os.O_NONBLOCK)
                        try:
                            os.write(fd, b'1')
                        finally:
                            os.close(fd)
                    self.assertEqual(process.wait(timeout=3), 1 if cancel else 0)
                    self.assertEqual(json.loads((state / 'completed.json').read_text())['outcome'],
                                     'cancelled' if cancel else 'released')
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=3)


if __name__ == '__main__':
    unittest.main()
