#!/usr/bin/env python3
"""Run the c1654cc helper-wire behaviors through the common helper4 API.

The case map preserves every original assertion and its source span. An absent
operation remains blocked; a partial scenario never counts as a full case pass.
Native captures are replayed with live UI pipes and absent native producers.
"""

import argparse
import asyncio
import base64
import hashlib
import itertools
import json
import os
from pathlib import Path
import pwd
import signal
import struct
import subprocess
import traceback


class Collector:
    def __init__(self):
        self.chunks = {}
        # Bootstrap body bound is the existing wire limit; Hello overrides it.
        self.kind, self.limit, self.frame = 5, None, 12_000_013

    def configure(self, hello):
        frame, kind, limit = (
            hello.get(key) for key in ("frame_limit", "chunk_kind", "chunk_limit")
        )
        if (
            type(frame) is not int or not 9 <= frame <= (1 << 32) - 10
            or type(kind) is not int or kind != 5
            or type(limit) is not int or not 0 < limit <= frame - 8
        ):
            raise ValueError("hello limits")
        self.frame, self.kind, self.limit = frame, kind, limit

    def push(self, kind, ident, body):
        if kind == self.kind:
            if len(body) < 8 or (self.limit is not None and len(body) - 8 > self.limit):
                raise ValueError("chunk length")
            sequence = struct.unpack_from("<Q", body)[0]
            count, data = self.chunks.setdefault(ident, [0, bytearray()])
            if sequence != count or count == (1 << 64) - 1:
                raise ValueError("chunk sequence")
            data.extend(body[8:])
            self.chunks[ident][0] += 1
            return None
        if kind not in (2, 3):
            raise ValueError("reply kind")
        value = json.loads(body.decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("reply envelope")
        if "stream" in value:
            stream = value["stream"]
            count, data = self.chunks.pop(ident, [0, bytearray()])
            if (
                not isinstance(stream, dict)
                or type(stream.get("chunks")) is not int
                or stream["chunks"] != count
                or type(stream.get("bytes")) is not int
                or stream["bytes"] != len(data)
            ):
                raise ValueError("stream counts")
            if "error" in value:
                return value
            if stream.get("encoding") == "json":
                value = json.loads(data.decode("utf-8"))
                if not isinstance(value, dict):
                    raise ValueError("reply envelope")
            elif stream.get("encoding") == "binary" and "result" in value:
                value = {"result": (value["result"], bytes(data))}
            else:
                raise ValueError("stream encoding")
        elif ident in self.chunks:
            raise ValueError("truncated stream")
        return value

    def finish(self):
        if self.chunks:
            raise ValueError("truncated stream")


class Client:
    def __init__(self, child, root):
        self.child, self.root = child, root
        self.serial = 0
        self.frames = []
        self.actions = []
        self.sent, self.received = bytearray(), bytearray()
        self.collector = Collector()
        self.hello = set()

    def packet(self, method, params=None, ident=None):
        self.serial += 1
        ident = self.serial if ident is None else ident
        if method == "hello":
            self.hello.add(ident)
        body = json.dumps({"method": method, "params": params or {}}).encode()
        return ident, struct.pack("<IBQ", len(body) + 9, 1, ident) + body

    async def write(self, data):
        self.sent.extend(data)
        self.actions.append({"write": data.hex()})
        self.child.stdin.write(data)
        await self.child.stdin.drain()

    async def read(self):
        for _ in itertools.count():
            try:
                header = await asyncio.wait_for(self.child.stdout.readexactly(13), 10)
                length, kind, ident = struct.unpack("<IBQ", header)
                if not 9 <= length <= self.collector.frame + 9:
                    raise ValueError("frame length")
                body = await asyncio.wait_for(
                    self.child.stdout.readexactly(length - 9), 10
                )
            except asyncio.IncompleteReadError:
                self.collector.finish()
                raise
            self.received.extend(header)
            self.received.extend(body)
            result = self.collector.push(kind, ident, body)
            if result is not None:
                if kind == 2 and ident in self.hello:
                    self.hello.remove(ident)
                    if "result" in result:
                        self.collector.configure(result["result"])
                value = (kind, ident, result)
                self.frames.append(value)
                self.actions.append({"read": value})
                return value

    async def result(self, ident, event=None):
        for _ in range(10000):
            kind, key, value = await self.read()
            if key == ident and (kind == 2 or value.get("method") == event):
                return value
        raise AssertionError("Result not found")

    async def request(self, method, params=None, event=None):
        ident, data = self.packet(method, params)
        await self.write(data)
        value = await self.result(ident, event)
        assert "error" not in value, (method, value)
        return ident, value.get("result", value.get("params"))

    def output(self, terminal):
        return b"".join(
            base64.b64decode(value["params"]["bytes"])
            for _, _, value in self.frames
            if value.get("method") == "terminal.output"
            and value["params"]["terminal"] == terminal
        )

    async def until(self, predicate):
        for _ in range(10000):
            if predicate():
                return
            await self.read()
        raise AssertionError("Expected event not found")

    async def stop(self):
        if not self.child.stdin.is_closing():
            self.actions.append({"eof": True})
            self.child.stdin.close()
        try:
            status = await asyncio.wait_for(self.child.wait(), 5)
        except TimeoutError:
            self.child.terminate()
            try:
                await asyncio.wait_for(self.child.wait(), 3)
            except TimeoutError:
                self.child.kill()
                await self.child.wait()
            raise AssertionError("Helper did not settle after UI EOF")
        finally:
            (self.root / "actions.json").write_text(
                json.dumps(self.actions, default=bytes.hex) + "\n"
            )
            (self.root / "frames.json").write_text(
                json.dumps(self.frames, default=bytes.hex) + "\n"
            )
            self.child._stderr.close()
        self.collector.finish()
        return status


async def start(root, options=(), replay=None):
    root.mkdir()
    environment = dict(os.environ)
    environment.pop("DISPATCH_CAPTURE", None)
    environment.pop("DISPATCH_REPLAY", None)
    environment["DISPATCH_REPLAY" if replay else "DISPATCH_CAPTURE"] = str(
        replay or root / "system.jsonl"
    )
    diagnostic = (root / "stderr.log").open("wb")
    child = await asyncio.create_subprocess_exec(
        "/mnt/helper", "--stdio", "--remote", "--cwd", "/mnt", *options,
        env=environment, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=diagnostic,
    )
    child._stderr = diagnostic
    return Client(child, root)


async def replay(client, options=()):
    trace = client.root / "system.jsonl"
    assert trace.exists()
    copy = await start(client.root.with_name(client.root.name + "-replay"), options, trace)
    expected = json.loads((client.root / "actions.json").read_text())
    try:
        for action in expected:
            if "write" in action:
                await copy.write(bytes.fromhex(action["write"]))
            elif "read" in action:
                value = await copy.read()
                assert json.loads(json.dumps(value, default=bytes.hex)) == action["read"], (
                    value, action
                )
            elif "eof" in action:
                copy.child.stdin.close()
        assert await copy.stop() == client.child.returncode
    finally:
        if copy.child.returncode is None:
            await copy.stop()
    assert copy.frames == client.frames


async def one(root, operation, options=()):
    client = await start(root, options)
    try:
        await operation(client)
    finally:
        status = await client.stop()
    assert status == 0, (status, (root / "stderr.log").read_text())
    await replay(client, options)
    return client


async def greeting(root):
    async def check(client):
        _, hello = await client.request("hello")
        assert hello["version"] == 4 and hello["frame_limit"] > 0
        assert "stats.sample" in hello["ops"] and "stats.processes" in hello["ops"]
        assert hello["os"] and hello["arch"]
    return await one(root, check)


async def forbidden(root):
    async def check(client):
        for method in ["exec", "socket", "file.replace", "path.resolve"]:
            ident, data = client.packet(method)
            await client.write(data)
            value = await client.result(ident)
            assert value.get("error", {}).get("code") == "unsupported", (method, value)
        _, result = await client.request("echo", {"after_denial": True})
        assert result == {"after_denial": True}
    return await one(root, check)


async def invalid(root):
    results = []
    async def check(client):
        for params in [{"argv": ["/bin/echo"]}, {"disks": "yes"}, {"disks": 1}, {"extra": None}]:
            ident, data = client.packet("stats.sample", params)
            await client.write(data)
            results.append(await client.result(ident))
        body = b'{"method":"stats.sample","method":"stats.sample","params":{}}'
        await client.write(struct.pack("<IBQ", len(body) + 9, 1, 99) + body)
        results.append(await client.result(99))
    client = await one(root, check)
    codes = [row.get("error", {}).get("code") for row in results]
    assert codes == ["invalid_input"] * 5, codes
    return client


async def workers(root):
    async def check(client):
        packets = [client.packet("stats.sample") for _ in range(16)]
        await client.write(b"".join(data for _, data in packets))
        wanted = {ident for ident, _ in packets}
        replies = []
        for _ in range(10000):
            kind, ident, value = await client.read()
            if kind == 2 and ident in wanted:
                wanted.remove(ident)
                replies.append(value)
            if not wanted:
                break
        assert not wanted and len(replies) == 16
        assert any(value.get("error", {}).get("code") == "stats_busy" for value in replies)
        _, value = await client.request("hello")
        assert value["os"] and value["arch"]
    return await one(root, check)


async def framing(root):
    root.mkdir()
    async def check(client):
        _, hello = await client.request("hello")
        for split in range(1, 14):
            ident, data = client.packet("hello", ident=(1 << 40) + split)
            await client.write(data[:split])
            await client.write(data[split:])
            assert await client.result(ident) == {"result": hello}
    client = await one(root / "fragmented", check)
    limit = client.frames[0][2]["result"]["frame_limit"]
    for index, length in enumerate([0, 8, limit + 10, 0xFFFFFFFF]):
        client = await start(root / ("bad-" + str(index)))
        try:
            await client.write(struct.pack("<IBQ", length, 1, 77))
            status = await asyncio.wait_for(client.child.wait(), 3)
            assert status != 0, (length, status)
            assert "panic" not in (client.root / "stderr.log").read_text()
        finally:
            await client.stop()
        await replay(client)


async def flood(root):
    client = await start(root)
    try:
        payload = json.dumps({"method": "hello", "params": {}}).encode()
        data = b"".join(struct.pack("<IBQ", len(payload) + 9, 1, ident) + payload
                        for ident in range(1, 32769))
        client.child.stdin.write(data)
        await asyncio.wait_for(client.child.wait(), 5)
        assert client.child.returncode != 0
    finally:
        await client.stop()


def native_rows(trace):
    rows = []
    with trace.open() as source:
        for line in source:
            row = json.loads(line)
            assert "invalid" not in row, row
            if row.get("op") != "file.done" or " native " not in row.get("args", ""):
                continue
            value = json.loads(bytes.fromhex(row["data"]))["output"]
            if value["kind"] == "bytes":
                rows.append(json.loads(bytes.fromhex(value["bytes"])))
    return rows


async def stats(root):
    async def check(client):
        _, value = await client.request("stats.sample")
        assert value["boot"] and value["memory"] is not None
        assert "processes" not in value
        _, disks = await client.request("stats.disks")
        assert len(disks) <= 2
        assert len({disk["identity"] for disk in disks}) == len(disks)
        assert "/" in [path for disk in disks for path in disk["paths"]]
    client = await one(root, check)
    rows = native_rows(client.root / "system.jsonl")
    host = next(row for row in rows if "memoryTotal" in row)
    assert host["boot"] == client.frames[0][2]["result"]["boot"]
    assert host["monotonic"] > 0 and host["memoryTotal"] is not None
    return client


async def processes(root):
    results = []
    async def check(client):
        _, (rows, truncated) = await client.request("stats.processes")
        assert isinstance(truncated, bool)
        assert len(rows) <= 4096
        assert any(row["pid"] == client.child.pid for row in rows)
        for row in rows:
            assert set(row) == {"pid", "start", "name", "cpu", "rss"}
            assert len(row["name"].encode()) <= 128
        for params in [{"pid": 1}, {"disks": True}, {"args": []}, {"extra": None}]:
            ident, data = client.packet("stats.processes", params)
            await client.write(data)
            results.append(await client.result(ident))
        body = b'{"method":"stats.processes","method":"stats.processes","params":{}}'
        await client.write(struct.pack("<IBQ", len(body) + 9, 1, 99) + body)
        results.append(await client.result(99))
    client = await one(root, check)
    native = next(row for row in native_rows(client.root / "system.jsonl") if "processes" in row)
    assert native["boot"] and native["monotonic"] > 0 and isinstance(native["truncated"], bool)
    assert len(native["processes"]) <= 4096
    for row in native["processes"]:
        assert set(row) == {"pid", "start", "name", "cpuNanos", "rss"}
        assert len(row["name"].encode()) <= 128 and row["cpuNanos"] >= 0
    codes = [row.get("error", {}).get("code") for row in results]
    assert codes == ["invalid_input"] * 5, codes
    return client


async def terminal(root, kind="terminal"):
    async def check(client):
        _, catalog = await client.request("backends.list")
        backend = next(row for row in catalog if row["default"])
        opened, parent = await client.request("backends.open", {"mux": backend["mux"], "key": backend["key"]}, "backend.opened")
        if kind == "large":
            command = "stty -echo; printf READY; read gate; python3 -c 'import os; os.write(1, b\"x\" * 1500000)'"
        elif kind == "hangup":
            command = "trap 'printf cleaned > /mnt/hangup; exit 0' HUP; printf READY; read answer"
        elif kind == "terminate":
            command = "printf READY; read answer"
        else:
            command = "stty size; printf READY; read answer; stty size; printf 'answer=%s' \"$answer\"; exit 7"
        _, ident = await client.request("terminals.create", {"parent": parent, "command": command})
        attached, _ = await client.request("terminals.attach", {"terminal": ident, "columns": 80, "rows": 24}, "terminal.attached")
        await client.until(lambda: b"READY" in client.output(ident))
        if kind in ["hangup", "terminate"]:
            client.child.send_signal(signal.SIGTERM)
            assert await asyncio.wait_for(client.child.wait(), 3) == 128 + signal.SIGTERM
            if kind == "hangup":
                assert Path("/mnt/hangup").read_bytes() == b"cleaned"
            return
        if kind == "terminal":
            assert b"24 80" in client.output(ident)
            await client.request("terminals.resize", {"terminal": ident, "columns": 120, "rows": 40})
        text = b"begin\r" if kind == "large" else b"hello world\r"
        await client.request("terminals.input", {"terminal": ident, "bytes": list(text)})
        await client.until(lambda: any(value.get("method") == "terminal.exit" and value["params"]["terminal"] == ident
                                      for _, _, value in client.frames))
        events = [value for _, _, value in client.frames if value.get("method") in ["terminal.output", "terminal.exit"]
                  and value["params"]["terminal"] == ident]
        assert events[-1] == {"method": "terminal.exit", "params": {"terminal": ident, "status": 0 if kind == "large" else 7}}
        assert sum(value["method"] == "terminal.exit" for value in events) == 1
        output = client.output(ident)
        if kind == "large":
            assert output.split(b"READY", 1)[1] == b"x" * 1_500_000
        else:
            assert b"40 120" in output and b"answer=hello world" in output
        await client.write(struct.pack("<IBQ", 9, 4, opened) + struct.pack("<IBQ", 9, 4, attached))
        _, value = await client.request("echo", {"barrier": True})
        assert value == {"barrier": True}
    return await one(root, check)


async def backend(root, name):
    root.mkdir()
    options = []
    socket = root / "native.sock"
    if name == "tmux":
        argv = ["/usr/bin/tmux", "-D", "-S", str(socket), "-f", "/dev/null"]
        environment = dict(os.environ)
    else:
        argv = ["/mnt/herdr", "server"]
        environment = dict(os.environ, HERDR_SOCKET_PATH=str(socket), HERDR_SESSION="wire")
        options = ["--herdr", "/mnt/herdr", "--herdr-socket", str(socket), "--herdr-session", "wire"]
    server = await asyncio.create_subprocess_exec(*argv, env=environment, stdin=asyncio.subprocess.DEVNULL,
                                                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    try:
        for _ in range(100):
            if socket.exists():
                break
            assert server.returncode is None
            await asyncio.sleep(0.01)
        assert socket.exists()
        if name == "tmux":
            child = await asyncio.create_subprocess_exec("/usr/bin/tmux", "-S", str(socket), "new-session", "-d", "-s", "fixture", "/bin/sh")
            assert await asyncio.wait_for(child.wait(), 3) == 0
        async def check(client):
            _, rows = await client.request("backends.list")
            mux = next(row["mux"] for row in rows if (row["key"] == "herdr") == (name == "herdr") and not row["default"])
            ident, parent = await client.request("backends.open", {"mux": mux, "key": "herdr" if name == "herdr" else str(socket)}, "backend.opened")
            await client.until(lambda: any(key == ident and value.get("method") == "topology" and value["params"]["nodes"] for _, key, value in client.frames))
            graph = next(value["params"] for _, key, value in client.frames if key == ident and value.get("method") == "topology" and value["params"]["nodes"])
            assert graph["backend"] == parent and graph["nodes"]
            _, value = await client.request("stats.sample")
            assert value["boot"]
            await client.write(struct.pack("<IBQ", 9, 4, ident))
            _, value = await client.request("echo", {"cancelled": True})
            assert value == {"cancelled": True}
            return client
        client = await start(root / "helper", options)
        try:
            await check(client)
        finally:
            assert await client.stop() == 0
    finally:
        if server.returncode is None:
            server.terminate()
            try:
                await asyncio.wait_for(server.wait(), 3)
            except TimeoutError:
                server.kill()
                await server.wait()
    assert server.returncode is not None
    await replay(client, options)
    return client


async def run(root):
    cases = json.loads(Path("/mnt/cases.json").read_text())
    methods = {"greeting": greeting, "forbidden": forbidden, "invalid": invalid, "workers": workers,
               "framing": framing, "flood": flood, "stats": stats, "processes": processes,
               "terminal": terminal, "large": lambda root: terminal(root, "large"),
               "hangup": lambda root: terminal(root, "hangup"), "terminate": lambda root: terminal(root, "terminate"),
               "tmux": lambda root: backend(root, "tmux"), "herdr": lambda root: backend(root, "herdr")}
    report = []
    for index, case in enumerate(cases["cases"], 1):
        row = {key: case[key] for key in ["test", "line", "end", "owner", "scenario", "held"]}
        if case["owner"] == "files":
            row["status"] = "delegated"
        elif case["scenario"] not in methods:
            row["status"] = "blocked"
        else:
            try:
                await asyncio.wait_for(methods[case["scenario"]](root / str(index)), 45)
                row["status"] = "partial" if case["held"] else "pass"
            except Exception:
                row["status"] = "fail"
                row["detail"] = traceback.format_exc()
        report.append(row)
        print(json.dumps(row), flush=True)
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    totals = {status: sum(row["status"] == status for row in report)
              for status in ["pass", "fail", "partial", "blocked", "delegated"]}
    totals["total"] = len(report)
    (root / "counts.json").write_text(json.dumps(totals, indent=2) + "\n")
    print(json.dumps(totals), flush=True)
    return int(any(totals[key] for key in ["fail", "partial", "blocked"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--herdr", type=Path, required=True)
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.inside:
        return asyncio.run(run(root))
    owner = pwd.getpwuid(os.getuid()).pw_dir
    command = ["bwrap", "--ro-bind", "/", "/", "--bind", str(root), "/mnt",
               "--bind", str(root / "home"), owner, "--bind", str(root / "tmp"), "/tmp",
               "--ro-bind", str(args.helper.resolve()), "/mnt/helper",
               "--ro-bind", str(args.herdr.resolve()), "/mnt/herdr",
               "--unshare-net", "--unshare-pid", "--proc", "/proc", "--dev", "/dev",
               "--die-with-parent", "--new-session", "--clearenv", "--setenv", "HOME", owner,
               "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "TMPDIR", "/mnt/tmp",
               "--chdir", "/mnt", "--", "/usr/bin/python3", "/mnt/port.py", "--inside",
               "--root", "/mnt", "--helper", "/mnt/helper", "--herdr", "/mnt/herdr"]
    print(json.dumps({"root": str(root), "command": command, "dry_run": args.dry_run}), flush=True)
    if args.dry_run:
        return
    assert not root.exists()
    for name in ["home", "tmp"]:
        (root / name).mkdir(parents=True)
    source = Path(__file__).resolve()
    for name, path in [("port.py", source), ("cases.json", source.with_name("helper4-wire-cases.json"))]:
        (root / name).write_bytes(path.read_bytes())
    for name in ["helper", "herdr"]:
        (root / name).touch()
    result = subprocess.run(command, capture_output=True, timeout=360)
    (root / "stdout.log").write_bytes(result.stdout)
    (root / "stderr.log").write_bytes(result.stderr)
    provenance = {"command": command, "exit": result.returncode,
                  "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source.parent.parent, text=True).strip(),
                  "inputs": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in
                             [("helper", args.helper), ("herdr", args.herdr), ("driver", source), ("cases", source.with_name("helper4-wire-cases.json"))]}}
    (root / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
    assert (root / "counts.json").exists(), result.stderr.decode(errors="replace")
    print((root / "counts.json").read_text())
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
