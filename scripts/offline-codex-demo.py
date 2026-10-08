#!/usr/bin/env python3
"""Serve and resume a large, isolated Codex conversation without internet access."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import urllib.request
import uuid
from codex_fixture import FixtureServer, prepare

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['serve', 'resume'])
    parser.add_argument('--state', type=Path, default=HERE.parent / 'offline-chat-state')
    parser.add_argument('--turns', type=int, default=120)
    parser.add_argument('--paragraphs', type=int, default=8)
    parser.add_argument('--codex', default=shutil.which('codex'))
    args = parser.parse_args()
    state = args.state.expanduser().resolve()
    binary = args.codex
    if not binary:
        parser.error('Codex must be installed: pass --codex /path/to/codex if it is not on PATH.')
    binary = str(Path(binary).expanduser().resolve())
    if not os.access(binary, os.X_OK):
        parser.error('Codex executable is not executable: ' + binary)
    history = state / 'history.json'
    fixture = HERE / 'codex_fixture.py'
    if args.mode == 'serve':
        if not 1 <= args.turns <= 1000 or not 0 <= args.paragraphs <= 40:
            parser.error('Use 1–1000 turns and 0–40 paragraphs.')
        if not history.exists():
            if state.exists() and any(state.iterdir()):
                parser.error('An incomplete or unrelated directory already exists. Use --state with a new directory: ' + str(state))
            print(f'Creating {args.turns} real Codex turns with synthetic content. This may take a few minutes.\n'
                  f'Everything stays in {state}; the model endpoint is loopback only.', flush=True)
            subprocess.run([sys.executable, str(HERE / 'seed-codex-history.py'), '--state', str(state),
                            '--turns', str(args.turns), '--paragraphs', str(args.paragraphs), '--codex', binary,
                            '--no-instructions'], check=True)
        with (state / '.server.lock').open('w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                parser.error('The server for this history is already running.')
            prepare(state, 1)
            server = FixtureServer(state, delay=0.01)
            home, _ = prepare(state, server.server_port)
            (home / 'hooks.json').unlink()
            metadata = json.loads(history.read_text())
            print('\nHistory ready: ' + str(metadata['turns']) + ' turns. Keep this server running.', flush=True)
            print(f'Local endpoint: http://127.0.0.1:{server.server_port}/v1', flush=True)
            print('In a Dispatch terminal, run:\n' + shlex.join([
                sys.executable, str(Path(__file__).resolve()), 'resume', '--state', str(state), '--codex', binary]), flush=True)
            print('Stop the server with Control-C after exiting the conversation.', flush=True)
            try:
                server.serve_forever()
            finally:
                server.server_close()
        return
    if not history.exists() or not (state / 'endpoint.json').exists():
        parser.error('Start this script with serve first and wait for "History ready".')
    metadata = json.loads(history.read_text())
    session = str(uuid.UUID(metadata['session_id']))
    endpoint = json.loads((state / 'endpoint.json').read_text())
    port = int(endpoint['port'])
    if not 1 < port < 65536:
        parser.error('The local endpoint is not ready yet.')
    try:
        # Ignore machine-wide proxies for this loopback-only readiness check.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f'http://127.0.0.1:{port}/health', timeout=2) as response:
            if not json.load(response).get('ok'):
                raise ValueError('Endpoint did not report ready')
    except (OSError, ValueError) as error:
        parser.error('Local server is not running. Start serve in another terminal. ' + str(error))
    arguments = [sys.executable, str(fixture), 'launch', '--state', str(state), '--codex', binary, '--resume', session]
    # Use the same isolated launch path as the other native Codex fixtures.
    os.execv(sys.executable, arguments)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
