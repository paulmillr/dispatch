#!/usr/bin/env python3
"""Drive a private real tmux/helper from the Swift client and capture its IO."""
import argparse
import asyncio
import json
import re
import os
from pathlib import Path
import shutil
import socket

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--helper", type=Path, required=True)
parser.add_argument("--probe", type=Path, required=True)
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--dry-run", action="store_true")
args = parser.parse_args()
if args.dry_run:
    print("Create new private root/home; start owned tmux/helper; create alpha/beta with both split axes")
    print("Pass actual Unix socket FD to Swift; compare whole topology with native list-panes")
    print("Capture actual notify/cancel/echo; finally terminate only owned children and remove sockets")
    raise SystemExit(0)
args.root = args.root.resolve()
# The tmux multiplexer's index is its registration order in the helper's main.rs.
main = (Path(__file__).resolve().parents[1] / "Helpers/helper4/bin/src/main.rs").read_text()
main = main[main.rindex("let mut helper = DispatchHelper::new();"):]
tmux_mux = re.findall(r"add_multiplexer\(\s*dispatch_helper4_(\w+)::", main).index("tmux")
args.helper = args.helper.resolve()
args.probe = args.probe.resolve()
args.root.mkdir(mode=0o700, parents=True, exist_ok=False)
home = args.root / "home"
home.mkdir(mode=0o700)
env = dict(os.environ, HOME=str(home))
env.pop("TMUX", None)
env.pop("TMUX_PANE", None)
# Wherever this system installs it (/usr/bin on Linux, Homebrew on macOS).
TMUX = shutil.which("tmux")
assert TMUX, "tmux is not on PATH"
children, files = [], []


async def start(command, name, extra=None, **kwargs):
    file = (args.root / (name + ".log")).open("wb")
    files.append(file)
    child = await asyncio.create_subprocess_exec(*map(str, command), cwd=args.root,
        env=env | (extra or {}), stdout=file, stderr=file, **kwargs)
    children.append(child)
    return child


async def connect(path, child):
    for _ in range(500):
        peer = socket.socket(socket.AF_UNIX)
        peer.setblocking(False)
        try:
            await asyncio.get_running_loop().sock_connect(peer, str(path))
            return peer
        except (FileNotFoundError, ConnectionRefusedError):
            peer.close()
            if child.returncode is not None:
                raise
            await asyncio.sleep(0.01)
    raise TimeoutError(str(path))


async def tmux(*argv):
    child = await asyncio.create_subprocess_exec(TMUX, "-S", "tmux.sock", *argv,
        cwd=args.root, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, error = await asyncio.wait_for(child.communicate(), 5)
    if child.returncode:
        raise RuntimeError(error.decode())
    return out


async def run():
    try:
        server = await start([TMUX, "-D", "-S", "tmux.sock", "-f", "/dev/null"], "tmux")
        peer = await connect(args.root / "tmux.sock", server)
        peer.close()
        for name in ("alpha", "beta"):
            await tmux("new-session", "-d", "-s", name, "-c", "/usr", "/bin/sh")
        await tmux("split-window", "-h", "-t", "alpha", "-c", "/usr", "/bin/sh")
        await tmux("split-window", "-v", "-t", "beta", "-c", "/usr", "/bin/sh")
        panes = (await tmux("list-panes", "-a", "-F", "#{pane_id}")).decode().splitlines()
        for pane in panes:
            await tmux("select-pane", "-t", pane, "-T", "captured terminal")
        native = await tmux("list-panes", "-a", "-F",
            "#{session_id}\t#{session_name}\t#{window_id}\t#{window_name}\t#{pane_id}\t#{pane_title}\t#{pane_current_path}\t#{pane_width}\t#{pane_height}")
        (args.root / "native-topology.tsv").write_bytes(native)
        helper = await start([args.helper, "--socket", "app.sock"], "helper",
                             {"DISPATCH_CAPTURE": str(args.root / "capture.jsonl")})
        peer = await connect(args.root / "app.sock", helper)
        probe = await start([args.probe, peer.fileno(), "tmux.sock", "swift-topology.json", tmux_mux],
                            "swift", pass_fds=(peer.fileno(),))
        peer.close()
        assert await asyncio.wait_for(probe.wait(), 10) == 0, "Swift probe failed (swift.log)"
        nodes = json.loads((args.root / "swift-topology.json").read_text())["nodes"]
        keys = {node["id"]: node["key"].rsplit(":", 1)[-1] for node in nodes}
        actual = {keys[n["id"]]: dict(key=keys[n["id"]], parent=keys.get(n["parent"]),
            kind=n["kind"], name=n["name"], cwd=n["cwd"], size=n["size"]) for n in nodes}
        expected = {}
        for line in native.decode().splitlines():
            sid, session, wid, window, pid, title, cwd, cols, rows = line.split("\t")
            # A session the app never grouped is one space named by its directory (legacy default
            # usesDirectoryName; tmux affinity.rs display), i.e. its first pane's cwd basename.
            expected.setdefault(sid, dict(key=sid, parent=None, kind="workspace", name=Path(cwd).name or "/", cwd=None, size=None))
            expected[wid] = dict(key=wid, parent=sid, kind="tab", name=window, cwd=None, size=None)
            expected[pid] = dict(key=pid, parent=wid, kind="terminal", name=title, cwd=cwd,
                                 size=dict(columns=int(cols), rows=int(rows)))
        (args.root / "comparison.json").write_text(json.dumps(dict(actual=actual, expected=expected), indent=2))
        assert actual == expected, "Swift/native topology mismatch (comparison.json)"
        print("PASS: Swift client -> real Unix helper -> real tmux; whole topology equal, cancel+echo complete")
    finally:
        for child in reversed(children):
            if child.returncode is None:
                child.terminate()
                try:
                    await asyncio.wait_for(child.wait(), 3)
                except TimeoutError:
                    child.kill()
                    await child.wait()
        for file in files:
            file.close()
        for name in ("app.sock", "tmux.sock"):
            (args.root / name).unlink(missing_ok=True)


asyncio.run(run())
