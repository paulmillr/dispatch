#!/usr/bin/env python3
"""Run real Codex against a local fixture endpoint, with isolated config."""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import socketserver
import sys
from http.server import BaseHTTPRequestHandler
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from codex_pty import CodexPTY

from codex_fixture import FixtureServer, environment, prepare, stop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', default=shutil.which('codex'))
    parser.add_argument('--keep', type=Path, help='Keep requests and real rollouts in this new fixture directory')
    args = parser.parse_args()
    if not args.codex:
        parser.error('Codex CLI is required')
    version = subprocess.check_output([args.codex, '--version'], text=True).strip()
    if not version.startswith('codex-cli ') or not version.removeprefix('codex-cli ').strip():
        parser.error('Expected a Codex CLI executable; got ' + version)
    state = (args.keep or Path(tempfile.mkdtemp(prefix='dispatch-codex-test-',
        dir='/private/tmp' if sys.platform == 'darwin' else None))).resolve()
    if args.keep and state.exists() and any(state.iterdir()):
        parser.error('--keep must name a new or empty directory')
    prepare(state, 1)
    server = FixtureServer(state, delay=0.005)
    home, work = prepare(state, server.server_port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = environment(home)

    def run(prompt, resume=None):
        command = [args.codex, 'exec', '--skip-git-repo-check', '--json']
        if resume:
            command += ['resume', resume]
        command += [prompt]
        result = subprocess.run(command, cwd=work, env=env, text=True, capture_output=True, timeout=30)
        (state / ('cli-' + prompt.splitlines()[0].replace(' ', '-') + '.log')).write_text(result.stdout + '\n' + result.stderr)
        assert result.returncode == 0, result.stderr + result.stdout
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        assert any('Local fixture reply: ' + prompt in json.dumps(row, ensure_ascii=False).replace('\\n', '\n') for row in rows), result.stdout
        session_id = next(row['thread_id'] for row in rows if row.get('type') == 'thread.started')
        return session_id, rows

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            a, b = list(pool.map(run, ['session alpha', 'session beta']))
        assert a[0] != b[0], 'Parallel sessions must have different IDs'
        resumed, _ = run('line one\nline two', resume=a[0])
        assert resumed == a[0], 'Resume must retain the Codex session ID'
        run('tool check')
        run('patch source preview')
        _, formatted = run('formatting preview')
        assert any(row.get('item', {}).get('exit_code') == 7 for row in formatted), formatted
        assert any('## Formatting preview' in json.dumps(row) for row in formatted), formatted
        assert (work / 'dispatch-fixture.swift').read_text() == 'let fixture = true\n', 'Real Codex did not write the local source fixture'
        assert any('+++ b/dispatch-fixture.swift' in json.dumps(r) for r in server.requests), 'Real Codex did not return the diff output'
        assert any(any(x.get('type') == 'function_call_output' for x in r.get('input', [])) for r in server.requests), 'Real Codex did not return tool output'
        assert all(r.get('model') == 'dispatch-fixture' for r in server.requests)
        assert not (state / 'hooks.jsonl').exists(), 'Unreviewed hooks unexpectedly ran'
        hook_events = []
        decision = ['allow']
        class HookHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_POST(self):
                event = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                hook_events.append(event)
                body = b''
                if event['hook_event_name'] == 'PermissionRequest' and decision[0]:
                    body = json.dumps({'hookSpecificOutput': {'hookEventName': 'PermissionRequest',
                                      'decision': {'behavior': decision[0]}}}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                try:
                    self.end_headers(); self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    # Session exit or native fallback can close an ordinary hook
                    # before its empty acknowledgment is written.
                    pass
        class HookServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
            daemon_threads = True
        hook_server = HookServer(str(state / 'hook.sock'), HookHandler)
        threading.Thread(target=hook_server.serve_forever, daemon=True).start()
        env['DISPATCH_CHAT_SOCKET'] = str(state / 'hook.sock')
        env['DISPATCH_CHAT_TOKEN'] = __import__('uuid').uuid4().hex
        cli = CodexPTY(args.codex, work, env)
        def wait_hook(name, after=0):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                cli.pump()
                matches = [e for e in hook_events[after:] if e['hook_event_name'] == name]
                if matches: return matches[-1]
            raise AssertionError('Missing real hook: ' + name)
        try:
            cli.trust_fixture_hooks()
            deadline = time.monotonic() + 10
            while (home / 'config.toml').read_text().count('trusted_hash') < 10 and time.monotonic() < deadline:
                cli.pump(0.1)
            assert (home / 'config.toml').read_text().count('trusted_hash') == 10, 'Native hook trust was not saved'
            (state / 'hook-review-cli.log').write_text(cli.transcript)
            cli.submit('initial local turn')
            wait_hook('SessionStart')
            wait_hook('Stop')
            for value in ['allow', 'deny', None]:
                decision[0] = value
                start = len(hook_events)
                cli.submit('approval ' + (value or 'terminal'))
                permission = wait_hook('PermissionRequest', start)
                assert permission['tool_name'] == 'Bash'
                assert 'DISPATCH_LOCAL_TOOL_OK' in permission['tool_input']['command']
                if value is None:
                    cli.expect('Would you like to run the following command?')
                    cli.send('y')  # Exercise native terminal fallback, once.
                event = wait_hook('Stop', start)
                assert 'Local fixture reply:' in event.get('last_assistant_message', '')
                if value == 'allow':
                    assert any(e['hook_event_name'] == 'PostToolUse' for e in hook_events[start:])
                if value == 'deny':
                    assert not any(e['hook_event_name'] == 'PostToolUse' for e in hook_events[start:])
            start = len(hook_events)
            cli.submit('/compact')
            wait_hook('PreCompact', start); wait_hook('PostCompact', start)
            cli.submit('/quit')
            wait_hook('SessionEnd')
        finally:
            print('Closing local CLI and hook receiver…', flush=True)
            (state / 'interactive-cli.log').write_text(cli.transcript)
            cli.close(); hook_server.shutdown(); hook_server.server_close()
        rollouts = list(home.glob('sessions/**/*.jsonl'))
        assert len(rollouts) >= 3, 'Expected real Codex rollouts'
        print(f'PASS: real Codex {version}; two sessions, resume, multiline, tools, source/diff and formatting fixtures, native hook trust review, allow/deny/terminal fallback, compaction, and session exit.')
        print(f'{len(server.requests)} requests served exclusively by 127.0.0.1:{server.server_port}. No API key used.')
        if args.keep:
            print('Artifacts: ' + str(state.resolve()))
    finally:
        print('Stopping local endpoint…', flush=True)
        server.shutdown(); server.server_close()
        stop(home, args.codex)
        if not args.keep:
            shutil.rmtree(state)


if __name__ == '__main__':
    main()
