#!/usr/bin/env python3
"""Extract UI wire messages from a real helper System capture as decoded, codec-independent fixtures.

Every body is decoded with the capture's own codec (--codec, the helper build's HelperBinary.py) and
stored as its value; a streamed reply is stored once, assembled (its value, or its envelope and the
binary payload). The tests encode the values with the current codec at replay, so a codec change
does not invalidate the fixtures; `schema` names the codec the frames were captured with.
--fixture migrates a fixture written in the older raw-frame form with that form's codec.

Values are kept as captured except the recording machine's identity: the hello reply's account
home, hostname, host and boot ids (anywhere in a value) and its uid become fixed placeholders
(fixtures are published; they must not name a machine). The written file then goes through
redact.clean (scripts/redact.py): any other machine or run data is masked at equal width, and the
write is refused if some remains."""
import argparse
import base64
import importlib.util
import hashlib
import json
import os
import re
from pathlib import Path
import struct


parser = argparse.ArgumentParser(description=__doc__)
source = parser.add_mutually_exclusive_group(required=True)
source.add_argument("--source", type=Path, help="A helper DISPATCH_CAPTURE file")
source.add_argument("--fixture", type=Path, help="A fixture in the older raw-frame form (one-time migration)")
parser.add_argument("--hello-from", type=Path,
                    help="The whole capture of a helper shared by several cases: a case slice without hello gets that helper's hello")
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--codec", type=Path, required=True,
                    help="The capturing helper build's generated HelperBinary.py: every body must decode")
parser.add_argument("--notify-sample", action="store_true",
                    help="Keep only helper notifications, the first of each method (consumer round-trip fixtures)")
parser.add_argument("--dry-run", action="store_true")
parser.add_argument("--section", default="ui", help="Captured wire section (current helper: startup)")
parser.add_argument("--private", action="store_true", help="Preserve exact values in a new private file; never publish without review")
args = parser.parse_args()
spec = importlib.util.spec_from_file_location("codec", args.codec)
codec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codec)

# Wire frames per direction: (kind, id, body, after); `after` counts the read frames before a frame, so
# a player can pace replies by what it has been asked (causal order, not clocks).
wire = {"read": [], "write": []}
if args.fixture:
    old = json.loads(args.fixture.read_bytes())
    digest = old["source_sha256"]
    for direction, frames in old["frames"].items():
        wire[direction] = [(frame["kind"], frame["id"], base64.b64decode(frame["body"]), None) for frame in frames]
else:
    def capture(path):
        """A capture's client frames per direction, each with `after`."""
        wire = {"read": [], "write": []}
        digest = hashlib.sha256()

        def rows(digest=None):
            with path.open("rb") as source:
                for line in source:
                    if digest is not None:
                        digest.update(line)
                    row = json.loads(line)
                    if row["section"] == args.section and row["op"] in wire and row["error"] is None and row.get("data"):
                        yield row

        def chunks(row):
            # A capture record holds the IO result: {"sequence", "output": {"kind": "bytes", "bytes": hex}}.
            output = json.loads(bytes.fromhex(row["data"]))["output"]
            return bytes.fromhex(output["bytes"]) if output["kind"] == "bytes" else b""

        # Discover all descriptors together, retaining only each one's first frame. Native
        # file results can dominate a capture's size; neither pass keeps those rows in memory.
        readers, first = {}, {}
        for row in rows(digest):
            key = row["op"], row["args"].split()[0]
            if key in first:
                continue
            reader = readers.setdefault(key, codec.Frames())
            try:
                frames = reader.feed(chunks(row))
            except ValueError:
                first[key] = None  # A login capture also holds the unframed origin shell descriptor.
            else:
                if not frames:
                    continue
                first[key] = frames[0]
            del readers[key]
        first.update((key, None) for key in readers)

        def client(op, accepts):
            # The app's descriptor: the one whose first frame is hello (read) or its reply (write); a slice cut
            # after hello (a helper shared by several cases) has only the client's descriptor left.
            found = sorted(fd for direction, fd in first if direction == op)
            hello = [fd for fd in found if (frame := first[op, fd]) and frame[2] and accepts(codec.decode(frame[2]))]
            assert hello or len(found) <= 1, f"several {op} descriptors and none starts with hello: {found}"
            return (hello or found or [None])[0]

        fds = dict(read=client("read", lambda value: value.get("method") == "hello"),
                   write=client("write", lambda value: "version" in (value.get("result") or {})))
        readers = {direction: codec.Frames() for direction in wire}
        for row in rows():
            direction = row["op"]
            if row["args"].split()[0] == fds[direction]:
                for kind, identity, body in readers[direction].feed(chunks(row)):
                    wire[direction].append((kind, identity, body, len(wire["read"])))
        for reader in readers.values():
            reader.finish()
        return wire, digest.hexdigest()

    wire, digest = capture(args.source)
    hello = lambda frame: codec.decode(frame[2]).get("method") == "hello"
    if args.hello_from and not (wire["read"] and hello(wire["read"][0])):
        # The app's first request and the helper's reply, then the slice paced one request later.
        shared, _ = capture(args.hello_from)
        assert shared["read"] and hello(shared["read"][0]), "the shared capture starts without hello"
        wire = dict(read=shared["read"][:1] + wire["read"],
                    write=shared["write"][:1] + [(k, i, b, after + 1) for k, i, b, after in wire["write"]])

# Logical messages: requests and cancels as sent; replies as the client assembles them.
frames = {"read": [], "write": []}
for kind, identity, body, _ in wire["read"]:
    frames["read"].append(dict(kind=kind, id=identity, **({"value": codec.decode(body)} if body else {})))
assert all("value" in frame or frame["kind"] == 4 for frame in frames["read"]), "only cancel has an empty body"
# A slice without hello (a shared helper) streams with the helper's hello settings (frame limit, chunk
# kind and size) as the current core sends them.
collector = None if any(frame[2] and "version" in (codec.decode(frame[2]).get("result") or {}) for frame in wire["write"][:1]) \
    else codec.Collector(12_000_013, 5, 65_536)
chunks = {}
for kind, identity, body, after in wire["write"]:
    if collector is None:
        value, payload = codec.decode(body), None
    else:
        reply = collector.push(kind, identity, body)
        if reply is None:
            chunks.setdefault(identity, []).append(body)
            continue  # a chunk of a streamed reply
        value, payload = reply[2], reply[3]
    envelope = codec.decode(body)
    frame = dict(kind=kind, id=identity, value=value, **({} if after is None else {"after": after}))
    if "stream" in envelope:
        frame["stream"] = envelope["stream"]["encoding"]
        if "error" in envelope:
            # An error may end a partial encoded value. Keep its bytes and chunk boundaries;
            # the collector validated them but intentionally discards their assembled payload.
            frame["chunks"] = [base64.b64encode(chunk[8:]).decode() for chunk in chunks.get(identity, [])]
        elif payload is not None:
            frame["value"] = {key: item for key, item in envelope.items() if key != "stream"}
            frame["bytes"] = base64.b64encode(payload).decode()
    chunks.pop(identity, None)
    result = value.get("result") if isinstance(value, dict) else None
    if isinstance(result, dict) and "chunk_kind" in result:
        assert result["version"] == codec.VERSION, "capture hello differs from selected codec"
        collector = codec.Collector(result["frame_limit"], result["chunk_kind"], result["chunk_limit"])
    frames["write"].append(frame)
if collector:
    collector.finish()

# The recording machine's identity, from the capture's own hello reply.
PLACEHOLDERS = dict(home="/Users/fixture", hostname="fixture-host",
                    host="00000000-0000-0000-0000-000000000001", boot="00000000-0000-0000-0000-000000000002")
names = {}
hello = None
for frame in frames["write"]:
    result = frame["value"].get("result")
    if isinstance(result, dict) and isinstance(result.get("identity"), dict):
        hello = frame
        found = dict(home=(result.get("account") or {}).get("home"), **{key: result["identity"].get(key)
                     for key in ("hostname", "host", "boot")})
        # An already scrubbed source (an exported slice) holds masks, not names: a mask is not replaced
        # everywhere it happens to occur.
        names = {real: PLACEHOLDERS[key] for key, real in found.items() if real and re.sub(r"[x./_-]", "", real)}
        break


def scrub(value):
    if isinstance(value, str):
        for real in sorted(names, key=len, reverse=True):
            value = value.replace(real, names[real])
        return value
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, dict):
        account = value.get("account")
        value = {key: scrub(item) for key, item in value.items()}
        if isinstance(account, dict) and "uid" in account and "identity" in value:
            value["account"]["uid"] = 501
        return value
    return value


def lossless(value, path):
    """JSON readers keep integers exactly only up to 2^53 and may turn integral reals into integers."""
    assert not isinstance(value, float), f"real number at {path}: not representable without its type"
    assert not isinstance(value, int) or isinstance(value, bool) or abs(value) < 2 ** 53, f"integer beyond 2^53 at {path}"
    for key, item in (value.items() if isinstance(value, dict) else enumerate(value) if isinstance(value, list) else []):
        lossless(item, f"{path}/{key}")


for direction in frames:
    for index, frame in enumerate(frames[direction]):
        if "value" in frame:
            if not args.private:
                frame["value"] = scrub(frame["value"])
            # The hello reply's version names the codec; replay serves the current one.
            checked = {**frame["value"], "result": {**frame["value"]["result"], "version": 0}} if frame is hello else frame["value"]
            if not args.private:
                lossless(checked, f"{direction}/{index}")
if args.notify_sample:
    seen = set()
    sample = []
    for frame in frames["write"]:
        if frame["kind"] == 3 and frame["value"]["method"] not in seen:
            seen.add(frame["value"]["method"])
            sample.append(frame)
    frames = dict(write=sample)
value = dict(source_sha256=digest, schema=str(codec.VERSION), frames=frames)
assert frames.get("read") and frames["write"], "capture contains no complete exchange"
output = (json.dumps(value, indent=1, ensure_ascii=False) + "\n").encode()
if not args.private:
    import redact
    output = redact.clean(output)
print(json.dumps(dict(output=str(args.output), read=len(frames.get("read", [])),
                     write=len(frames["write"]), sha256=hashlib.sha256(output).hexdigest())))
if not args.dry_run:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.private:
        with open(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as file:
            file.write(output)
    else:
        args.output.write_bytes(output)
