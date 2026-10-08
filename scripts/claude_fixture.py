#!/usr/bin/env python3
"""Deterministic localhost Messages API for real Claude Code integration tests.

Standard library only; no model, real credentials, or upstream requests.
"""
import argparse
from collections import deque
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import uuid
from fixture_barriers import FixtureBarriers, BarrierCancelled, interrupt_fixture, write_json

MODEL = 'dispatch-fixture'
API_KEY = 'dispatch-local-fixture'
MAX_BODY = 4 * 1024 * 1024
MAX_LOG = 64 * 1024 * 1024
TOOL_COMMAND = "printf 'DISPATCH_CLAUDE_TOOL_OK\\n'"


def prepare(state):
    state = Path(state).resolve()
    marker = state / '.dispatch-claude-fixture'
    if state.exists() and any(state.iterdir()) and not marker.is_file():
        raise ValueError(f'Refusing to overwrite a non-fixture directory: {state}')
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    marker.touch()
    for name in ('claude-home', 'work', 'offline-bin'):
        (state / name).mkdir(exist_ok=True, mode=0o700)
    ssh = state / 'offline-bin' / 'ssh'
    ssh.write_text('#!/bin/sh\nexit 1\n')
    ssh.chmod(0o700)
    return state


def environment(state, port, config=None):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('ANTHROPIC_', 'CLAUDE_', 'CLAUDECODE', 'AWS_', 'GOOGLE_', 'VERTEX_'))
           and not key.lower().endswith('_proxy')}
    env.update(ANTHROPIC_BASE_URL=f'http://127.0.0.1:{port}', ANTHROPIC_API_KEY=API_KEY,
               CLAUDE_CONFIG_DIR=str(config or Path(state) / 'claude-home'),
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
               DISABLE_TELEMETRY='1', DISABLE_ERROR_REPORTING='1',
               NO_PROXY='127.0.0.1,localhost,::1', no_proxy='127.0.0.1,localhost,::1')
    # Best effort for clients honoring proxies, not a network sandbox.
    for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        env[key] = env[key.lower()] = 'http://127.0.0.1:1'
    # Git's SSH transport ignores HTTP proxies. Startup catalog checks must
    # remain offline too, without consulting personal SSH configuration.
    env['GIT_SSH_COMMAND'] = '/usr/bin/false'
    # Claude also probes GitHub auth by spawning ssh directly during startup.
    # Keep that probe offline and out of the foreground SSH-discovery path.
    env['PATH'] = str(Path(state) / 'offline-bin') + os.pathsep + env.get('PATH', os.defpath)
    return env


def command(executable, *arguments, integration=False):
    # Bare mode avoids personal hooks, plugins, memory and keychain auth.
    # Keep manual permission prompts even when Claude defaults to auto mode.
    mode = ['--system-prompt', 'You are helping test Dispatch locally.'] if integration else ['--bare']
    return [executable, *mode, '--model', MODEL, '--permission-mode', 'default', '--setting-sources', '',
            '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', *arguments]


def prepare_integration(state, config):
    """Skip the vendor's online welcome tour in this disposable test profile."""
    state = prepare(state)
    config.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = config / '.claude.json'
    # Preserve choices and sessions on subsequent launches; never touch HOME.
    try:
        with path.open('x') as output:
            path.chmod(0o600)
            json.dump({'hasCompletedOnboarding': True, 'theme': 'dark', 'autoUpdates': False,
                       'customApiKeyResponses': {'approved': [API_KEY[-20:]], 'rejected': []},
                       'projects': {str(state / 'work'): {'hasTrustDialogAccepted': True}}}, output)
    except FileExistsError:
        pass
    # Current Claude persists this updater choice during first startup. Seed it
    # before exec so that startup cannot overwrite hooks installed concurrently
    # by Dispatch after discovering the new process. Preserve existing hooks.
    settings = config / 'settings.json'
    try:
        with settings.open('x') as output:
            settings.chmod(0o600)
            json.dump({'env': {'DISABLE_AUTOUPDATER': '1'}}, output)
    except FileExistsError:
        pass


def validate(body):
    if not isinstance(body, dict) or not isinstance(body.get('model'), str):
        raise ValueError('Expected a model and messages object')
    messages = body.get('messages')
    if not isinstance(messages, list) or not messages or len(messages) > 10000:
        raise ValueError('Expected a bounded nonempty messages array')
    if 'stream' in body and type(body['stream']) is not bool:
        raise ValueError('stream must be a boolean')
    for message in messages:
        # Normal Claude sessions also send trailing system context messages.
        # They must not become the echoed user prompt or a tool result.
        if not isinstance(message, dict) or message.get('role') not in ('user', 'assistant', 'system'):
            raise ValueError('Invalid message role')
        content = message.get('content')
        if not isinstance(content, (str, list)):
            raise ValueError('Invalid message content')
        if isinstance(content, list) and any(not isinstance(item, dict) for item in content):
            raise ValueError('Invalid content block')
    tools = body.get('tools', [])
    if not isinstance(tools, list) or any(not isinstance(tool, dict) for tool in tools):
        raise ValueError('Invalid tools')


def prompt_and_result(body):
    """Only this turn's result can finish a tool scenario, including after resume."""
    def human_text(parts):
        text = '\n'.join(reversed(parts))
        text = re.sub(r'<(system-reminder|local-command-caveat|command-name|command-message|command-args|local-command-stdout)>.*?</\1>',
                      '', text, flags=re.S).strip()
        return re.sub(r'^\[Request interrupted by user(?: for tool use)?\](?:\s*\n+|$)', '', text)

    results = []
    for message in reversed(body['messages']):
        if message['role'] != 'user':
            continue
        content = message['content']
        blocks = [{'type': 'text', 'text': content}] if isinstance(content, str) else content
        text = []
        for item in reversed(blocks):
            if item.get('type') == 'text' and isinstance(item.get('text'), str):
                text.append(item['text'])
            elif item.get('type') == 'tool_result':
                # Claude merges a cancelled tool result, interruption marker,
                # and the next human prompt into one user message. A result
                # before that new prompt belongs to the previous turn.
                if prompt := human_text(text):
                    return prompt, list(reversed(results))
                text = []
                results.append(item)
        if prompt := human_text(text):
            return prompt, list(reversed(results))
    return '', list(reversed(results))


def response(body):
    prompt, results = prompt_and_result(body)
    lowered = prompt.lower()
    blocks = []
    thinking = body.get('thinking', {})
    if 'thinking' in lowered and isinstance(thinking, dict) and thinking.get('type') in ('enabled', 'adaptive'):
        blocks.append({'type': 'thinking', 'thinking':
                       'Synthetic fixture trace: checking the request, preparing a small change, and verifying the result.',
                       'signature': 'dispatch-fixture-signature'})
    tools = {tool.get('name') for tool in body.get('tools', []) if isinstance(tool.get('name'), str)}
    shell = next((name for name in ('Bash', 'bash') if name in tools), None)
    if 'question' in lowered and 'AskUserQuestion' in tools and not results:
        questions = [{'question': 'How much detail should the reply include?', 'header': 'Detail',
                      'options': [{'label': 'Compact', 'description': 'A short reply.'},
                                  {'label': 'Detailed', 'description': 'Include the reasoning.'}], 'multiSelect': False}]
        if 'multiple' in lowered:
            questions += [{'question': 'Which checks should be included?', 'header': 'Checks',
                           'options': [{'label': 'Tests', 'description': 'Run the focused tests.'},
                                       {'label': 'Documentation', 'description': 'Check the usage notes.'}], 'multiSelect': True},
                          {'question': 'Which language should the example use?', 'header': 'Language',
                           'options': [{'label': 'Swift', 'description': 'A native app example.'},
                                       {'label': 'Rust', 'description': 'A helper example.'}], 'multiSelect': False}]
        blocks += [{'type': 'text', 'text': 'I need a few choices before continuing.'},
                   {'type': 'tool_use', 'id': 'toolu_' + uuid.uuid4().hex, 'name': 'AskUserQuestion',
                    'input': {'questions': questions}}]
        stop = 'tool_use'
    elif 'tool' in lowered and shell and not results:
        tool_command = "python3 -c \"from pathlib import Path; Path('dispatch-approval-marker').write_text('approved')\"" if 'permission' in lowered else TOOL_COMMAND
        arguments = {'command': tool_command}
        if shell == 'Bash':
            arguments['description'] = 'Print the Dispatch fixture marker'
        blocks += [{'type': 'text', 'text': 'I’ll run the local fixture check.'},
                   {'type': 'tool_use', 'id': 'toolu_' + uuid.uuid4().hex, 'name': shell,
                    'input': arguments}]
        stop = 'tool_use'
    else:
        text = 'Local Claude fixture reply: ' + prompt[-4000:]
        if results:
            failed = any(item.get('is_error') for item in results)
            text += '\n\nTool result received: ' + ('denied or failed.' if failed else 'completed.')
            if 'question' in lowered:
                text += '\n\nAnswers received: ' + json.dumps([item.get('content') for item in results], ensure_ascii=False)[-4000:]
        if 'formatting' in lowered:
            text += '\n\n## Formatting preview\n\n- Streaming text\n- `inline code`\n\n```swift\nlet fixture = true\n```\n'
        if 'long' in lowered:
            text += '\n\n' + '\n\n'.join(f'{i}. Local fixture paragraph for scrolling and history.' for i in range(1, 81))
        blocks.append({'type': 'text', 'text': text})
        stop = 'end_turn'
    return {'id': 'msg_' + uuid.uuid4().hex, 'type': 'message', 'role': 'assistant',
            'model': body['model'], 'content': blocks, 'stop_reason': stop, 'stop_sequence': None,
            'usage': {'input_tokens': 100, 'output_tokens': 80,
                      'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}}


def events(message):
    yield {'type': 'message_start', 'message': {**message, 'content': [], 'stop_reason': None,
                                              'usage': {**message['usage'], 'output_tokens': 0}}}
    for index, block in enumerate(message['content']):
        kind = block['type']
        field = {'text': 'text', 'thinking': 'thinking', 'tool_use': 'input'}[kind]
        start = {**block, field: {} if kind == 'tool_use' else ''}
        if kind == 'thinking':
            start['signature'] = ''
        yield {'type': 'content_block_start', 'index': index, 'content_block': start}
        value = json.dumps(block[field]) if kind == 'tool_use' else block[field]
        for offset in range(0, len(value), 32):
            delta = ({'type': 'input_json_delta', 'partial_json': value[offset:offset + 32]}
                     if kind == 'tool_use' else {'type': kind + '_delta', field: value[offset:offset + 32]})
            yield {'type': 'content_block_delta', 'index': index, 'delta': delta}
        if kind == 'thinking':
            yield {'type': 'content_block_delta', 'index': index,
                   'delta': {'type': 'signature_delta', 'signature': block['signature']}}
        yield {'type': 'content_block_stop', 'index': index}
    yield {'type': 'message_delta', 'delta': {'stop_reason': message['stop_reason'], 'stop_sequence': None},
           'usage': message['usage']}
    yield {'type': 'message_stop'}


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, state, port=0, delay=0.04):
        if not math.isfinite(delay) or not 0 <= delay <= 1:
            raise ValueError('delay must be between 0 and 1 second')
        self.state = prepare(state)
        self.delay = delay
        self.lock = threading.Lock()
        self.slots = threading.BoundedSemaphore(8)
        self.requests = deque(maxlen=32)
        self.request_count = 0
        self.barriers = FixtureBarriers(self.state)
        super().__init__(('127.0.0.1', port), Handler)
        write_json(self.state / 'endpoint.json', {'port': self.server_port})

    def server_close(self):
        self.barriers.close()
        super().server_close()

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def record(self, path, body, identifier):
        with self.lock:
            log = self.state / 'requests.jsonl'
            data = json.dumps({'id': identifier, 'path': path, 'body': body}) + '\n'
            if (log.stat().st_size if log.exists() else 0) + len(data.encode()) > MAX_LOG:
                raise ValueError('Fixture capture is full; use a new state directory')
            with log.open('a') as file:
                file.write(data)
            self.requests.append(body)
            self.request_count += 1


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_args):
        pass

    def json_response(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, message, status=400):
        self.json_response({'type': 'error', 'error': {'type': 'invalid_request_error', 'message': message}}, status)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/health':
            self.json_response({'ok': True, 'fixture': 'dispatch-claude', 'requests': self.server.request_count})
        elif path == '/v1/models':
            self.json_response({'data': [{'id': MODEL, 'type': 'model', 'display_name': 'Dispatch local fixture',
                                          'created_at': '2000-01-01T00:00:00Z'}],
                                'has_more': False, 'first_id': MODEL, 'last_id': MODEL})
        else:
            self.error('Unknown fixture endpoint', 404)

    def do_POST(self):
        try:
            self.post()
        except FileExistsError:
            self.error('Fixture barrier marker already used', 409)
        except (BarrierCancelled, BrokenPipeError, ConnectionResetError, TimeoutError):
            pass  # Cancellation is expected; no retry and no global turn state.

    def post(self):
        path = urlsplit(self.path).path
        if path not in ('/v1/messages', '/v1/messages/count_tokens'):
            self.error('Unknown fixture endpoint', 404)
            return
        if self.headers.get('Authorization') or self.headers.get('x-api-key') != API_KEY:
            self.error('Use only the dummy fixture API key; credentials are never recorded', 401)
            return
        try:
            lengths = self.headers.get_all('Content-Length', [])
            if len(lengths) != 1 or self.headers.get('Transfer-Encoding'):
                raise ValueError('Expected one Content-Length')
            length = int(lengths[0])
            if not 0 < length <= MAX_BODY:
                self.error('Request body exceeds the fixture limit', 413)
                return
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError('Incomplete request')
            body = json.loads(data)
            validate(body)
        except (ValueError, RecursionError, UnicodeError):
            self.error('Invalid, incomplete or oversized fixture request/capture')
            return
        prompt = '' if path.endswith('/count_tokens') else prompt_and_result(body)[0]
        with self.server.barriers.request(prompt, self.connection) as request:
            self.server.record(path, body, request.identifier)
            request.wait()
            self.respond(body, path, data)

    def respond(self, body, path, data):
        if path.endswith('/count_tokens'):
            self.json_response({'input_tokens': max(1, len(data) // 4)})
            return
        message = response(body)
        if not body.get('stream'):
            self.json_response(message)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        for event in events(message):
            self.wfile.write(f'event: {event["type"]}\ndata: {json.dumps(event)}\n\n'.encode())
            self.wfile.flush()
            if event['type'] == 'content_block_delta':
                time.sleep(self.server.delay)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['serve', 'launch'])
    parser.add_argument('--state', type=Path, default=Path('/tmp/dispatch-claude-demo'))
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--delay', type=float, default=0.04, help='Seconds between streamed chunks (0–1)')
    parser.add_argument('--claude', default=shutil.which('claude'))
    parser.add_argument('--resume', help='Resume an exact fixture session ID')
    parser.add_argument('--integration', action='store_true', help='Use normal interactive mode with its live session registry')
    parser.add_argument('--hooks', action='store_true', help='Load settings.json from the isolated fixture profile (requires --integration)')
    parser.add_argument('--config', type=Path, help='Claude config directory (default STATE/claude-home), e.g. where the helper installs its integration')
    args = parser.parse_args()
    try:
        if args.mode == 'serve':
            signal.signal(signal.SIGTERM, interrupt_fixture)
            with FixtureServer(args.state, args.port, args.delay) as server:
                print(f'Local Claude endpoint: http://127.0.0.1:{server.server_port}', flush=True)
                print('In a Dispatch terminal: ' + shlex.join(['python3', str(Path(__file__).resolve()),
                      'launch', '--state', str(server.state)]), flush=True)
                print('Try: hello, thinking, tool check, formatting, long reply. Stop with Ctrl-C.', flush=True)
                server.serve_forever()
        else:
            state = args.state.resolve()
            if not (state / '.dispatch-claude-fixture').is_file():
                parser.error('Start the fixture server first')
            port = json.loads((state / 'endpoint.json').read_text())['port']
            if type(port) is not int or not 1 <= port <= 65535:
                parser.error('Invalid fixture port')
            if not args.claude:
                parser.error('Claude Code is required; pass --claude /path/to/claude')
            from urllib.request import ProxyHandler, build_opener
            with build_opener(ProxyHandler({})).open(f'http://127.0.0.1:{port}/health', timeout=2) as reply:
                if json.load(reply).get('fixture') != 'dispatch-claude':
                    parser.error('The fixture server is not running at this endpoint')
            # Native Claude also creates settings during startup. Keep future
            # fixture files private even when the login shell uses umask 0002;
            # the protected hook installer correctly rejects writable sharing.
            os.umask(0o077)
            os.chdir(state / 'work')
            config = (args.config or state / 'claude-home').resolve()
            if args.integration:
                prepare_integration(state, config)
            extra = ['--resume', args.resume] if args.resume else []
            if args.hooks:
                if not args.integration:
                    parser.error('--hooks requires --integration')
                settings = config / 'settings.json'
                if not settings.is_file():
                    parser.error('Install hooks into the fixture settings.json first')
                extra += ['--settings', str(settings)]
            env = environment(state, port, config)
            os.execvpe(args.claude, command(args.claude, *extra, integration=args.integration), env)
    except KeyboardInterrupt:
        pass
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
