#!/usr/bin/env python3
"""Exercise the localhost fixture and real Claude Code, without an API account."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'scripts'))
from claude_fixture import API_KEY, MAX_BODY, MODEL, TOOL_COMMAND, FixtureServer, command, environment, prepare, prepare_integration


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dispatch-claude-endpoint-')
        self.addCleanup(self.temp.cleanup)
        self.server = FixtureServer(self.temp.name, delay=0)
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.02), daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def request(self, body=None, path='/v1/messages?beta=true', key=API_KEY, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        self.addCleanup(connection.close)
        data = json.dumps(body) if body is not None else None
        connection.request('POST' if data is not None else 'GET', path, data,
                           headers or {'x-api-key': key, 'Content-Type': 'application/json'})
        reply = connection.getresponse()
        return reply.status, reply.read()

    def body(self, prompt='hello', **values):
        return {'model': MODEL, 'max_tokens': 1024, 'messages': [{'role': 'user', 'content': prompt}], **values}

    def testJSONStreamingThinkingAndTools(self):
        status, data = self.request(self.body())
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['content'][0]['text'], 'Local Claude fixture reply: hello')
        status, data = self.request(self.body('thinking tool', stream=True, thinking={'type': 'adaptive'},
                                              tools=[{'name': 'Bash'}]))
        self.assertEqual(status, 200)
        events = [json.loads(line[6:]) for line in data.decode().splitlines() if line.startswith('data: ')]
        self.assertEqual(events[0]['type'], 'message_start')
        self.assertEqual(events[-1]['type'], 'message_stop')
        self.assertEqual(events[-2]['delta']['stop_reason'], 'tool_use')
        deltas = [event['delta'] for event in events if event['type'] == 'content_block_delta']
        self.assertTrue(any(delta['type'] == 'thinking_delta' for delta in deltas))
        self.assertTrue(any(delta['type'] == 'signature_delta' for delta in deltas))
        arguments = ''.join(delta['partial_json'] for delta in deltas if delta['type'] == 'input_json_delta')
        self.assertEqual(json.loads(arguments)['command'], TOOL_COMMAND)

    def testToolResultCompletesOnlyItsTurn(self):
        body = self.body('tool check', tools=[{'name': 'Bash'}])
        first = json.loads(self.request(body)[1])
        body['messages'] += [{'role': 'assistant', 'content': first['content']},
                             {'role': 'user', 'content': [{'type': 'tool_result',
                              'tool_use_id': first['content'][-1]['id'], 'content': 'denied', 'is_error': True}]}]
        finished = json.loads(self.request(body)[1])
        self.assertEqual(finished['stop_reason'], 'end_turn')
        self.assertIn('denied or failed', finished['content'][0]['text'])
        body['messages'].append({'role': 'user', 'content': 'tool check again'})
        self.assertEqual(json.loads(self.request(body)[1])['stop_reason'], 'tool_use')

    def testQuestionsRequireTheToolAndPreserveTheActualAnswerResult(self):
        unavailable = json.loads(self.request(self.body('multiple questions'))[1])
        self.assertEqual(unavailable['stop_reason'], 'end_turn')
        body = self.body('multiple questions', tools=[{'name': 'AskUserQuestion'}])
        question = json.loads(self.request(body)[1])['content'][-1]
        self.assertEqual(question['name'], 'AskUserQuestion')
        self.assertEqual(len(question['input']['questions']), 3)
        self.assertTrue(question['input']['questions'][1]['multiSelect'])
        answer = 'Selected Detailed, Tests, Documentation, and Python λ'
        body['messages'] += [{'role': 'assistant', 'content': [question]},
                             {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': question['id'], 'content': answer}]}]
        result = json.loads(self.request(body)[1])
        self.assertEqual(result['stop_reason'], 'end_turn')
        self.assertIn(answer, result['content'][0]['text'])

    def testRecoveryAfterInterruptUsesTheNextHumanPrompt(self):
        body = self.body()
        body['messages'] = [{'role': 'user', 'content': [
            {'type': 'text', 'text': '[Request interrupted by user]'},
            {'type': 'text', 'text': 'recovered after stop'}]}]
        result = json.loads(self.request(body)[1])
        self.assertEqual(result['content'][0]['text'], 'Local Claude fixture reply: recovered after stop')

    def testMergedCancelledToolResultDoesNotCompleteTheNextHumanPrompt(self):
        body = self.body('permission tool before reconnect', tools=[{'name': 'Bash'}, {'name': 'AskUserQuestion'}])
        previous = json.loads(self.request(body)[1])
        rejected = {'type': 'tool_result', 'tool_use_id': previous['content'][-1]['id'],
                    'content': 'The user rejected this tool use.', 'is_error': True}
        # Real Claude 2.1.260 request after native Escape and a fresh prompt;
        # adjacent user transcript records become one API content array.
        history = body['messages'] + [{'role': 'assistant', 'content': previous['content']}]
        for prompt, tool in [('permission tool after reconnect', 'Bash'),
                             ('multiple questions after reconnect', 'AskUserQuestion'),
                             ('hello after reconnect', None)]:
            with self.subTest(prompt=prompt):
                body['messages'] = history + [{'role': 'user', 'content': [rejected,
                    {'type': 'text', 'text': '[Request interrupted by user for tool use]\n'},
                    {'type': 'text', 'text': prompt}]},
                    {'role': 'system', 'content': 'total_tokens context'}]
                result = json.loads(self.request(body)[1])
                if tool:
                    self.assertEqual(result['stop_reason'], 'tool_use')
                    self.assertEqual(result['content'][-1]['name'], tool)
                    body['messages'] += [{'role': 'assistant', 'content': result['content']},
                        {'role': 'user', 'content': [{'type': 'tool_result',
                            'tool_use_id': result['content'][-1]['id'], 'content': 'new turn completed'},
                            {'type': 'text', 'text': '<system-reminder>context only</system-reminder>'}]}]
                    completed = json.loads(self.request(body)[1])
                    self.assertEqual(completed['stop_reason'], 'end_turn')
                    self.assertIn('Tool result received: completed.', completed['content'][0]['text'])
                    self.assertNotIn('denied or failed', completed['content'][0]['text'])
                else:
                    self.assertEqual(result['content'][0]['text'], 'Local Claude fixture reply: ' + prompt)

    def testHealthModelsAndTokenCount(self):
        self.assertEqual(json.loads(self.request(path='/health')[1])['fixture'], 'dispatch-claude')
        self.assertEqual(json.loads(self.request(path='/v1/models')[1])['data'][0]['id'], MODEL)
        self.assertGreater(json.loads(self.request(self.body(), '/v1/messages/count_tokens')[1])['input_tokens'], 0)
        self.assertEqual(self.request(path='/unknown')[0], 404)

    def testInteractiveSystemContextDoesNotReplaceUserPrompt(self):
        body = self.body('thinking hello')
        body['messages'].append({'role': 'system', 'content': [{'type': 'text', 'text': 'tool system context'}]})
        status, data = self.request(body)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)['content'][-1]['text'], 'Local Claude fixture reply: thinking hello')
        body['messages'][0]['content'] = '<local-command-caveat>context</local-command-caveat>\n<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>\n<local-command-stdout></local-command-stdout>\nnew conversation'
        self.assertEqual(json.loads(self.request(body)[1])['content'][-1]['text'], 'Local Claude fixture reply: new conversation')
        body['messages'][-1]['role'] = 'invalid'
        self.assertEqual(self.request(body)[0], 400)

    def testInvalidRequestsAndCredentialsAreRejectedWithoutCapture(self):
        for value in [[], {}, self.body(stream='true'), self.body(messages=[{'role': 'user', 'content': [1]}])]:
            self.assertEqual(self.request(value)[0], 400)
        self.assertEqual(self.request(self.body(), key='real-key-must-not-be-captured')[0], 401)
        self.assertEqual(self.request(self.body(), headers={'x-api-key': API_KEY, 'Authorization': 'Bearer secret'})[0], 401)
        self.assertEqual(self.request(self.body(), headers={'x-api-key': API_KEY, 'Content-Length': str(MAX_BODY + 1)})[0], 413)
        self.assertEqual(self.server.request_count, 0)
        self.assertFalse((self.server.state / 'requests.jsonl').exists())

    def testConfigurationAndEnvironmentAreIsolated(self):
        with patch.dict(os.environ, {'ANTHROPIC_AUTH_TOKEN': 'secret', 'CLAUDE_CODE_USE_BEDROCK': '1',
                                     'CLAUDE_CODE_OAUTH_TOKEN': 'secret', 'HTTPS_PROXY': 'http://external'}):
            env = environment(self.server.state, self.server.server_port)
        self.assertNotIn('ANTHROPIC_AUTH_TOKEN', env)
        self.assertNotIn('CLAUDE_CODE_OAUTH_TOKEN', env)
        self.assertNotIn('CLAUDE_CODE_USE_BEDROCK', env)
        self.assertEqual(env['ANTHROPIC_API_KEY'], API_KEY)
        self.assertEqual(env['GIT_SSH_COMMAND'], '/usr/bin/false')
        self.assertEqual(shutil.which('ssh', path=env['PATH']), str(self.server.state / 'offline-bin' / 'ssh'))
        probe = subprocess.run(['ssh', '-T', '-o', 'BatchMode=yes', 'git@github.com'],
                               env=env, capture_output=True, timeout=2)
        self.assertEqual(probe.returncode, 1)
        self.assertEqual(probe.stdout + probe.stderr, b'')
        prepare_integration(self.server.state, self.server.state / 'claude-home')
        profile = self.server.state / 'claude-home' / '.claude.json'
        settings = json.loads(profile.read_text())
        self.assertTrue(settings['hasCompletedOnboarding'])
        self.assertEqual(set(settings['projects']), {str(self.server.state / 'work')})
        self.assertNotIn('permissions', settings)
        native_settings = self.server.state / 'claude-home' / 'settings.json'
        self.assertEqual(json.loads(native_settings.read_text()), {'env': {'DISABLE_AUTOUPDATER': '1'}})
        self.assertEqual(native_settings.stat().st_mode & 0o777, 0o600)
        native_settings.write_text('{"hooks":{"PermissionRequest":[]}}')
        profile.write_text('{"existing":"choice"}')
        prepare_integration(self.server.state, self.server.state / 'claude-home')
        self.assertEqual(json.loads(profile.read_text()), {'existing': 'choice'})
        self.assertEqual(json.loads(native_settings.read_text()), {'hooks': {'PermissionRequest': []}})
        self.assertNotIn('--bare', command('claude', integration=True))
        self.assertIn('--bare', command('claude'))
        native = self.server.state / 'native-file-fixture'
        native.write_text('#!/bin/sh\nprintf \'{}\\n\' > "$CLAUDE_CONFIG_DIR/native-settings.json"\n')
        native.chmod(0o700)
        subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / 'scripts/claude_fixture.py'), 'launch',
                        '--state', str(self.server.state), '--claude', str(native), '--integration'],
                       check=True, capture_output=True, timeout=5, umask=0o002)
        self.assertEqual((self.server.state / 'claude-home/native-settings.json').stat().st_mode & 0o777, 0o600)
        with tempfile.TemporaryDirectory() as path:
            original = Path(path) / 'personal.txt'
            original.write_text('unchanged')
            with self.assertRaises(ValueError):
                prepare(path)
            self.assertEqual(original.read_text(), 'unchanged')

    def testMalformedJSONAndCancelledStreamLeaveServerUsable(self):
        for data in (b'{', b'\xff', b'[' * 1100 + b']' * 1100):
            with closing(http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)) as connection:
                connection.request('POST', '/v1/messages', data, {'x-api-key': API_KEY})
                reply = connection.getresponse()
                self.assertEqual(reply.status, 400)
                reply.read()
        with closing(http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)) as connection:
            connection.request('POST', '/v1/messages', json.dumps(self.body('long reply', stream=True)),
                               {'x-api-key': API_KEY})
            reply = connection.getresponse()
            self.assertEqual(reply.status, 200)
            reply.read(32)
            reply.close()
        status, data = self.request(self.body('after cancellation'))
        self.assertEqual(status, 200)
        self.assertIn('after cancellation', json.loads(data)['content'][0]['text'])


def real_cli(executable, state):
    state = prepare(state)
    started = time.monotonic()
    version = subprocess.check_output([executable, '--version'], text=True, timeout=5).strip()
    if 'Claude Code' not in version:
        raise RuntimeError('Expected a Claude Code executable: ' + version)
    with FixtureServer(state, delay=0.001) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = environment(state, server.server_port)

        def run(label, prompt, *extra, integration=False):
            result = subprocess.run(command(executable, '-p', prompt, '--output-format', 'stream-json', '--verbose',
                                            '--include-partial-messages', *extra, integration=integration), cwd=state / 'work', env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
            (state / (label + '.log')).write_text(result.stdout + '\n' + result.stderr)
            if result.returncode:
                raise AssertionError(label + ': ' + result.stderr + result.stdout[-2000:])
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            final = next(row for row in reversed(rows) if row.get('type') == 'result')
            assert not final['is_error'] and 'Local Claude fixture reply: ' + prompt in final['result'], final
            assert any(row.get('type') == 'stream_event' for row in rows), 'No real streaming output'
            return final, rows

        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(run, label, label) for label in ('alpha', 'beta')]
                a, b = [job.result()[0] for job in futures]
            assert a['session_id'] != b['session_id'], 'Parallel sessions share identity'
            resumed, _ = run('resume', 'line one\nline two', '--resume', a['session_id'])
            assert resumed['session_id'] == a['session_id'], 'Resume changed session ID'
            _, thinking = run('thinking', 'thinking formatting preview')
            assert any(row.get('event', {}).get('delta', {}).get('type') == 'thinking_delta' for row in thinking)
            allowed, _ = run('tool', 'tool check', '--allowedTools', 'Bash(printf *)')
            assert 'Tool result received: completed.' in allowed['result'], allowed
            denied, _ = run('denied', 'tool denial check', '--permission-mode', 'dontAsk',
                            '--settings', '{"permissions":{"deny":["Bash(printf *)"]}}')
            assert 'Tool result received: denied or failed.' in denied['result'], denied
            assert any('DISPATCH_CLAUDE_TOOL_OK' in json.dumps(request['messages']) and
                       'tool_result' in json.dumps(request['messages']) for request in server.requests)
            prepare_integration(state, state / 'claude-home')
            run('normal', 'thinking normal startup', integration=True)
            transcripts = list((state / 'claude-home/projects').rglob('*.jsonl'))
            assert transcripts, 'Real Claude did not persist its conversation transcripts'
            summary = {'version': version, 'seconds': time.monotonic() - started, 'cli_cases': 7,
                       'requests': server.request_count, 'session_ids': [a['session_id'], b['session_id']],
                       'transcripts': [str(path.relative_to(state)) for path in transcripts]}
            (state / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(json.dumps(summary, indent=2))
        finally:
            server.shutdown()
            thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--claude', default=shutil.which('claude'))
    parser.add_argument('--keep', type=Path, help='New or empty directory for real CLI captures and timing')
    parser.add_argument('--endpoint-only', action='store_true', help='Run protocol tests without the CLI')
    args = parser.parse_args()
    if not args.endpoint_only and not args.claude:
        parser.error('Install Claude Code first or pass --claude')
    if args.keep and args.keep.exists() and any(args.keep.iterdir()):
        parser.error('--keep must be a new or empty directory')
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(EndpointTests)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        return 1
    if not args.endpoint_only:
        if args.keep:
            real_cli(args.claude, args.keep.resolve())
        else:
            with tempfile.TemporaryDirectory(prefix='dispatch-claude-test-') as state:
                real_cli(args.claude, state)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
