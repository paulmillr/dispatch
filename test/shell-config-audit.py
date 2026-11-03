#!/usr/bin/env python3
"""Real-shell audit using production Swift/Rust startup generators.

macOS: python3 test/shell-config-audit.py -v
Optional: AUDIT_FISH=/path/to/fish AUDIT_BASH=/path/to/bash RUSTC=/path/to/rustc
The S1-S6 findings of the 2026-10-31 audit are ordinary regressions now; AUDIT_STRICT=1 is kept for
any case marked known_bug later.
No app, SSH server, agent CLI, user configuration, or package installation needed.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Vendor/Term/Resources/ghostty'
FISH = os.environ.get('AUDIT_FISH') or shutil.which('fish')
BASH = os.environ.get('AUDIT_BASH') or '/opt/homebrew/bin/bash'
known_bug = (lambda test: test) if os.environ.get('AUDIT_STRICT') else unittest.expectedFailure


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], text=True, capture_output=True,
                          timeout=30, **kwargs)


class ShellConfigAudit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='dispatch-shell-audit-build-')
        cls.addClassCleanup(cls.build.cleanup)
        build = Path(cls.build.name)
        cls.generator = build / 'native-generator'
        cls.remote = build / 'remote-shell'
        cache = ['-module-cache-path', str(build / 'swift-cache')]
        commands = [
            ['swiftc', '-parse-as-library', '-emit-module', '-emit-object', '-module-name', 'Term',
             *cache, ROOT / 'test/fixtures/shell-audit-term.swift', '-emit-module-path',
             build / 'Term.swiftmodule', '-o', build / 'Term.o'],
            ['swiftc', '-I', build, *cache, build / 'Term.o',
             ROOT / 'Vendor/Term/Sources/TermApple/Launch.swift',
             ROOT / 'Dispatch/Terminal/ShellCommandWrapper.swift',
             ROOT / 'Dispatch/Hosts/NativeSSHEnvironment.swift',
             ROOT / 'test/fixtures/shell-audit.swift', '-o', cls.generator],
            [os.environ.get('RUSTC', 'rustc'), '--edition', '2024',
             ROOT / 'test/fixtures/shell-audit.rs', '-o', cls.remote],
        ]
        for command in commands:
            result = run(command)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dispatch shell audit ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.fake = self.bin / 'launcher'
        self.fake.write_text('#!/bin/sh\nprintf WRAPPED; printf " <%s>" "$@"; printf "\\n"\n')
        self.fake.chmod(0o700)
        # A failed integration must never fall through to the user's installed CLIs.
        for name in ['codex', 'ssh']:
            file = self.bin / name
            file.write_text('#!/bin/sh\nprintf "UNWRAPPED '+name+'\\n"\n')
            file.chmod(0o700)
        tmux = self.bin / 'tmux'
        tmux.write_text('#!/bin/sh\nprintf "XDG=<%s>\\n" "$XDG_DATA_DIRS"\n')
        tmux.chmod(0o700)
        self.env = {
            'HOME': str(self.home), 'PATH': str(self.bin) + ':/usr/bin:/bin',
            'AUDIT_BIN': str(self.bin), 'TERM': 'xterm-256color', 'TERM_PROGRAM': 'audit',
            'LANG': 'en_US.UTF-8', 'PS1': '', 'PS2': '', 'BASH_SILENCE_DEPRECATION_WARNING': '1',
            'XDG_CONFIG_HOME': str(self.home / '.config'), 'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_CACHE_HOME': str(self.home / '.cache'), 'CODEX_HOME': str(self.home / '.codex'),
            'TMUX_TMPDIR': str(self.root),
            'DISPATCH_HERDR_DIRECTORY': str(self.root), 'DISPATCH_EXECUTABLE': str(self.fake),
            'DISPATCH_HELPER_EXECUTABLE': str(self.fake),
        }
        self.write('.zprofile', 'export PATH="$AUDIT_BIN:/usr/bin:/bin"\necho PROFILE\n')
        self.write('.bash_profile', 'export PATH="$AUDIT_BIN:/usr/bin:/bin"\necho PROFILE\n')
        self.write('.zshrc', 'echo RC\n')
        self.write('.zlogin', 'echo LOGIN\n')

    def write(self, name, text):
        file = self.home / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def generate(self):
        result = run([self.generator, self.root], env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def launch(self, command, env):
        result = run([self.generator, '--launch', command, RESOURCES], env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def shell(self, mode, shell, probe):
        env = dict(self.env, SHELL=shell)
        if mode in ('native', 'local-helper'):
            env.update(self.generate()['environment'])
        injected = False
        if mode == 'local-helper':
            launch = self.launch(shell, env)
            env, injected = launch['environment'], launch['injected']
        if mode == 'native':
            args = [shell, '-l', '-i']
        else:
            args = [self.remote, shell, self.home, self.root / 'startup', self.fake]
            # The app tells the helper to skip its startup files only when Ghostty's integration went in.
            if injected:
                args.append('integrated')
        # Fish's system login configuration may rebuild PATH (macOS path_helper).
        # Restore the fixture PATH before any command probe can resolve a real CLI.
        if Path(shell).name == 'fish':
            probe = 'set -gx PATH $AUDIT_BIN /usr/bin /bin\n' + probe
        return run(args, env=env, cwd=self.home, input=probe + '\nexit\n')

    def output_contains(self, output, expected):
        self.assertIn(expected, output.stdout, output.stdout + '\nSTDERR:\n' + output.stderr)

    def require_bash(self):
        if not Path(BASH).is_file():
            self.skipTest('Set AUDIT_BASH to a modern Bash binary')

    def require_fish(self):
        if not FISH:
            self.skipTest('Set AUDIT_FISH to a Fish binary')

    def test_zsh_startup_and_wrapper_controls(self):
        for mode in ['native', 'local-helper', 'remote']:
            with self.subTest(mode=mode):
                result = self.shell(mode, '/bin/zsh', 'codex "two words" ""')
                for marker in ['PROFILE\n', 'RC\n', 'LOGIN\n', 'WRAPPED <launch> <codex> <two words> <>']:
                    self.output_contains(result, marker)

    def test_zsh_redirected_zdotdir_control(self):
        config = self.home / 'config dir'
        config.mkdir()
        self.write('.zshenv', 'ZDOTDIR="$HOME/config dir"\n')
        for file in ['.zprofile', '.zshrc', '.zlogin']:
            (config / file).write_text('echo CUSTOM-'+file+'\n')
        for mode in ['native', 'local-helper', 'remote']:
            with self.subTest(mode=mode):
                result = self.shell(mode, '/bin/zsh', 'typeset -f codex')
                for file in ['.zprofile', '.zshrc', '.zlogin']:
                    self.output_contains(result, 'CUSTOM-'+file+'\n')
                self.output_contains(result, 'launch codex' if mode == 'remote' else "'codex'")

    def test_bash_profile_controls(self):
        self.require_bash()
        for mode, shell in [('native', '/bin/bash'), ('remote', '/bin/bash'),
                            ('native', BASH), ('remote', BASH), ('local-helper', BASH)]:
            with self.subTest(mode=mode, shell=shell):
                result = self.shell(mode, shell, 'codex "two words" ""')
                self.output_contains(result, 'PROFILE\n')
                self.output_contains(result, 'WRAPPED <launch> <codex> <two words> <>')

    def test_alias_and_function_controls(self):
        for shell in ['/bin/zsh', '/bin/bash']:
            startup = '.zshrc' if shell.endswith('zsh') else '.bash_profile'
            for mode in ['native', 'remote']:
                for name in ['codex', 'ssh'] if mode == 'native' else ['codex']:
                    for setup in [f'alias {name}="printf USER-COMMAND"',
                                  f'function {name} {{ printf USER-COMMAND; }}']:
                        with self.subTest(shell=shell, mode=mode, name=name, setup=setup):
                            self.write(startup, setup + '\n')
                            self.output_contains(self.shell(mode, shell, name), 'USER-COMMAND')

    def test_bash_exported_function_control(self):
        self.env['BASH_FUNC_codex%%'] = '() { printf USER-EXPORTED; }'
        for mode in ['native', 'local-helper', 'remote']:
            with self.subTest(mode=mode):
                self.output_contains(self.shell(mode, '/bin/bash', 'codex'), 'USER-EXPORTED')

    def test_bash_custom_rcfile_with_spaces_control(self):
        self.require_bash()
        rc = self.write('custom bash rc', 'echo CUSTOM-RC\n')
        launch = self.launch(BASH + ' --rcfile "' + str(rc) + '" -i', self.env)
        result = run(['/bin/bash', '--noprofile', '--norc', '-c', 'exec ' + launch['command']],
                     env=launch['environment'], input='exit\n')
        self.output_contains(result, 'CUSTOM-RC\n')

    def test_fish_standard_autoload_and_config_controls(self):
        self.require_fish()
        for startup in ['.config/fish/functions/codex.fish', '.config/fish/config.fish']:
            for mode in ['native', 'local-helper', 'remote']:
                with self.subTest(startup=startup, mode=mode):
                    self.write(startup, 'function codex\n echo USER-CODEX\nend\n')
                    self.output_contains(self.shell(mode, FISH, 'codex'), 'USER-CODEX')
            (self.home / startup).unlink()

    def test_fish_late_autoload_remote_control(self):
        self.require_fish()
        self.write('.config/fish/config.fish', 'set -p fish_function_path $HOME/custom-functions\n')
        self.write('custom-functions/codex.fish', 'function codex\n echo USER-CODEX\nend\n')
        self.output_contains(self.shell('remote', FISH, 'codex'), 'USER-CODEX')

    def test_default_local_bash32_reads_profile(self):
        """S1: Ghostty injects nothing into /bin/bash, so the helper's startup files load the profile, once."""
        self.write('.bash_profile', 'export PATH="$AUDIT_BIN:/usr/bin:/bin"\necho PROFILE\n'
                   'HISTFILE=$HOME/.audit_history\nfunction profiled { printf PROFILED; }\n')
        self.env['BASH_FUNC_exported%%'] = '() { printf EXPORTED; }'
        result = self.shell('local-helper', '/bin/bash',
                            'printf "READY\\n"; shopt -qo posix && echo POSIX; echo "HIST=$HISTFILE"; profiled; exported')
        self.output_contains(result, 'READY\n')
        self.assertEqual(result.stdout.count('PROFILE\n'), 1, result.stdout)
        self.assertNotIn('POSIX', result.stdout)
        self.output_contains(result, 'HIST=' + str(self.home / '.audit_history'))
        self.output_contains(result, 'PROFILEDEXPORTED')

    def test_fish_late_autoload_local_preserves_user_command(self):
        """S2: the wrappers are autoload files, so a function folder config.fish or a plugin adds wins."""
        self.require_fish()
        self.write('custom-functions/codex.fish', 'function codex\n echo USER-CODEX\nend\n')
        self.write('custom-functions/ssh.fish', 'function ssh\n echo USER-SSH\nend\n')
        for startup in ['.config/fish/config.fish', '.config/fish/conf.d/plugin.fish']:
            for mode in ['native', 'local-helper']:
                with self.subTest(startup=startup, mode=mode):
                    self.write(startup, 'set -p fish_function_path $HOME/custom-functions\n')
                    self.output_contains(self.shell(mode, FISH, 'codex; ssh'), 'USER-CODEX\nUSER-SSH\n')
            (self.home / startup).unlink()
        # Without a user function the wrappers still run, typed and from scripts.
        for mode in ['native', 'local-helper']:
            with self.subTest(mode=mode, user=False):
                result = self.shell(mode, FISH, 'codex "two words"; ssh')
                self.output_contains(result, 'WRAPPED <launch> <codex> <two words>')
                self.output_contains(result, 'WRAPPED <--ssh-launch>')

    def test_remote_zsh_word_split_preserves_startup(self):
        """S3a: the source operand is quoted, so SH_WORD_SPLIT and a folder with spaces keep every file."""
        self.write('.zshenv', 'setopt SH_WORD_SPLIT\n')
        result = self.shell('remote', '/bin/zsh', 'typeset -f codex')
        for marker in ['PROFILE\n', 'RC\n', 'LOGIN\n']:
            self.output_contains(result, marker)

    def test_remote_zsh_source_alias_preserves_startup(self):
        """S3b: `builtin source` is immune to a user alias for source."""
        self.write('.zshenv', 'alias source="echo SOURCE-INTERCEPT"\n')
        self.output_contains(self.shell('remote', '/bin/zsh', 'typeset -f codex'), 'RC\n')

    def test_local_zsh_word_split_and_source_alias_controls(self):
        for setup in ['setopt SH_WORD_SPLIT', 'alias source="echo SOURCE-INTERCEPT"']:
            with self.subTest(setup=setup):
                self.write('.zshenv', setup + '\n')
                result = self.shell('local-helper', '/bin/zsh', 'typeset -f codex')
                for marker in ['PROFILE\n', 'RC\n', 'LOGIN\n']:
                    self.output_contains(result, marker)

    def test_native_zsh_unset_zdotdir_with_nounset(self):
        """S4: a user file that unsets ZDOTDIR under nounset falls back to HOME, as zsh does."""
        for name in ['.zshenv', '.zshrc', '.zlogin']:
            for mode in ['native', 'local-helper']:
                with self.subTest(file=name, mode=mode):
                    self.setUp()
                    self.write(name, 'unset ZDOTDIR\nsetopt nounset\necho USER' + name + '\n')
                    result = self.shell(mode, '/bin/zsh', 'typeset -f codex')
                    self.assertNotIn('ZDOTDIR: parameter not set', result.stderr, result.stderr)
                    self.output_contains(result, 'USER' + name + '\n')
                    for marker in {'.zshenv': ['PROFILE\n', 'RC\n', 'LOGIN\n'], '.zshrc': ['LOGIN\n'], '.zlogin': ['RC\n']}[name]:
                        self.output_contains(result, marker)
                    self.output_contains(result, 'DISPATCH_HELPER_EXECUTABLE')

    def test_remote_zsh_unset_zdotdir_with_nounset_control(self):
        self.write('.zshrc', 'unset ZDOTDIR\nsetopt nounset\n')
        self.output_contains(self.shell('remote', '/bin/zsh', 'typeset -f codex'), 'DISPATCH_SSH_HELPER')

    def test_quoted_bash_executable_can_launch(self):
        """S5: integration quotes the arguments it rebuilds, so a quoted executable path still launches."""
        self.require_bash()
        shell = self.root / 'custom shell' / 'bash'
        shell.parent.mkdir()
        shell.symlink_to(BASH)
        original = '"' + str(shell) + '" -il'
        control = run(['/bin/bash', '--noprofile', '--norc', '-c', 'exec -l ' + original],
                      env=self.env, input='echo READY\nexit\n')
        self.output_contains(control, 'READY\n')
        launch = self.launch(original, self.env)
        result = run(['/bin/bash', '--noprofile', '--norc', '-c', 'exec -l ' + launch['command']],
                     env=launch['environment'], input='echo READY\nexit\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.output_contains(result, 'READY\n')
        # Words the shell expands keep expanding: $HOME, ~ (Ghostty's join never quoted them).
        # A home without blanks, so the unquoted $HOME of the original command is one word.
        home = Path(tempfile.mkdtemp(prefix='dshellhome-', dir='/private/tmp'))
        self.addCleanup(shutil.rmtree, home)
        (home / 'bin').mkdir()
        (home / 'bin/bash').symlink_to(BASH)
        for command in ['$HOME/bin/bash -il', '~/bin/bash -il', '"$HOME/bin/bash" -il']:
            with self.subTest(command=command):
                launch = self.launch(command, dict(self.env, HOME=str(home)))
                result = run(['/bin/bash', '--noprofile', '--norc', '-c', 'exec -l ' + launch['command']],
                             env=launch['environment'], input='echo READY\nexit\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.output_contains(result, 'READY\n')

    def test_fish_tmux_preserves_path_typed_xdg_data_dirs(self):
        """S6: the tmux wrapper joins a fish path list with colons; unset or empty is the XDG default."""
        self.require_fish()
        cases = [
            ('set --erase XDG_DATA_DIRS', '/native/share:/usr/local/share:/usr/share>'),
            ('set -gx XDG_DATA_DIRS ""', '/native/share:/usr/local/share:/usr/share>'),
            ('set -gx --path XDG_DATA_DIRS /fixture/one', '/native/share:/fixture/one>'),
            ('set --global --export --path XDG_DATA_DIRS /fixture/one /fixture/two', '/native/share:/fixture/one:/fixture/two>'),
            ('set -gx --path XDG_DATA_DIRS "/fixture/with space" /fixture/two', '/native/share:/fixture/with space:/fixture/two>'),
            ('set -gx XDG_DATA_DIRS /fixture/one:/fixture/two', '/native/share:/fixture/one:/fixture/two>'),
        ]
        for setup, expected in cases:
            with self.subTest(setup=setup):
                self.write('.config/fish/config.fish', setup + '\n')
                self.output_contains(self.shell('native', FISH, 'tmux'), expected)


if __name__ == '__main__':
    unittest.main()
