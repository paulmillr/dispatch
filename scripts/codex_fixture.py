#!/usr/bin/env python3
"""Deterministic, loopback-only Responses endpoint for the real Codex CLI.

No third-party modules, API keys, proxying, or outgoing HTTP requests.
"""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from fixture_barriers import FixtureBarriers, BarrierCancelled, interrupt_fixture, write_json
from codex_pty import command as codex_command

ROOT = Path(__file__).resolve().parent.parent
EVENTS = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse',
          'PostToolUse', 'PermissionRequest', 'PreCompact', 'PostCompact', 'Stop', 'Interrupt']


def prepare(state, port):
    state = Path(state).resolve()
    marker = state / '.dispatch-codex-fixture'
    if state.exists() and any(state.iterdir()) and not marker.exists():
        raise SystemExit(f'Refusing to overwrite a non-fixture directory: {state}')
    state.mkdir(parents=True, exist_ok=True)
    marker.touch()
    home = state / 'codex-home'
    work = state / 'work'
    home.mkdir(exist_ok=True)
    work.mkdir(exist_ok=True)
    settings = home / 'app-server-daemon/settings.json'
    settings.parent.mkdir(exist_ok=True)
    value = json.loads(settings.read_text()) if settings.exists() else {}
    value.setdefault('updater', {})['autoUpdateEnabled'] = False
    write_json(settings, value)
    if ledger := os.environ.get('DISPATCH_TEST_FIXTURES'):
        with open(ledger, 'a') as stream:
            stream.write(json.dumps(str(home)) + '\n')
    config = f'''model = "dispatch-fixture"
model_provider = "dispatch_fixture"
model_context_window = 128000
model_auto_compact_token_limit = 120000
approval_policy = "on-request"
sandbox_mode = "workspace-write"
web_search = "disabled"
check_for_update_on_startup = false
project_root_markers = []

[model_providers.dispatch_fixture]
name = "Dispatch local test endpoint"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 10000

[projects.{json.dumps(str(work))}]
trust_level = "trusted"

[features]
shell_snapshot = false
shell_snapshot_v2 = false

[analytics]
enabled = false

[feedback]
enabled = false

[otel]
exporter = "none"
trace_exporter = "none"
metrics_exporter = "none"
'''
    old_config = (home / 'config.toml').read_text() if (home / 'config.toml').exists() else ''
    trust = '\n'.join(re.findall(r'(?ms)^\[hooks\.state[^\n]*\]\n.*?(?=^\[|\Z)', old_config))
    (home / 'config.toml').write_text(config + '\n' + trust)
    # The capture wrapper records only synthetic fixture traffic, then invokes
    # the shipping bridge. Codex still requires its normal /hooks trust review.
    wrapper = state / 'capture-hook.sh'
    import shlex
    wrapper.write_text(f'''#!/bin/sh
input=$(/bin/cat)
printf '%s\\n' "$input" >> {shlex.quote(str(state / 'hooks.jsonl'))}
printf '%s' "$input" | /bin/sh {shlex.quote(str(ROOT / 'Dispatch/Resources/codex-chat-hook.sh'))}
''')
    wrapper.chmod(0o700)
    command = '/bin/sh ' + shlex.quote(str(wrapper))
    (home / 'hooks.json').write_text(json.dumps({'hooks': {
        event: [{'hooks': [{'type': 'command', 'command': command,
                            'timeout': 60 if event == 'PermissionRequest' else 3}]}]
        for event in EVENTS}}, indent=2))
    write_json(state / 'endpoint.json', {'port': port, 'home': str(home), 'work': str(work)})
    return home, work


def environment(home):
    env = dict(os.environ)
    # Avoid credentials and inherited provider overrides. Keep Dispatch routing
    # env vars, which are supplied independently by each real terminal surface.
    for key in list(env):
        if key.startswith(('OPENAI_', 'CHATGPT_', 'CODEX_')) or key.lower().endswith('_proxy'):
            env.pop(key, None)
    env['CODEX_HOME'] = str(home)
    env['ZDOTDIR'] = str(home)  # zshenv and shell plugins stay out of fixture tools
    env['NO_PROXY'] = '127.0.0.1,localhost,::1'
    # Fail non-local HTTP attempts before DNS for clients honoring proxy settings.
    # This is not a firewall: tools that ignore these variables can still connect.
    for key in ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY']:
        env[key] = 'http://127.0.0.1:1'
    return env


def last_prompt(body):
    for item in reversed(body.get('input', [])):
        if item.get('role') == 'user':
            content = item.get('content', [])
            if isinstance(content, str):
                return content
            return '\n'.join(x.get('text', '') for x in content if isinstance(x, dict))
    return ''


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, state, port=0, delay=0.04):
        self.state = Path(state)
        self.delay = delay
        self.lock = threading.Lock()
        self.requests = []
        self.barriers = FixtureBarriers(self.state)
        super().__init__(('127.0.0.1', port), Handler)

    def server_close(self):
        self.barriers.close()
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == '/health':
            self.json_response({'ok': True, 'requests': len(self.server.requests)})
        else:
            self.send_error(404)

    def json_response(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path not in ('/v1/responses', '/v1/responses/compact'):
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', '0'))
        if not 0 < length < 16 * 1024 * 1024:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(length))
        # Codex 0.154 also asks the provider for a background conversation title.
        # Keep that traffic visible, with a valid structured response, while
        # allowing submission tests to count actual conversation turns.
        schema = body.get('text', {}).get('format', {}).get('schema', {})
        title_request = (schema.get('required') == ['title']
                         and set(schema.get('properties', {})) == {'title'}
                         and not body.get('tools'))
        # /recap asks for a structured catch-up whose prompt mentions tools.
        recap_request = (schema.get('required') == ['summary', 'next_action']
                         and set(schema.get('properties', {})) == {'summary', 'next_action'})
        kind = 'title' if title_request else 'recap' if recap_request else 'conversation'
        title_request = title_request or recap_request
        # Never accept an accidental real credential, even on localhost.
        # Nanocodex always authenticates; its tests pass this fixed sentinel.
        if self.headers.get('Authorization') not in (None, 'Bearer dispatch-fixture'):
            self.send_error(400, 'Fixture requests must not include credentials')
            return
        prompt = '' if title_request or self.path.endswith('/compact') else last_prompt(body)
        try:
            with self.server.barriers.request(prompt, self.connection) as request:
                with self.server.lock:
                    self.server.requests.append(body)
                    with (self.server.state / 'requests.jsonl').open('a') as file:
                        file.write(json.dumps({'id': request.identifier, 'path': self.path,
                            'kind': kind, 'body': body}) + '\n')
                request.wait()
                self.respond(body, title_request, kind == 'recap')
        except FileExistsError:
            self.send_error(409, 'Fixture barrier marker already used')
        except (BarrierCancelled, BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True

    def respond(self, body, title_request, recap_request=False):
        if self.path.endswith('/compact'):
            self.json_response({'id': 'cmp_fixture', 'object': 'response.compaction', 'created_at': int(time.time()),
                                'output': [{'type': 'message', 'role': 'assistant', 'content': [
                                    {'type': 'output_text', 'text': 'Earlier fixture turns were compacted.'}]}],
                                'usage': {'input_tokens': 100, 'output_tokens': 20, 'total_tokens': 120}})
            return
        prompt = last_prompt(body)
        outputs = [x for x in body.get('input', []) if x.get('type') in ('function_call_output', 'custom_tool_call_output')]
        # Request one harmless local command for each matching user turn. The
        # call ID is prompt-specific so parallel sessions do not share state.
        call_id = 'fixture_' + __import__('hashlib').sha256(prompt.encode()).hexdigest()[:16]
        completed_tool = any(x.get('call_id') == call_id for x in outputs)
        wants_tool = not title_request and any(word in prompt.lower() for word in ('tool', 'approval', 'patch', 'formatting'))
        response_id = 'resp_' + uuid.uuid4().hex
        message_id = 'msg_' + uuid.uuid4().hex
        if not title_request and 'DISPATCH_CODE_APPROVAL' in prompt and not completed_tool:
            arguments = json.dumps({'cmd': "printf 'DISPATCH_LOCAL_TOOL_OK\\n'",
                                    'login': False, 'sandbox_permissions': 'require_escalated',
                                    'justification': 'Allow the repeated local fixture command?'})
            item = {'type': 'custom_tool_call', 'id': message_id, 'call_id': call_id,
                    'name': 'exec', 'input': 'for (let i = 0; i < 2; i++) { text(await tools.exec_command(' + arguments + ')); }',
                    'status': 'completed'}
            text = None
        elif not title_request and 'DISPATCH_LIVE_PATCH' in prompt and not completed_tool:
            item = {'type': 'custom_tool_call', 'id': message_id, 'call_id': call_id,
                    'name': 'apply_patch', 'input': '*** Begin Patch\n*** Add File: live-diff.swift\n+let first = 1\n+let second = 2\n*** End Patch\n', 'status': 'completed'}
            text = None
        elif not title_request and 'DISPATCH_ASYNC_QUESTION' in prompt and not completed_tool:
            item = {'type': 'function_call', 'id': message_id, 'call_id': call_id,
                    'name': 'request_user_input_async', 'arguments': json.dumps({'questions': [{
                        'title': 'Which format should the ongoing work use?',
                        'options': ['Brief (Recommended)', 'Detailed']}]}), 'status': 'completed'}
            text = None
        elif not title_request and any(marker in prompt for marker in ('DISPATCH_PLAN_QUESTION', 'DISPATCH_SIDE_QUESTION')) and not completed_tool:
            item = {'type': 'function_call', 'id': message_id, 'call_id': call_id,
                    'name': 'request_user_input', 'arguments': json.dumps({'questions': [{
                        'id': 'approach', 'header': 'Approach', 'question': 'Which approach should the fixture use?',
                        'options': [{'label': 'Small change (Recommended)', 'description': 'Keep the change focused.'},
                                    {'label': 'Broader change', 'description': 'Include the surrounding code.'}]}] + ([{
                        'id': 'detail', 'header': 'Detail', 'question': 'How should the answer be presented?',
                        'options': [{'label': 'Brief', 'description': 'A short answer.'},
                                    {'label': 'Detailed', 'description': 'Include examples.'}]}] if 'DISPATCH_SIDE_QUESTION' in prompt else [])}), 'status': 'completed'}
            text = None
        elif wants_tool and not completed_tool:
            advertised = list(body.get('tools', []))
            for entry in body.get('input', []):
                if entry.get('type') == 'additional_tools': advertised.extend(entry.get('tools', []))
            names = []
            while advertised:
                entry = advertised.pop()
                if entry.get('type') == 'namespace': advertised.extend(entry.get('tools', []))
                else: names.append(entry.get('name'))
            name = 'exec_command' if 'exec_command' in names else 'shell_command'
            args = {'cmd' if name == 'exec_command' else 'command': "printf 'DISPATCH_LOCAL_TOOL_OK\\n'"}
            if 'formatting' in prompt.lower():
                args = {'cmd' if name == 'exec_command' else 'command':
                        "printf 'Formatting fixture: intentional failure\\n'; exit 7"}
            if 'patch' in prompt.lower():
                args = {'cmd' if name == 'exec_command' else 'command':
                        "printf 'let fixture = true\\n' > dispatch-fixture.swift; "
                        "printf '%s\\n' '--- a/dispatch-fixture.swift' '+++ b/dispatch-fixture.swift' '@@ -0,0 +1 @@' '+let fixture = true'"}
            args['login'] = False
            if 'DISPATCH_BACKGROUND_TOOL' in prompt:
                args['cmd' if name == 'exec_command' else 'command'] = "printf '%s' $$ > dispatch-background.pid; exec sleep 60"
                if name == 'exec_command': args['yield_time_ms'] = 1000
            if 'approval' in prompt.lower():
                args.update(sandbox_permissions='require_escalated', justification='Allow the local fixture to print its test marker?')
            item = {'type': 'function_call', 'id': message_id, 'call_id': call_id,
                    'name': name, 'arguments': json.dumps(args), 'status': 'completed'}
            text = None
        else:
            suffix = '\n\nTool result received.' if completed_tool else ''
            text = 'Local fixture reply: ' + prompt + suffix
            if recap_request:
                text = json.dumps({'summary': 'Fixture recap: the conversation is ready for its next turn.',
                                   'next_action': 'Send the next fixture prompt.'})
            elif title_request:
                text = json.dumps({'title': 'Dispatch fixture conversation'})
            elif 'DISPATCH_PROPOSED_PLAN' in prompt:
                text = '<proposed_plan>\n# Fixture plan\n\nImplement the small fixture change and verify it.\n</proposed_plan>'
            elif 'formatting' in prompt.lower():
                text += ('\n\n## Formatting preview\n\nThe `event.id` is **stable**.\n\n'
                         '- Read the file\n- [x] Inspect the output\n\n'
                         '> This command intentionally exits with code 7.\n\n'
                         '```swift\n// Retry guard\nlet attempts = 3\nlet message = "Ready"\n```\n\n'
                         '| Check | Result |\n| --- | --- |\n| Markdown | Ready |\n| Shell | Exit 7 |')
            item = {'type': 'message', 'id': message_id, 'role': 'assistant', 'status': 'completed',
                    'phase': 'final_answer', 'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        sequence = 0

        def event(kind, **fields):
            nonlocal sequence
            value = {'type': kind, 'sequence_number': sequence, **fields}
            sequence += 1
            self.wfile.write(('event: ' + kind + '\ndata: ' + json.dumps(value) + '\n\n').encode())
            self.wfile.flush()

        event('response.created', response={'id': response_id, 'status': 'in_progress', 'output': []})
        if not title_request and 'DISPATCH_ASYNC_QUESTION ongoing' in prompt and completed_tool:
            time.sleep(1)
        if not title_request and prompt.startswith('SLOW_RESPONSE'):
            time.sleep(6)
        output = []
        if not title_request and prompt.startswith('DISPATCH_THINKING_ANIMATION'):
            # Exercise the real CLI/rollout path, including the interval
            # before it has a reported summary. Other fixtures stay fast.
            time.sleep(1)
            summary = 'two files changed, one new; tests green before commit'
            reasoning = {'id': 'rs_' + uuid.uuid4().hex, 'type': 'reasoning',
                         'summary': [{'type': 'summary_text', 'text': summary}]}
            event('response.output_item.added', output_index=0, item={**reasoning, 'summary': []})
            event('response.reasoning_summary_part.added', output_index=0, item_id=reasoning['id'],
                  summary_index=0, part={'type': 'summary_text', 'text': ''})
            for index in range(0, len(summary), 12):
                event('response.reasoning_summary_text.delta', output_index=0, item_id=reasoning['id'],
                      summary_index=0, delta=summary[index:index+12])
                time.sleep(0.1)
            event('response.output_item.done', output_index=0, item=reasoning)
            output.append(reasoning)
            time.sleep(4)
        output_index = len(output)
        if text is not None:
            event('response.output_item.added', output_index=output_index, item={**item, 'content': [], 'status': 'in_progress'})
            event('response.content_part.added', output_index=output_index, item_id=message_id, content_index=0,
                  part={'type': 'output_text', 'text': '', 'annotations': []})
            for index in range(0, len(text), 12):
                event('response.output_text.delta', output_index=output_index, item_id=message_id, content_index=0, delta=text[index:index+12])
                time.sleep(self.server.delay)
            event('response.output_text.done', output_index=output_index, item_id=message_id, content_index=0, text=text)
        elif item['type'] == 'custom_tool_call':
            event('response.output_item.added', output_index=output_index, item={**item, 'input': '', 'status': 'in_progress'})
            for chunk in ['*** Begin Patch\n*** Add File: live-diff.swift\n+let first = 1\n', '+let second = 2\n', '*** End Patch\n']:
                event('response.custom_tool_call_input.delta', output_index=output_index, item_id=message_id, call_id=call_id, delta=chunk)
                time.sleep(0.5)
            event('response.custom_tool_call_input.done', output_index=output_index, item_id=message_id, input=item['input'])
        else:
            event('response.output_item.added', output_index=output_index, item={**item, 'arguments': '', 'status': 'in_progress'})
            event('response.function_call_arguments.delta', output_index=output_index, item_id=message_id, delta=item['arguments'])
            event('response.function_call_arguments.done', output_index=output_index, item_id=message_id, arguments=item['arguments'])
        event('response.output_item.done', output_index=output_index, item=item)
        event('response.completed', response={'id': response_id, 'status': 'completed', 'output': output + [item],
              'usage': {'input_tokens': 100, 'output_tokens': 30, 'total_tokens': 130}})
        self.close_connection = True


def resources(homes):
    packages = []
    for home in map(Path, homes):
        home = home.resolve()
        if not home.exists():
            continue
        if not (home.parent / '.dispatch-codex-fixture').is_file() or home.stat().st_uid != os.getuid():
            raise RuntimeError('Not an owned Codex fixture: ' + str(home))
        if (home / 'packages').exists():
            packages.append(str(home / 'packages'))
    processes = {}
    if packages:
        for line in subprocess.check_output(['ps', '-axww', '-o', 'uid=,pid=,command='], text=True).splitlines():
            uid, pid, command = line.strip().split(None, 2)
            if int(uid) == os.getuid() and any(command.startswith(path + '/') for path in packages):
                processes[int(pid)] = command
    return {'processes': processes, 'packages': packages}


def stop(home, codex):
    if any((home / 'app-server-daemon' / name).exists() for name in ['daemon.pid', 'app-server.pid']):
        if not codex:
            raise RuntimeError('Cannot stop fixture daemon without its Codex executable')
        subprocess.run([codex, 'app-server', 'daemon', 'stop'],
                       env=environment(home), check=True, timeout=20)
    # Codex's daemon stop deliberately leaves its updater running. Recheck each
    # process against this fixture before signalling; never touch another home.
    for pid, command in resources([home])['processes'].items():
        if resources([home])['processes'].get(pid) == command:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 5
    while resources([home])['processes']:
        if time.monotonic() >= deadline:
            raise RuntimeError('Codex fixture processes did not stop: ' + str(home))
        time.sleep(0.05)
    for path in resources([home])['packages']:
        shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['serve', 'launch', 'routing', 'sessions', 'app-server'])
    parser.add_argument('--state', type=Path, default=Path('/tmp/dispatch-codex-demo'))
    parser.add_argument('--hook-driver', action='store_true', help='Accept one synthetic hook from a real child of this fixture TUI')
    parser.add_argument('--no-hooks', action='store_true', help='Test process/transcript discovery without installing fixture hooks')
    parser.add_argument('--remote', help='Existing app-server endpoint, or listener for app-server mode')
    parser.add_argument('--no-daemon', action='store_true', help='Keep the native conversation and rollout descriptors in the TUI process')
    parser.add_argument('--dispatch', action='store_true', help='Use the shipping Dispatch Codex launcher')
    parser.add_argument('--resume', help='Resume this exact Codex session ID')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--delay', type=float, default=0.08)
    parser.add_argument('--codex', default=shutil.which('codex'))
    args = parser.parse_args()
    if args.mode == 'sessions':
        for path in sorted((args.state / 'codex-home/sessions').rglob('*.jsonl')):
            try:
                with path.open() as file:
                    record = json.loads(file.readline())
                meta = record.get('payload', {})
                if record.get('type') == 'session_meta':
                    print(meta.get('id') or meta.get('session_id'), path.name)
            except (OSError, ValueError):
                continue
        return
    if args.mode == 'serve':
        signal.signal(signal.SIGTERM, interrupt_fixture)
        # Validate directory ownership before creating request logs.
        prepare(args.state, 1)
        server = FixtureServer(args.state, args.port, args.delay)
        home, work = prepare(args.state, server.server_port)
        if args.no_hooks:
            (home / 'hooks.json').unlink()
        print(f'Local Codex endpoint: http://127.0.0.1:{server.server_port}/v1', flush=True)
        print(f'In a Dispatch terminal: python3 {Path(__file__).resolve()} launch --state {args.state}', flush=True)
        print('Stop with Ctrl-C. Requests and hook events stay in the fixture directory.', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            try:
                server.server_close()
            finally:
                stop(home, args.codex)
    else:
        if args.mode == 'routing':
            prepare(args.state, 1)
            (args.state / 'codex-home/hooks.json').unlink()
        metadata = json.loads((args.state / 'endpoint.json').read_text())
        if not args.codex:
            parser.error('Install Codex CLI first, or pass --codex /path/to/codex')
        os.chdir(metadata['work'])
        env = environment(metadata['home'])
        if args.mode == 'app-server':
            if not args.remote: parser.error('app-server mode requires --remote')
            os.execvpe(args.codex, [args.codex, 'app-server', '--listen', args.remote], env)
        if args.remote and args.no_daemon:
            parser.error('--remote and --no-daemon select different native launch modes')
        arguments = (['--no-daemon'] if args.no_daemon else []) + (['--remote', args.remote] if args.remote else []) + (['resume', args.resume] if args.resume else [])
        if args.dispatch and not env.get('DISPATCH_HELPER_EXECUTABLE') and not env.get('DISPATCH_SSH_HELPER'):
            parser.error('--dispatch requires a Dispatch terminal')
        env['PATH'] = str(Path(args.codex).parent) + os.pathsep + env.get('PATH', '')
        argv = codex_command(args.codex, ['--no-alt-screen', *arguments], env)
        if args.hook_driver:
            if args.remote:
                parser.error('--hook-driver requires a local TUI owner')
            # The typed launcher spawns Codex: a child of that launcher would be
            # a sibling, not an authenticated descendant of the TUI. Use the
            # existing standalone native mode for this ownership fixture.
            argv = [args.codex, '--no-alt-screen', *([] if args.no_daemon else ['--no-daemon']), *arguments]
            # exec preserves this PID; the sender remains an actual descendant of
            # the verified TUI. No payload PID or test-only authentication route.
            owner = os.getpid()
            mailbox = args.state.resolve() / f'hook-{owner}'
            mailbox.mkdir(mode=0o700)
            if os.fork() == 0:
                child = None
                try:
                    request = mailbox / 'request.json'
                    while os.getppid() == owner:
                        if request.exists():
                            helper = env.get('DISPATCH_HELPER_EXECUTABLE') or env.get('DISPATCH_SSH_HELPER')
                            if not helper:
                                raise RuntimeError('Fixture hook requires a Dispatch helper')
                            child = subprocess.Popen([helper, 'hook', 'codex'], env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                            payload = request.read_bytes()
                            deadline = time.monotonic() + 60
                            while os.getppid() == owner and time.monotonic() < deadline:
                                try:
                                    output, error = child.communicate(payload, timeout=0.1)
                                    write_json(mailbox / 'reply.json', {'status': child.returncode,
                                        'output': output.decode(), 'error': error.decode()})
                                    break
                                except subprocess.TimeoutExpired:
                                    payload = None
                            else:
                                raise TimeoutError("Hook owner exited or hook reply timed out")
                            break
                        time.sleep(0.025)
                except BaseException as error:
                    write_json(mailbox / 'reply.json', {'status': 1, 'output': '', 'error': str(error)})
                finally:
                    if child is not None and child.poll() is None:
                        child.kill()
                        child.communicate()
                    os._exit(0)
        os.execvpe(argv[0], argv, env)


if __name__ == '__main__':
    main()
