"""Deterministic protocol-v2 peer for Swift transport tests, never packaged.

Only fixed terminal scenarios are accepted. This tests the client's frame/credit
state machine; production Rust terminal workers have separate integration tests.
"""
import hashlib
import json
import os
import pathlib
import select
import struct
import sys

ROOT = pathlib.Path(sys.argv[1])
WINDOW = 1_048_576
streams = {}
incoming = bytearray()
outgoing = bytearray()


def send(kind, ident, value=b""):
    if isinstance(value, dict):
        value = json.dumps(value, separators=(",", ":")).encode()
    assert len(value) <= WINDOW and len(outgoing) + len(value) + 9 <= 4 * WINDOW
    outgoing.extend(struct.pack(">IcI", len(value) + 5, kind, ident) + value)


def finish(ident, status=0):
    send(b"X", ident, {"status": status})
    streams.pop(ident, None)


def dispatch(kind, ident, payload):
    if kind == b"J":
        request = json.loads(payload)
        if request.get("method") in ("host.identity", "stats.sample"):
            send(b"J", ident, {"ok": True})
            send(b"E", ident)
            return
        assert request == {"method": "herdr.terminal", "handle": "fixture",
                           "terminal": request["terminal"], "cols": 80, "rows": 24}
        mode = request["terminal"]
        assert mode in ("echo", "wait", "slow", "close", "finished", "noisy")
        assert len(streams) < 128
        streams[ident] = {"mode": mode, "pending": bytearray(), "ended": False,
                          "digest": hashlib.sha256(), "count": 0, "closed": False}
        send(b"J", ident, {"ready": True})
        send(b"W", ident, struct.pack(">I", WINDOW))
        if mode in ("slow", "close"):
            (ROOT / "ready").write_text(str(os.getpid()))
        elif mode == "finished":
            send(b"D", ident, b"FINISHED")
            finish(ident, 7)
    elif kind == b"C":
        streams.pop(ident, None)
    elif ident in streams:
        state = streams[ident]
        if kind == b"D":
            assert not state["ended"] and not state["closed"]
            if state["mode"] == "echo":
                send(b"D", ident, payload)
                send(b"W", ident, struct.pack(">I", len(payload)))
            else:
                state["pending"].extend(payload)
                assert len(state["pending"]) <= WINDOW
        else:
            assert kind == b"E" and not payload
            state["ended"] = True
            if state["mode"] == "echo":
                finish(ident)


os.set_blocking(0, False)
os.set_blocking(1, False)
send(b"J", 0, {"version": 2, "host": "stream-fixture", "boot": "fixture-boot",
                "uid": os.getuid(), "home": str(ROOT), "profile": "full", "policyRevision": 1,
                "capabilities": ["host.identity", "stats.sample", "cancel", "herdr.terminal", "input.window"]})
while True:
    readable, writable, _ = select.select([0], [1] if outgoing else [], [], 0.001)
    if 1 in writable:
        try:
            count = os.write(1, outgoing)
            del outgoing[:count]
        except BlockingIOError:
            pass
    if 0 in readable:
        data = os.read(0, 65536)
        if not data:
            break
        incoming.extend(data)
        assert len(incoming) <= WINDOW + 9
        while len(incoming) >= 4:
            size = struct.unpack_from(">I", incoming)[0]
            assert 5 <= size <= WINDOW + 5
            if len(incoming) < size + 4:
                break
            kind, ident = struct.unpack_from(">cI", incoming, 4)
            payload = bytes(incoming[9:size + 4])
            del incoming[:size + 4]
            dispatch(kind, ident, payload)
    # Each iteration services all stream states and bounds outgoing memory.
    if len(outgoing) > WINDOW:
        continue
    for ident, state in list(streams.items()):
        mode = state["mode"]
        if mode == "noisy":
            send(b"D", ident, b"y" * 65536)
        elif mode == "close" and (ROOT / "release").exists():
            if not state["closed"]:
                state["pending"].clear()
                state["closed"] = True
                send(b"W", ident, bytes(4))
                send(b"D", ident, b"OUTPUT_AFTER_STDIN_CLOSED\n")
            if (ROOT / "exit").exists():
                send(b"D", ident, b"OUTPUT_BEFORE_EXIT\n")
                finish(ident, 23)
        elif mode == "slow" and (ROOT / "release").exists():
            chunk = state["pending"][:32768]
            del state["pending"][:len(chunk)]
            if chunk:
                state["digest"].update(chunk)
                state["count"] += len(chunk)
                # E closes input only after queued bytes have drained.
                if not state["ended"]:
                    send(b"W", ident, struct.pack(">I", len(chunk)))
            if state["ended"] and not state["pending"]:
                send(b"D", ident, f'{state["count"]} {state["digest"].hexdigest()}\n'.encode())
                finish(ident)
