#!/usr/bin/env python3
"""Create a real, multi-turn Codex conversation using only a local fixture endpoint."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import threading
from codex_fixture import FixtureServer, environment, prepare


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True, help='New or empty fixture directory')
    parser.add_argument('--turns', type=int, default=60)
    parser.add_argument('--paragraphs', type=int, default=0, help='Add rich synthetic content to each turn')
    parser.add_argument('--no-instructions', action='store_true', help='Only print generation progress')
    parser.add_argument('--codex', default=shutil.which('codex'))
    args = parser.parse_args()
    if not args.codex or not 1 <= args.turns <= 1000:
        parser.error('A Codex executable and 1–1000 turns are required')
    if not 0 <= args.paragraphs <= 40:
        parser.error('--paragraphs must be between 0 and 40')
    if args.state.exists() and any(args.state.iterdir()):
        parser.error('--state must be new or empty')
    prepare(args.state, 1)
    server = FixtureServer(args.state, delay=0.001)
    home, work = prepare(args.state, server.server_port)
    (home / 'hooks.json').unlink()
    env = environment(home)
    version = subprocess.check_output([args.codex, '--version'], env=env, text=True).strip()
    if not version.startswith('codex-cli ') or not version.removeprefix('codex-cli ').strip():
        parser.error('Expected a Codex CLI executable; got ' + version)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    session_id = None
    try:
        for index in range(args.turns):
            command = [args.codex, 'exec', '--skip-git-repo-check', '--json']
            if session_id:
                command += ['resume', session_id]
            prompt = f'history message {index}'
            if args.paragraphs:
                prompt += '\n\n' + '\n\n'.join(
                    f'### Sample {index + 1}, section {part + 1}\n\n'
                    'This is synthetic text for a scrolling comparison. '
                    'The conversation stays entirely on this computer. '
                    'Readability, line wrapping, and vertical spacing can be compared at different window sizes.\n\n'
                    '- A short list entry\n- A longer entry with **bold text** and `inline code`\n\n'
                    f'```swift\nlet sample = {index + 1}\nlet section = {part + 1}\nprint(sample + section)\n```'
                    for part in range(args.paragraphs))
            result = subprocess.run(command + [prompt], env=env, cwd=work, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError(result.stderr + result.stdout)
            rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            actual = next(row['thread_id'] for row in rows if row.get('type') == 'thread.started')
            assert session_id is None or actual == session_id, 'Resume changed session identity'
            session_id = actual
            assert any(row.get('item', {}).get('text') == 'Local fixture reply: ' + prompt for row in rows), rows
            if (index + 1) % 10 == 0 or index + 1 == args.turns:
                print(f'Created {index + 1}/{args.turns} turns', flush=True)
        paths = []
        for path in (home / 'sessions').rglob('*.jsonl'):
            with path.open() as file:
                meta = json.loads(file.readline()).get('payload', {})
            if (meta.get('id') or meta.get('session_id')) == session_id:
                paths.append(path)
        assert len(paths) == 1
        conversation_requests = [body for body in server.requests
            if body.get('text', {}).get('format', {}).get('schema', {}).get('required') != ['title']]
        assert len(conversation_requests) == args.turns
        (args.state / 'history.json').write_text(json.dumps({'session_id': session_id,
            'transcript_path': str(paths[0]), 'turns': args.turns, 'requests': len(server.requests),
            'paragraphs': args.paragraphs, 'codex_version': version}))
        print(f'Created {args.turns} real turns in {session_id}; {len(server.requests)} loopback requests.')
        if not args.no_instructions:
            print(f'Start the fixture: python3 scripts/codex_fixture.py serve --no-hooks --state {args.state}')
            print(f'In Dispatch: python3 scripts/codex_fixture.py launch --state {args.state} --resume {session_id}')
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
