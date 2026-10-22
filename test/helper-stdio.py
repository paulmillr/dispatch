#!/usr/bin/env python3
"""The iPhone's helper session, reproduced: `dispatch-helper --remote --capabilities <full> --stdio`
on plain pipes or on a non-PTY `ssh` exec channel, with no login shell, no TERM, no `login`
wrapper and no `connect` bridge. Frames flow over the channel's stdin and stdout.

Live cases start private tmux and herdr servers, a user-owned sshd on a free loopback port and
the scripted agent fixtures, all under a short root (/tmp/hs-<pid>); nothing touches the real
account's ~/.dispatch, tmux or herdr. They run only with --live (or DISPATCH_HELPER_STDIO_LIVE=1):

    python3 test/helper-stdio.py --live [--helper PATH] [-k pattern] [--keep]

Without --live only the codec cases run. Numbers (reattach time, observe throughput) are
printed as `METRIC name value unit` lines.
"""
import argparse
import asyncio
import base64
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'build/test-tools/bin'
# What the phone grants: Dispatch/SSH/SSHIntegrationPolicy.swift capabilities(.full, hooks: true).
FULL = sorted({'host.identity', 'stats.sample', 'stats.ping', 'stats.processes', 'shell.lifecycle', 'cancel',
               'events', 'input.window', 'agent.inspect', 'agent.version', 'agent.submit', 'agent.events',
               'agent.queue', 'agent.side', 'backend.register', 'tmux.pane', 'herdr.start', 'herdr.rpc',
               'herdr.terminal', 'file.read', 'file.text', 'hooks.configure', 'agent.pi', 'agent.pi.configure'})
CAPABILITIES = ','.join(FULL)
# The opt-in features the phone names in hello (helper/core/src/dispatch/features.rs). A client that
# names none (the Mac app) gets exactly the replies its replay corpus recorded.
FEATURES = ['interaction.options', 'chat.list', 'projects.recent', 'multiplexers.versions', 'terminals.coalesce',
            'launch.names', 'stdio.liveness', 'terminals.activity']
# With stdio.liveness the helper ends after 45 s without traffic; the phone pings this often.
PING = 15
# sshd's PATH for a non-login exec channel (macOS; Linux adds /usr/local/bin and /usr/games).
SSHD_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'
REQUEST, RESPONSE, NOTIFY, CANCEL, CHUNK = 1, 2, 3, 4, 5


# ---------------------------------------------------------------------------------------------
# Binary value codec (helper/core/src/wire/body.rs), names from the app's generated codec.

class Codec:
    def __init__(self, source=ROOT / 'Dispatch/Helper/HelperBinary.swift'):
        text = Path(source).read_text()
        self.schema = bytes(json.loads(re.search(r'static let schema: \[UInt8\] = (\[[^\]]*\])', text).group(1)))
        self.version = int(re.search(r'static let version: UInt64 = (\d+)', text).group(1))
        symbols = re.search(r'static let symbols: \[String\] = \[(.*?)\n\]', text, re.S).group(1)
        self.symbols = json.loads('[' + symbols.strip().rstrip(',') + ']')
        records = re.search(r'static let records: \[\[String\]\] = \[(.*?)\n\]', text, re.S).group(1)
        self.records = json.loads('[' + records.strip().rstrip(',') + ']')
        assert self.version == struct.unpack('<Q', self.schema)[0], 'schema and version disagree'

    @staticmethod
    def put(out, value):
        if value is None:
            out.append(0)
        elif value is False:
            out.append(1)
        elif value is True:
            out.append(2)
        elif isinstance(value, int):
            out += (b'\x03' + struct.pack('<Q', value)) if value >= 0 else (b'\x04' + struct.pack('<q', value))
        elif isinstance(value, float):
            out += b'\x05' + struct.pack('<d', value)
        elif isinstance(value, str):
            data = value.encode()
            out += b'\x06' + struct.pack('<I', len(data)) + data
        elif isinstance(value, (bytes, bytearray)):
            out += b'\x0b' + struct.pack('<I', len(value)) + bytes(value)
        elif isinstance(value, (list, tuple)):
            out += b'\x07' + struct.pack('<I', len(value))
            for item in value:
                Codec.put(out, item)
        elif isinstance(value, dict):
            out += b'\x08' + struct.pack('<I', len(value))
            for key, item in value.items():
                data = key.encode()
                out += b'\xff\xff' + struct.pack('<I', len(data)) + data
                Codec.put(out, item)
        else:
            raise TypeError(type(value))

    def encode(self, value, schema=True):
        out = bytearray(self.schema if schema else b'')
        self.put(out, value)
        return bytes(out)

    def decode(self, data, schema=True):
        if schema:
            if data[:8] != self.schema:
                raise ValueError('outdated schema ' + data[:8].hex())
            at = 8
        else:
            at = 0
        names = self.symbols if schema else []
        records = self.records if schema else []

        def take(count):
            nonlocal at
            chunk = data[at:at + count]
            if len(chunk) != count:
                raise ValueError('truncated body')
            at += count
            return chunk

        def key():
            index = struct.unpack('<H', take(2))[0]
            if index == 0xFFFF:
                return take(struct.unpack('<I', take(4))[0]).decode()
            return names[index]

        def value():
            tag = take(1)[0]
            if tag == 0:
                return None
            if tag in (1, 2):
                return tag == 2
            if tag == 3:
                return struct.unpack('<Q', take(8))[0]
            if tag == 4:
                return struct.unpack('<q', take(8))[0]
            if tag == 5:
                return struct.unpack('<d', take(8))[0]
            if tag == 6:
                return take(struct.unpack('<I', take(4))[0]).decode()
            if tag == 11:
                return bytes(take(struct.unpack('<I', take(4))[0]))
            if tag == 9:
                return names[struct.unpack('<H', take(2))[0]]
            if tag == 10:
                fields = records[struct.unpack('<H', take(2))[0]]
                return {field: value() for field in fields}
            if tag == 7:
                return [value() for _ in range(struct.unpack('<I', take(4))[0])]
            if tag == 8:
                result = {}
                for _ in range(struct.unpack('<I', take(4))[0]):
                    name = key()
                    result[name] = value()
                return result
            raise ValueError('tag %d' % tag)

        result = value()
        if at != len(data):
            raise ValueError('trailing bytes')
        return result


# ---------------------------------------------------------------------------------------------
# One helper session over a byte stream (a child's pipes: local or the ssh client).

class HelperError(Exception):
    def __init__(self, method, error):
        self.method, self.error = method, error
        self.code = (error or {}).get('code') if isinstance(error, dict) else None
        super().__init__(f'{method}: {error}')


class Session:
    def __init__(self, codec, process, log=None):
        self.codec, self.process, self.log = codec, process, log
        self.serial = 0
        self.pending = {}
        self.queues = {}
        self.chunks = {}
        self.methods = {}
        self.closed = asyncio.get_running_loop().create_future()
        self.bytes_in = 0
        # terminal.output bytes per terminal (not queued), latest topology per backend.
        self.output = {}
        self.output_bytes = 0
        self.output_frames = 0
        self.changed = asyncio.Event()
        self.topology = {}
        self.pinger = None
        self.reader = asyncio.ensure_future(self.read())

    @classmethod
    async def start(cls, codec, argv, env, log=None, cwd=None):
        process = await asyncio.create_subprocess_exec(
            *map(str, argv), stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=log or asyncio.subprocess.DEVNULL, env=env, cwd=cwd, start_new_session=True,
            limit=1 << 24)
        return cls(codec, process, log)

    async def read(self):
        stream = self.process.stdout
        try:
            while True:
                header = await stream.readexactly(13)
                length, kind, ident = struct.unpack('<IBQ', header)
                body = await stream.readexactly(length - 9)
                self.bytes_in += 13 + len(body)
                self.frame(kind, ident, body)
        except (asyncio.IncompleteReadError, ConnectionError) as error:
            reason = error
        except Exception as error:  # a codec failure is a test failure, not a hang
            reason = error
        for future in self.pending.values():
            if not future.done():
                future.set_exception(EOFError('helper closed: %r' % reason))
                future.exception()  # retrieved: a closed session fails its waiters, not the loop
        for queue in self.queues.values():
            queue.put_nowait(('closed', reason))
        if not self.closed.done():
            self.closed.set_result(reason)

    def frame(self, kind, ident, body):
        if kind == CHUNK:
            sequence = struct.unpack_from('<Q', body)[0]
            parts = self.chunks.setdefault(ident, [])
            assert sequence == len(parts), 'chunk sequence'
            parts.append(body[8:])
            return
        value = self.codec.decode(body)
        if isinstance(value, dict) and 'stream' in value:
            raw = b''.join(self.chunks.pop(ident, []))
            stream = value['stream']
            assert stream['bytes'] == len(raw), 'stream totals'
            if 'error' in value and value['error'] is not None:
                pass
            elif stream.get('encoding') == 'value':
                value = self.codec.decode(raw)
            else:
                value = dict(value, data=raw)
        if kind == RESPONSE:
            future = self.pending.pop(ident, None)
            if future and not future.done():
                if isinstance(value, dict) and value.get('error') is not None:
                    future.set_exception(HelperError(self.methods.get(ident), value['error']))
                else:
                    future.set_result(value.get('result') if isinstance(value, dict) else value)
            elif ident in self.queues:
                self.queues[ident].put_nowait(('response', value))
        elif kind == NOTIFY:
            method, params = value.get('method'), value.get('params')
            if method == 'terminal.output':
                self.output.setdefault(params['terminal'], bytearray()).extend(params['bytes'])
                self.output_bytes += len(params['bytes'])
                self.output_frames += 1
                self.changed.set()
                return
            if method == 'topology':
                self.topology[params['backend']] = params
                self.changed.set()
            queue = self.queues.get(ident)
            if queue is None:
                queue = self.queues.setdefault(0, asyncio.Queue())
            queue.put_nowait((value.get('method'), value.get('params')))

    def send(self, kind, ident, body):
        self.process.stdin.write(struct.pack('<IBQ', len(body) + 9, kind, ident) + body)

    def submit(self, method, params=None, observe=False):
        self.serial += 1
        ident = self.serial
        future = asyncio.get_running_loop().create_future()
        self.pending[ident] = future
        self.methods[ident] = method
        if observe:
            self.queues[ident] = asyncio.Queue()
        self.send(REQUEST, ident, self.codec.encode({'method': method, 'params': params or {}}))
        return ident, future

    async def request(self, method, params=None, timeout=20):
        _, future = self.submit(method, params)
        await self.process.stdin.drain()
        return await asyncio.wait_for(future, timeout)

    async def observe(self, method, params=None, timeout=20, wait=True):
        """An observer request: its response (when it comes) and every notification on its id."""
        ident, future = self.submit(method, params, observe=True)
        await self.process.stdin.drain()
        result = await asyncio.wait_for(future, timeout) if wait else future
        return ident, result

    async def until(self, predicate, timeout=20, what='condition'):
        """Wait until predicate() is true, re-checked whenever output or topology changes."""
        deadline = time.monotonic() + timeout
        while True:
            value = predicate()
            if value:
                return value
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('timed out waiting for ' + what)
            self.changed.clear()
            try:
                await asyncio.wait_for(self.changed.wait(), min(remaining, 0.25))
            except asyncio.TimeoutError:
                pass
            if self.closed.done():
                raise EOFError('helper closed while waiting for ' + what)

    def nodes(self, backend):
        return (self.topology.get(backend) or {}).get('nodes', [])

    def cancel(self, ident):
        self.send(CANCEL, ident, b'')
        self.queues.pop(ident, None)

    async def notification(self, ident, accept=lambda method, params: True, timeout=20):
        queue = self.queues[ident]
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f'no matching notification on {ident} ({self.methods.get(ident)})')
            try:
                method, params = await asyncio.wait_for(queue.get(), remaining)
            except asyncio.TimeoutError:
                raise TimeoutError(f'no matching notification on {ident} ({self.methods.get(ident)})') from None
            if method == 'closed':
                raise EOFError('helper closed: %r' % (params,))
            if accept(method, params):
                return method, params

    async def ping(self, interval):
        """`echo` every `interval` seconds, as the phone does (its stats.ping), until closed."""
        while not self.closed.done():
            await asyncio.sleep(interval)
            try:
                await self.request('echo', {'ping': 1}, timeout=10)
            except (HelperError, EOFError, asyncio.TimeoutError, ConnectionError):
                return

    async def close(self, kill=False):
        if self.pinger:
            self.pinger.cancel()
        if self.process.returncode is None:
            if kill:
                self.process.kill()
            else:
                try:
                    self.process.stdin.close()
                except (BrokenPipeError, ConnectionError):
                    pass
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()
        self.reader.cancel()




# ---------------------------------------------------------------------------------------------
# The client's screen. Chat input is verified against the screen the client publishes
# (terminals.publish, like the Mac's TerminalBackend.publishScreen): the phone must keep a Term
# surface per agent terminal and publish its visible text, cursor and faint tail. This minimal
# VT model stands in for Term: enough for herdr's frame renderer and tmux capture-pane output.

class Screen:
    def __init__(self, rows=24, columns=80):
        self.rows, self.columns = rows, columns
        self.reset()

    def reset(self):
        self.cells = [[(' ', False)] * self.columns for _ in range(self.rows)]
        self.row = self.column = 0
        self.faint = False
        self.pending = b''

    def feed(self, data):
        data = self.pending + bytes(data)
        self.pending = b''
        text = data.decode('utf-8', errors='replace') if not data.endswith(b'\x1b') else data[:-1].decode('utf-8', 'replace')
        if data.endswith(b'\x1b'):
            self.pending = b'\x1b'
        i, n = 0, len(text)
        while i < n:
            c = text[i]
            if c == '\x1b' and i + 1 < n:
                kind = text[i + 1]
                if kind == '[':
                    j = i + 2
                    while j < n and not ('@' <= text[j] <= '~'):
                        j += 1
                    if j >= n:
                        self.pending = text[i:].encode()
                        return
                    self.csi(text[i + 2:j], text[j])
                    i = j + 1
                    continue
                if kind == ']':
                    j = i + 2
                    while j < n and text[j] != '\x07' and not text.startswith('\x1b\\', j):
                        j += 1
                    if j >= n:
                        self.pending = text[i:].encode()
                        return
                    i = j + (1 if text[j] == '\x07' else 2)
                    continue
                if kind == 'c':
                    self.reset()
                i += 2
                continue
            if c == '\r':
                self.column = 0
            elif c == '\n':
                self.newline()
            elif c == '\b':
                self.column = max(0, self.column - 1)
            elif c >= ' ':
                if self.column >= self.columns:
                    self.column = 0
                    self.newline()
                self.cells[self.row][self.column] = (c, self.faint)
                self.column += 1
            i += 1

    def newline(self):
        if self.row == self.rows - 1:
            self.cells = self.cells[1:] + [[(' ', False)] * self.columns]
        else:
            self.row += 1

    def csi(self, params, final):
        private = params.startswith(('?', '>', '<', '='))
        values = [int(v) if v.isdigit() else 0 for v in params.lstrip('?><=').split(';')] if params else []
        first = values[0] if values else 0
        if private:
            return
        if final in 'Hf':
            self.row = min(max((values[0] if values and values[0] else 1) - 1, 0), self.rows - 1)
            self.column = min(max((values[1] if len(values) > 1 and values[1] else 1) - 1, 0), self.columns - 1)
        elif final == 'G':
            self.column = min(max((first or 1) - 1, 0), self.columns - 1)
        elif final == 'd':
            self.row = min(max((first or 1) - 1, 0), self.rows - 1)
        elif final == 'A':
            self.row = max(0, self.row - (first or 1))
        elif final == 'B':
            self.row = min(self.rows - 1, self.row + (first or 1))
        elif final == 'C':
            self.column = min(self.columns - 1, self.column + (first or 1))
        elif final == 'D':
            self.column = max(0, self.column - (first or 1))
        elif final == 'J':
            if first == 2 or first == 3:
                self.cells = [[(' ', False)] * self.columns for _ in range(self.rows)]
            elif first == 0:
                self.cells[self.row][self.column:] = [(' ', False)] * (self.columns - self.column)
                for row in range(self.row + 1, self.rows):
                    self.cells[row] = [(' ', False)] * self.columns
        elif final == 'K':
            if first == 0:
                self.cells[self.row][self.column:] = [(' ', False)] * (self.columns - self.column)
            elif first == 2:
                self.cells[self.row] = [(' ', False)] * self.columns
        elif final == 'X':
            for column in range(self.column, min(self.columns, self.column + (first or 1))):
                self.cells[self.row][column] = (' ', False)
        elif final == 'm':
            for value in values or [0]:
                if value in (0, 22):
                    self.faint = False
                elif value == 2:
                    self.faint = True

    def published(self):
        """{text, cursor, faint_tail} as the Mac's publishScreen sends them."""
        text = '\n'.join(''.join(c for c, _ in row).rstrip() for row in self.cells)
        tail = self.cells[self.row][self.column:]
        faint = any(f for c, f in tail if c != ' ') and all(f for c, f in tail if c != ' ')
        return {'text': text, 'cursor': {'column': self.column, 'row': self.row}, 'faint_tail': faint}


# ---------------------------------------------------------------------------------------------
# Fixture: a short private root with its own HOME, tmux socket, herdr socket, sshd and agents.
#
# Safety: shells here may run inside the user's tmux, where `$TMUX` names
# the user's server and tmux ignores TMUX_TMPDIR. Every tmux command this script runs carries
# an explicit `-S <root>/…` socket and runs without TMUX; herdr is reached only through
# HERDR_SOCKET_PATH under the root; teardown kills only pids this script recorded, after
# checking their command line.

def metric(name, value, unit):
    print(f'METRIC {name} {value:.3f} {unit}' if isinstance(value, float) else f'METRIC {name} {value} {unit}',
          flush=True)


class Host:
    """Where the helper, tmux, herdr and the agents run: this Mac, or an SSH destination (`--remote`).
    Everything the cases do on that machine goes through `run`, so both behave the same."""
    remote = False

    def __init__(self):
        self.scripts = ROOT / 'scripts'
        self.tmux_executable = str(TOOLS / 'tmux')
        self.path = SSHD_PATH
        self.uid = os.getuid()

    def run(self, argv, input=None, timeout=30):
        """argv on the host without TMUX; stdout as text."""
        env = {k: v for k, v in os.environ.items() if k not in ('TMUX', 'TMUX_PANE')}
        result = subprocess.run([str(a) for a in argv], input=input, capture_output=True, timeout=timeout, env=env)
        return subprocess.CompletedProcess(result.args, result.returncode, result.stdout.decode(errors='replace'),
                                           result.stderr.decode(errors='replace'))

    def sh(self, script, *arguments, input=None, timeout=30):
        return self.run(['/bin/sh', '-c', script, 'sh', *map(str, arguments)], input=input, timeout=timeout)

    def exists(self, path):
        return self.sh('test -e "$1" || test -S "$1"', path).returncode == 0

    def read(self, path):
        result = self.sh('cat "$1"', path)
        if result.returncode:
            raise FileNotFoundError(str(path))
        return result.stdout

    def write(self, path, data, mode=0o600):
        data = data.encode() if isinstance(data, str) else data
        result = self.sh('umask 077; cat > "$1" && chmod "$2" "$1"', path, oct(mode)[2:], input=data)
        if result.returncode:
            raise OSError(result.stderr)

    def mkdir(self, path):
        self.sh('mkdir -p -m 700 "$1"', path)

    def listdir(self, path):
        return sorted(self.sh('ls -A "$1" 2>/dev/null', path).stdout.split())

    def python(self, code):
        """A Python snippet on the host with the fixture scripts importable; prints one JSON value."""
        prelude = f'import json, sys; sys.path.insert(0, {str(self.scripts)!r})\n'
        result = self.run(['python3', '-c', prelude + code], timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1]) if result.stdout.strip() else None

    def spawn(self, argv, log):
        """A detached process group; its pid."""
        child = subprocess.Popen([str(a) for a in argv], start_new_session=True, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=open(log, 'ab'))
        return child.pid

    def command(self, pid):
        return self.run(['ps', '-o', 'args=', '-p', str(pid)]).stdout.strip()

    def alive(self, pid):
        return self.run(['kill', '-0', str(pid)]).returncode == 0

    def kill(self, pid, signal_name='TERM', group=False):
        self.run(['kill', '-' + signal_name, ('-' if group else '') + str(pid)] if not group else
                 ['kill', '-' + signal_name, '--', '-' + str(pid)])

    def processes(self):
        return self.run(['ps', '-A', '-o', 'pid=', '-o', 'args=']).stdout.splitlines()

    def close(self):
        pass


class Remote(Host):
    """An SSH destination (user@host[:port]). Fixture files live under the same private root there;
    one private ControlMaster carries the fixture's own commands, never the helper sessions."""
    remote = True

    def __init__(self, destination, identity, local):
        super().__init__()
        user_host, _, port = destination.rpartition(':') if destination.count(':') == 1 else (destination, '', '')
        self.destination, self.port = (user_host or destination), port
        self.local = local
        local.mkdir(mode=0o700)
        self.options = ['-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
                        '-o', f'UserKnownHostsFile={local}/known_hosts', '-o', 'LogLevel=ERROR',
                        '-o', 'IdentitiesOnly=yes', '-o', 'ServerAliveInterval=15']
        if identity:
            self.options += ['-i', str(identity)]
        if self.port:
            self.options += ['-p', self.port]
        self.control = local / 'cm'
        self.master = subprocess.Popen(['/usr/bin/ssh', *self.options, '-o', 'ControlMaster=yes', '-o',
                                        f'ControlPath={self.control}', '-N', self.destination],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 15
        while not self.control.exists():
            if self.master.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f'cannot reach {destination}')
            time.sleep(0.05)
        self.tmux_executable = 'tmux'
        self.path = self.sh('printf %s "$PATH"').stdout
        self.uid = int(self.run(['id', '-u']).stdout)

    def ssh(self, command, multiplexed=True):
        mux = ['-o', f'ControlPath={self.control}'] if multiplexed else ['-o', 'ControlPath=none']
        return ['/usr/bin/ssh', *self.options, *mux, '-T', self.destination, command]

    def run(self, argv, input=None, timeout=30):
        command = 'exec env -u TMUX -u TMUX_PANE ' + ' '.join(shlex.quote(str(a)) for a in argv)
        return super().run(self.ssh(command), input=input, timeout=timeout)

    def spawn(self, argv, log):
        # setsid: its own session and group, as start_new_session locally; $! is that process.
        command = ' '.join(shlex.quote(str(a)) for a in argv)
        result = self.sh(f'cd /; setsid {command} >>"$1" 2>&1 </dev/null & echo $!', log)
        return int(result.stdout.split()[-1])

    def close(self):
        if self.master.poll() is None:
            self.master.terminate()
            self.master.wait(5)


class Fixture:
    def __init__(self, helper, keep=False, host=None, prepend=None):
        self.host = host or Host()
        host = self.host
        self.helper = Path(helper).resolve()
        self.keep = keep
        self.root = Path(f'/tmp/hs-{os.getpid()}')
        if host.exists(self.root):
            raise RuntimeError(f'{self.root} exists')
        host.mkdir(self.root)
        self.home = self.root / 'h'
        # Programs where a user installs them; only the login shell's profile names the folder.
        bin = self.home / '.local/bin'
        host.mkdir(bin)
        if not host.remote:
            for tool in ('tmux', 'herdr', 'claude', 'codex', 'pi'):
                if (TOOLS / tool).exists():
                    (bin / tool).symlink_to(TOOLS / tool)
        host.write(self.home / '.bash_profile',
                   f'export PATH="{prepend + ":" if prepend else ""}$HOME/.local/bin:$PATH"\n', 0o644)
        host.mkdir(self.root / 't')
        self.tmux_socket = self.root / 't' / f'tmux-{host.uid}' / 'default'
        # herdr's default under XDG_CONFIG_HOME: the phone's exec channel names no socket.
        self.herdr_socket = self.root / 'x/herdr/herdr.sock'
        host.mkdir(self.root / 'x')
        if host.remote:
            # The fixture scripts the cases run, next to the root (they import each other).
            host.mkdir(self.root / 'scripts')
            for name in ('claude_fixture', 'pi_fixture', 'codex_fixture', 'fixture_barriers', 'codex_pty'):
                host.write(self.root / 'scripts' / f'{name}.py', (ROOT / 'scripts' / f'{name}.py').read_bytes(), 0o644)
            host.scripts = self.root / 'scripts'
        # The phone's install path: ~/.dispatch/bin/versions/<sha256>/dispatch-helper.
        import hashlib
        data = self.helper.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        versions = self.home / '.dispatch/bin/versions' / digest
        host.mkdir(versions)
        for part in (self.home / '.dispatch', self.home / '.dispatch/bin', self.home / '.dispatch/bin/versions'):
            host.sh('chmod 700 "$1"', part)
        self.installed = versions / 'dispatch-helper'
        host.write(self.installed, data, 0o700)
        if host.remote:
            remote = host.sh('sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"', self.installed).stdout.split()[0]
            assert remote == digest, 'uploaded helper differs'
        self.relative = f'.dispatch/bin/versions/{digest}/dispatch-helper'
        self.children = []  # (pid, expected command fragment), on the host
        self.sessions = []  # local ssh clients and helper children
        self.sshd = None
        # What sshd gives a non-PTY exec channel, plus the isolation this test needs.
        self.isolation = {'TMUX_TMPDIR': str(self.root / 't'), 'XDG_CONFIG_HOME': str(self.root / 'x'),
                          'DISPATCH_TEST_ROOT': str(self.home)}
        self.codec = Codec()

    @property
    def transports(self):
        return ('ssh',) if self.host.remote else ('pipes', 'ssh')

    def environment(self):
        """sshd's environment for `ssh host command` without a PTY (no TERM, minimal PATH)."""
        user = os.environ.get('USER') or os.environ['LOGNAME']
        return dict({'HOME': str(self.home), 'USER': user, 'LOGNAME': user, 'SHELL': '/bin/bash',
                     'PATH': SSHD_PATH}, **self.isolation)

    def tmux(self, *arguments):
        return self.host.run([self.host.tmux_executable, '-S', self.tmux_socket, *arguments], timeout=10)

    def herdr(self, method, **params):
        return self.host.python(f"""
import socket
client = socket.socket(socket.AF_UNIX); client.settimeout(5); client.connect({str(self.herdr_socket)!r})
client.sendall(json.dumps({{'id': 'hs', 'method': {method!r}, 'params': {params!r}}}).encode() + b'\\n')
data = b''
while b'\\n' not in data:
    chunk = client.recv(65536)
    if not chunk: break
    data += chunk
print(json.dumps(json.loads(data or b'{{}}')))
""")

    def real(self, path):
        """The resolved path on the host (/tmp is /private/tmp on macOS)."""
        return self.host.sh('cd "$1" && pwd -P', path).stdout.strip()

    def spawn(self, argv, expected, log):
        pid = self.host.spawn(argv, log)
        self.children.append((pid, expected))
        return pid

    def path(self, *before):
        """A PATH for an agent launch: `before`, the profile's folder, then sshd's PATH on the host."""
        return ':'.join([*map(str, before), str(self.home / '.local/bin'), self.host.path])

    # -- sshd (this Mac only; a remote host has its own) ----------------------------------------
    def start_sshd(self):
        if self.host.remote:
            return
        directory = self.root / 's'
        directory.mkdir(mode=0o700)
        for name in ('host', 'user'):
            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(directory / name)],
                           check=True)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        values = ' '.join(f'"{k}={v}"' for k, v in dict(HOME=str(self.home), SHELL='/bin/bash', **self.isolation).items())
        (directory / 'sshd_config').write_text(f'''ListenAddress 127.0.0.1
Port {self.port}
HostKey {directory}/host
AuthorizedKeysFile {directory}/user.pub
PidFile {directory}/pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SetEnv {values}
LogLevel ERROR
''')
        (directory / 'known_hosts').write_text(f'[127.0.0.1]:{self.port} ' + (directory / 'host.pub').read_text())
        self.ssh_options = ['-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                            '-o', f'UserKnownHostsFile={directory}/known_hosts', '-o', 'LogLevel=ERROR',
                            '-o', 'IdentitiesOnly=yes', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                            '-i', str(directory / 'user'), '-p', str(self.port), '-T']
        self.sshd = self.spawn(['/usr/sbin/sshd', '-D', '-e', '-f', directory / 'sshd_config'],
                               '/usr/sbin/sshd -D -e -f ' + str(directory), self.root / 'sshd.log')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                socket.create_connection(('127.0.0.1', self.port), 0.2).close()
                return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError('sshd did not start (sshd.log)')

    def ssh(self, command):
        if self.host.remote:
            return self.host.ssh(command, multiplexed=False)
        return ['/usr/bin/ssh', *self.ssh_options, '127.0.0.1', command]

    # -- helper sessions ------------------------------------------------------------------------
    def command(self, extra=None):
        """The exact command line the phone runs on its exec channel. On a remote host whose sshd
        this test does not configure, the isolation variables are set by `env` instead. `extra`:
        test-only variables for this session."""
        extra = ' '.join(shlex.quote(f'{k}={v}') for k, v in (extra or {}).items())
        if self.host.remote:
            values = ' '.join(shlex.quote(f'{k}={v}') for k, v in
                              dict(HOME=str(self.home), SHELL='/bin/bash', **self.isolation).items())
            return (f'cd {shlex.quote(str(self.home))} && exec env -u TMUX -u TMUX_PANE {values} {extra} '
                    f'{shlex.quote(str(self.installed))} --remote --capabilities {CAPABILITIES} --stdio')
        if extra:
            return f'exec env {extra} "$HOME/{self.relative}" --remote --capabilities {CAPABILITIES} --stdio'
        return f'exec "$HOME/{self.relative}" --remote --capabilities {CAPABILITIES} --stdio'

    async def connect(self, transport, name='helper', extra=None):
        log = open(self.local / f'{name}.log', 'ab')
        if transport == 'pipes':
            argv = [self.installed, '--remote', '--capabilities', CAPABILITIES, '--stdio']
            env, cwd = dict(self.environment(), **(extra or {})), self.home
        else:
            argv = self.ssh(self.command(extra))
            env = {k: v for k, v in os.environ.items() if k not in ('SSH_AUTH_SOCK', 'TMUX', 'TMUX_PANE')}
            cwd = '/tmp'
        session = await Session.start(self.codec, argv, env, log=log, cwd=cwd)
        self.sessions.append(session.process.pid)
        return session

    @property
    def local(self):
        """Local logs: the root itself on this Mac, the ControlMaster folder for a remote host."""
        return self.host.local if self.host.remote else self.root

    def helpers(self):
        """Live helper processes of this fixture (their executable is under this root)."""
        return [int(line.split()[0]) for line in self.host.processes()
                if str(self.installed) in line and ' --stdio' in line]

    # -- teardown -------------------------------------------------------------------------------
    def stop(self):
        host = self.host
        if self.keep:
            # Everything stays for inspection; this prints how to stop it safely later.
            print(f'kept {self.root}{" on the remote host" if host.remote else ""}: stop with '
                  f'`env -u TMUX {host.tmux_executable} -S {self.tmux_socket} kill-server`, '
                  f'herdr server.stop on {self.herdr_socket}, kill pids {[pid for pid, _ in self.children]}', flush=True)
            return
        if host.exists(self.tmux_socket):
            self.tmux('kill-server')
        if host.exists(self.herdr_socket):
            try:
                self.herdr('server.stop')
            except (OSError, RuntimeError, ValueError):
                pass
            # herdr writes a last session snapshot while it stops.
            deadline = time.monotonic() + 5
            while host.exists(self.herdr_socket) and time.monotonic() < deadline:
                time.sleep(0.1)
        for pid, expected in reversed(self.children):
            command = host.command(pid)
            if command and expected in command:
                host.kill(pid, group=True)
                if host.alive(pid):
                    host.kill(pid)
        for pid in self.sessions:
            command = subprocess.run(['/bin/ps', '-o', 'command=', '-p', str(pid)], capture_output=True,
                                     text=True).stdout
            if 'dispatch-helper' in command or '/usr/bin/ssh' in command:
                try:
                    os.killpg(pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
        # Helpers of this fixture (sshd's children; the executable is under this root).
        for pid in self.helpers():
            host.kill(pid)
        # Exiting helpers may still write their run folders: remove the root once they are gone.
        deadline = time.monotonic() + 10
        while self.helpers() and time.monotonic() < deadline:
            time.sleep(0.1)
        time.sleep(0.2)
        assert str(self.root).startswith('/tmp/hs-')
        host.sh('rm -rf "$1"; sleep 1; rm -rf "$1"', self.root)
        host.close()
        if host.remote:
            shutil.rmtree(host.local, ignore_errors=True)


# ---------------------------------------------------------------------------------------------
# Cases

GRID = {'rows': 24, 'columns': 80, 'cell_width': 0, 'cell_height': 0}
TMUX, NATIVE, HERDR = 0, 1, 2  # registration order in helper/bin/src/main.rs


def run(coroutine, timeout=300):
    return asyncio.run(asyncio.wait_for(coroutine, timeout))


class CodecTests(unittest.TestCase):
    def test_values_round_trip_through_the_generated_names(self):
        codec = Codec()
        value = {'method': 'hello', 'params': {'a': [None, True, False, 1, -2, 1.5, 'x', b'\x00\xff']}}
        self.assertEqual(codec.decode(codec.encode(value)), value)
        self.assertEqual(struct.unpack('<Q', codec.schema)[0], codec.version)
        with self.assertRaises(ValueError):
            codec.decode(b'\x00' * 8 + b'\x00')


class Live(unittest.TestCase):
    fixture = None
    helper = None
    keep = False
    remote = None  # (destination, identity, prepend)
    agents = []  # agent pids test 8 and 9 started, ended after their case
    state = {}
    screens = {}

    @classmethod
    def setUpClass(cls):
        if not cls.helper:
            raise unittest.SkipTest('live cases need --live')
        if cls.remote:
            destination, identity, prepend = cls.remote
            host = Remote(destination, identity, Path(f'/tmp/hs-{os.getpid()}-l'))
            cls.fixture = Fixture(cls.helper, cls.keep, host, prepend)
        else:
            cls.fixture = Fixture(cls.helper, cls.keep)
        cls.fixture.start_sshd()

    @classmethod
    def tearDownClass(cls):
        if cls.fixture:
            cls.fixture.stop()

    # -- shared steps -------------------------------------------------------------------------
    async def closing(self, coroutine):
        """Run a case; whatever happens, end the helper sessions it left open."""
        try:
            return await coroutine
        finally:
            for pid in self.fixture.helpers():
                self.fixture.host.kill(pid)

    async def hello(self, session, features=True):
        """hello as the phone sends it: `{features: FEATURES}` (features=False: as the Mac does)."""
        started = time.monotonic()
        names = FEATURES if features is True else features
        hello = await session.request('hello', {'features': names} if names else {}, timeout=30)
        if 'stdio.liveness' in hello.get('features', []) and session.pinger is None:
            session.pinger = asyncio.ensure_future(session.ping(PING))
        return hello, time.monotonic() - started

    async def opened(self, session, mux, key, create=False):
        """backends.create (optionally) then backends.open; the backend id and its first topology."""
        if create:
            await session.request('backends.create', {'mux': mux, 'key': key}, timeout=30)
        ident, _ = await session.observe('backends.open', {'mux': mux, 'key': key}, wait=False)
        _, backend = await session.notification(ident, lambda m, p: m == 'backend.opened', timeout=30)
        await session.until(lambda: session.topology.get(backend), what='topology')
        return backend, ident

    async def window(self, session, mux, backend, cwd, **extra):
        """A new tmux window or herdr tab in the first space, attached and observed."""
        space = next(n['id'] for n in session.nodes(backend) if n['kind'] == 'workspace')
        terminal = await session.request('terminals.create', dict({'mux': mux, 'parent': space, 'cwd': str(cwd)}, **extra),
                                         timeout=30)
        attach, _ = await session.observe('terminals.attach', {'mux': mux, 'terminal': terminal, 'size': GRID,
                                                               'takeover': False}, wait=False)
        await session.notification(attach, lambda m, p: m == 'terminal.attached', timeout=20)
        observe, _ = await session.observe('terminals.observe', {'terminal': terminal}, wait=False)
        return terminal, attach

    async def typed(self, session, mux, terminal, text):
        await session.request('terminals.input', {'mux': mux, 'terminal': terminal, 'bytes': text.encode()})

    async def publish(self, session, mux, backend, terminal, stop):
        """Publish the terminal's screen as the phone's Term surface would (about 10 a second)."""
        screen, offset, last = Screen(GRID['rows'], GRID['columns']), 0, None
        while not stop.is_set() and not session.closed.done():
            node = self.node(session, backend, terminal)
            if node is None:
                await asyncio.sleep(0.1)
                continue
            if mux == TMUX:
                pane = node['key'].rsplit(':', 1)[1]
                lines = self.fixture.tmux('capture-pane', '-p', '-e', '-t', pane).stdout.split('\n')
                cursor = self.fixture.tmux('display', '-p', '-t', pane, '#{cursor_x} #{cursor_y}').stdout.split()
                screen.reset()
                screen.feed(('\x1b[H' + '\r\n'.join(lines[:screen.rows])).encode())
                if len(cursor) == 2:
                    screen.column, screen.row = int(cursor[0]), int(cursor[1])
            else:
                data = session.output.get(terminal, b'')
                screen.feed(data[offset:])
                offset = len(data)
            published = screen.published()
            self.screens[terminal] = published['text']
            if published != last:
                try:
                    await session.request('terminals.publish', dict({'mux': mux, 'terminal': terminal}, **published))
                except (HelperError, EOFError, asyncio.TimeoutError):
                    pass
                last = published
            try:
                await asyncio.wait_for(stop.wait(), 0.1)
            except asyncio.TimeoutError:
                pass

    def node(self, session, backend, terminal):
        return next((n for n in session.nodes(backend) if n['id'] == terminal), None)

    # -- 1. hello and host identity ---------------------------------------------------------------
    def test_1_hello_identity_ping_and_stats(self):
        async def case():
            for transport in self.fixture.transports:
                started = time.monotonic()
                session = await self.fixture.connect(transport, 'hello-' + transport)
                plain, _ = await self.hello(session, features=False)
                metric(f'{transport}.connect_to_hello', (time.monotonic() - started) * 1000, 'ms')
                self.assertNotIn('features', plain, "a hello without features keeps the Mac's reply shape")
                hello, _ = await self.hello(session)
                print(transport, 'features accepted:', hello['features'], flush=True)
                # The login environment's HOME (this fixture's private one) beside the passwd home.
                self.assertNotIn('login_home', plain['account'])
                self.assertNotEqual(hello['account']['home'], str(self.fixture.home))
                self.assertEqual(hello['account'].get('login_home'), str(self.fixture.home))
                self.assertTrue(set(hello['features']) <= set(FEATURES))
                self.assertEqual(plain['ops'], [op for op in hello['ops'] if op not in ('chat.list', 'projects.recent', 'terminals.activity')])
                with self.assertRaises(HelperError):
                    await session.request('hello', {'features': 'chat.list'})
                self.assertEqual(hello['version'], self.fixture.codec.version, 'schema id = HelperBinary.version')
                self.assertIsNone(hello['terminal'], 'no login terminal')
                identity = hello['identity']
                for field in ('host', 'boot', 'hostname', 'os', 'os_version', 'os_label'):
                    self.assertTrue(identity.get(field), field)
                if identity['os'] == 'Darwin':
                    self.assertRegex(identity['os_label'], r'^macOS \d+(\.\d+)*$')
                elif identity.get('distribution') == 'ubuntu':
                    self.assertRegex(identity['os_label'], r'^Ubuntu \d+\.\d+$')
                print(transport, 'identity', json.dumps(identity), flush=True)
                for op in ('backends.create', 'backends.open', 'multiplexers.list', 'terminals.create',
                           'terminals.attach', 'terminals.observe', 'terminals.input', 'terminals.resize',
                           'terminals.scroll', 'close.request', 'chat.open', 'chat.page', 'interactions.answer',
                           'queue.add', 'queue.hold', 'stats.sample', 'echo', 'files.read'):
                    self.assertIn(op, hello['ops'])
                # Latency: the Mac's stats.ping is an `echo` round trip (HelperStatistics.ping).
                samples = []
                for _ in range(20):
                    started = time.monotonic()
                    self.assertEqual(await session.request('echo', {'ping': 1}), {'ping': 1})
                    samples.append((time.monotonic() - started) * 1000)
                metric(f'{transport}.echo_median', sorted(samples)[10], 'ms')
                sample = await session.request('stats.sample', {'plugin': 'stats'})
                self.assertIn('uptime', sample)
                await session.close()
        run(self.closing(case()))

    # -- 2. multiplexers and tmux -----------------------------------------------------------------
    def test_2_tmux_from_a_plain_exec_channel(self):
        async def case():
            fixture = self.fixture
            session = await fixture.connect('ssh', 'tmux')
            await self.hello(session)
            kinds = {k['name']: k for k in await session.request('multiplexers.list')}
            self.assertEqual(kinds['tmux']['mux'], TMUX)
            self.assertEqual(kinds['herdr']['mux'], HERDR)
            backends = {(b['mux'], b['key']) for b in await session.request('backends.list')}
            # Found through the login shell's PATH (~/.bash_profile), not sshd's.
            self.assertIn((TMUX, 'tmux'), backends)
            self.assertIn((HERDR, 'herdr'), backends)
            self.assertFalse(fixture.host.exists(fixture.tmux_socket), 'no tmux server yet')
            before = {row['name']: row for row in await session.request('multiplexers.list')}
            self.assertIs(before['tmux']['running'], False, 'probing never starts a server')
            self.assertIs(before['herdr']['running'], False)
            self.assertIsNone(before['native']['running'])
            self.assertFalse(fixture.host.exists(fixture.tmux_socket))
            self.assertFalse(fixture.host.exists(fixture.herdr_socket))
            with self.assertRaises(HelperError):
                await session.request('backends.open', {'mux': TMUX, 'key': 'tmux'}, timeout=10)
            started = time.monotonic()
            backend, _ = await self.opened(session, TMUX, 'tmux', create=True)
            metric('tmux.create_and_open', (time.monotonic() - started) * 1000, 'ms')
            self.assertTrue(fixture.host.exists(fixture.tmux_socket), 'backends.create started the server')
            # The server outlives this helper session: not a child holding the channel open.
            work = fixture.root / 'work'
            fixture.host.mkdir(work)
            terminal, attach = await self.window(session, TMUX, backend, work)
            # The topology's cwd follows tmux's pane_current_path, which can name the server's
            # directory until the new shell has started in `work`.
            expected = fixture.real(work)
            await session.until(lambda: (self.node(session, backend, terminal) or {}).get('cwd') in (str(work), expected),
                                timeout=15, what='cwd of the new window')
            await self.typed(session, TMUX, terminal, "printf 'HS_%s_OK\\n' tmux; printf '%s\\n' \"$PATH\" \"TERM=$TERM\"\r")
            await session.until(lambda: b'HS_tmux_OK' in session.output.get(terminal, b''), what='printf output')
            await session.until(lambda: b'TERM=' in session.output.get(terminal, b'').split(b'HS_tmux_OK')[-1], what='env')
            tail = bytes(session.output[terminal]).split(b'HS_tmux_OK')[-1].decode(errors='replace')
            self.assertIn(str(fixture.home / '.local/bin'), tail)
            self.assertRegex(tail, r'TERM=\S+')
            pane = fixture.tmux('list-panes', '-a', '-F', '#{pane_id} #{window_width}x#{window_height}').stdout
            # tmux before 3.7 cannot report bracketed-paste state (`#{bracket_paste_flag}` is empty):
            # harness typing into a bound agent then proceeds unverified, other typing is refused
            # ("This tmux server cannot report bracketed-paste state", tmux ops.rs).
            version, flag = fixture.tmux('display', '-p', '-t', pane.split()[0], '#{version}|#{bracket_paste_flag}').stdout.strip().split('|')
            print(f'tmux server {version}: bracket_paste_flag={flag!r}', flush=True)
            Live.state['tmux_version'] = version
            numbers = tuple(int(part) for part in re.findall(r'\d+', version)[:2])
            # multiplexers.versions: the phone's "herdr 0.9.3 / tmux 3.7 / none" line and the
            # older-tmux warning come from multiplexers.list.
            listed = {row['name']: row for row in await session.request('multiplexers.list')}
            print('multiplexers.list (versions):', json.dumps(listed), flush=True)
            self.assertIs(listed['tmux']['installed'], True)
            self.assertEqual(listed['tmux']['version'], version)
            self.assertEqual(listed['tmux']['paste_state'], numbers >= (3, 7))
            self.assertIs(listed['herdr']['installed'], True)
            self.assertRegex(listed['herdr']['version'], r'^\d+\.\d+')
            self.assertIs(listed['tmux']['running'], True)
            self.assertIsNone(listed['native']['installed'])
            if numbers < (3, 7):
                self.assertEqual(flag, '', 'older tmux has no bracketed-paste state')
            else:
                self.assertIn(flag, ('0', '1'))
            await session.request('terminals.resize', {'mux': TMUX, 'terminal': terminal,
                                                       'size': dict(GRID, rows=30, columns=100)})
            await session.until(lambda: '100x30' in fixture.tmux('list-windows', '-a', '-F', '#{window_width}x#{window_height}').stdout,
                                what='tmux resize')
            with self.assertRaises(HelperError) as scrolled:
                await session.request('terminals.scroll', {'mux': TMUX, 'terminal': terminal, 'lines': 5, 'page': False,
                                                           'modifiers': 0})
            self.assertEqual(scrolled.exception.code, 'scrollback_app_owned')
            tab = self.node(session, backend, terminal)['parent']
            for node, name in ((terminal, 'terminal'), (tab, 'tab')):
                closed = await session.request('close.request', {'mux': TMUX, 'node': node, 'policy': 'prompt', 'check': True})
                print('tmux idle check', name, closed, flush=True)
                self.assertFalse(closed['confirmation'], 'an idle shell needs no confirmation')
                self.assertFalse(closed['closed'], 'check never closes')
            closed = await session.request('close.request', {'mux': TMUX, 'node': tab, 'policy': 'prompt'})
            self.assertEqual(closed, {'closed': True, 'confirmation': False})
            await session.until(lambda: self.node(session, backend, terminal) is None, what='closed window')
            await session.close()
            self.assertTrue(fixture.host.exists(fixture.tmux_socket), 'tmux survives the helper')
            self.assertIn(pane.split()[0], fixture.tmux('list-panes', '-a', '-F', '#{pane_id}').stdout,
                          'the first window stays')
        run(self.closing(case()))

    # -- 3. herdr ---------------------------------------------------------------------------------
    def test_3_herdr_from_a_plain_exec_channel(self):
        async def case():
            fixture = self.fixture
            session = await fixture.connect('ssh', 'herdr')
            await self.hello(session)
            started = time.monotonic()
            backend, _ = await self.opened(session, HERDR, 'herdr', create=True)
            metric('herdr.create_and_open', (time.monotonic() - started) * 1000, 'ms')
            self.assertTrue(fixture.host.exists(fixture.herdr_socket))
            listed = {row['name']: row for row in await session.request('multiplexers.list')}
            self.assertIs(listed['herdr']['running'], True)
            work = fixture.root / 'work'
            fixture.host.mkdir(work)
            terminal, attach = await self.window(session, HERDR, backend, work)
            await self.typed(session, HERDR, terminal, "printf 'HS_%s_OK\\n' herdr\r")
            await session.until(lambda: b'HS_herdr_OK' in session.output.get(terminal, b''), what='printf output')
            await session.request('terminals.resize', {'mux': HERDR, 'terminal': terminal,
                                                       'size': dict(GRID, rows=30, columns=100)})
            await self.typed(session, HERDR, terminal, "seq 1 200\r")
            await session.until(lambda: b'200' in session.output.get(terminal, b''), what='seq output')
            await session.request('terminals.scroll', {'mux': HERDR, 'terminal': terminal, 'lines': 10, 'page': False,
                                                       'modifiers': 0})
            _, scroll = await session.notification(attach, lambda m, p: m == 'terminal.scroll' and p['offset'] > 0)
            print('herdr scroll', scroll, flush=True)
            tab = self.node(session, backend, terminal)['parent']
            for node, name in ((terminal, 'terminal'), (tab, 'tab')):
                closed = await session.request('close.request', {'mux': HERDR, 'node': node, 'policy': 'prompt', 'check': True})
                print('herdr idle check', name, closed, flush=True)
                self.assertFalse(closed['confirmation'], 'an idle shell needs no confirmation')
                self.assertFalse(closed['closed'])
            closed = await session.request('close.request', {'mux': HERDR, 'node': tab, 'policy': 'prompt'})
            self.assertEqual(closed, {'closed': True, 'confirmation': False})
            await session.until(lambda: self.node(session, backend, terminal) is None, what='closed tab')
            await session.close()
            self.assertIn('result', fixture.herdr('workspace.list'), 'herdr survives the helper')
        run(self.closing(case()))

    # -- 4. observe throughput ------------------------------------------------------------------
    def test_4_observe_throughput(self):
        """`yes | head -c 50M` in a window; bytes reach the client through the attach stream."""
        async def case():
            fixture = self.fixture
            size = 50 * 1024 * 1024
            for transport, mux, key, coalesce in (('ssh', TMUX, 'tmux', False), ('ssh', TMUX, 'tmux', True),
                                                  ('ssh', HERDR, 'herdr', True)):
                session = await fixture.connect(transport, f'throughput-{key}')
                await self.hello(session, FEATURES if coalesce else [f for f in FEATURES if f != 'terminals.coalesce'])
                transport = transport + ('.coalesced' if coalesce else '')
                backend, _ = await self.opened(session, mux, key, create=True)
                terminal, _ = await self.window(session, mux, backend, fixture.root)
                await self.typed(session, mux, terminal, 'stty -echo; clear\r')
                await asyncio.sleep(1)
                before, frames, count = session.output_bytes, session.bytes_in, session.output_frames
                started = time.monotonic()
                await self.typed(session, mux, terminal, f"yes | head -c {size}; printf 'HS_%s\\n' DONE\r")
                await session.until(lambda: b'HS_DONE' in session.output.get(terminal, b'')[-8192:], timeout=600,
                                    what='end of output')
                elapsed = time.monotonic() - started
                received = session.output_bytes - before
                wire = session.bytes_in - frames
                metric(f'{key}.{transport}.observe_seconds', elapsed, 's')
                metric(f'{key}.{transport}.observe_MBps', size / elapsed / 1e6, 'MB/s')
                metric(f'{key}.{transport}.observe_terminal_bytes', received, 'bytes')
                metric(f'{key}.{transport}.observe_wire_bytes', wire, 'bytes')
                metric(f'{key}.{transport}.observe_output_frames', session.output_frames - count, 'frames')
                session.output[terminal] = bytearray()
                await session.close()
        run(self.closing(case()), timeout=1300)

    # -- 5, 6. a scripted Claude in a tmux window and a herdr tab ---------------------------------
    def claude_fixture(self, name):
        """scripts/claude_fixture.py serving a private state on the host; the agent's launch environment."""
        fixture, host = self.fixture, self.fixture.host
        state = fixture.root / name
        fixture.spawn(['python3', host.scripts / 'claude_fixture.py', 'serve', '--state', state, '--delay', '0'],
                      'claude_fixture.py serve', fixture.root / f'{name}.log')
        deadline = time.monotonic() + 15
        while not host.exists(state / 'endpoint.json'):
            if time.monotonic() > deadline:
                raise RuntimeError('fixture did not start')
            time.sleep(0.1)
        port = json.loads(host.read(state / 'endpoint.json'))['port']
        config = state / 'claude-home'
        # Manual permission prompts (the fixture's CLI tests pass --permission-mode default; a
        # launch has no arguments) and no auto-mode opt-in dialog.
        environment = host.python(f"""
import claude_fixture
from pathlib import Path
state, config = Path({str(state)!r}), Path({str(config)!r})
claude_fixture.prepare_integration(state, config)
settings = json.loads((config / 'settings.json').read_text())
settings['permissions'] = {{'defaultMode': 'default', 'disableAutoMode': 'disable'}}
(config / 'settings.json').write_text(json.dumps(settings))
print(json.dumps(claude_fixture.environment(state, {port}, config)))
""")
        environment = {k: v for k, v in environment.items()
                       if k.startswith(('ANTHROPIC_', 'CLAUDE_', 'DISABLE_', 'GIT_SSH')) or k.lower().endswith('_proxy')}
        # offline-bin first keeps Claude's startup ssh probe off the network.
        environment['PATH'] = fixture.path(state / 'offline-bin')
        return state, config, [f'{k}={v}' for k, v in environment.items()]

    async def records(self, session, chat, text, timeout=40):
        """The first record on the chat observer whose text contains `text`."""
        _, params = await session.notification(chat, lambda m, p: m == 'chat.records' and any(
            text in record.get('text', '') for record in p['records']), timeout=timeout)
        return next(record for record in params['records'] if text in record.get('text', ''))

    async def paged(self, session, route, text, timeout=30):
        """chat.page until a record contains `text` (history loads after the binding moves)."""
        deadline = time.monotonic() + timeout
        while True:
            page = await session.request('chat.page', route)
            if any(text in record.get('text', '') for record in page['records']):
                return page
            if time.monotonic() > deadline:
                raise AssertionError(f'{text!r} not in {len(page["records"])} paged records')
            await asyncio.sleep(0.5)

    async def send(self, session, route, text):
        """chat.send; a prompt that is still starting refuses input (`input`), as the Mac's Chat
        shows it, and the user sends again: retried a few times here."""
        for attempt in range(6):
            try:
                return await session.request('chat.send', dict(route, text=text, mode='prompt', command=False), timeout=30)
            except HelperError as error:
                if error.code != 'input' or attempt == 5:
                    print('screen at send:', self.screens.get(route['terminal'], ''), flush=True)
                    raise
                print('chat.send refused while the prompt starts; again', flush=True)
                await asyncio.sleep(0.5)

    async def prompt(self, terminal, timeout=40):
        await asyncio.wait_for(self._until(lambda: 'for shortcuts' in self.screens.get(terminal, '')), timeout)

    async def _until(self, predicate):
        while not predicate():
            await asyncio.sleep(0.05)

    async def claude(self, mux, key):
        fixture = self.fixture
        state, config, environment = self.claude_fixture('c-' + key)
        session = await fixture.connect('ssh', 'claude-' + key)
        await self.hello(session)
        launches = {launch['key']: launch['launch'] for launch in await session.request('launches.list')}
        backend, _ = await self.opened(session, mux, key, create=True)
        stop = asyncio.Event()
        terminal, _ = await self.window(session, mux, backend, state / 'work', launch=launches['claude'],
                                        environment=environment)
        publisher = asyncio.ensure_future(self.publish(session, mux, backend, terminal, stop))
        started = time.monotonic()
        binding = await session.until(lambda: (self.node(session, backend, terminal) or {}).get('agent'), timeout=40,
                                      what='agent binding')
        metric(f'claude.{key}.launch_to_binding', (time.monotonic() - started) * 1000, 'ms')
        # launch.names: the window or tab is named after the agent, not "dispatch-helper", and
        # stays so while the agent runs (tmux automatic-rename is off for it).
        def tab_name():
            node = self.node(session, backend, terminal)
            parent = node and self.node(session, backend, node['parent'])
            return parent and parent['name']
        await session.until(lambda: tab_name() == 'claude', timeout=10, what='launched tab name')
        await asyncio.sleep(2)
        self.assertEqual(tab_name(), 'claude')
        if mux == TMUX:
            pane = self.node(session, backend, terminal)['key'].rsplit(':', 1)[1]
            self.assertEqual(fixture.tmux('display', '-p', '-t', pane, '#{window_name}').stdout.strip(), 'claude')
        hooks = json.loads(fixture.host.read(config / 'settings.json')).get('hooks', {})
        self.assertIn('PermissionRequest', hooks, "launch setup installed hooks into the agent's config")
        self.assertFalse(fixture.host.exists(fixture.home / '.claude/settings.json'), 'not into the account default')
        chat, _ = await session.observe('chat.open', {'terminal': terminal}, wait=False)
        _, opened = await session.notification(chat, lambda m, p: m == 'chat.history', timeout=30)
        self.assertEqual(opened['session'], binding['session'])
        conversation = opened['session']
        route = {'terminal': terminal, 'session': conversation}
        await self.prompt(terminal)
        # Approvals through the hook socket of a helper started on a plain exec channel.
        marker = state / 'work/dispatch-approval-marker'
        session_scope = False
        for choice, expected in (('Deny', 'denied or failed.'), ('This session', 'completed.')):
            await self.send(session, route, f'permission tool {choice}')
            started = time.monotonic()
            _, opened = await session.notification(chat, lambda m, p: m == 'interaction.opened', timeout=40)
            metric(f'claude.{key}.send_to_approval', (time.monotonic() - started) * 1000, 'ms')
            interaction = opened['interaction']
            self.assertTrue(interaction['approval'])
            self.assertIn('dispatch-approval-marker', interaction['questions'][0]['text'])
            self.assertFalse(fixture.host.exists(marker))
            labels = [option['label'] for option in interaction['questions'][0]['options']]
            print(f'claude {key} approval choices (interaction.options):', labels, flush=True)
            self.assertEqual(labels[:3], ['Allow', 'Deny', 'Terminal'])
            if choice == 'This session' and choice not in labels:
                choice = 'Allow'  # Claude suggested no rule for this command
            session_scope |= choice == 'This session'
            await session.request('interactions.answer', dict(route, interaction=interaction['id'],
                                                              answers={interaction['questions'][0]['id']: [labels.index(choice)]}))
            await self.records(session, chat, 'Tool result received: ' + expected)
            self.assertEqual(fixture.host.exists(marker), expected == 'completed.')
            await self.prompt(terminal)
        if session_scope:
            # The session rule answers the same command without asking again.
            fixture.host.sh('rm -f "$1"', marker)
            await self.send(session, route, 'permission tool again')
            while True:
                method, params = await session.notification(chat, lambda m, p: m in ('chat.records', 'interaction.opened'))
                if method == 'interaction.opened':
                    self.assertFalse(params['interaction']['questions'], 'asked again despite the session rule')
                    continue
                reply = next((r for r in params['records'] if 'fixture reply: permission tool again' in r.get('text', '')), None)
                if reply and 'Tool result received' in reply['text']:
                    break
            self.assertIn('completed.', reply['text'])
            self.assertTrue(fixture.host.exists(marker))
            print(f'claude {key}: "This session" allowed the repeat without asking', flush=True)
            await self.prompt(terminal)
        fixture.host.sh('rm -f "$1"', marker)
        # The helper-held queue (Claude has no native queue).
        await session.request('queue.hold', dict(route, held=True))
        items = [await session.request('queue.add', dict(route, text=f'queued {name}', mode='prompt', command=False))
                 for name in ('one', 'two', 'three')]
        listed = await session.request('queue.list', route)
        self.assertEqual([item['id'] for item in listed], [item['id'] for item in items])
        first = items[0]
        await session.request('queue.update', dict(route, item=first['id'], revision=first['revision'],
                                                   text='queued one edited', command=False))
        listed = {item['id']: item for item in await session.request('queue.list', route)}
        self.assertEqual(listed[first['id']]['preview'][0]['text'], 'queued one edited')
        order = [items[2]['id'], items[0]['id'], items[1]['id']]
        await session.request('queue.reorder', dict(route, items=order))
        self.assertEqual([item['id'] for item in await session.request('queue.list', route)], order)
        await session.request('queue.remove', dict(route, item=items[1]['id'], revision=listed[items[1]['id']]['revision']))
        third = next(item for item in await session.request('queue.list', route) if item['id'] == items[2]['id'])
        await session.request('queue.start', dict(route, item=third['id'], revision=third['revision'], mode='prompt'),
                              timeout=30)
        await self.records(session, chat, 'Local Claude fixture reply: queued three')
        await self.prompt(terminal)
        await session.request('queue.hold', dict(route, held=False))
        await self.records(session, chat, 'Local Claude fixture reply: queued one edited')
        await session.until(lambda: True)
        self.assertEqual(await session.request('queue.list', route), [])
        page = await session.request('chat.page', route)
        print(f'claude {key} page records', len(page['records']), flush=True)
        Live.state['claude-' + key] = {'backend_key': key, 'mux': mux, 'terminal_key': self.node(session, backend, terminal)['key'],
                                       'session': conversation, 'pid': binding['pid'], 'state': state,
                                       'records': len(page['records'])}
        stop.set()
        await publisher
        await session.close()

    def test_5_claude_in_tmux_hooks_answers_and_queue(self):
        run(self.closing(self.claude(TMUX, 'tmux')))

    def test_6_claude_in_herdr_hooks_answers_and_queue(self):
        run(self.closing(self.claude(HERDR, 'herdr')))

    # -- 7. the connection dies; a new helper reattaches ------------------------------------------
    def test_7_survival_and_reattach(self):
        for name, mux, key in (('claude-tmux', TMUX, 'tmux'), ('claude-herdr', HERDR, 'herdr')):
            if name not in Live.state:
                run(self.closing(self.claude(mux, key)))

        async def attach(session):
            """Open both backends and Chat on both agents, as the phone does after connecting."""
            chats = {}
            for name in ('claude-tmux', 'claude-herdr'):
                agent = Live.state[name]
                backend, _ = await self.opened(session, agent['mux'], agent['backend_key'])
                node = await session.until(lambda: next((n for n in session.nodes(backend)
                                                         if n['key'] == agent['terminal_key'] and n.get('agent')), None),
                                           timeout=30, what='bound agent terminal')
                chat, _ = await session.observe('chat.open', {'terminal': node['id']}, wait=False)
                _, opened = await session.notification(chat, lambda m, p: m == 'chat.history', timeout=30)
                chats[name] = (agent, backend, node, chat, opened)
            return chats

        async def case():
            fixture = self.fixture
            session = await fixture.connect('ssh', 'survival-0')
            await self.hello(session)
            chats = await attach(session)
            for name, (agent, backend, node, chat, opened) in chats.items():
                route = {'terminal': node['id'], 'session': agent['session']}
                await session.request('queue.hold', dict(route, held=True))
                await session.request('queue.add', dict(route, text='queued before the drop', mode='prompt', command=False))
            for mode in ('ssh-client', 'helper'):
                helpers = fixture.helpers()
                self.assertEqual(len(helpers), 1, helpers)
                started = time.monotonic()
                if mode == 'ssh-client':
                    session.process.kill()  # the phone's connection vanishes (no FIN from the app)
                else:
                    fixture.host.kill(helpers[0], 'KILL')
                await session.closed
                while fixture.helpers():
                    self.assertLess(time.monotonic() - started, 15, 'the helper outlived its connection')
                    await asyncio.sleep(0.02)
                metric(f'survival.{mode}.helper_gone', (time.monotonic() - started) * 1000, 'ms')
                for agent in (Live.state['claude-tmux'], Live.state['claude-herdr']):
                    self.assertTrue(fixture.host.alive(agent['pid']), 'still running in its tmux window / herdr tab')
                await session.close()
                started = time.monotonic()
                session = await fixture.connect('ssh', f'survival-{mode}')
                await self.hello(session)
                hello = time.monotonic()
                chats = await attach(session)
                pages = {}
                for name, (agent, backend, node, chat, opened) in chats.items():
                    route = {'terminal': node['id'], 'session': agent['session']}
                    pages[name] = await session.request('chat.page', route)
                elapsed = time.monotonic() - started
                metric(f'survival.{mode}.reconnect_to_hello', (hello - started) * 1000, 'ms')
                # The Agents list in one call (feature chat.list).
                listed = time.monotonic()
                rows = await session.request('chat.list', {})
                metric(f'survival.{mode}.chat_list', (time.monotonic() - listed) * 1000, 'ms')
                by_session = {row['session']: row for row in rows}
                for agent in (Live.state['claude-tmux'], Live.state['claude-herdr']):
                    row = by_session[agent['session']]
                    self.assertEqual(row['key'], 'claude')
                    self.assertEqual(row['binding']['pid'], agent['pid'])
                    self.assertIs(row['busy'], False)
                    self.assertTrue(row['preview'].startswith('Local Claude fixture reply'), row['preview'])
                    self.assertIsInstance(row['time_ms'], int)
                    self.assertIs(row['waiting'], False, 'no approval or question is open')
                print('chat.list row:', json.dumps({k: v for k, v in rows[0].items() if k != 'binding'})[:300], flush=True)
                metric(f'survival.{mode}.reconnect_to_both_chats_paged', elapsed * 1000, 'ms')
                for name, (agent, backend, node, chat, opened) in chats.items():
                    self.assertEqual(node['agent']['pid'], agent['pid'], 'the same agent process')
                    self.assertEqual(opened['session'], agent['session'], 'the same conversation')
                    self.assertGreaterEqual(len(pages[name]['records']), agent['records'])
                    self.assertTrue(any('queued one edited' in r.get('text', '') for r in pages[name]['records']))
                    route = {'terminal': node['id'], 'session': agent['session']}
                    # The helper-held queue lived in the dead helper.
                    queue = await session.request('queue.list', route)
                    print(f'{name} queue after {mode} drop:', queue, flush=True)
                    self.assertEqual(queue, [])
            # Input and approvals route to the new helper.
            # Chat input needs the client's screen: the phone attaches the agent's terminal and
            # publishes what its Term surface shows.
            stop = asyncio.Event()
            for agent, backend, node, _, _ in chats.values():
                stream, _ = await session.observe('terminals.attach', {'mux': agent['mux'], 'terminal': node['id'],
                                                                       'size': GRID, 'takeover': False}, wait=False)
                await session.notification(stream, lambda m, p: m == 'terminal.attached', timeout=20)
            publishers = [asyncio.ensure_future(self.publish(session, agent['mux'], backend, node['id'], stop))
                          for agent, backend, node, _, _ in chats.values()]
            for name, (agent, backend, node, chat, opened) in chats.items():
                route = {'terminal': node['id'], 'session': agent['session']}
                await self.prompt(node['id'])
                await self.send(session, route, 'permission tool after reattach')
                # Asked through the new helper's hook route, or allowed by the session rule a
                # "This session" answer gave the same Claude process before the drop.
                while True:
                    method, params = await session.notification(
                        chat, lambda m, p: m == 'interaction.opened' and p['interaction']['questions'] or m == 'chat.records',
                        timeout=40)
                    if method == 'interaction.opened':
                        interaction = params['interaction']
                        # An open approval is a list row's "needs you" (chat.list `waiting`).
                        listed = {row['terminal']: row for row in await session.request('chat.list', {})}
                        self.assertIs(listed[node['id']]['waiting'], True, 'the open approval makes the row wait')
                        await session.request('interactions.answer', dict(route, interaction=interaction['id'],
                                                                          answers={interaction['questions'][0]['id']: [0]}))
                        continue
                    if any('permission tool after reattach' in r.get('text', '') and 'Tool result received: completed.' in r.get('text', '')
                           for r in params['records']):
                        break
            stop.set()
            await asyncio.gather(*publishers)
            await session.close()
            # Small hosts (the 1 GB test VM) run the later agents only once these have ended.
            for agent in (Live.state['claude-tmux'], Live.state['claude-herdr']):
                fixture.host.kill(agent['pid'])
        run(self.closing(case()))

    # -- 8. Codex and Pi through the same launch path ---------------------------------------------
    def test_typed_agents_install_hooks_across_updates_and_config_homes(self):
        """Legacy migration and immutable updates, custom homes, concurrent launches, repeat installs."""
        async def case():
            import hashlib
            fixture, host = self.fixture, self.fixture.host
            session = await fixture.connect('ssh', 'typed-agent-updates')
            await self.hello(session)
            backend, _ = await self.opened(session, TMUX, 'tmux', create=True)
            stable = fixture.home / '.dispatch/bin/dispatch-helper'
            builds = stable.parent / 'launchers'
            for scenario, (agent, variable, filename, custom_home) in enumerate([
                ('codex', 'CODEX_HOME', 'hooks.json', False),
                ('codex', 'CODEX_HOME', 'hooks.json', True),
                ('claude', 'CLAUDE_CONFIG_DIR', 'settings.json', False),
                ('claude', 'CLAUDE_CONFIG_DIR', 'settings.json', True),
            ]):
                with self.subTest(agent=agent, custom_home=custom_home):
                    home = fixture.root / f'typed-home-{scenario}'
                    config = home / ('.' + agent) if custom_home else fixture.root / f'typed-config-{scenario}'
                    binary = fixture.root / f'typed-bin-{scenario}'
                    host.mkdir(config)
                    host.mkdir(binary)
                    before = {'fixture_setting': 'keep', 'hooks': {'SessionStart': [{'hooks': [{'type': 'command', 'command': 'printf existing-hook'}]}]}}
                    host.write(config / filename, json.dumps(before), 0o640)
                    host.write(binary / agent, f'''#!/bin/sh
if [ "$1" = --help ]; then printf '%s\\n' --no-daemon; exit; fi
cat "${{{variable}:-$HOME/.{agent}}}/{filename}" > "$DISPATCH_FIXTURE_MARKER.tmp" && mv "$DISPATCH_FIXTURE_MARKER.tmp" "$DISPATCH_FIXTURE_MARKER"
''', 0o700)
                    terminals = [(await self.window(session, TMUX, backend, fixture.root))[0] for _ in range(2)]
                    # A byte-distinct runnable build represents an older connected helper.
                    older = fixture.helper.read_bytes() + f'\nprevious-helper-build-{scenario}\n'.encode()
                    staged = fixture.root / 'previous-helper'
                    if scenario == 0:
                        host.write(staged, older, 0o700)  # migrate the old regular-file layout
                    else:
                        digest = hashlib.sha256(older).hexdigest()
                        version = builds / digest
                        host.mkdir(version)
                        host.write(version / 'dispatch-helper', older, 0o700)
                        result = host.sh('ln -s "$1" "$2"', f'launchers/{digest}/dispatch-helper', staged)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    result = host.sh('mv -f "$1" "$2"', staged, stable)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    previous = None
                    for repeat in range(2):
                        markers = [fixture.root / f'typed-started-{scenario}-{repeat}-{i}' for i in range(2)]
                        for terminal, marker in zip(terminals, markers):
                            environment = f'{variable}= HOME={shlex.quote(str(home))}' if custom_home else f'{variable}={shlex.quote(str(config))}'
                            await self.typed(session, TMUX, terminal,
                                f'{environment} DISPATCH_FIXTURE_MARKER={shlex.quote(str(marker))} PATH={shlex.quote(str(binary))}:$PATH {agent}\r')
                        deadline = time.monotonic() + 20
                        while not all(host.exists(marker) for marker in markers):
                            for terminal in terminals:
                                pane = self.node(session, backend, terminal)['key'].rsplit(':', 1)[1]
                                screen = fixture.tmux('capture-pane', '-p', '-t', pane).stdout
                                self.assertNotIn('The agent exited.', screen, screen)
                                self.assertNotIn('Agent settings changed', screen, screen)
                                self.assertLess(time.monotonic(), deadline, screen)
                            await asyncio.sleep(0.1)
                        raw = host.read(config / filename)
                        settings = json.loads(raw)
                        self.assertEqual(settings['fixture_setting'], 'keep')
                        self.assertIn('PermissionRequest', settings['hooks'])
                        self.assertEqual(settings['hooks']['SessionStart'][0], before['hooks']['SessionStart'][0])
                        for marker in markers:
                            self.assertEqual(json.loads(host.read(marker)), settings, 'hooks must be installed before the agent starts')
                        if previous is not None:
                            self.assertEqual(raw, previous, 'repeat setup must preserve hook indices and avoid duplicate hooks')
                        previous = raw
                    info = host.python(f'import os, stat; print(json.dumps([stat.S_IMODE(os.stat({str(config / filename)!r}).st_mode), os.path.islink({str(stable)!r})]))')
                    self.assertEqual(info, [0o640, True])
            digest = host.python(f'import hashlib; print(json.dumps(hashlib.sha256(open({str(stable)!r}, "rb").read()).hexdigest()))')
            self.assertEqual(digest, hashlib.sha256(fixture.helper.read_bytes()).hexdigest())
            await session.close()
        run(self.closing(case()))

    async def agent(self, name, launch, environment, cwd, mux=TMUX, key='tmux', enable=False):
        """Launch `launch` in a new window with the fixture's environment; bound, chat open, screen published.
        `enable`: turn the optional integration on first (per helper process, so per connection)."""
        session = await self.fixture.connect('ssh', name)
        await self.hello(session)
        launches = {item['key']: item['launch'] for item in await session.request('launches.list')}
        if enable:
            installed = await session.request('installation.install', {'launch': launches[launch], 'enabled': True})
            print(launch, 'enabled:', [edit['path'] for edit in installed['edits']], flush=True)
        backend, _ = await self.opened(session, mux, key, create=True)
        terminal, _ = await self.window(session, mux, backend, cwd, launch=launches[launch], environment=environment)
        stop = asyncio.Event()
        publisher = asyncio.ensure_future(self.publish(session, mux, backend, terminal, stop))
        started = time.monotonic()
        try:
            binding = await session.until(lambda: (self.node(session, backend, terminal) or {}).get('agent'), timeout=60,
                                          what=launch + ' binding')
        except TimeoutError:
            print(self.screens.get(terminal, ''), flush=True)
            raise
        metric(f'{launch}.launch_to_binding', (time.monotonic() - started) * 1000, 'ms')
        self.agents.append(binding['pid'])
        node = self.node(session, backend, terminal)
        await session.until(lambda: (self.node(session, backend, node['parent']) or {}).get('name') == launch,
                            timeout=10, what=f'{launch} tab name')
        chat, _ = await session.observe('chat.open', {'terminal': terminal}, wait=False)
        _, opened = await session.notification(chat, lambda m, p: m == 'chat.history', timeout=30)
        return session, backend, terminal, chat, opened, (stop, publisher)

    def test_8_codex_launch_chat_approval_and_native_queue(self):
        async def case():
            fixture = self.fixture
            host = fixture.host
            state = fixture.root / 'cx'
            fixture.spawn(['python3', host.scripts / 'codex_fixture.py', 'serve', '--state', state, '--delay', '0',
                           '--no-hooks'], 'codex_fixture.py serve', fixture.root / 'cx.log')
            deadline = time.monotonic() + 15
            while not host.exists(state / 'endpoint.json'):
                self.assertLess(time.monotonic(), deadline)
                await asyncio.sleep(0.1)
            metadata = json.loads(host.read(state / 'endpoint.json'))
            env = host.python(f"import codex_fixture; print(json.dumps(codex_fixture.environment({metadata['home']!r})))")
            environment = [f'{k}={env[k]}' for k in env if k.startswith('CODEX_') or k.lower().endswith('_proxy')
                           or k == 'NO_PROXY'] + [f'PATH={fixture.path()}']
            session, backend, terminal, chat, opened, (stop, publisher) = await self.agent(
                'codex', 'codex', environment, metadata['work'])
            print('codex chat', json.dumps({k: opened.get(k) for k in ('label', 'native_queue', 'capabilities')}), flush=True)
            route = {'terminal': terminal, 'session': opened['session']}
            # Codex asks the user to review hooks it has not seen (the helper's, from launch setup):
            # a native trust step the phone must surface in the terminal (`t` trusts all).
            screen = lambda: self.screens.get(terminal, '')
            await asyncio.wait_for(self._until(lambda: 'need review' in screen() or 'for shortcuts' in screen()
                                               or '? for' in screen()), 40)
            try:  # the review list opens just after the composer appears
                await asyncio.wait_for(self._until(lambda: 'need review' in screen()), 4)
            except asyncio.TimeoutError:
                pass
            if 'need review' in screen():
                print('codex: hooks need review on first launch; trusting them in the terminal', flush=True)
                deadline = time.monotonic() + 20
                while 'need review' in screen() or 'Trust all' in screen():
                    self.assertLess(time.monotonic(), deadline, screen())
                    if 'Trust all and continue' in screen():
                        await self.typed(session, TMUX, terminal, '2')
                        await asyncio.sleep(0.5)
                        if 'Trust all and continue' in screen():
                            await self.typed(session, TMUX, terminal, '\r')
                    elif 't trust all' in screen():
                        await self.typed(session, TMUX, terminal, 't')
                    await asyncio.sleep(1)
                print('codex after trust:', screen().strip()[-300:], flush=True)
            await asyncio.sleep(1)
            await self.send(session, route, 'hello codex')
            await asyncio.wait_for(self._until(lambda: 'Local fixture reply: hello codex' in screen()), 60)
            # Codex starts its thread with the first prompt: the binding moves to the new session,
            # and the client reopens Chat on it (topology / agent.changed carry the new binding).
            binding = await session.until(lambda: ((self.node(session, backend, terminal) or {}).get('agent') or {})
                                          if ((self.node(session, backend, terminal) or {}).get('agent') or {}).get('session')
                                          != opened['session'] else None, timeout=20, what='codex thread binding')
            print('codex session moved', opened['session'], '->', binding['session'], flush=True)
            session.cancel(chat)
            chat, _ = await session.observe('chat.open', {'terminal': terminal}, wait=False)
            _, opened = await session.notification(chat, lambda m, p: m == 'chat.history', timeout=30)
            route = {'terminal': terminal, 'session': opened['session']}
            await self.paged(session, route, 'Local fixture reply: hello codex')
            await self.send(session, route, 'approval tool please')
            _, opened_interaction = await session.notification(chat, lambda m, p: m == 'interaction.opened', timeout=60)
            interaction = opened_interaction['interaction']
            print('codex interaction', json.dumps(interaction)[:400], flush=True)
            await session.request('interactions.answer', dict(route, interaction=interaction['id'],
                                                              answers={interaction['questions'][0]['id']: [0]}))
            await self.paged(session, route, 'Tool result received.', timeout=60)
            # Codex's own queue (native_queue through its app-server).
            result = {}
            for op, params in (('queue.hold', dict(held=True)),
                               ('queue.add', dict(text='queued for codex', mode='prompt', command=False)),
                               ('queue.list', {})):
                try:
                    result[op] = await session.request(op, dict(route, **params), timeout=30)
                except HelperError as error:
                    result[op] = error.error
            print('codex queue', json.dumps(result, default=repr)[:600], flush=True)
            Live.state['codex-queue'] = result
            stop.set()
            await publisher
            await session.close()
            while self.agents:
                fixture.host.kill(self.agents.pop())
        run(self.closing(case()))

    def test_9_pi_launch_extension_chat_and_queue(self):
        async def case():
            fixture = self.fixture
            host = fixture.host
            state, _, _ = self.claude_fixture('pi')
            port = json.loads(host.read(state / 'endpoint.json'))['port']
            home = state / 'pi-home'
            # A launch has no arguments: the fixture's provider and model become Pi's defaults.
            env = host.python(f"""
import pi_fixture
from pathlib import Path
state, home = Path({str(state)!r}), Path({str(home)!r})
pi_fixture.configure(state, {port}, home)
(home / 'settings.json').write_text(json.dumps({{'defaultProvider': pi_fixture.PROVIDER, 'defaultModel': pi_fixture.MODEL}}))
print(json.dumps(pi_fixture.environment(state, {port}, home)))
""")
            environment = [f'{k}={v}' for k, v in env.items() if k.startswith('PI_') or k.lower().endswith('_proxy')
                           or k in ('NO_PROXY', 'GIT_SSH_COMMAND')]
            environment.append(f'PATH={fixture.path(state / "offline-bin")}')
            session, backend, terminal, chat, opened, (stop, publisher) = await self.agent(
                'pi', 'pi', environment, state / 'work', enable=True)
            print('pi chat', json.dumps({k: opened.get(k) for k in ('label', 'native_queue', 'capabilities', 'session')}),
                  flush=True)
            print('pi extension', host.listdir(home / 'extensions') or 'none', flush=True)
            route = {'terminal': terminal, 'session': opened['session']}
            await asyncio.sleep(2)
            await self.send(session, route, 'hello pi')
            await self.paged(session, route, 'Local Claude fixture reply: hello pi', timeout=60)
            result = {}
            for op, params in (('queue.hold', dict(held=True)),
                               ('queue.add', dict(text='queued for pi', mode='follow_up', command=False)),
                               ('queue.list', {})):
                try:
                    result[op] = await session.request(op, dict(route, **params), timeout=30)
                except HelperError as error:
                    result[op] = error.error
            print('pi queue', json.dumps(result, default=repr)[:600], flush=True)
            stop.set()
            await publisher
            await session.close()
        run(self.closing(case()))

    # -- 10. projects.recent from the agents' own session stores --------------------------------
    def test_10_projects_recent(self):
        async def case():
            fixture, host = self.fixture, self.fixture.host
            alpha, beta = fixture.root / 'work-alpha', fixture.root / 'work-beta'
            host.mkdir(alpha)
            host.mkdir(beta)
            # Where the agents keep sessions by default under this HOME.
            host.mkdir(fixture.home / '.claude/projects/-alpha')
            host.write(fixture.home / '.claude/projects/-alpha/1.jsonl',
                       json.dumps({'type': 'user', 'cwd': str(alpha)}) + '\n')
            host.mkdir(fixture.home / '.codex/sessions/2026/10/18')
            host.write(fixture.home / '.codex/sessions/2026/10/18/rollout-1.jsonl',
                       json.dumps({'type': 'session_meta', 'payload': {'cwd': str(beta)}}) + '\n')
            host.sh('touch -t 202601010000 "$1"', fixture.home / '.claude/projects/-alpha/1.jsonl')
            session = await fixture.connect('ssh', 'projects')
            await self.hello(session)
            started = time.monotonic()
            rows = await session.request('projects.recent', {'limit': 10})
            metric('projects.recent', (time.monotonic() - started) * 1000, 'ms')
            print('projects.recent', json.dumps(rows)[:300], flush=True)
            self.assertEqual([row['path'] for row in rows], [str(beta), str(alpha)])
            self.assertEqual(rows[0]['agents'], ['codex'])
            self.assertTrue(all(row['exists'] for row in rows))
            with self.assertRaises(HelperError):
                await session.request('projects.recent', {'limit': 0})
            await session.close()
            # A client that did not name the feature has no such operation.
            plain = await fixture.connect('ssh', 'projects-plain')
            await self.hello(plain, features=False)
            with self.assertRaises(HelperError) as refused:
                await plain.request('projects.recent', {})
            self.assertEqual(refused.exception.code, 'unsupported')
            await plain.close()
        run(self.closing(case()))

    # -- 11. a connection whose close never arrives ---------------------------------------------
    def test_11_stdio_liveness(self):
        async def case():
            fixture = self.fixture
            extra = {'DISPATCH_STDIO_LIVENESS_SECONDS': '3'}
            for transport in fixture.transports:
                # Pinging keeps it alive past the limit.
                session = await fixture.connect(transport, 'liveness-' + transport, extra)
                hello, _ = await self.hello(session, ['stdio.liveness'])
                self.assertEqual(hello['features'], ['stdio.liveness'])
                session.pinger.cancel()
                session.pinger = asyncio.ensure_future(session.ping(1))
                await asyncio.sleep(5)
                self.assertFalse(session.closed.done(), 'a pinging client keeps its helper')
                # Silence: the stream stays open (a dead NAT entry), the helper ends by itself.
                session.pinger.cancel()
                silent = time.monotonic()
                await asyncio.wait_for(asyncio.shield(session.closed), 15)
                metric(f'liveness.{transport}.silence_to_exit', time.monotonic() - silent, 's')
                deadline = time.monotonic() + 10
                while fixture.helpers() and time.monotonic() < deadline:
                    await asyncio.sleep(0.1)
                self.assertEqual(fixture.helpers(), [], 'the helper process ended')
                await session.close()
                # Without the feature (the Mac) silence ends nothing.
                quiet = await fixture.connect(transport, 'quiet-' + transport, extra)
                await self.hello(quiet, [f for f in FEATURES if f != 'stdio.liveness'])
                await asyncio.sleep(5)
                self.assertFalse(quiet.closed.done())
                await quiet.close()
        run(self.closing(case()))

    # -- 12. terminals.activity: tmux's own window activity times --------------------------------
    def test_12_terminals_activity(self):
        async def case():
            fixture = self.fixture
            session = await fixture.connect('ssh', 'activity')
            hello, _ = await self.hello(session)
            self.assertIn('terminals.activity', hello['features'])
            self.assertIn('terminals.activity', hello['ops'])
            # Cases run by name: test_2 (after this one) expects no tmux server, so one started here is stopped.
            started_server = not fixture.host.exists(fixture.tmux_socket)
            backend, _ = await self.opened(session, TMUX, 'tmux', create=True)
            work = fixture.root / 'work-activity'
            fixture.host.mkdir(work)
            terminal, _ = await self.window(session, TMUX, backend, work)
            await self.typed(session, TMUX, terminal, "printf 'HS_%s_ONE\\n' act\r")
            await session.until(lambda: b'HS_act_ONE' in session.output.get(terminal, b''), what='first output')
            tab = self.node(session, backend, terminal)['parent']
            tab_key = next(n['key'] for n in session.nodes(backend) if n['id'] == tab)
            window = tab_key.rsplit(':', 1)[1]

            async def times():
                started = time.monotonic()
                rows = await session.request('terminals.activity', {})
                metric('terminals.activity', (time.monotonic() - started) * 1000, 'ms')
                return rows

            def native():
                return int(fixture.tmux('display', '-p', '-t', window, '#{window_activity}').stdout.strip()) * 1000

            # Between tmux's own value before and after the request (a late prompt redraw may move it).
            before = native()
            rows = await times()
            print('terminals.activity', json.dumps(rows)[:400], flush=True)
            self.assertTrue(all(row['key'].startswith('tmux:') for row in rows), 'herdr and native report no times')
            row = next(row for row in rows if row['node'] == tab)
            self.assertEqual((row['key'], row['kind']), (tab_key, 'tab'))
            self.assertTrue(before <= row['time_ms'] <= native(), (before, row['time_ms']))
            self.assertFalse(any(r['node'] == terminal for r in rows), 'tmux has no per-pane time')
            # tmux counts whole seconds: the next output lands in a later one.
            first = row['time_ms']
            await asyncio.sleep(2.2)
            await self.typed(session, TMUX, terminal, "printf 'HS_%s_TWO\\n' act\r")
            await session.until(lambda: b'HS_act_TWO' in session.output.get(terminal, b''), what='second output')
            before = native()
            later = next(row for row in await times() if row['node'] == tab)['time_ms']
            self.assertGreaterEqual(later - first, 2000, 'typing moved the window activity')
            self.assertTrue(before <= later <= native(), (before, later))
            with self.assertRaises(HelperError):
                await session.request('terminals.activity', {'node': tab})
            await session.request('close.request', {'mux': TMUX, 'node': tab, 'policy': 'prompt'})
            await session.close()
            # A client that did not name the feature (the Mac) has no such operation.
            plain = await fixture.connect('ssh', 'activity-plain')
            plain_hello, _ = await self.hello(plain, features=False)
            self.assertNotIn('terminals.activity', plain_hello['ops'])
            with self.assertRaises(HelperError) as refused:
                await plain.request('terminals.activity', {})
            self.assertEqual(refused.exception.code, 'unsupported')
            await plain.close()
            if started_server:
                pid = int(fixture.tmux('display', '-p', '#{pid}').stdout.strip())
                fixture.host.kill(pid)
                deadline = time.monotonic() + 10
                while fixture.host.alive(pid) and time.monotonic() < deadline:
                    await asyncio.sleep(0.1)
                self.assertFalse(fixture.host.alive(pid), 'the tmux server this case started ended')
                fixture.host.sh('rm -f "$1"', fixture.tmux_socket)
        run(self.closing(case()))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--live', action='store_true', default=os.environ.get('DISPATCH_HELPER_STDIO_LIVE') == '1',
                        help='Run the live cases (sshd, tmux, herdr, agent fixtures)')
    parser.add_argument('--helper', type=Path, help='dispatch-helper for this Mac (default: the newest local build)')
    parser.add_argument('--keep', action='store_true', help='Keep the fixture root for inspection')
    parser.add_argument('--remote', metavar='USER@HOST[:PORT]', help='Run everything on this SSH destination '
                        '(a private root under its /tmp; the Linux helper from build/helper-rust/bin)')
    parser.add_argument('--identity', type=Path, help='SSH key for --remote')
    parser.add_argument('--lima', metavar='NAME', help='--remote and --identity of this running Lima VM')
    parser.add_argument('--prepend', metavar='DIR', help="A folder the remote login profile puts first in PATH "
                        "(e.g. a newer tmux)")
    parser.add_argument('-k', dest='patterns', action='append', default=[], help='Only cases matching (unittest -k)')
    args = parser.parse_args()
    if args.lima:
        for line in subprocess.run(['limactl', 'list', '--json'], capture_output=True, text=True, check=True).stdout.splitlines():
            vm = json.loads(line)
            if vm['name'] == args.lima:
                if vm['status'] != 'Running':
                    parser.error(f'{args.lima} is {vm["status"]}')
                args.remote = f"{vm['config']['user']['name']}@{vm.get('sshAddress', '127.0.0.1')}:{vm['sshLocalPort']}"
                args.identity = args.identity or Path.home() / '.lima/_config/user'
                arch = vm.get('arch', 'aarch64')
                break
        else:
            parser.error(f'no Lima VM {args.lima}')
    if args.live:
        if args.remote:
            machine = locals().get('arch') or subprocess.run(
                ['/usr/bin/ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', *(['-i', str(args.identity)] if args.identity else []),
                 *(['-p', args.remote.rsplit(':', 1)[1]] if args.remote.count(':') == 1 else []),
                 args.remote.rsplit(':', 1)[0] if args.remote.count(':') == 1 else args.remote, 'uname -m'],
                capture_output=True, text=True).stdout.strip()
            candidates = [args.helper] if args.helper else [
                ROOT / f'build/helper-rust/bin/linux-{"aarch64" if machine in ("aarch64", "arm64") else "x86_64"}']
            Live.remote = (args.remote, args.identity, args.prepend)
        else:
            candidates = [args.helper] if args.helper else [
                ROOT / 'build/hs-target/aarch64-apple-darwin/local/dispatch-helper',
                ROOT / 'build/helper-rust/bin/darwin-arm64']
        helper = next((path for path in candidates if path and path.is_file()), None)
        if not helper:
            parser.error('build the helper first or pass --helper')
        Live.helper, Live.keep = helper, args.keep
    loader = unittest.TestLoader()
    loader.testNamePatterns = ['*' + pattern + '*' for pattern in args.patterns] or None
    suite = unittest.TestSuite([loader.loadTestsFromTestCase(CodecTests), loader.loadTestsFromTestCase(Live)])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
