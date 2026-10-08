#!/usr/bin/env python3
"""Launch isolated Pi sessions against the shared local Messages fixture."""
import argparse
import json
import os
from pathlib import Path
import shutil
from urllib.request import ProxyHandler, build_opener

from claude_fixture import API_KEY, MODEL, environment as claude_environment, prepare

PROVIDER = 'dispatch-local'


def configure(state, port, home):
    state = prepare(state)
    home.mkdir(mode=0o700, exist_ok=True)
    (home / 'models.json').write_text(json.dumps({'providers': {PROVIDER: {
        'baseUrl': f'http://127.0.0.1:{port}', 'api': 'anthropic-messages', 'apiKey': API_KEY,
        'models': [{'id': MODEL, 'name': 'Dispatch local fixture', 'reasoning': True,
                    'input': ['text'], 'contextWindow': 128000, 'maxTokens': 16384,
                    'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}]}}}, indent=2) + '\n')
    return state


def environment(state, port, home):
    env = {key: value for key, value in claude_environment(state, port).items()
           if not key.startswith('PI_') and not key.endswith(('_API_KEY', '_AUTH_TOKEN', '_OAUTH_TOKEN'))}
    env.update(PI_CODING_AGENT_DIR=str(home), PI_CODING_AGENT_SESSION_DIR=str(home / 'sessions'),
               PI_OFFLINE='1', PI_TELEMETRY='0')
    return env


def command(executable, *arguments, discover_extensions=False):
    values = [executable, '--provider', PROVIDER, '--model', MODEL, '--thinking', 'medium',
            '--offline', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes',
            '--no-context-files', '--no-approve', '--tools', 'bash',
            '--system-prompt', 'You are helping test Dispatch locally.', *arguments]
    if discover_extensions:
        values.remove('--no-extensions')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, default=Path('/tmp/dispatch-claude-demo'))
    parser.add_argument('--pi', default=shutil.which('pi'))
    parser.add_argument('--session', help='Resume an exact fixture session file or ID')
    parser.add_argument('--extension', type=Path, action='append', help='Load an explicit local extension for native Chat tests (repeatable)')
    parser.add_argument('--integration', action='store_true', help='Discover extensions normally inside the isolated fixture Pi home')
    parser.add_argument('--home', type=Path, help='Pi agent directory (default STATE/pi-home), e.g. where the helper installs its bridge')
    args = parser.parse_args()
    try:
        state = args.state.resolve()
        if not (state / '.dispatch-claude-fixture').is_file():
            parser.error('Start scripts/claude_fixture.py serve first')
        port = json.loads((state / 'endpoint.json').read_text())['port']
        if type(port) is not int or not 1 <= port <= 65535:
            parser.error('Invalid fixture port')
        if not args.pi:
            parser.error('Pi is required; pass --pi /path/to/pi')
        with build_opener(ProxyHandler({})).open(f'http://127.0.0.1:{port}/health', timeout=2) as reply:
            if json.load(reply).get('fixture') != 'dispatch-claude':
                parser.error('The fixture server is not running at this endpoint')
        home = (args.home or state / 'pi-home').resolve()
        configure(state, port, home)
        extra = ['--session', args.session] if args.session else []
        for extension in args.extension or []:
            extra += ['--extension', str(extension.resolve())]
        os.chdir(state / 'work')
        os.execvpe(args.pi, command(args.pi, *extra, discover_extensions=args.integration), environment(state, port, home))
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
