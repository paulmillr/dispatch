"""Inert app-server fixture; the native parent owns its Unix socket identity."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import sys

scenario, record_path = sys.argv[1:]
stream = socket.socket(fileno=0)
stream.settimeout(4)
thread = "00dc6acf-ac00-7000-8000-000000000106"
commands = []

def exact(length):
    result = bytearray()
    while len(result) < length:
        data = stream.recv(length - len(result))
        if not data:
            raise EOFError()
        result.extend(data)
    return bytes(result)

def receive():
    first, second = exact(2)
    assert first & 0x80 and second & 0x80
    length = second & 127
    if length == 126:
        length = struct.unpack("!H", exact(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", exact(8))[0]
    assert length <= 4096
    mask = exact(4)
    return first & 15, bytes(byte ^ mask[index % 4] for index, byte in enumerate(exact(length)))

def request():
    opcode, value = receive()
    assert opcode == 1
    value = json.loads(value)
    commands.append(value)
    Path(record_path).write_text(json.dumps(commands))
    return value

def frame(payload, opcode=1, final=True):
    flags = opcode | (128 if final else 0)
    if len(payload) < 126:
        header = bytes([flags, len(payload)])
    elif len(payload) <= 65535:
        header = bytes([flags, 126]) + struct.pack("!H", len(payload))
    else:
        header = bytes([flags, 127]) + struct.pack("!Q", len(payload))
    stream.sendall(header + payload)

def message(value):
    frame(json.dumps(value, separators=(",", ":")).encode())

try:
    header = bytearray()
    while not header.endswith(b"\r\n\r\n"):
        header.extend(exact(1))
        assert len(header) <= 16384
    fields = dict(line.decode().split(": ", 1) for line in header.split(b"\r\n")[1:-2])
    accept = base64.b64encode(hashlib.sha1((fields["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
    stream.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
    assert request() == {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "dispatch-diff-view", "version": "1"}, "capabilities": {"experimentalApi": True}}}
    message({"id": 90, "method": "item/fileChange/requestApproval", "params": {"threadId": thread}})
    message({"id": 1, "result": {"userAgent": "fixture"}})
    assert request() == {"method": "initialized", "params": {}}
    assert request() == {"id": 2, "method": "thread/read", "params": {"threadId": thread, "includeTurns": False}}
    message({"id": 2, "result": {"thread": {"id": thread if scenario != "wrong-thread" else "different", "status": {"type": "notLoaded" if scenario == "not-loaded" else "active"}}}})
    if scenario in ("not-loaded", "wrong-thread"):
        try:
            assert not stream.recv(1), "Must not resume an unverified/unloaded thread"
        except ConnectionResetError:
            pass
        sys.exit(0)
    if scenario == "queue":
        queued = request()
        assert queued["id"] == 4
        assert queued["params"]["threadId"] == thread
        assert queued["method"] in ["thread/queue/" + op for op in ["add", "list", "update", "delete", "start", "reorder"]] + ["turn/steer"]
        message({"id": 4, "result": {"echo": queued}})
        sys.exit(0)
    assert request() == {"id": 3, "method": "thread/resume", "params": {"threadId": thread, "excludeTurns": True, "initialTurnsPage": {"limit": 1, "itemsView": "full"}}}
    message({"id": 3, "result": {"thread": {"id": thread}, "initialTurnsPage": {"data": [{"id": "turn", "items": [{"type": "reasoning", "text": "omit"}, {"id": "patch", "type": "fileChange", "status": "inProgress", "changes": []}]}]}}})
    if scenario == "hold":
        assert not stream.recv(1), "Cancelled observers must not send mutations"
        sys.exit(0)
    message({"method": "item/fileChange/patchUpdated", "params": {"threadId": "other", "changes": []}})
    message({"id": 91, "method": "item/fileChange/requestApproval", "params": {"threadId": thread}})
    large = json.dumps({"method": "item/fileChange/patchUpdated", "params": {"threadId": thread, "turnId": "turn", "itemId": "patch", "changes": [{"path": "fixture.txt", "kind": {"type": "update"}, "diff": "x" * 1200000}]}}, separators=(",", ":")).encode()
    frame(large[:600000], final=False)
    frame(b"health", opcode=9)
    frame(large[600000:], opcode=0)
    assert receive() == (10, b"health"), "Only a Pong may be returned, never an approval"
    message({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn"}}})
    frame(b"", opcode=8)
except EOFError:
    if scenario not in ("not-loaded", "wrong-thread"):
        raise
