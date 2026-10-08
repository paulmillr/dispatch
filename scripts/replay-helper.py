#!/usr/bin/env python3
"""Replays a recorded app<->helper exchange (a capture-helper-wire.py fixture) as the helper.

The app starts it like the helper binary (DISPATCH_HELPER_EXECUTABLE; `--stdio` is ignored) and talks the
same framed wire on stdin/stdout. Environment: DISPATCH_REPLAY_FIXTURE (the fixture), DISPATCH_REPLAY_REPORT
(written when stdin ends), DISPATCH_REPLAY_CODEC (default: HelperBinary.py beside this script, generated
with Dispatch/Helper/HelperBinary.swift).

Each app request must equal the next recorded request, including method and all values. Only wire
request IDs are rebound; cancellation must refer to that same request. Replies retain recorded order
and are released after their preceding requests. Missing, unexpected, truncated, or undelivered frames
fail the replay; the player never launches a live helper. Dynamic paths are compared literally.
Report values are arrays; success requires every array empty and process exit zero.
"""
import base64, importlib.util, json, os, struct, sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("codec", os.environ.get("DISPATCH_REPLAY_CODEC", Path(__file__).with_name("HelperBinary.py")))
codec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codec)
path = Path(os.environ["DISPATCH_REPLAY_FIXTURE"])
if directory := os.environ.get("DISPATCH_REPLAY_DIRECTORY"):
    path = Path(directory) / path.name
fixture = json.loads(path.read_bytes())
assert fixture["schema"] == str(codec.VERSION), "replay codec differs from recording"
reads, writes = fixture["frames"]["read"], fixture["frames"]["write"]
used = [False] * len(reads)
ids, unexpected = {}, []
# Streams are chunked with the recorded hello's chunk size (the helper's current one without a hello).
CHUNK = next((w["value"]["result"]["chunk_limit"] for w in writes
              if isinstance(w["value"].get("result"), dict) and "chunk_limit" in w["value"]["result"]), 65_536)


def send(*frames):
    sys.stdout.buffer.write(b"".join(frames))
    sys.stdout.buffer.flush()


def emit(frame):
    """One recorded helper message: plain, or streamed in chunks as the helper sends it."""
    identity, value = ids.get(frame["id"], frame["id"]), frame["value"]
    if "stream" not in frame:
        return send(codec.frame(frame["kind"], identity, value))
    if "chunks" in frame:
        chunks = [base64.b64decode(chunk) for chunk in frame["chunks"]]
        assert "error" in value and value["stream"] == dict(chunks=len(chunks), bytes=sum(map(len, chunks)), encoding=frame["stream"]), "invalid recorded error stream"
        end = value
    else:
        payload = base64.b64decode(frame["bytes"]) if frame["stream"] == "binary" else codec.encode(value)
        chunks = [payload[at:at + CHUNK] for at in range(0, len(payload), CHUNK)]
        end = dict(value if frame["stream"] == "binary" else {}, stream=dict(chunks=len(chunks), bytes=len(payload), encoding=frame["stream"]))
    send(*(struct.pack("<IBQ", len(chunk) + 17, 5, identity) + struct.pack("<Q", index) + chunk for index, chunk in enumerate(chunks)))
    send(codec.frame(frame["kind"], identity, end))


def receive(kind, identity, body):
    value = codec.decode(body) if body else None
    index = next((i for i, done in enumerate(used) if not done), len(used))
    recorded = reads[index] if index < len(reads) else None
    match = recorded is not None and recorded["kind"] == kind
    if match:
        match = ids.get(recorded["id"]) == identity if kind == 4 else json.dumps(recorded.get("value"), sort_keys=True) == json.dumps(value, sort_keys=True)
    if match:
        used[index] = True
        ids[recorded["id"]] = identity
        return
    unexpected.append(dict(kind=kind, id=identity, value=value, expected=recorded))
    if kind != 4:
        send(codec.frame(2, identity, {"error": {"code": "replay", "message": "Request differs from the next recorded request."}}))
    raise ValueError("app request differs from recording")


sent = 0
frames = codec.Frames()
errors = []
try:
    for data in iter(lambda: os.read(0, 65_536), b""):
        for kind, identity, body in frames.feed(data):
            receive(kind, identity, body)
            asked = next((i for i, done in enumerate(used) if not done), len(used))
            for frame in writes[sent:]:
                if frame.get("after", 0) > asked:
                    break
                emit(frame)
                sent += 1
    frames.finish()
except Exception as error:
    errors.append(str(error))
result = dict(unexpected=unexpected, missing=[r for i, r in enumerate(reads) if not used[i]],
              undelivered=writes[sent:], errors=errors)
reports = [Path(os.environ["DISPATCH_REPLAY_REPORT"])]
if directory:
    reports.append(Path(directory) / reports[0].name)
for report in dict.fromkeys(reports):
    pending = report.with_name(report.name + ".pending")
    with open(os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        json.dump(result, output, indent=1)
        output.write("\n")
    os.link(pending, report)
    pending.unlink()
sys.exit(int(any(result.values())))
