#!/usr/bin/env python3
"""How fast a terminal consumes output, and how long programs writing to it are blocked.

Run it inside the terminal to measure (any terminal; Python 3.9 standard library only). Each
workload writes a fixed, seeded stream, then asks the terminal for its cursor position: a
terminal answers only after it has processed everything written before the question, so the
answer time is the time the terminal needed to consume the stream. Every write() is timed per
stream, so a terminal that starves its writers (logs on stdout and stderr) shows up as stalls.

  ascii    plain lines, written in 64 KiB chunks
  logs     colored log lines, one write() per line, stdout and stderr from two threads at once
  unicode  CJK, emoji and combining marks, 64 KiB chunks
  long     lines much wider than the window, 64 KiB chunks
  kitty    kitty graphics: RGBA images of 64x64, 256x256 and 1024x1024 pixels in turn, sent and
           shown (a=T, 4096-byte base64 chunks, 8 image ids reused), a line after each; 64 KiB chunks

Each stream is written by its own process from bytes prepared before the clock starts, so the
writers never wait for each other or for Python.

--self-test runs the workloads under a pty this program drains itself: every line must arrive,
in order per stream, and every end check must pass. There the two log writers take turns per
line, so lines stay whole for the check. Inside a real terminal the screen cannot be read back:
only the end check (the reported cursor column after a known sentinel) is verified.

--ceiling runs the workloads under a pty that `dd` drains: the most any terminal can show on this
machine (the writers + the pty). Nothing answers there, so nothing is asked: each workload's time
is when the pty took its last byte.

usage: benchmark-terminal-throughput.py [--workloads ascii,logs,unicode,long,kitty] [--mib N] [--runs N] [--json FILE]
       benchmark-terminal-throughput.py --self-test|--ceiling [--mib N] [--runs N]
"""
import argparse
import atexit
import base64
import bisect
import fcntl
import functools
import json
import os
import pty
import random
import re
import select
import shutil
import subprocess
import statistics
import struct
import sys
import tempfile
import termios
import time
import tty
from array import array

WORKLOADS = ('ascii', 'logs', 'unicode', 'long', 'kitty')
CHUNK = 64 * 1024
SENTINEL = b'BENCH-END'
QUERY = b'\x1b[6n'
REPLY = re.compile(rb'\x1b\[(\d+);(\d+)R')
TAG = re.compile(rb'\[(out|err) (\w+) (\d{8})\] ')
LEVELS = [(b'32', b'INFO '), (b'33', b'WARN '), (b'31', b'ERROR'), (b'36', b'DEBUG')]
UNICODE = 'ä€漢字かなカナ한글😀🚀👍🏽✨éñΩЖשéä'


LENGTHS = {'logs': (30, 140), 'unicode': (10, 60), 'long': (2000, 6000), 'ascii': (20, 120)}
POOL = 1 << 16
KITTY = ((64, 64), (256, 256), (1024, 1024))
# The writers' clock, the same in C and Python (perf_counter's).
CLOCK = time.CLOCK_UPTIME_RAW if sys.platform == 'darwin' else time.CLOCK_MONOTONIC
WRITER_C = r'''
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
/* writer() in C. argv: output fd, go fd, result fd, turn take fd, turn give fd (-1: no turns).
   stdin: blob length, blob, cut count, cuts (int64). result: 'r' when loaded, then the writes. */
static int64_t now(void) { struct timespec t; clock_gettime(CLOCK, &t); return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec; }
static void all(int fd, void *p, int64_t n, int in) {
    for (char *c = p; n > 0;) {
        ssize_t k = in ? read(fd, c, (size_t)n) : write(fd, c, (size_t)n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) _exit(2);
        c += k, n -= k;
    }
}
int main(int argc, char **argv) {
    if (argc != 6) return 1;
    int out = atoi(argv[1]), go = atoi(argv[2]), result = atoi(argv[3]), take = atoi(argv[4]), give = atoi(argv[5]);
    int64_t size, cuts, writes = 0, room = 1024, start = 0;
    char token;
    all(0, &size, 8, 1);
    char *blob = malloc(size + 1);
    all(0, blob, size, 1);
    all(0, &cuts, 8, 1);
    int64_t *cut = malloc(cuts * 8 + 8), *end = malloc(room * 8), *stall = malloc(room * 8);
    all(0, cut, cuts * 8, 1);
    all(result, "r", 1, 0);
    all(go, &token, 1, 1);
    for (int64_t i = 0; i < cuts; i++) {
        if (take >= 0) all(take, &token, 1, 1);
        while (start < cut[i]) {
            int64_t t = now();
            ssize_t k = write(out, blob + start, (size_t)(cut[i] - start));
            if (k < 0 && errno == EINTR) continue;
            if (k <= 0) _exit(3);
            if (writes == room) room *= 2, end = realloc(end, room * 8), stall = realloc(stall, room * 8);
            end[writes] = now(), stall[writes] = end[writes] - t, writes++, start += k;
        }
        if (give >= 0) all(give, &token, 1, 0);
    }
    all(result, &writes, 8, 0), all(result, end, writes * 8, 0), all(result, stall, writes * 8, 0);
    return 0;
}
'''


def now():
    return time.clock_gettime_ns(CLOCK)


@functools.lru_cache(None)
def c_writer():
    """WRITER_C compiled with the system's cc into a temporary directory (None: no cc, the Python writer runs)."""
    directory = tempfile.mkdtemp(prefix='terminal-benchmark-')
    atexit.register(shutil.rmtree, directory, True)
    source, binary = os.path.join(directory, 'writer.c'), os.path.join(directory, 'writer')
    with open(source, 'w') as f:
        f.write(WRITER_C)
    clock = 'CLOCK_UPTIME_RAW' if sys.platform == 'darwin' else 'CLOCK_MONOTONIC'
    try:
        return binary if subprocess.run(['cc', '-O2', f'-DCLOCK={clock}', '-o', binary, source], capture_output=True).returncode == 0 else None
    except OSError:
        return None


def lines(workload, stream, size, seed):
    """One stream: about `size` bytes of lines, each tagged `[stream workload sequence]`, and the
    offset where each line ends. The line texts are slices of a seeded random text (quick at any size)."""
    rng = random.Random(f'{seed}-{workload}-{stream}')
    pool = ''.join(rng.choice(UNICODE if workload == 'unicode' else 'abcdefghijklmnopqrstuvwxyz0123456789 ') for _ in range(POOL)) * 2
    prefix = b'[%s %s ' % (stream.encode(), workload.encode())
    pixels = rng.randbytes(8 * max(w * h for w, h in KITTY)) if workload == 'kitty' else b''
    blob, ends = bytearray(), array('q')
    while len(blob) < size:
        tag = prefix + b'%08d] ' % (len(ends) + 1)
        if workload == 'kitty':
            (w, h), start = KITTY[len(ends) % len(KITTY)], rng.randrange(len(pixels) // 2)
            data = base64.b64encode(pixels[start:start + w * h * 4])
            keys = b'a=T,f=32,s=%d,v=%d,i=%d,C=1,q=2,' % (w, h, len(ends) % 8 + 1)
            for i in range(0, len(data), 4096):
                blob += b'\x1b_G%sm=%d;%s\x1b\\' % (keys if i == 0 else b'', i + 4096 < len(data), data[i:i + 4096])
            blob += tag + b'\r\n'
            ends.append(len(blob))
            continue
        at, (low, high) = rng.randrange(POOL), LENGTHS[workload]
        text = pool[at:at + rng.randint(low, high)].encode()
        if workload == 'logs':
            color, level = LEVELS[rng.randrange(len(LEVELS))]
            blob += b'2026-09-27T12:00:%02d.%03dZ \x1b[%sm%s\x1b[0m %s%s\r\n' % (len(ends) % 60, len(ends) % 1000, color, level, tag, text)
        else:
            blob += tag + text + b'\r\n'
        ends.append(len(blob))
    return blob, ends


def percentile(values, p):
    """Nearest-rank percentile of sorted values."""
    return values[min(len(values) - 1, max(0, round(p / 100 * len(values)) - 1))] if values else 0


def starvation(ends, t0):
    """Longest time (ns) one stream made no progress while another stream did."""
    worst = 0
    for stream, times in ends.items():
        others, previous = sorted(t for s, ts in ends.items() if s != stream for t in ts), t0
        for t in times:
            i = bisect.bisect_right(others, previous)
            if i < len(others) and others[i] < t:
                worst = max(worst, t - previous)
            previous = t
    return worst


def prepare(workload, mib, seed):
    """Each stream's bytes and where its writes end (logs: one write per line; the others: 64 KiB
    chunks), and the line counts."""
    streams = ('out', 'err') if workload == 'logs' else ('out',)
    data, counts = {}, {}
    for s in streams:
        blob, ends = lines(workload, s, mib * 1024 * 1024 // len(streams), seed)
        counts[s] = len(ends)
        data[s] = (blob, ends if workload == 'logs' else array('q', [*range(CHUNK, len(blob), CHUNK), len(blob)]))
    return data, counts


def writer(fd, blob, cuts, go, turns, result):
    """A stream's writing process (without cc; WRITER_C otherwise): says it is ready, waits for `go`,
    writes up to each cut (holding `turns`, a token pipe, around each write when given), then sends
    each write's end and duration (ns) to `result`."""
    view, start, write, clock = memoryview(blob), 0, os.write, time.clock_gettime_ns
    stall, end = array('q'), array('q')
    os.write(result, b'r')
    os.read(go, 1)
    for cut in cuts:
        if turns:
            os.read(turns[0], 1)
        while start < cut:
            t = clock(CLOCK)
            start += write(fd, view[start:cut])
            end.append(clock(CLOCK))
            stall.append(end[-1] - t)
        if turns:
            os.write(turns[1], b'.')
    with os.fdopen(result, 'wb') as f:
        f.write(struct.pack('q', len(end)) + end.tobytes() + stall.tobytes())


def run(workload, data, counts, tty_fd, turns, ask, terminal):
    """One workload: timed writes from each stream's own process, then (`ask`) the sentinel and the
    cursor question; the CPU time `terminal`'s processes spent meanwhile (when known)."""
    go, children, stalls, ends, binary = os.pipe(), {}, {}, {}, c_writer()
    for stream, (blob, cuts) in data.items():
        result, fd = os.pipe(), {'out': 1, 'err': 2}[stream]
        if binary:
            process = subprocess.Popen([binary, str(fd), str(go[0]), str(result[1]), *map(str, turns or (-1, -1))],
                                       stdin=subprocess.PIPE, pass_fds=(go[0], result[1], *(turns or ())))
            for part in (struct.pack('q', len(blob)), blob, struct.pack('q', len(cuts)), cuts.tobytes()):
                process.stdin.write(part)
            process.stdin.close()
            wait = process.wait
        else:
            pid = os.fork()
            if pid == 0:
                os.close(result[0])
                writer(fd, blob, cuts, go[0], turns, result[1])
                os._exit(0)
            wait = functools.partial(os.waitpid, pid, 0)
        os.close(result[1])
        children[stream] = (wait, result[0])
    for _, fd in children.values():
        os.read(fd, 1)   # every writer has its bytes: the clock starts
    cpu = terminal_cpu(terminal) if terminal else None
    t0 = now()
    os.write(go[1], b'.' * len(children))
    for stream, (wait, fd) in children.items():
        with os.fdopen(fd, 'rb') as f:
            n = struct.unpack('q', f.read(8))[0]
            ends[stream], stalls[stream] = array('q'), array('q')
            ends[stream].frombytes(f.read(8 * n))
            stalls[stream].frombytes(f.read(8 * n))
        wait()
    for fd in go:
        os.close(fd)
    streams, accepted, reply = list(data), max(e[-1] for e in ends.values()), b''
    if ask:
        os.write(1, b'\x1b[0m\r\n' + SENTINEL + QUERY)
        deadline = time.monotonic() + 120
        while not REPLY.search(reply) and select.select([tty_fd], [], [], max(0.0, deadline - time.monotonic()))[0]:
            reply += os.read(tty_fd, 64)
    consumed, match = now() if ask else accepted, REPLY.search(reply) if ask else True
    cpu = terminal_cpu(terminal) - cpu if terminal else None
    total = sum(len(data[s][0]) for s in streams)
    return {'workload': workload, 'bytes': total, 'lines': counts, 'accept_s': (accepted - t0) / 1e9,
            'consume_s': (consumed - t0) / 1e9 if match else None,
            'consume_mb_s': total / 1e3 / ((consumed - t0) / 1e6) if match else None,
            'end_check': bool(match) and (not ask or int(match.group(2)) == len(SENTINEL) + 1),
            'terminal_cpu_s': cpu, 'cpu_ms_per_mb': cpu * 1e3 / (total / 1e6) if cpu is not None else None,
            'starve_max_ms': starvation(ends, t0) / 1e6,
            'streams': {s: {'writes': len(stalls[s]), 'blocked_fraction': sum(stalls[s]) / max(1, accepted - t0),
                            **{f'stall_{p}_ms': percentile(sorted(stalls[s]), p) / 1e6 for p in (50, 95, 99, 100)}} for s in streams}}


def seconds(text):
    """ps's CPU time ([[dd-]hh:]mm:ss.cc) in seconds."""
    days, _, rest = text.rpartition('-')
    return (int(days) * 86400 if days else 0) + sum(float(p) * 60 ** i for i, p in enumerate(reversed(rest.split(':'))))


def processes():
    """pid -> (parent pid, CPU seconds, command) for every process: ps on macOS, /proc elsewhere."""
    table = {}
    if sys.platform == 'darwin':
        for line in subprocess.run(['ps', '-A', '-o', 'pid=,ppid=,time=,comm='], capture_output=True, text=True).stdout.splitlines():
            pid, parent, cpu, command = line.split(None, 3)
            table[int(pid)] = (int(parent), seconds(cpu), command)
        return table
    tick = os.sysconf('SC_CLK_TCK')
    for name in filter(str.isdigit, os.listdir('/proc')):
        try:
            with open(f'/proc/{name}/stat') as f:
                stat = f.read()
        except OSError:
            continue
        fields = stat[stat.rindex(')') + 2:].split()
        table[int(name)] = (int(fields[1]), (int(fields[11]) + int(fields[12])) / tick, stat[stat.index('(') + 1:stat.rindex(')')])
    return table


def terminal_roots(pid):
    """The terminal's processes to charge: `pid` (else the nearest ancestor from a macOS .app bundle),
    and the tmux server when inside tmux. None: not known."""
    table, at = processes(), os.getppid()
    for _ in range(64):
        if pid or at not in table or at <= 1:
            break
        if '.app/Contents/MacOS/' in table[at][2]:
            pid = at
        at = table[at][0]
    tmux = int(os.environ['TMUX'].split(',')[1]) if os.environ.get('TMUX', '').count(',') >= 2 else None
    return [p for p in (pid, tmux) if p] or None


def terminal_cpu(roots):
    """CPU seconds so far of `roots` and everything they started, without this benchmark's processes."""
    table, children = processes(), {}
    for pid, (parent, _, _) in table.items():
        children.setdefault(parent, []).append(pid)
    mine, stack = set(), [os.getpid()]
    while stack:
        mine.add(stack[-1])
        stack += children.get(stack.pop(), [])
    seen, stack = set(), [r for r in roots if r in table]
    while stack:
        pid = stack.pop()
        if pid not in seen and pid not in mine:
            seen.add(pid)
            stack += children.get(pid, [])
    return sum(table[p][1] for p in seen)


def measure(workloads, mib, runs, seed, turns, ask, terminal):
    """Every workload `runs` times in this terminal (cbreak on /dev/tty for the answers); one
    workload's bytes in memory at a time. `turns`: the log writers take turns per line (self-test)."""
    tty_fd = os.open('/dev/tty', os.O_RDWR)
    saved = termios.tcgetattr(tty_fd)
    columns, rows = os.get_terminal_size(tty_fd)
    results, token = [], None
    if turns:
        token = os.pipe()
        os.write(token[1], b'.')
    try:
        tty.setcbreak(tty_fd)
        for w in workloads:
            prepared = prepare(w, mib, seed)
            results += [run(w, *prepared, tty_fd, token, ask, terminal) for _ in range(runs)]
    finally:
        os.write(1, b'\x1b[0m\x1b[?25h\r\n')
        termios.tcsetattr(tty_fd, termios.TCSADRAIN, saved)
    return {'terminal': os.environ.get('TERM_PROGRAM', '?'), 'terminal_version': os.environ.get('TERM_PROGRAM_VERSION', '?'),
            'term': os.environ.get('TERM', '?'), 'columns': columns, 'rows': rows, 'mib': mib, 'seed': seed,
            'writer': 'c' if c_writer() else 'python', 'terminal_processes': terminal, 'results': results}


def summary(report):
    """Medians (min-max) per workload."""
    out = [f"{report['terminal']} {report['terminal_version']} ({report['term']}, {report['columns']}x{report['rows']}), "
           f"{report['mib']} MiB per workload, {report['writer']} writer"]
    for w in dict.fromkeys(r['workload'] for r in report['results']):
        rs = [r for r in report['results'] if r['workload'] == w]
        span = lambda values, f: f'{f(statistics.median(values))} ({f(min(values))}-{f(max(values))})' if None not in values else 'no answer'
        line = f"{w:8} consume {span([r['consume_mb_s'] for r in rs], lambda v: f'{v:.1f}')} MB/s"
        if rs[0]['cpu_ms_per_mb'] is not None:
            line += f"  terminal cpu {span([r['cpu_ms_per_mb'] for r in rs], lambda v: f'{v:.2f}')} ms/MB"
        for s in rs[0]['streams']:
            line += f"  {s}: stall p99 {span([r['streams'][s]['stall_99_ms'] for r in rs], lambda v: f'{v:.2f}')} ms, " \
                    f"max {span([r['streams'][s]['stall_100_ms'] for r in rs], lambda v: f'{v:.2f}')} ms"
        if len(rs[0]['streams']) > 1:
            line += f"  starve max {span([r['starve_max_ms'] for r in rs], lambda v: f'{v:.2f}')} ms"
        out.append(line + ('' if all(r['end_check'] for r in rs) else '  END CHECK FAILED'))
    return '\n'.join(out)


def self_test(workloads, mib, runs, seed, check):
    """Run the workloads in a child under a pty; drain it and answer its questions; `check`: every
    line (the writers take turns), otherwise as fast as possible (the ceiling)."""
    read, write = os.pipe()
    os.set_inheritable(write, True)
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        os.environ.update(TERM_PROGRAM='self-test' if check else 'ceiling', TERM_PROGRAM_VERSION=f'python {sys.version.split()[0]}')
        os.execv(sys.executable, [sys.executable, __file__, '--child', str(write), '--mib', str(mib), '--runs', str(runs),
                                  '--seed', str(seed), '--workloads', ','.join(workloads)] + (['--turns'] if check else ['--no-ask']))
    os.close(write)
    seen, pending, errors = {}, bytearray(), []

    def verify(line):
        line = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]', b'', line.replace(b'\r', b''))
        if line and line != SENTINEL:
            tag = TAG.search(line)
            if not tag:
                errors.append(f'line without a tag: {line[:60]!r}')
                return
            key = (tag.group(2).decode(), tag.group(1).decode())
            if int(tag.group(3)) != seen.get(key, 0) + 1:
                errors.append(f'{key}: line {int(tag.group(3))} after {seen.get(key, 0)}')
            seen[key] = int(tag.group(3))

    if not check:
        subprocess.run(['dd', 'bs=1048576', 'of=/dev/null'], stdin=master, capture_output=True)
    while check:
        try:
            data = os.read(master, 1 << 20)
        except OSError:
            data = b''
        if not data:
            break
        # Only the new bytes are searched (an image line spans thousands of small pty reads).
        new = max(0, len(pending) - len(QUERY) + 1)
        pending += data
        while QUERY in pending[new:]:
            before, rest = bytes(pending).split(QUERY, 1)
            *complete, current = before.split(b'\n')
            for line in complete:
                verify(line)
            verify(current)
            os.write(master, b'\x1b[1;%dR' % (len(re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]', b'', current.replace(b'\r', b''))) + 1))
            pending, new = bytearray(rest), 0
        if b'\n' in data:
            *complete, rest = bytes(pending).split(b'\n')
            for line in complete:
                verify(line)
            pending = bytearray(rest)
    status = os.waitpid(pid, 0)[1]
    with os.fdopen(read) as f:
        report = json.loads(f.read() or '{}')
    for r in report.get('results', []):
        for stream, count in r['lines'].items():
            if check and seen.get((r['workload'], stream)) != count:
                errors.append(f"{r['workload']}/{stream}: {seen.get((r['workload'], stream))} of {count} lines arrived")
        if not r['end_check']:
            errors.append(f"{r['workload']}: end check failed")
    if status or not report:
        errors.append(f'child exit status {status}')
    print(summary(report) if report else '', *errors, ('self-test: ' if check else 'ceiling: ') + ('FAILED' if errors else 'ok'), sep='\n')
    return 1 if errors else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--workloads', default=','.join(WORKLOADS))
    parser.add_argument('--mib', type=int, default=16, help='MiB written per workload (any size: one workload is in memory at a time)')
    parser.add_argument('--runs', type=int, default=1)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--json', help='also write the report here')
    parser.add_argument('--self-test', action='store_true', help='check every line under a pty drained by this program (one run)')
    parser.add_argument('--ceiling', action='store_true', help='the most any terminal can show here: a pty that dd drains')
    parser.add_argument('--child', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--turns', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--no-ask', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--terminal', type=int, help="the terminal app's pid for its CPU time (default: the nearest .app ancestor on macOS)")
    args = parser.parse_args()
    workloads = args.workloads.split(',')
    if set(workloads) - set(WORKLOADS) or args.mib < 1 or args.runs < 1:
        parser.error('workloads: ' + ', '.join(WORKLOADS) + '; --mib and --runs at least 1')
    if args.self_test or args.ceiling:
        return self_test(workloads, args.mib, 1 if args.self_test else args.runs, args.seed, args.self_test)
    report = measure(workloads, args.mib, args.runs, args.seed, args.turns, not args.no_ask,
                     None if args.child is not None else terminal_roots(args.terminal))
    if args.child is not None:
        with os.fdopen(args.child, 'w') as f:
            json.dump(report, f)
        return 0
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(report, f, indent=1)
    print('\x1b[2J\x1b[H' + summary(report))
    return 0 if all(r['end_check'] for r in report['results']) else 1


if __name__ == '__main__':
    sys.exit(main())
