#!/usr/bin/env python3
"""Real app-server patch fixture. Uses only the local deterministic endpoint."""
import argparse
import base64
import hashlib
import signal
import socket as socket_module
import struct
import json
import os
import pty
import select
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from codex_fixture import FixtureServer, prepare, environment

parser = argparse.ArgumentParser()
parser.add_argument('--codex', required=True)
parser.add_argument('--state', required=True)
parser.add_argument('--agent', action='store_true', help='Attach an owned real Codex TUI for registered SSH observation')
args = parser.parse_args()
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
state = Path(args.state)
server = FixtureServer(state, delay=0.01)
home, work = prepare(state, server.server_port)
(home / 'hooks.json').unlink(missing_ok=True)
# Declare the streamed freeform apply_patch tool through the repository's
# fixture model. Codex's bundled catalog changes per release (0.158 no longer
# offers apply_patch to gpt-5.4), which would silently remove the patch turn.
catalog = Path(__file__).resolve().parent.parent / 'DispatchTests/Fixtures/codex-command-models.json'
config = home / 'config.toml'
config.write_text('model_catalog_json = ' + json.dumps(str(catalog)) + '\n' + config.read_text())
threading.Thread(target=server.serve_forever, daemon=True).start()
env = environment(home)
with tempfile.TemporaryDirectory(prefix='hd-diff-', dir='/tmp') as sockets:
    socket = str(Path(sockets) / 'server.sock')
    with (state / 'server.log').open('w') as log:
        daemon = subprocess.Popen([args.codex, 'app-server', '--listen', 'unix://' + socket,
                                   '--enable', 'apply_patch_streaming_events'], env=env,
                                  stdout=log, stderr=log)
        proxy = None
        agent = None
        terminal = None
        terminal_reader = None
        try:
            deadline = time.monotonic() + 15
            while not Path(socket).exists():
                if daemon.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('App-server did not start; see ' + str(state / 'server.log'))
                time.sleep(0.05)
            proxy = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
            proxy.settimeout(25)
            proxy.connect(socket)
            incoming = proxy.makefile('rb')
            key = base64.b64encode(os.urandom(16)).decode()
            proxy.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
            assert b'101' in incoming.readline()
            headers = {}
            while True:
                line = incoming.readline()
                if line == b'\r\n': break
                name, value = line.decode().split(':', 1)
                headers[name.lower()] = value.strip()
            assert headers['sec-websocket-accept'] == base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            def frame(data, opcode=1):
                mask = os.urandom(4)
                length = len(data)
                head = bytes([0x80 | opcode])
                head += bytes([0x80 | length]) if length < 126 else bytes([0xfe]) + struct.pack('!H', length)
                proxy.sendall(head + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))
            def send(value):
                frame(json.dumps(value).encode())
            def receive():
                fragments = b''
                while True:
                    head = incoming.read(2)
                    if len(head) != 2: raise RuntimeError('App-server closed')
                    opcode, length = head[0] & 15, head[1] & 127
                    if length == 126: length = struct.unpack('!H', incoming.read(2))[0]
                    elif length == 127: length = struct.unpack('!Q', incoming.read(8))[0]
                    data = incoming.read(length)
                    if opcode == 9: frame(data, 10); continue
                    if opcode == 8: raise RuntimeError('App-server closed')
                    if opcode == 10: continue
                    fragments += data
                    if head[0] & 0x80: return json.loads(fragments)
            def response(identifier):
                while True:
                    value = receive()
                    if value.get('id') == identifier:
                        if 'error' in value: raise RuntimeError(value['error'])
                        return value['result']
            send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'dispatch-fixture', 'version': '1'}, 'capabilities': {'experimentalApi': True}}})
            response(1)
            send({'method': 'initialized', 'params': {}})
            send({'id': 2, 'method': 'thread/start', 'params': {'cwd': str(work), 'model': 'dispatch-fixture', 'approvalPolicy': 'never', 'sandbox': 'workspace-write'}})
            thread = response(2)['thread']['id']
            # Codex defers the durable rollout until the first turn; a fresh
            # empty thread cannot yet be resumed by a second client.
            send({'id': 20, 'method': 'turn/start', 'params': {'threadId': thread, 'input': [{'type': 'text', 'text': 'warmup', 'text_elements': []}]}})
            response(20)
            while receive().get('method') != 'turn/completed': pass
            metadata = {'thread': thread, 'socket': socket}
            if args.agent:
                terminal, slave = pty.openpty()
                agent = subprocess.Popen([args.codex, '--remote', 'unix://' + socket,
                                          '--no-alt-screen', 'resume', thread],
                                         env=dict(env, TERM='xterm-256color'), cwd=work,
                                         stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
                os.close(slave)
                def drain_terminal():
                    with (state / 'agent.log').open('wb') as output:
                        pending = b''
                        while agent.poll() is None:
                            if not select.select([terminal], [], [], 0.1)[0]: continue
                            try: data = os.read(terminal, 65536)
                            except OSError: break
                            if not data: break
                            output.write(data); output.flush()
                            pending += data
                            while b'\x1b[6n' in pending:
                                _, pending = pending.split(b'\x1b[6n', 1)
                                os.write(terminal, b'\x1b[1;1R')
                            pending = pending[-16:]
                terminal_reader = threading.Thread(target=drain_terminal, daemon=True)
                terminal_reader.start()
                time.sleep(0.3)
                if agent.poll() is not None:
                    raise RuntimeError('Codex TUI exited; see ' + str(state / 'agent.log'))
                metadata['agent'] = str(agent.pid)
            (state / 'ready.json').write_text(json.dumps(metadata))
            # XCTest attaches the shipping observer before releasing the turn.
            while not (state / 'go').exists():
                if time.monotonic() > deadline + 30:
                    raise RuntimeError('Observer did not attach')
                time.sleep(0.05)
            send({'id': 3, 'method': 'turn/start', 'params': {'threadId': thread, 'input': [{'type': 'text', 'text': 'DISPATCH_LIVE_PATCH', 'text_elements': []}]}})
            response(3)
            with (state / 'events.jsonl').open('w') as events:
                while True:
                    value = receive()
                    line = json.dumps(value) + '\n'
                    events.write(line); events.flush()
                    if value.get('method') == 'turn/completed':
                        (state / 'done.json').write_text(line)
                        break
            # Keep the owning client alive while XCTest checks reconnection.
            deadline = time.monotonic() + 15
            while not (state / 'stop').exists() and time.monotonic() < deadline:
                time.sleep(0.05)
        finally:
            if agent and agent.poll() is None:
                agent.terminate()
                try: agent.wait(timeout=5)
                except subprocess.TimeoutExpired: agent.kill(); agent.wait()
            if terminal_reader:
                terminal_reader.join(timeout=1)
            if terminal is not None:
                os.close(terminal)
            if proxy:
                proxy.close()
            daemon.terminate(); daemon.wait(timeout=10)
            server.shutdown()
