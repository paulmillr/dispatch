#!/usr/bin/env python3
"""Custom tmux configuration audit. Every server uses an owned temporary socket.

python3 test/tmux-config-audit.py -v
AUDIT_TMUX=/path/to/tmux selects a version. The T1-T5 findings of the 2026-10-31 audit are ordinary
regressions now; AUDIT_STRICT=1 is kept for any case marked known_bug later.
Needs macOS, swiftc, cargo, Unix sockets and permission to run Swift compiler macros.
"""
import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TMUX = os.environ.get('AUDIT_TMUX') or shutil.which('tmux')
known_bug = (lambda test: test) if os.environ.get('AUDIT_STRICT') else unittest.expectedFailure


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=60, **kwargs)


class TmuxConfigAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not TMUX:
            raise unittest.SkipTest('Set AUDIT_TMUX to a tmux executable')
        cls.build = Path(os.environ.get('AUDIT_TMUX_BUILD', '/private/tmp/dispatch-tmux-audit-build'))
        cls.build.mkdir(parents=True, exist_ok=True)
        cls.driver = cls.build / 'debug/examples/config-audit'
        cls.prefix = cls.build / 'prefix-audit'
        # Compile actual methods with UI model stubs, not rewritten implementations.
        source = (ROOT / 'Dispatch/AppDelegate+PrefixKeys.swift').read_text()
        method = source[source.index('    func prefixTable('):source.index('    /// Runs a binding')]
        selection = source.split('        case .selectWindow(let index):\n', 1)[1].split('        case .selectTab', 1)[0]
        client = (ROOT / 'Dispatch/Helper/HelperClient.swift').read_text()
        start = client.index('  /// backends.prefix:')
        reply = client[start:client.index('\n  }\n', start) + 4]
        extracted = cls.build / 'prefix-method.swift'
        extracted.write_text('import AppKit\nenum HelperClient {\n' + reply + '}\nextension AppDelegate {\n' + method
                             + 'func auditSelectWindow(_ index: Int, surface: UUID) {\n' + selection + '}\n}\n')
        commands = [
            ['cargo', 'build', '--offline', '--manifest-path', ROOT / 'helper/Cargo.toml',
             '-p', 'dispatch-helper-tmux', '--example', 'config-audit', '--target-dir', cls.build],
            ['swiftc', '-module-cache-path', cls.build / 'swift-cache', ROOT / 'Dispatch/PrefixKeys.swift',
             ROOT / 'test/fixtures/tmux-prefix-audit.swift', extracted, '-o', cls.prefix],
        ]
        for command in commands:
            result = run(command)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)

    @contextlib.contextmanager
    def server(self, config=''):
        with tempfile.TemporaryDirectory(prefix='dtmux-', dir='/private/tmp') as directory:
            root = Path(directory)
            home = root / 'home'
            home.mkdir()
            socket = str(root / 'socket')
            config_file = root / 'tmux.conf'
            config_file.write_text('set -g default-shell /bin/sh\nset -g default-command "exec /bin/cat"\n' + config)
            env = dict(HOME=str(home), PATH='/usr/bin:/bin', TERM='xterm-256color', LANG='en_US.UTF-8',
                       SHELL='/bin/sh', TMUX_TMPDIR=directory)

            def native(*args):
                result = run([TMUX, '-S', socket, *args], env=env, cwd=home)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout

            def driver(operation='create', *extra, relay=False):
                result = run([self.driver, TMUX, socket, operation, *extra],
                             env=dict(env, **({'AUDIT_RELAY': '1'} if relay else {})), cwd=home)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout

            try:
                native('-f', config_file, 'new-session', '-d', '-s', 'audit', '-x', '100', '-y', '35')
                # Some tmux socket errors surprisingly return zero; explicitly verify the server.
                native('display-message', '-p', '#{pid}')
                yield native, driver
            finally:
                run([TMUX, '-S', socket, 'kill-server'], env=env)

    def test_configuration_and_hook_controls(self):
        configs = [
            '',
            'set -g base-index 5\nsetw -g pane-base-index 7\nset -g renumber-windows on\n',
            'set -g pane-border-status top\nset -g status 3\n',
            'set -g window-size manual\nset -g default-size 93x31\n',
            'set -g remain-on-exit on\n',
            'set-hook -g after-new-window "select-window -t :0"\n',
            'set-hook -g after-new-window "display-message -p HOOK"\n',
            'set-hook -g after-select-pane "display-message -p FOCUS"\n',
        ]
        for config in configs:
            for relay in [False, True]:
                with self.subTest(config=config, relay=relay), self.server(config) as (native, driver):
                    result = driver(relay=relay)
                    self.assertIn('OPEN=OK', result)
                    self.assertIn('CREATE=Ok(', result)
                    self.assertIn('FOCUS=Ok(())', result)
                    panes = native('list-panes', '-a', '-F', '#{pane_id}|#{@dispatch-creation}').splitlines()
                    self.assertEqual(len(panes), 2)
                    self.assertTrue(panes[1].split('|')[1], panes)

    def test_global_prefix_helper_control(self):
        with self.server('set -g prefix C-a\nset -g repeat-time 1234\nbind c split-window -h\n') as (_, driver):
            result = driver('prefix')
            self.assertIn('PREFIX_KEY=Some("C-a") REPEAT=Some(1234)', result)
            self.assertIn('key: "c", command: "split-window -h"', result)

    def server_table(self, driver):
        reply = Path(tempfile.mkdtemp(prefix='dprefix-', dir='/private/tmp')) / 'reply.json'
        self.addCleanup(shutil.rmtree, reply.parent)
        reply.write_text(next(line for line in driver('prefix-json').splitlines() if line.startswith('{')))
        return reply

    def test_app_uses_server_prefix_and_bindings(self):
        # T1: the helper's reply for the tab's session reaches the app's table and its key handler.
        config = ('set -g prefix C-a\nset -g prefix2 F12\nset -g repeat-time 1234\nbind c split-window -h\n'
                  'bind h new-window -n logs "tail -f /tmp/app.log"\n')
        with self.server(config) as (native, driver):
            self.assertEqual(native('show-options', '-gv', 'prefix').strip(), 'C-a')
            result = run([self.prefix, '--server', self.server_table(driver)]).stdout
            self.assertIn('APP_PREFIX=a CONTROL=true REPEAT=1.234 PREFIX2=F12', result)
            for line in ['HANDLED_0_a=true', 'ACTION=splitRight', 'HANDLED_1_c=true', 'HANDLED_2_b=false',
                         'HANDLED_3_a=true', 'REJECTED=new-window -n logs "tail -f /tmp/app.log"', 'HANDLED_4_h=true']:
                self.assertIn(line, result)
            self.assertNotIn('newTab', result)
        # Before the helper answers: tmux's defaults; a server whose prefix is None: no prefix keys.
        self.assertIn('APP_PREFIX=b CONTROL=true REPEAT=0.5', run([self.prefix]).stdout)
        with self.server('set -g prefix None\n') as (_, driver):
            self.assertIn('APP_PREFIX=none', run([self.prefix, '--server', self.server_table(driver)]).stdout)

    def test_helper_reads_session_prefix_override(self):
        # T4: each terminal's own session options, else the global ones; prefix2 too.
        with self.server('set -g prefix2 F12\n') as (native, driver):
            native('new-session', '-d', '-s', 'other', '-x', '100', '-y', '35')
            native('set-option', '-t', 'audit', 'prefix', 'C-a')
            native('set-option', '-t', 'audit', 'repeat-time', '1234')
            native('set-option', '-t', 'other', 'prefix2', 'None')
            self.assertEqual(native('show-options', '-v', '-t', 'audit', 'prefix').strip(), 'C-a')
            panes = dict(line.split() for line in native('list-panes', '-a', '-F', '#{pane_id} #{session_name}').splitlines())
            tables = {}
            for line in driver('prefix').splitlines():
                if line.startswith('PREFIX_KEY='):
                    pane = re.search(r'TERMINAL=.*:(%\d+)$', line).group(1)
                    tables[panes[pane]] = line.split(' TERMINAL=')[0]
            self.assertEqual(tables, {
                'audit': 'PREFIX_KEY=Some("C-a") REPEAT=Some(1234) PREFIX2=Some("F12")',
                'other': 'PREFIX_KEY=Some("C-b") REPEAT=Some(500) PREFIX2=None',
            })

    def test_helper_prefix_key_escaping_control(self):
        with self.server() as (native, driver):
            cli_line = next(line for line in native('list-keys', '-T', 'prefix').splitlines()
                            if len(line.split()) > 3 and line.split()[3].endswith('%'))
            cli_key = cli_line.split()[3]
            binding = next(line for line in driver('prefix').splitlines() if 'BINDING=' in line and '%' in line)
            helper_key = json.loads(re.search(r'key: ("(?:\\.|[^"\\])*"),', binding).group(1))
            control = run([self.prefix, '--key', cli_key]).stdout
            self.assertNotIn('PARSED_KEY=nil', control)
            result = run([self.prefix, '--key', helper_key]).stdout
            self.assertNotIn('PARSED_KEY=nil', result, repr(helper_key) + '\n' + result)

    def test_prefix_window_index_is_not_ui_ordinal(self):
        # T2: a tmux space's window index goes to the server as that index, never a UI position.
        with self.server('set -g base-index 5\n') as (native, driver):
            native('new-window', '-d')
            self.assertEqual(native('list-windows', '-F', '#{window_index}').split(), ['5', '6'])
            for index in [6, 5, 0]:
                result = run([self.prefix, '--server', self.server_table(driver), str(index)]).stdout
                self.assertNotIn('SELECTED_ORDINAL', result, result)
                self.assertIn(f'COMMAND=select-window -t :={index}', result)
            # The command the handler sends selects that index on the server.
            self.assertIn('COMMAND=Ok(())', driver('command', 'select-window -t :=6'))
            self.assertEqual(native('display-message', '-p', '-t', 'audit:', '#{window_index}').strip(), '6')

    def test_custom_binding_arguments_are_not_silently_discarded(self):
        # T5: only equivalent commands map to Dispatch's actions; the rest are refused, never replaced.
        refused = ['new-window -n logs "tail -f /tmp/app.log"', 'split-window -h -l 15 -c /tmp', 'kill-pane -t %42',
                   'new-window -d', 'split-window -b', 'next-window -t :3', 'detach-client -a',
                   'command-prompt -T window-target -p index { select-window -t ":%%" }',
                   'confirm-before -p "kill?" "kill-pane -t %3"', 'source-file ~/.tmux.conf \\; display-message ok']
        mapped = {'new-window': 'newTab', 'new-window -c "#{pane_current_path}"': 'newTab',
                  'split-window -h -c "#{pane_current_path}"': 'splitRight', 'split-window -v': 'splitDown',
                  'kill-pane': 'closePane', 'confirm-before -p "kill-pane #P? (y/n)" kill-pane': 'closePane',
                  'command-prompt -I "#W" { rename-window "%%" }': 'renameTab',
                  'select-window -t :=3': 'selectWindow(3)', 'resize-pane -U 5': 'tmux("resize-pane -U 5")',
                  'send-prefix': 'tmux("send-prefix")'}
        result = run([self.prefix, *refused, *mapped]).stdout
        for command in refused:
            self.assertIn(f'MAPPED={command} => nil', result)
        for command, action in mapped.items():
            self.assertIn(f'MAPPED={command} => Optional(main.PrefixAction.{action})', result)

    def test_helper_created_shell_honors_tmux_default_command(self):
        # T3 (docs/integrations.md): an ordinary new terminal runs the server's default-command,
        # like `tmux new-window`; Dispatch's integration comes through its environment only.
        with self.server('set -g default-command "exec /usr/bin/tail -f /dev/null"\n') as (native, driver):
            native('new-window', '-d')
            control = native('display-message', '-p', '-t', ':1', '#{pane_start_command}')
            self.assertIn('tail -f /dev/null', control)
            result = driver('create-shell')
            self.assertIn('CREATE=Ok(', result)
            starts = native('list-panes', '-a', '-F', '#{pane_start_command}').splitlines()
            self.assertTrue(all('tail -f /dev/null' in line for line in starts), starts)

    def test_helper_created_shell_honors_tmux_default_shell(self):
        # No default-command: a default-shell other than the prepared one (/bin/sh) runs as a login
        # shell; the prepared one keeps the helper's command, whose integration may need arguments.
        for default_shell, explicit in [('/bin/zsh', False), ('/bin/sh', True)]:
            config = f'set -g default-command ""\nset -g default-shell {default_shell}\n'
            with self.subTest(default_shell=default_shell), self.server(config) as (native, driver):
                self.assertIn('CREATE=Ok(', driver('create-shell'))
                created = [line for line in native('list-panes', '-a', '-F',
                                                   '#{@dispatch-creation}|#{pane_start_command}').splitlines()
                           if line.split('|', 1)[0]]
                self.assertEqual(len(created), 1, created)
                start = created[0].split('|', 1)[1]
                if explicit:
                    self.assertIn('/bin/sh', start)
                    self.assertIn('env', start)
                else:
                    self.assertEqual(start, '', created)


if __name__ == '__main__':
    unittest.main()
