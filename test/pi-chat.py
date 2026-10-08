#!/usr/bin/env python3
"""Test real Pi JSON and RPC sessions against the shared localhost fixture."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import threading
import time
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from claude_fixture import FixtureServer
from pi_fixture import configure, environment, command, PROVIDER, MODEL


def assistant_text(message):
    return ''.join(block.get('text', '') for block in message.get('content', []) if block.get('type') == 'text')


def check_reply(rows, prompt):
    messages = [row['message'] for row in rows if row.get('type') == 'message_end'
                and row.get('message', {}).get('role') == 'assistant']
    assert messages and messages[-1]['stopReason'] == 'stop', messages
    assert 'Local Claude fixture reply: ' + prompt in assistant_text(messages[-1]), messages[-1]
    assert any(row.get('assistantMessageEvent', {}).get('type') == 'text_delta' for row in rows)
    assert any(row['type'] == 'agent_settled' for row in rows), 'Pi did not settle'
    return assistant_text(messages[-1])


def rpc(executable, state, env, server):
    """Read LF-framed JSON without text buffering or Unicode line splitting."""
    with (state / 'rpc.stderr.log').open('w') as stderr, (state / 'rpc.jsonl').open('wb') as log:
        process = subprocess.Popen(command(executable, '--mode', 'rpc'), cwd=state / 'work', env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
        pending = bytearray()
        rows = []

        def send(kind, identifier, **values):
            process.stdin.write((json.dumps({'type': kind, 'id': identifier, **values}, ensure_ascii=False) + '\n').encode())
            process.stdin.flush()

        def until(predicate):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, _, rest = pending.partition(b'\n')
                    pending[:] = rest
                    if not line.strip():
                        continue
                    row = json.loads(line)
                    rows.append(row)
                    if row.get('type') == 'response':
                        assert row.get('success'), row
                    if predicate(row):
                        return row
                if select.select([process.stdout], [], [], 0.1)[0]:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError('Pi RPC closed before the expected event')
                    log.write(chunk)
                    log.flush()
                    pending.extend(chunk)
                    assert len(pending) <= 4 * 1024 * 1024, 'Unbounded RPC frame'
            raise AssertionError('Pi RPC timed out; inspect rpc.jsonl')

        try:
            send('get_state', 'state')
            initial = until(lambda row: row.get('id') == 'state')['data']
            assert initial['model']['provider'] == PROVIDER and initial['model']['id'] == MODEL, initial
            send('set_thinking_level', 'effort', level='high')
            until(lambda row: row.get('id') == 'effort')
            send('get_state', 'effort-state')
            assert until(lambda row: row.get('id') == 'effort-state')['data']['thinkingLevel'] == 'high'
            start = len(rows)
            prompt = 'thinking RPC\nUnicode separator: \u2028 done'
            send('prompt', 'prompt', message=prompt)
            until(lambda row: row['type'] == 'agent_settled')
            check_reply(rows[start:], prompt)
            assert any(row.get('id') == 'prompt' and row.get('success') for row in rows)

            # Cancel a stream while it is producing output, then reuse the same
            # process/session. No mutation retries or artificial CLI success.
            server.delay = 0.02
            send('prompt', 'long', message='long cancellation check')
            until(lambda row: row.get('assistantMessageEvent', {}).get('type') == 'text_delta')
            send('abort', 'abort')
            until(lambda row: row.get('id') == 'abort')
            send('get_state', 'idle')
            idle = until(lambda row: row.get('id') == 'idle')['data']
            assert not idle['isStreaming'] and idle['sessionId'] == initial['sessionId'], idle
            server.delay = 0.001
            start = len(rows)
            send('prompt', 'recovery', message='after cancellation')
            until(lambda row: row['type'] == 'agent_settled')
            check_reply(rows[start:], 'after cancellation')
            return initial['sessionId']
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            process.stdin.close()
            process.stdout.close()


def test(executable, state):
    started = time.monotonic()
    version = subprocess.check_output([executable, '--version'], text=True, timeout=5).strip()
    with FixtureServer(state, delay=0.001) as server:
        state = configure(state, server.server_port)
        env = environment(state, server.server_port)
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.02), daemon=True)
        thread.start()

        def run(label, prompt, *extra):
            result = subprocess.run(command(executable, '-p', '--mode', 'json', *extra),
                                    cwd=state / 'work', env=env, input=prompt,
                                    capture_output=True, text=True, timeout=20)
            (state / (label + '.log')).write_text(result.stdout + '\n' + result.stderr)
            assert result.returncode == 0, result.stderr + result.stdout[-2000:]
            rows = [json.loads(line) for line in result.stdout.split('\n') if line.startswith('{')]
            text = check_reply(rows, prompt)
            session = next(row['id'] for row in rows if row.get('type') == 'session')
            return session, rows, text

        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                jobs = [pool.submit(run, name, name) for name in ('alpha', 'beta')]
                a, b = [job.result() for job in jobs]
            assert a[0] != b[0], 'Parallel sessions share an identity'
            resumed, _, _ = run('resume', 'line one\nline two', '--session', a[0])
            assert resumed == a[0], 'Resume changed the session ID'
            for label, prompt in [('literal-option', '--not-an-option'), ('literal-file', '@not-a-file')]:
                resumed, _, _ = run(label, prompt, '--session', a[0])
                assert resumed == a[0], 'Literal prompt changed the session ID'
            _, thinking, _ = run('thinking', 'thinking formatting preview')
            assert any(row.get('assistantMessageEvent', {}).get('type') == 'thinking_delta' for row in thinking)
            _, tools, text = run('tool', 'tool check')
            assert 'Tool result received: completed.' in text
            assert any(row.get('type') == 'tool_execution_end' and not row.get('isError') and
                       'DISPATCH_CLAUDE_TOOL_OK' in json.dumps(row.get('result')) for row in tools)
            _, disabled, _ = run('disabled', 'tool disabled check', '--exclude-tools', 'bash')
            assert not any(row['type'].startswith('tool_execution') for row in disabled)
            rpc_session = rpc(executable, state, env, server)
            transcripts = list((state / 'pi-home/sessions').glob('*.jsonl'))
            assert len(transcripts) == 6, 'Missing or duplicate Pi session transcripts'
            summary = {'version': version, 'seconds': time.monotonic() - started, 'cli_cases': 8,
                       'rpc': ['model and effort state', 'streamed Unicode prompt', 'abort', 'recovery in same session'],
                       'requests': server.request_count, 'rpc_session': rpc_session,
                       'transcripts': [str(path.relative_to(state)) for path in transcripts]}
            (state / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(json.dumps(summary, indent=2))
        finally:
            server.shutdown()
            thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pi', default=shutil.which('pi'))
    parser.add_argument('--keep', type=Path, help='New or empty results directory')
    args = parser.parse_args()
    if not args.pi:
        parser.error('Pi is required; pass --pi /path/to/pi')
    if args.keep and args.keep.exists() and any(args.keep.iterdir()):
        parser.error('--keep must be a new or empty directory')
    if args.keep:
        test(args.pi, args.keep.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='dispatch-pi-test-') as state:
            test(args.pi, Path(state))


if __name__ == '__main__':
    main()
