#!/usr/bin/env python3
"""Exercise the bundled bridge inside a real isolated interactive Pi CLI."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import termios
import threading
import time
import uuid
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from claude_fixture import FixtureServer
from pi_fixture import command, configure, environment, MODEL, PROVIDER


def test(executable, state):
    started = time.monotonic()
    extension = Path(__file__).resolve().parents[1] / 'Dispatch/Resources/pi-chat.js'
    navigation = Path(__file__).resolve().parent.parent / 'scripts/fixtures/pi-navigation.js'
    with FixtureServer(state, delay=0.015) as server:
        configure(state, server.server_port)
        worker = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
        worker.start()
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(state / 'work')
            os.execvpe(executable, command(executable, '--extension', str(extension), '--extension', str(navigation)), environment(state, server.server_port))
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        output = bytearray()

        def pump(seconds=0.02):
            until = time.monotonic() + seconds
            while time.monotonic() < until:
                if select.select([fd], [], [], 0.01)[0]:
                    try:
                        data = os.read(fd, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            return  # Linux reports EOF this way after the PTY slave exits.
                        raise
                    if not data:
                        return
                    output.extend(data)
                    if b'\x1b[6n' in data:
                        os.write(fd, b'\x1b[1;1R')

        def wait(predicate, seconds=10):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                pump()
                result = predicate()
                if result:
                    return result
            raise AssertionError('Pi bridge condition timed out; inspect terminal.log')

        def registration():
            path = state / f'pi-home/dispatch/sessions/{pid}.json'
            return json.loads(path.read_text()) if path.exists() else None

        def request(record, method, **values):
            identifier = str(uuid.uuid4())
            body = dict(id=identifier, token=record['token'], sessionId=record['sessionId'], method=method, **values)
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(4)
                client.connect(record['socket'])
                client.sendall((json.dumps(body, ensure_ascii=False) + '\n').encode())
                result = bytearray()
                deadline = time.monotonic() + 4
                while b'\n' not in result:
                    pump()
                    if not select.select([client], [], [], 0.01)[0]:
                        assert time.monotonic() < deadline, 'Bridge response timed out'
                        continue
                    chunk = client.recv(65536)
                    assert chunk, 'Bridge closed without a response'
                    result.extend(chunk)
                    assert len(result) <= 4 * 1024 * 1024
            response = json.loads(result)
            assert response['id'] == identifier
            if response['ok']:
                assert response['sessionId'] == record['sessionId']
            return response

        def state_of(record):
            response = request(record, 'state')
            assert response['ok'], response
            return response['state']

        def prompt(record, text):
            response = request(record, 'prompt', text=text)
            assert response['ok'], response

        def transcript(record):
            path = Path(record['transcriptPath'])
            return [json.loads(line) for line in path.read_text().split('\n') if line] if path.exists() else []

        def reply(record, text):
            rows = transcript(record)
            return any(row.get('message', {}).get('role') == 'assistant' and
                       text in ''.join(block.get('text', '') for block in row['message'].get('content', [])) for row in rows)

        try:
            record = wait(registration)
            initial = state_of(record)
            assert initial['sessionId'] == record['sessionId'] and not initial['busy'], initial
            assert initial['model']['provider'] == PROVIDER and initial['model']['id'] == MODEL
            invalid = dict(record, token=str(uuid.uuid4()))
            assert not request(invalid, 'prompt', text='must never run')['ok']
            invalid = dict(record, sessionId=str(uuid.uuid4()))
            assert not request(invalid, 'prompt', text='wrong conversation')['ok']
            catalog = request(record, 'models')
            assert catalog['ok'] and catalog['models'][0]['provider'] == PROVIDER, catalog
            selected = request(record, 'configure', provider=PROVIDER, model=MODEL, effort='high')
            assert selected['ok'] and selected['state']['effort'] == 'high', selected
            assert not request(record, 'configure', provider=PROVIDER, model=MODEL, effort='unsupported')['ok']
            for method in ['confirm', 'select', 'input', 'editor']:
                os.write(fd, ('/dispatch-test-question ' + method + '\r').encode())
                question = wait(lambda: state_of(record).get('uiPrompt'))
                assert question['kind'] == method, question
                assert state_of(record)['busy']
                assert not request(record, 'prompt', text='must preserve native question')['ok']
                assert not request(record, 'configure', provider=PROVIDER, model=MODEL, effort='low')['ok']
                assert not request(record, 'abort')['ok']
                os.write(fd, b'\x1b')
                wait(lambda: not state_of(record).get('uiPrompt') and not state_of(record)['busy'])
            os.write(fd, b'\x1b[200~native draft\x1b[201~')
            wait(lambda: state_of(record)['editor'] == 'native draft')
            assert not request(record, 'prompt', text='must preserve editor')['ok']
            os.write(fd, b'\x15')
            wait(lambda: not state_of(record)['editor'])
            text = 'thinking bridge\nUnicode separator: \u2028 done'
            prompt(record, text)
            streamed = wait(lambda: state_of(record).get('partial'))
            assert streamed['turnId'] != 'history', streamed
            assert streamed['user']['id'] == streamed['turnId'], streamed
            assert streamed['user']['message']['role'] == 'user', streamed
            assert text in json.dumps(streamed['user']['message'], ensure_ascii=False).replace('\\n', '\n'), streamed
            wait(lambda: not state_of(record)['busy'] and reply(record, text))
            for text in ['/new', '/model\nquoted text', '!printf DISPATCH_LITERAL_PROBE']:
                prompt(record, text)
                wait(lambda: not state_of(record)['busy'] and reply(record, text))
                assert registration()['sessionId'] == record['sessionId'], 'Literal text ran a command'
            prompt(record, 'tool bridge')
            wait(lambda: not state_of(record)['busy'] and reply(record, 'Tool result received: completed.'))
            rows = transcript(record)
            assert any(row.get('message', {}).get('role') == 'toolResult' and
                       'DISPATCH_CLAUDE_TOOL_OK' in json.dumps(row) for row in rows)
            prompt(record, 'long cancellation')
            wait(lambda: state_of(record).get('partial'))
            aborted = request(record, 'abort')
            assert aborted['ok'], aborted
            wait(lambda: not state_of(record)['busy'])
            assert request(record, 'abort')['ok'], 'Idle abort should be harmless'
            prompt(record, 'after cancellation')
            wait(lambda: not state_of(record)['busy'] and reply(record, 'after cancellation'))
            prompt(record, 'long steering source')
            wait(lambda: state_of(record).get('partial'))
            steered = request(record, 'steer', text='follow this direction now')
            assert steered['ok'], steered
            wait(lambda: reply(record, 'follow this direction now'), seconds=20)
            wait(lambda: not state_of(record)['busy'], seconds=20)
            os.write(fd, b'/new\r')
            replacement = wait(lambda: (value if (value := registration()) and value['sessionId'] != record['sessionId'] else None))
            assert not state_of(replacement)['busy']
            assert replacement['token'] != record['token']
            assert not Path(record['socket']).exists(), 'Old bridge remained reachable after session switch'
            prompt(replacement, 'replacement session')
            wait(lambda: not state_of(replacement)['busy'] and reply(replacement, 'replacement session'))
            summary = {'seconds': time.monotonic() - started,
                       'version': subprocess.check_output([executable, '--version'], text=True).strip(),
                       'checks': ['identity and token rejection', 'model catalog and effort', 'native dialog preservation', 'native draft preservation',
                                  'multiline Unicode streaming', 'literal slash and bang prompts', 'tool result', 'abort and recovery', 'immediate steering', 'new-session rebinding']}
            (state / 'bridge-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(json.dumps(summary, indent=2))
        finally:
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 2
            while not os.waitpid(pid, os.WNOHANG)[0]:
                if time.monotonic() >= deadline:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
                    break
                pump()
            os.close(fd)
            (state / 'terminal.log').write_bytes(output)
            server.shutdown()
            worker.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pi', default=shutil.which('pi'))
    parser.add_argument('--keep', required=True, type=Path)
    args = parser.parse_args()
    if not args.pi:
        parser.error('An existing Pi installation is required')
    if args.keep.exists() and any(args.keep.iterdir()):
        parser.error('--keep must be a new or empty directory')
    test(args.pi, args.keep.resolve())
