#!/usr/bin/env python3
"""Record the iPhone's chat fixtures (Mobile/Tests/Fixtures/Chat) from the real helper.

Each fixture is the helper's own `chat.page` reply for a transcript read without a live terminal (the archive read),
decoded to JSON: the records the phone's transcript merges, as the current helper produces them. Inputs are the
committed real Codex rollouts (DispatchTests/Fixtures) and a constructed Claude Code transcript written here (the
M4a mockup's two turns: synthetic ids, paths under /work, times on 2000-01-01). The snapshot's file identity and
generation are replaced by neutral values. Rerun after a helper change to the record encoders:

    python3 test/mobile-chat-fixtures.py [--helper build/helper-rust/bin/darwin-universal]
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'Mobile/Tests/Fixtures/Chat'
SESSION = '00000000-0000-4000-8000-000000000201'


def claude_thread():
    lines = []

    def row(kind, uid, message, ts, **extra):
        root = {'type': kind, 'uuid': uid, 'message': message, 'sessionId': SESSION, 'version': '2.1.260',
                'timestamp': ts, 'cwd': '/work/app'}
        root.update(extra)
        lines.append(json.dumps(root, sort_keys=True))

    def t(minute, second):
        return '2000-01-01T09:%02d:%02d.000Z' % (minute, second)

    def user(i, text, ts):
        row('user', 'u%d' % i, {'role': 'user', 'content': text}, ts, promptId='p%d' % i)

    def tool(call, name, arguments, result, ts1, ts2, prompt):
        row('assistant', 'a' + call, {'role': 'assistant', 'model': 'fable-5.1', 'stop_reason': 'tool_use',
            'content': [{'type': 'tool_use', 'id': call, 'name': name, 'input': arguments}]}, ts1, effort='high')
        row('user', 'r' + call, {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': call,
            'content': result, 'is_error': False}]}, ts2, promptId='p%d' % prompt)

    def answer(uid, text, ts):
        row('assistant', uid, {'role': 'assistant', 'model': 'fable-5.1', 'stop_reason': 'end_turn',
            'content': [{'type': 'text', 'text': text}]}, ts, effort='high')

    user(1, 'Make billing webhook retries idempotent.', t(30, 0))
    tool('c1', 'Read', {'file_path': '/work/app/src/routes/billing.ts'}, '1\texport function handle() {}\n', t(30, 5), t(30, 6), 1)
    tool('c2', 'Grep', {'pattern': 'attempt', 'path': '/work/app/src'}, 'src/routes/billing.ts:12', t(30, 10), t(30, 11), 1)
    tool('c3', 'Edit', {'file_path': '/work/app/src/lib/idempotent.ts', 'old_string': 'const seen = new Set()\n',
                        'new_string': 'const seen = new Map()\nconst ttl = 86400\n'},
         'The file /work/app/src/lib/idempotent.ts has been updated.', t(30, 40), t(30, 41), 1)
    tool('c4', 'Bash', {'command': 'pnpm test billing', 'description': 'Run the billing tests'}, '12 passed', t(31, 0), t(31, 5), 1)
    tool('c5', 'Read', {'file_path': '/work/app/src/lib/stripe.ts'}, '1\texport const stripe = {}\n', t(31, 10), t(31, 11), 1)
    answer('f1', 'Stripe retries the same event with a new attempt counter, so a counter-based guard can '
           'double-process. I’ll key on the event id instead and persist what we’ve seen.', t(31, 26))
    user(2, 'Also cover invoice.paid — it has a separate handler.', t(32, 0))
    tool('d1', 'Read', {'file_path': '/work/app/src/routes/invoices.ts'}, '1\texport function paid() {}\n', t(32, 4), t(32, 5), 2)
    tool('d2', 'Read', {'file_path': '/work/app/src/lib/stripe.ts'}, '1\texport const stripe = {}\n', t(32, 8), t(32, 9), 2)
    tool('d3', 'Edit', {'file_path': '/work/app/src/lib/idempotent.ts', 'old_string': 'a\n', 'new_string': 'b\nc\n'},
         'updated', t(32, 30), t(32, 31), 2)
    tool('d4', 'Edit', {'file_path': '/work/app/src/routes/invoices.ts', 'old_string': 'x\ny\nz\n', 'new_string': 'w\nv\n'},
         'updated', t(32, 40), t(32, 41), 2)
    answer('f2', 'Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. '
           'Moving the check into a shared middleware so both routes get it.', t(32, 52))
    return '\n'.join(lines) + '\n'


def neutral(pages):
    for page in pages:
        snapshot = page.get('snapshot')
        if snapshot:
            snapshot['generation'] = '00000000-0000-4000-8000-0000000000ff'
            if snapshot.get('file'):
                snapshot['file'] = {'device': 1, 'inode': 1}
        for record in page['records']:
            if record.get('position'):
                record['position']['file'] = {'device': 1, 'inode': 1}
    return pages


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--helper', default=str(ROOT / 'build/helper-rust/bin/darwin-universal'))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='mcf', dir='/tmp') as work:
        work = Path(work)
        recorder = work / 'record'
        sources = ['test/mobile-chat-record.swift', 'test/helper-client-stubs.swift', 'Mobile/Shared/System.swift'] + [
            'Dispatch/Helper/' + name + '.swift' for name in
            ('HelperWire', 'HelperBinary', 'HelperConnection', 'HelperTransport', 'AppReplay')]
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-o', str(recorder)] + sources, cwd=ROOT, check=True)
        thread = work / 'thread.jsonl'
        thread.write_text(claude_thread())
        cases = [
            ('claude-thread', 'claude', thread, SESSION),
            ('codex-formatting-0.154.0', 'codex', ROOT / 'DispatchTests/Fixtures/codex-formatting-0.154.0.jsonl',
             '00000000-0000-4000-8000-000000000013'),
            ('codex-observed-0.153.2', 'codex', ROOT / 'DispatchTests/Fixtures/codex-observed-0.153.2.jsonl',
             '11111111-1111-4111-8111-111111111111'),
        ]
        # The helper's sockets live under HOME: keep it short (sun_path is 104 bytes).
        home = work / 'home'
        home.mkdir()
        environment = {key: value for key, value in os.environ.items() if key != 'TMUX'}
        environment['HOME'] = str(home)
        OUT.mkdir(parents=True, exist_ok=True)
        for name, key, path, session in cases:
            out = work / (name + '.json')
            subprocess.run([str(recorder), args.helper, key, str(path), session, str(out)], env=environment,
                           check=True, timeout=60)
            pages = neutral(json.loads(out.read_text()))
            (OUT / (name + '.json')).write_text(json.dumps(pages, indent=1, sort_keys=True, ensure_ascii=False) + '\n')
            print(name, sum(len(page['records']) for page in pages), 'records')


if __name__ == '__main__':
    main()
