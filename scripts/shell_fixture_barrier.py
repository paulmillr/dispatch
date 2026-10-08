#!/usr/bin/env python3
"""Pause one test shell on a FIFO until its owning test releases it."""
import json
import os
from pathlib import Path
import select
import signal
import sys


def interrupted(_signal, _frame):
    raise InterruptedError('Fixture shell cancelled')


def main(directory):
    directory = Path(directory)
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, interrupted)
    fd = os.open(directory / 'release', os.O_RDONLY | os.O_NONBLOCK)
    outcome = 'failed'
    try:
        temporary = directory / 'ready.tmp'
        temporary.write_text(json.dumps({'pid': os.getpid(), 'parent': os.getppid()}) + '\n')
        temporary.replace(directory / 'ready.json')
        ready, _, _ = select.select([fd], [], [], 20)
        if not ready:
            outcome = 'timed_out'
            return 1
        if os.read(fd, 1) != b'1':
            return 1
        outcome = 'released'
        return 0
    except InterruptedError:
        outcome = 'cancelled'
        return 1
    finally:
        temporary = directory / 'completed.tmp'
        temporary.write_text(json.dumps({'outcome': outcome}) + '\n')
        temporary.replace(directory / 'completed.json')
        os.close(fd)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
