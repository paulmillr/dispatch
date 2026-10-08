#!/usr/bin/env python3
"""Capture real common request/reply frames from one owned helper stdio process.

The written files go through redact.clean (scripts/redact.py): machine and run data are masked,
and the write is refused if some remains."""
import argparse
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import struct

import redact

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--assembly-sha', required=True)
parser.add_argument('--dry-run', action='store_true')
parser.add_argument('methods', nargs='+')
args = parser.parse_args()
if args.dry_run:
    print(json.dumps(dict(helper=str(args.helper), output=str(args.output),
                         methods=args.methods, cleanup='Terminate only the owned helper child.'), indent=2))
    raise SystemExit(0)


async def run():
    args.output.mkdir(mode=0o700, exist_ok=False)
    home = args.output / 'home'
    home.mkdir(mode=0o700)
    frames = {'read': [], 'write': []}
    with (args.output / 'stderr.log').open('xb') as log:
        child = await asyncio.create_subprocess_exec(
            str(args.helper), '--stdio', cwd=args.output,
            env=dict(os.environ, HOME=str(home)), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=log)
        try:
            for identifier, method in enumerate(args.methods, 1):
                body = json.dumps(dict(method=method, params={}), separators=(',', ':')).encode()
                header = struct.pack('<IBQ', len(body) + 9, 1, identifier)
                wire = header + body
                frames['read'].append(dict(kind=1, id=identifier,
                    body=base64.b64encode(body).decode(), wire=base64.b64encode(wire).decode()))
                child.stdin.write(wire)
                await child.stdin.drain()
                header = await asyncio.wait_for(child.stdout.readexactly(13), 5)
                length, kind, identity = struct.unpack('<IBQ', header)
                assert kind == 2 and identity == identifier and 9 <= length <= 1048585
                body = await asyncio.wait_for(child.stdout.readexactly(length - 9), 5)
                frames['write'].append(dict(kind=kind, id=identity,
                    body=base64.b64encode(body).decode(), wire=base64.b64encode(header + body).decode()))
                (args.output / (method + '.json')).write_bytes(redact.clean(body))
        finally:
            if child.returncode is None:
                child.terminate()
                try:
                    await asyncio.wait_for(child.wait(), 3)
                except asyncio.TimeoutError:
                    child.kill()
                    await child.wait()
    (args.output / 'frames.json').write_bytes(redact.clean((json.dumps(dict(frames=frames), indent=2) + '\n').encode()))
    (args.output / 'provenance.json').write_bytes(redact.clean((json.dumps(dict(
        helper=args.helper.name, sha256=hashlib.sha256(args.helper.read_bytes()).hexdigest(),
        assembly_sha=args.assembly_sha,
        capture_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()), indent=2) + '\n').encode()))


asyncio.run(run())
