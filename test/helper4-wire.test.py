"""The common Python client consumes unchanged production helper stream vectors."""

import asyncio
import base64
import importlib.util
import json
from pathlib import Path
import struct
from types import SimpleNamespace
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("wire", root / "test/helper4-wire.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)
fixture = json.loads(
    (root / "DispatchTests/HelperClient/Fixtures/streamed-replies.json").read_text()
)


def frames(name):
    return [
        (row["kind"], row["id"], base64.b64decode(row["body"]))
        for row in fixture["frames"][name]
    ]


class Streams(unittest.IsolatedAsyncioTestCase):
    async def test_real_capture_returns_whole_large_and_small_replies(self):
        reader = asyncio.StreamReader()
        raw = b"".join(
            base64.b64decode(row["wire"]) for row in fixture["frames"]["write"]
        )
        reader.feed_data(raw)
        reader.feed_eof()
        client = wire.Client(SimpleNamespace(stdout=reader), root)
        actual = [await client.read() for _ in range(3)]
        inputs = [json.loads(body.decode()) for _, _, body in frames("read")]
        self.assertEqual(
            actual,
            [
                (2, 1, json.loads(frames("write")[0][2])),
                (2, 2, {"result": inputs[1]["params"]}),
                (2, 3, {"result": inputs[2]["params"]}),
            ],
        )
        self.assertEqual(bytes(client.received), raw)
        client.collector.finish()

    async def test_interleaved_json_binary_and_notifications(self):
        collector = wire.Collector()
        actual = []
        original = frames("write")
        binary = frames("binary")
        schedule = [original[0], (3, 99, b'{"method":"tick","params":{}}')]
        for index in range(max(len(original) - 1, len(binary))):
            if index < len(binary):
                kind, _, body = binary[index]
                schedule.append((kind, 55, body))
            if index + 1 < len(original):
                schedule.append(original[index + 1])
        for kind, ident, body in schedule:
            value = collector.push(kind, ident, body)
            if value is not None:
                actual.append((kind, ident, value))
        inputs = [json.loads(body.decode()) for _, _, body in frames("read")]
        self.assertEqual(
            actual,
            [
                (2, 1, json.loads(original[0][2])),
                (3, 99, {"method": "tick", "params": {}}),
                (2, 55, {"result": ({"mime": "image/png"}, bytes(i % 256 for i in range(200000)))}),
                (2, 2, {"result": inputs[1]["params"]}),
                (2, 3, {"result": inputs[2]["params"]}),
            ],
        )
        collector.finish()

    async def test_gaps_counts_encoding_and_eof_are_protocol_errors(self):
        chunk = struct.pack("<Q", 0) + b"{}"
        end = {"stream": {"chunks": 1, "bytes": 2, "encoding": "json"}}
        cases = [
            [(5, 1, struct.pack("<Q", 1) + b"{}")],
            [(5, 1, b"short")],
            [(5, 1, chunk), (5, 1, chunk)],
            [(5, 1, chunk), (2, 1, b'{"result":{}}')],
            [(5, 1, chunk)],
        ]
        for key, value in [("chunks", 2), ("bytes", 3), ("encoding", "unknown"), ("chunks", True)]:
            changed = {"stream": dict(end["stream"], **{key: value})}
            cases.append([(5, 1, chunk), (2, 1, json.dumps(changed).encode())])
        failed = []
        for schedule in cases:
            collector = wire.Collector()
            try:
                for message in schedule:
                    collector.push(*message)
                collector.finish()
            except ValueError:
                failed.append(True)
            else:
                failed.append(False)
        self.assertEqual(failed, [True] * len(cases))

    async def test_negotiated_bounds_and_failed_stream_cleanup(self):
        collector = wire.Collector()
        hello = {"result": {"version": 4, "frame_limit": 100, "chunk_kind": 5, "chunk_limit": 2}}
        collector.configure(hello["result"])
        self.assertEqual(collector.push(2, 1, json.dumps(hello).encode()), hello)
        with self.assertRaises(ValueError):
            collector.push(5, 2, struct.pack("<Q", 0) + b"big")
        collector = wire.Collector()
        collector.push(5, 2, struct.pack("<Q", 0) + b"partial")
        error = {"stream": {"chunks": 1, "bytes": 7, "encoding": "binary"}, "error": {"code": "changed"}}
        self.assertEqual(collector.push(2, 2, json.dumps(error).encode()), error)
        collector.finish()

    async def test_echo_json_does_not_configure_transport(self):
        collector = wire.Collector()
        value = {"result": {"version": 4, "frame_limit": "opaque native data"}}
        self.assertEqual(collector.push(2, 9, json.dumps(value).encode()), value)
        self.assertEqual((collector.kind, collector.limit, collector.frame), (5, None, 12000013))


if __name__ == "__main__":
    unittest.main()
