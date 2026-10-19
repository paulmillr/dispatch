#!/usr/bin/env python3
"""Expected screens for screen.test.rs from the terminal the recordings were drawn by (Ghostty's, inside herdr): every
case of cases.json is played into a herdr pane of its size (the pane runs `cat` on a pipe with its tty raw, so bytes
arrive as written; resize steps resize the attached terminal), then the pane's visible rows (pane.read) and the
cursor (the last cursor position in herdr's frames) are read back. Writes herdr.json: the cases with `screen` (rows,
trailing blanks dropped, a character the screen model keeps as `?` per cell it takes) and `cursor` ([column, row]).
Usage: python3 herdr.py HERDR   (an installed herdr executable; its socket goes in a temporary directory)"""
import base64, json, os, re, socket, subprocess, sys, tempfile, threading, time, unicodedata, uuid
from pathlib import Path

HERE, HERDR = Path(__file__).resolve().parent, str(Path(sys.argv[1]).resolve())
CUP = re.compile(rb'\x1b\[(\d+);(\d+)H')


def cells(text):
    # The screen model keeps one byte per cell: ASCII as itself, any other character as '?' per cell it covers.
    out = ''
    for char in text:
        if ord(char) < 128:
            out += char
        elif not unicodedata.combining(char) and unicodedata.category(char) not in ('Me', 'Cf'):
            out += '??' if unicodedata.east_asian_width(char) in ('W', 'F') else '?'
    return out


def wait(test, what):
    for _ in range(400):
        value = test()
        if value:
            return value
        time.sleep(0.02)
    raise RuntimeError(f'herdr did not {what}')


class Server:
    def __init__(self, directory):
        self.path = f'{directory}/herdr/herdr.sock'
        Path(self.path).parent.mkdir()
        self.env = dict(os.environ, XDG_CONFIG_HOME=directory, HERDR_SOCKET_PATH=self.path, HERDR_SESSION='default')
        self.process = subprocess.Popen([HERDR, 'server'], env=self.env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait(lambda: Path(self.path).exists(), 'open its socket')
        self.workspace = self.rpc('workspace.create', cwd=directory, focus=True)['workspace']['workspace_id']

    def rpc(self, method, **params):
        ident = uuid.uuid4().hex
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            client.connect(self.path)
            client.sendall(json.dumps({'id': ident, 'method': method, 'params': params}).encode() + b'\n')
            data = b''
            while not data.endswith(b'\n'):
                chunk = client.recv(65536)
                if not chunk:
                    raise RuntimeError('herdr closed the socket')
                data += chunk
        reply = json.loads(data)
        if reply.get('id') != ident or 'error' in reply:
            raise RuntimeError(f'{method}: {reply}')
        return reply['result']

    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)


class Terminal:
    """A pane running `cat` on a pipe and a controller attached to it at a given size."""

    def __init__(self, server, directory, size):
        self.server, self.fifo = server, f'{directory}/f'
        os.mkfifo(self.fifo)
        layout = server.rpc('layout.apply', focus=True, workspace_id=server.workspace,
                            root={'type': 'pane', 'command': ['sh', '-c', f'stty raw -echo; exec cat {self.fifo}']})
        pane = layout['layout']['root']['pane_id']
        self.pane = wait(lambda: next((p for p in server.rpc('pane.list')['panes'] if p['pane_id'] == pane), None), 'show the pane')
        self.frames, self.lock = [], threading.Lock()
        self.controller = subprocess.Popen(
            [HERDR, 'terminal', 'session', 'control', self.pane['terminal_id'], '--cols', str(size[0]), '--rows', str(size[1])],
            env=server.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self.read, daemon=True).start()
        self.pipe = open(self.fifo, 'wb', buffering=0)
        wait(lambda: self.sized(size), 'size the pane')

    def read(self):
        for line in self.controller.stdout:
            frame = json.loads(line)
            if frame.get('type') == 'terminal.frame':
                with self.lock:
                    self.frames.append(frame)

    def sized(self, size):
        with self.lock:
            return bool(self.frames) and [self.frames[-1]['width'], self.frames[-1]['height']] == list(size)

    def text(self):
        return self.server.rpc('pane.read', pane_id=self.pane['pane_id'], source='visible')['read']['text']

    def settle(self):
        # Done when two reads a moment apart show the same text and frames stopped coming.
        last = None
        for _ in range(200):
            time.sleep(0.1)
            with self.lock:
                count = len(self.frames)
            now = (self.text(), count)
            if now == last:
                return
            last = now
        raise RuntimeError('herdr kept changing')

    def play(self, step):
        if 'resize' in step:
            columns, rows = step['resize']
            self.controller.stdin.write(json.dumps({'type': 'terminal.resize', 'cols': columns, 'rows': rows}).encode() + b'\n')
            self.controller.stdin.flush()
            wait(lambda: self.sized(step['resize']), 'resize the pane')
        else:
            self.pipe.write(step['bytes'].encode())
        self.settle()

    def screen(self, rows):
        lines = [cells(line).rstrip(' ') for line in self.text().split('\n')][:rows]
        with self.lock:
            moves = [move for frame in self.frames for move in CUP.findall(base64.b64decode(frame['bytes']))]
        row, column = moves[-1]
        return lines + [''] * (rows - len(lines)), [int(column) - 1, int(row) - 1]

    def close(self):
        self.pipe.close()
        self.controller.terminate()
        self.controller.wait(timeout=5)


def main():
    cases = json.loads((HERE / 'cases.json').read_text())
    version = subprocess.run([HERDR, '--version'], check=True, capture_output=True, text=True).stdout.strip()
    out = []
    with tempfile.TemporaryDirectory(prefix='hs-') as directory:
        server = Server(directory)
        try:
            for index, case in enumerate(cases):
                place = f'{directory}/{index}'
                os.mkdir(place)
                terminal = Terminal(server, place, case['size'])
                try:
                    for step in case['steps']:
                        terminal.play(step)
                    rows = next((step['resize'][1] for step in reversed(case['steps']) if 'resize' in step), case['size'][1])
                    screen, cursor = terminal.screen(rows)
                finally:
                    terminal.close()
                out.append({**case, 'screen': screen, 'cursor': cursor})
        finally:
            server.close()
    (HERE / 'herdr.json').write_text(json.dumps({'made': f'herdr.py with {version}', 'cases': out}, indent=1, ensure_ascii=True) + '\n')


main()
