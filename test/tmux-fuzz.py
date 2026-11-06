#!/usr/bin/env python3
"""Randomized custom tmux configuration fuzz of the helper's tmux backend.

python3 test/tmux-fuzz.py                      # the regression set: seeds 1-24, 60 steps each
python3 test/tmux-fuzz.py --runs 200 --steps 80 --seed 1000   # explore

Each run starts a private tmux server (its own socket, home and TMUX_TMPDIR) with a random configuration: options,
hooks and session names that change what tmux reports. The driver (helper/multiplexers/tmux/examples/fuzz.rs)
interleaves Dispatch's operations with commands a user types into tmux and checks that the published topology
follows the server. The seed picks how the backend is reached: by its socket (seeds 0 and 2 mod 4), as a tab's own
`tmux -CC` (1 mod 4), or as an unverified relayed stream (3 mod 4). A run fails on a panic, a hang, a Dispatch
operation that timed out, a topology that did not follow the server, or a claimed client whose spaces stayed after
it ended. `--seed N --runs 1` repeats one run; failing runs' logs are kept (`--keep`: every run's).
AUDIT_TMUX selects a tmux executable; AUDIT_TMUX_BUILD the build cache (shared with tmux-config-audit.py).
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TMUX = os.environ.get('AUDIT_TMUX') or shutil.which('tmux')
BUILD = Path(os.environ.get('AUDIT_TMUX_BUILD', '/private/tmp/dispatch-tmux-audit-build'))
DRIVER = BUILD / 'debug/examples/fuzz'

OPTIONS = [
    'set -g base-index {n}', 'setw -g pane-base-index {n}', 'set -g renumber-windows on', 'setw -g automatic-rename off',
    'setw -g allow-rename off', 'setw -g remain-on-exit on', 'setw -g remain-on-exit failed',
    'setw -g pane-border-status top', 'setw -g pane-border-status bottom', 'set -g status off', 'set -g status 5',
    'set -g status-position top', 'setw -g window-size manual', 'setw -g window-size smallest',
    'setw -g window-size largest', 'setw -g window-size latest', 'set -g default-size 40x10',
    'set -g default-size 300x90', 'setw -g aggressive-resize on', 'set -g history-limit 0', 'set -g history-limit 1',
    'set -g history-limit 200000', 'set -g mouse on', 'setw -g mode-keys vi', 'set -g prefix C-a', 'set -g prefix None',
    'set -g prefix2 F12', 'set -g detach-on-destroy off', 'set -g detach-on-destroy previous', 'set -g set-titles on',
    'set -g focus-events on', 'setw -g synchronize-panes on', 'set -s extended-keys always', 'set -s escape-time 0',
    'setw -g alternate-screen off', 'setw -g main-pane-width 70%', 'setw -g monitor-activity on',
    'set -g visual-activity on', 'set -g bell-action none', 'set -g default-terminal screen',
    'set -g update-environment ""', 'set -g @dispatch-window "{"',
    'set -g @dispatch-window \'{"group":"g","name":"global","order":1}\'', 'set -g repeat-time 0',
    'setw -g pane-active-border-style fg=red', 'set -g status-left "#(date)"', 'setw -g allow-passthrough on',
    'set -g set-clipboard on', 'setw -g clock-mode-style 12', 'set -s exit-empty off',
    'setw -g automatic-rename-format "#{pane_current_path}|#{pane_title}"', 'setw -g automatic-rename-format "x\x01y"',
    'set -g window-status-format "#I"', 'set -s command-alias[100] "nw=new-window"', 'set -g history-file ""',
    'set -g destroy-unattached keep-last', 'set -g lock-after-time 1', 'set -g lock-command "true"',
]
HOOKS = [
    'set-hook -g after-new-window "split-window -d"', 'set-hook -g after-split-window "select-layout tiled"',
    'set-hook -g after-new-window "rename-window hooked"', 'set-hook -g after-new-window "select-window -t :0"',
    'set-hook -g after-select-pane "display-message -p FOCUS"', 'set-hook -g window-linked "display-message hi"',
    'set-hook -g session-created "new-window -d"', 'set-hook -g after-kill-pane "display-message -p killed"',
    'set-hook -g pane-exited "display-message gone"', 'set-hook -g after-resize-pane "display-message -p r"',
    'set-hook -g client-attached "new-window -d -n attached"', 'set-hook -g after-select-window "refresh-client"',
    'set-hook -g after-rename-window "set-option -w automatic-rename on"',
    'set-hook -g window-renamed "display-message -p renamed"', 'set-hook -g after-new-session "rename-session hooked"',
    'set-hook -g after-split-window "select-pane -T hookedtitle"',
    'set-hook -g after-new-window "set-option -w @dispatch-window junk"',
    'set-hook -g after-split-window "resize-pane -Z"',
]
SESSIONS = ['work', 'a b', 'é', '1', 'x|y', '-dash', 'dot.ted']
MODES = {0: 'socket', 1: 'local', 2: 'socket', 3: 'relay'}
FAILURES = ('MISMATCH', 'STALE', 'BADKEY', 'STREAM_ERR', 'OPEN=ERR')


def configuration(rng):
    # Panes run cat: input the driver types is echoed, never run.
    lines = ['set -g default-shell /bin/sh', 'set -g default-command "exec /bin/cat"']
    for option in rng.sample(OPTIONS, rng.randint(0, 8)):
        lines.append(option.replace('{n}', str(rng.choice([0, 1, 5, 99]))))
    lines += rng.sample(HOOKS, rng.choice([0, 0, 1, 2, 3]))
    return '\n'.join(lines) + '\n'


def one(seed, steps, logs, keep):
    rng = random.Random(seed)
    mode = MODES[seed % 4]
    with tempfile.TemporaryDirectory(prefix='dfuzz-', dir='/private/tmp') as directory:
        root = Path(directory)
        (root / 'home/proj dir').mkdir(parents=True)
        socket = str(root / 's')
        conf = configuration(rng)
        (root / 'tmux.conf').write_text(conf)
        env = dict(HOME=str(root / 'home'), PATH='/usr/bin:/bin', TERM='xterm-256color', LANG='en_US.UTF-8',
                   SHELL='/bin/sh', TMUX_TMPDIR=directory)
        session = rng.choice(SESSIONS)

        def native(*args):
            return subprocess.run([TMUX, '-S', socket, *args], env=env, cwd=root / 'home/proj dir',
                                  capture_output=True, text=True, timeout=20)

        log, status = '', None
        try:
            started = native('-f', str(root / 'tmux.conf'), 'new-session', '-d', '-s', session, '-x', '120', '-y', '40')
            # Some configurations end the server at once (destroy-unattached): nothing to drive.
            if started.returncode or native('display-message', '-p', '#{pid}').returncode:
                return seed, mode, 'skipped', []
            for _ in range(rng.randint(0, 3)):
                native('new-window', '-d')
            try:
                result = subprocess.run([DRIVER, TMUX, socket, str(seed), str(steps)],
                                        env=dict(env, RUST_BACKTRACE='1', FUZZ_MODE=mode), cwd=root / 'home',
                                        capture_output=True, text=True, timeout=steps * 10 + 60)
                log, status = result.stdout + result.stderr, result.returncode
            except subprocess.TimeoutExpired as expired:
                log, status = str(expired.stdout or ''), 'hang'
        finally:
            native('kill-server')
    lines = log.splitlines()
    failures = [line for line in lines if line.startswith(FAILURES) or 'panicked' in line
                or (' D ' in line and '"timeout"' in line)]
    if status != 0:
        failures.append(f'driver exit status {status}')
    elif 'DONE' not in lines:
        failures.append('driver did not finish')
    if failures or keep:
        (logs / f'seed-{seed}.log').write_text(f'# seed {seed} mode {mode} session {session!r}\n# config:\n{conf}\n{log}')
    return seed, mode, status, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--runs', type=int, default=24)
    parser.add_argument('--steps', type=int, default=60)
    parser.add_argument('--seed', type=int, default=1, help='first seed')
    parser.add_argument('--jobs', type=int, default=8)
    parser.add_argument('--keep', action='store_true', help="keep every run's log")
    options = parser.parse_args()
    if not TMUX:
        sys.exit('Set AUDIT_TMUX to a tmux executable')
    BUILD.mkdir(parents=True, exist_ok=True)
    build = subprocess.run(['cargo', 'build', '--offline', '--manifest-path', ROOT / 'helper/Cargo.toml',
                            '-p', 'dispatch-helper-tmux', '--example', 'fuzz', '--target-dir', BUILD],
                           capture_output=True, text=True)
    if build.returncode:
        sys.exit(build.stdout + build.stderr)
    logs = Path(tempfile.mkdtemp(prefix='dispatch-tmux-fuzz-', dir='/private/tmp'))
    failed = 0
    seeds = range(options.seed, options.seed + options.runs)
    with ThreadPoolExecutor(options.jobs) as pool:
        for seed, mode, status, failures in pool.map(lambda seed: one(seed, options.steps, logs, options.keep), seeds):
            failed += bool(failures)
            print(f'seed {seed} ({mode}): {"FAIL" if failures else status if status == "skipped" else "ok"}')
            for line in failures[:5]:
                print('   ', line[:300])
    if failed:
        print(f'{failed} of {options.runs} runs failed; logs in {logs}')
        sys.exit(1)
    if options.keep:
        print(f'logs in {logs}')
    else:
        shutil.rmtree(logs)
    print(f'{options.runs} runs passed')


if __name__ == '__main__':
    main()
