#!/usr/bin/env python3
"""This Mac as a live host for Dispatch for iPhone's end-to-end tests (docs/ios.md, Testing).

  start ROOT        the loopback sshd of scripts/mobile-ssh-fixture.py (ROOT: a short /tmp/sim-… path), plus in
                    ROOT/home a private tmux server with one session ("fixture"), and `claude` on the login PATH:
                    Claude Code from build/test-tools talking to scripts/claude_fixture.py (a local Messages API,
                    never the network). Writes ROOT/live.json.
  stop ROOT         ends what start began (only the pids it recorded, after checking their command lines) and
                    removes ROOT
  stop-sshd ROOT    kills the fixture's sshd and its session processes (the phone sees the link drop)
  start-sshd ROOT   starts the same sshd again (same port and host key)
  serve ROOT        runs stop-sshd / start-sshd when a test asks: a file ROOT/requests/<n>-<command> appears, the
                    command runs, ROOT/requests/<n>-<command>.done follows (the simulator cannot start processes)

tmux runs only on the explicit socket ROOT/tmux-<uid>/default (the helper's default path for TMUX_TMPDIR=ROOT) and
without $TMUX, so the user's own tmux server is never addressed."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / 'build/test-tools/bin'
SSHD_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'


def command_line(pid):
    return subprocess.run(['/bin/ps', '-ww', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()


def kill(pid, fragment):
    """SIGTERM `pid` only when its command line still contains `fragment`."""
    text = command_line(pid)
    if text and fragment in text:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return False
        return True
    return False


def children(pid):
    rows = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid='], capture_output=True, text=True).stdout.split('\n')
    pairs = [tuple(map(int, row.split())) for row in rows if row.strip()]
    found, frontier = [], [pid]
    while frontier:
        parent = frontier.pop()
        for child, ppid in pairs:
            if ppid == parent:
                found.append(child)
                frontier.append(child)
    return found


def tmux(root, *arguments, env=None):
    socket_path = root / f'tmux-{os.getuid()}' / 'default'
    environment = {k: v for k, v in (env or os.environ).items() if k != 'TMUX'}
    return subprocess.run([str(TOOLS / 'tmux'), '-S', str(socket_path), *arguments], env=environment,
                          capture_output=True, text=True, timeout=10)


def wait_port(port, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def start(root, agent=True):
    subprocess.run([sys.executable, str(ROOT / 'scripts/mobile-ssh-fixture.py'), 'start', str(root)], check=True,
                   stdout=subprocess.DEVNULL)
    profile = json.loads((root / 'profile.json').read_text())
    home = Path(profile['home'])
    bin = home / '.local/bin'
    bin.mkdir(parents=True, mode=0o700)
    (bin / 'tmux').symlink_to(TOOLS / 'tmux')
    # Only the login shell's profile names the folder, as on a user's machine; the helper asks the login shell.
    for name in ('.zprofile', '.bash_profile'):
        (home / name).write_text('export PATH="$HOME/.local/bin:$PATH"\n')
    work = home / 'work'
    work.mkdir(mode=0o700)
    live = dict(profile, root=str(root), work=str(work), uid=os.getuid())
    if agent:
        state = root / 'cl'
        log = open(root / 'claude.log', 'w')
        server = subprocess.Popen([sys.executable, str(ROOT / 'scripts/claude_fixture.py'), 'serve', '--state', str(state),
                                   '--delay', '0.02'], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        live['claudePid'] = server.pid
        deadline = time.monotonic() + 15
        while not (state / 'endpoint.json').is_file():
            if time.monotonic() > deadline:
                raise SystemExit('the Claude fixture did not start')
            time.sleep(0.1)
        port = json.loads((state / 'endpoint.json').read_text())['port']
        sys.path.insert(0, str(ROOT / 'scripts'))
        import claude_fixture
        config = home / '.claude'
        claude_fixture.prepare_integration(state, config)
        settings = json.loads((config / 'settings.json').read_text())
        # Manual permission prompts (approvals reach the phone) and no auto-mode opt-in dialog.
        settings['permissions'] = {'defaultMode': 'default', 'disableAutoMode': 'disable'}
        (config / 'settings.json').write_text(json.dumps(settings))
        projects = json.loads((config / '.claude.json').read_text())
        projects.setdefault('projects', {})[str(work)] = {'hasTrustDialogAccepted': True}
        projects['projects'][str(work.resolve())] = {'hasTrustDialogAccepted': True}
        (config / '.claude.json').write_text(json.dumps(projects))
        environment = claude_fixture.environment(state, port, config)
        environment = {k: v for k, v in environment.items()
                       if k.startswith(('ANTHROPIC_', 'CLAUDE_', 'DISABLE_', 'GIT_SSH')) or k.lower().endswith('_proxy')}
        exports = ''.join(f"export {key}='{value}'\n" for key, value in sorted(environment.items()))
        wrapper = bin / 'claude'
        wrapper.write_text('#!/bin/sh\n'
                           '# Claude Code from build/test-tools against scripts/claude_fixture.py: a local Messages API.\n'
                           + exports + f'export PATH="{state}/offline-bin:$PATH"\n'
                           + f'exec "{(TOOLS / "claude").resolve()}" "$@"\n')
        wrapper.chmod(0o700)
        live['claudeState'] = str(state)
    # The private tmux server: the session the Spaces tree shows. Its environment is the fixture's.
    directory = root / f'tmux-{os.getuid()}'
    directory.mkdir(mode=0o700)
    env = {'HOME': str(home), 'PATH': f'{bin}:{SSHD_PATH}', 'SHELL': '/bin/zsh', 'TMUX_TMPDIR': str(root),
           'LANG': 'en_US.UTF-8', 'TERM': 'xterm-256color', 'USER': profile['user'], 'LOGNAME': profile['user'],
           'DISPATCH_TEST_ROOT': str(root / 'dt')}
    result = tmux(root, 'new-session', '-d', '-s', 'fixture', '-c', str(work), env=env)
    if result.returncode != 0:
        raise SystemExit('tmux: ' + result.stderr)
    live['tmuxSocket'] = str(directory / 'default')
    live['tmuxPid'] = int(tmux(root, 'display-message', '-p', '#{pid}').stdout.strip())
    (root / 'live.json').write_text(json.dumps(live, indent=2))
    print(root / 'live.json')


def stop_sshd(root):
    pid_file = root / 'sshd.pid'
    if not pid_file.is_file():
        return
    master = int(pid_file.read_text().split()[0])
    if str(root) not in command_line(master):
        return
    # Session processes first (sshd-session, the helper under it): the phone's connection drops at once.
    for pid in reversed(children(master)):
        if 'sshd' in command_line(pid):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    kill(master, str(root))
    deadline = time.monotonic() + 5
    while command_line(master) and time.monotonic() < deadline:
        time.sleep(0.05)
    pid_file.unlink(missing_ok=True)


def start_sshd(root):
    profile = json.loads((root / 'profile.json').read_text())
    subprocess.run(['/usr/sbin/sshd', '-f', str(root / 'sshd_config'), '-E', str(root / 'sshd.log')], check=True)
    if not wait_port(profile['port']):
        raise SystemExit('sshd did not listen again')


def stop(root):
    live = json.loads((root / 'live.json').read_text()) if (root / 'live.json').is_file() else {}
    if (root / f'tmux-{os.getuid()}' / 'default').exists():
        tmux(root, 'kill-server')
    if 'tmuxPid' in live:
        kill(live['tmuxPid'], 'tmux')
    if 'claudePid' in live:
        kill(live['claudePid'], 'claude_fixture.py serve')
    stop_sshd(root)
    subprocess.run([sys.executable, str(ROOT / 'scripts/mobile-ssh-fixture.py'), 'stop', str(root)], check=False)


def serve(root):
    requests = root / 'requests'
    requests.mkdir(exist_ok=True)
    handled = set()
    while (root / 'live.json').is_file():
        for request in sorted(requests.iterdir()):
            if request.suffix == '.done' or request.name in handled:
                continue
            handled.add(request.name)
            command = request.name.split('-', 1)[-1]
            started = time.monotonic()
            {'stop-sshd': stop_sshd, 'start-sshd': start_sshd}.get(command, lambda _: None)(root)
            (requests / (request.name + '.done')).write_text(f'{time.monotonic() - started:.3f}\n')
            print(f'{command} done in {time.monotonic() - started:.2f}s', flush=True)
        time.sleep(0.1)


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('start', 'stop', 'stop-sshd', 'start-sshd', 'serve'):
        sys.exit(__doc__)
    target = Path(sys.argv[2])
    if not str(target).startswith('/tmp/sim-'):
        sys.exit('ROOT must be a short /tmp/sim-… path')
    action = sys.argv[1]
    if action == 'start':
        start(target, agent='--no-agent' not in sys.argv)
    else:
        {'stop': stop, 'stop-sshd': stop_sshd, 'start-sshd': start_sshd, 'serve': serve}[action](target)
