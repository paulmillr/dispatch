"""Request-scoped control for localhost model fixtures, never shared across runs.

Prefix a prompt with FIXTURE_BARRIER_<32 lowercase hex digits>. The endpoint
writes barriers/<id>/accepted.json, waits for release, then writes completed.json
only after the handler returns. Cancellation, disconnect, timeout, and shutdown
are terminal outcomes too. A released request cannot release any other request.
"""
from contextlib import contextmanager
import json
import math
from pathlib import Path
import re
import select
import socket
import threading
import time
import uuid


class BarrierCancelled(Exception):
    pass


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value) + '\n')
    temporary.replace(path)


class RequestRecord:
    def __init__(self, owner, prompt, connection):
        self.owner = owner
        self.connection = connection
        match = re.match(r'FIXTURE_BARRIER_([a-f0-9]{32})(?:\s|$)', prompt)
        self.identifier = match[1] if match else uuid.uuid4().hex
        self.directory = owner.state / 'barriers' / self.identifier if match else None
        self.started = time.monotonic()
        self.released = False
        if self.directory:
            # Reusing a marker must fail: accepting a retry would hide duplicate
            # submissions and could consume an earlier request's release file.
            self.directory.mkdir(parents=True, exist_ok=False)
            self.write('accepted', {'id': self.identifier})

    def write(self, name, value):
        write_json(self.directory / (name + '.json'), value)

    def wait(self):
        if not self.directory:
            return
        deadline = self.started + self.owner.timeout
        while True:
            if self.owner.closed.is_set() or (self.directory / 'cancel').exists():
                raise BarrierCancelled('Fixture request cancelled')
            ready, _, _ = select.select([self.connection], [], [], 0)
            if ready and not self.connection.recv(1, socket.MSG_PEEK):
                raise ConnectionResetError('Fixture client disconnected')
            if (self.directory / 'release').exists():
                self.released = True
                return
            if time.monotonic() >= deadline:
                raise TimeoutError('Fixture barrier was never released')
            # This polls an explicit condition, not a sleep to create a race.
            self.owner.closed.wait(min(0.01, max(0, deadline - time.monotonic())))

    def finish(self, outcome):
        record = {'id': self.identifier, 'outcome': outcome, 'released': self.released,
                  'seconds': time.monotonic() - self.started}
        with self.owner.lock:
            with (self.owner.state / 'completions.jsonl').open('a') as stream:
                stream.write(json.dumps(record) + '\n')
        if self.directory:
            self.write('completed', record)


class FixtureBarriers:
    def __init__(self, state, timeout=20):
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError('Barrier timeout must be positive and finite')
        self.state = Path(state)
        self.timeout = timeout
        self.lock = threading.Lock()
        self.closed = threading.Event()

    @contextmanager
    def request(self, prompt, connection):
        record = RequestRecord(self, prompt, connection)
        outcome = 'failed'
        try:
            yield record
            outcome = 'delivered'
        except BarrierCancelled:
            outcome = 'cancelled'
            raise
        except (BrokenPipeError, ConnectionResetError):
            outcome = 'disconnected'
            raise
        except TimeoutError:
            outcome = 'timed_out'
            raise
        finally:
            record.finish(outcome)

    def close(self):
        self.closed.set()


def interrupt_fixture(_signum, _frame):
    """Let the serving process unwind its server context on SIGTERM."""
    raise KeyboardInterrupt()
