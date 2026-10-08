"""Small PTY driver used only by the local Codex integration tests."""
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import time


def command(executable, arguments, environment):
    """Exercise Dispatch's wrapper, or the same native isolation outside the app."""
    # A Dispatch terminal: the helper's typed launch (what typing `codex` there runs). Local terminals name
    # the helper in DISPATCH_HELPER_EXECUTABLE, remote login shells in DISPATCH_SSH_HELPER.
    helper = environment.get('DISPATCH_HELPER_EXECUTABLE') or environment.get('DISPATCH_SSH_HELPER')
    if helper:
        return [helper, 'launch', 'codex', *arguments]
    isolated = []
    if not any(arg in ('--no-daemon', '--remote') or arg.startswith('--remote=') for arg in arguments):
        result = subprocess.run([executable, '--help'], env=environment, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, check=True)
        if b'--no-daemon' in result.stdout.split():
            isolated = ['--no-daemon']
    return [executable, *isolated, *arguments]


class CodexPTY:
    def __init__(self, executable, work, env, arguments=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(work)
            env = dict(env, PATH=os.path.dirname(executable) + os.pathsep + env.get('PATH', ''))
            argv = command(executable, ['--no-alt-screen', *(arguments or [])], env)
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        self.output = ''
        self.transcript = ''

    def pump(self, timeout=0.05):
        if not select.select([self.fd], [], [], timeout)[0]:
            return
        try:
            data = os.read(self.fd, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                return
            raise
        if b'\x1b[6n' in data:
            self.send(b'\x1b[1;1R')
        self.output += data.decode(errors='replace')
        self.transcript += data.decode(errors='replace')

    def send(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)

    def expect(self, *texts, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump()
            clean = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', self.output)
            if any(text in clean for text in texts):
                self.output = ''
                return
        raise AssertionError(f'Codex did not display any of {texts!r}: {self.output[-4000:]!r}')

    def submit(self, text):
        self.send('\x1b[200~' + text + '\x1b[201~')
        time.sleep(0.2)
        self.pump(0.05)
        self.send('\r')

    def trust_fixture_hooks(self):
        self.expect('Hooks need review')
        time.sleep(0.25)
        self.pump()
        self.send('\r')  # Open the real review UI; never set trust hashes ourselves.
        self.expect('trust all')
        time.sleep(0.15)
        self.send('t')   # Only the generated fixture hooks are installed in this home.
        self.expect('Press enter to view hooks', 'enter details')
        self.send('\x1b')
        self.pump(0.1)

    def close(self):
        # Drain terminal output while the child restores its TTY. Waiting without
        # reading can deadlock macOS tty teardown with a full output queue.
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        reaped = False
        for _ in range(50):
            self.pump(0.02)
            child, _ = os.waitpid(self.pid, os.WNOHANG)
            if child:
                reaped = True
                break
        os.close(self.fd)
        if not reaped:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for _ in range(100):
                child, _ = os.waitpid(self.pid, os.WNOHANG)
                if child: break
                time.sleep(0.02)
            else:
                raise RuntimeError('Codex test child did not exit after closing its PTY')
