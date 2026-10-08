SCHEMA = bytes([255, 219, 180, 3, 50, 46, 145, 3])
VERSION = int.from_bytes(SCHEMA, 'little')
SYMBOLS = [
":",
"activity",
"add",
"additions",
"after",
"agent",
"answers",
"approval",
"at",
"attention",
"available",
"awaiting_creation",
"axis",
"backend",
"backends.claim",
"backends.command",
"backends.create",
"backends.list",
"backends.open",
"backends.prefix",
"backup",
"before",
"beside",
"binding",
"bindings",
"blocking",
"blocks",
"boot",
"busy",
"bytes",
"capabilities",
"caught_up",
"cell_height",
"cell_width",
"changed",
"changed_ns",
"chat.command",
"chat.models",
"chat.open",
"chat.page",
"chat.send",
"chat.settings",
"chat.settings.set",
"chat.side",
"chat.side.close",
"chat.state",
"chat.stop",
"chat.tools",
"check",
"children",
"choice",
"choices",
"chunks",
"clipboard.request",
"close.request",
"code",
"column",
"columns",
"command",
"compacting",
"completed",
"confirmed_result",
"container",
"containers.create",
"cores",
"cpu",
"cpu_present",
"credit",
"current",
"cursor",
"custom",
"cwd",
"deadline",
"default",
"deletions",
"detached",
"detail",
"device",
"dialog",
"diff",
"directory",
"documents",
"draft",
"earlier",
"echo",
"edit",
"editable",
"editing",
"edits",
"effort",
"enabled",
"encoding",
"end",
"entities.focus",
"entities.rename",
"environment",
"error",
"event",
"exit_code",
"expected",
"failed",
"faint_tail",
"fd",
"file",
"files.branch",
"files.read",
"files.text",
"filters",
"focus",
"follow",
"full",
"generation",
"goal",
"header",
"held",
"hello",
"hold",
"id",
"identity",
"initial",
"inline_reasoning",
"inode",
"input",
"installation.audit",
"installation.install",
"installed",
"interaction",
"interactions.answer",
"interactions.dismiss",
"invalidated",
"item",
"items",
"key",
"keys",
"kind",
"label",
"language",
"launch",
"launches.list",
"layouts",
"layouts.resize",
"layouts.zoom",
"leaf",
"length",
"lines",
"list",
"load",
"max",
"may_have_sent",
"memberships.move",
"memberships.place",
"memberships.reorder",
"memory",
"message",
"method",
"mode",
"model",
"model_label",
"modified_ns",
"modifiers",
"multiple",
"multiplexers.list",
"mux",
"name",
"node",
"nodes",
"offset",
"optional",
"options",
"orchestration",
"output",
"page",
"params",
"parent",
"patch",
"path",
"paths",
"pattern",
"paused",
"peer",
"pending",
"permissions.reduce",
"pid",
"place",
"plugin",
"plugins.reset",
"policy",
"position",
"preview",
"process",
"question",
"questions",
"queue.add",
"queue.edit",
"queue.hold",
"queue.list",
"queue.remove",
"queue.reorder",
"queue.restore",
"queue.start",
"queue.update",
"ratio",
"read",
"read_only",
"reason",
"received_per_second",
"record",
"records",
"reload",
"remove",
"renamed",
"renderer.request",
"reorder",
"repeat",
"repeat_ms",
"reply",
"reset",
"restart",
"restore",
"result",
"revision",
"route",
"row",
"rows",
"rss",
"search",
"secret",
"selection",
"sent_per_second",
"service_tier",
"session",
"shell",
"size",
"snapshot",
"source",
"standard_input",
"start",
"state",
"stats.disks",
"stats.processes",
"stats.sample",
"status",
"stdout",
"stream",
"subscription",
"summary",
"swap",
"swift_tests",
"symbol",
"takeover",
"target",
"terminal",
"terminals.attach",
"terminals.control",
"terminals.create",
"terminals.history",
"terminals.input",
"terminals.keys",
"terminals.observe",
"terminals.publish",
"terminals.ready",
"terminals.release",
"terminals.resize",
"terminals.scroll",
"terminals.seek",
"text",
"time_ms",
"title",
"tool",
"topics",
"total",
"transcript",
"trust",
"tty",
"turn",
"update",
"uptime",
"usage",
"version",
"viewport",
"visible",
"waiting",
"watch",
"work",
"workdir",
"workspace",
"write",
"written",
"zoomed"
]
RECORDS = [
["page", "snapshot", "state"],
["session", "transcript", "process"],
["language", "text"],
["id", "label", "detail"],
["identity", "paths", "total", "available"],
["path", "kind", "diff", "workdir"],
["path", "before", "after", "backup"],
["code", "message"],
["watch", "reset"],
["reply"],
["work", "result", ":"],
["pid", "status"],
["peer", "route", "message", "reply"],
["watch", "pid"],
["fd", "read", "write"],
["at"],
["device", "inode"],
["file", "offset"],
["title", "choice"],
["model"],
["model", "effort"],
["text", "mode", "command"],
["columns", "rows"],
["terminal", "credit"],
["edits", "restart", "installed", "optional", "reload", "trust"],
["id", "key", "approval", "blocking", "questions", "turn", "record"],
["name", "input", "deadline"],
["path"],
["path", "deadline"],
["path", "mode"],
["name", "input"],
["pid"],
["path", "offset", "length"],
["path", "expected"],
["command", "input", "deadline"],
["path", "follow"],
["path", "bytes", "mode", "expected"],
["container", "full", "visible", "focus"],
["choices", "current", "default"],
["kind", "size", "device", "inode", "modified_ns", "changed_ns"],
["id", "key", "parent", "kind", "name", "renamed", "cwd", "size", "agent", "tty", "detached"],
["title", "text"],
["command", "output", "exit_code"],
["status", "stdout"],
["before", "after", "bytes"],
["records", "earlier"],
["parent", "before"],
["target", "axis", "ratio"],
["workspace", "label"],
["label"],
["key", "repeat_ms", "bindings"],
["key", "command", "repeat"],
["id", "header", "text", "secret", "options", "multiple", "custom", "blocks"],
["id", "mode", "revision", "preview", "editable", "editing", "paused", "error"],
["start", "end"],
["id", "turn", "kind", "text", "title", "output", "blocks", "completed", "exit_code", "patch", "documents", "tool", "inline_reasoning", "time_ms", "position"],
["pid", "start", "name", "cpu", "rss"],
["boot", "cpu_present", "cpu", "cores", "load", "memory", "swap", "received_per_second", "sent_per_second", "uptime"],
["text", "cursor", "faint_tail"],
["written", "may_have_sent", "reason"],
["generation", "session", "version", "initial", "caught_up", "invalidated", "awaiting_creation", "file"],
["id", "axis", "children"],
["busy", "activity", "model", "model_label", "effort", "usage", "goal", "draft", "attention", "leaf", "dialog", "title", "version", "pending", "compacting", "service_tier", "mode"],
["waiting", "busy", "activity", "revision"],
["kind", "title", "symbol", "summary", "input", "language", "directory", "failed", "read", "search", "shell", "children", "orchestration", "patch", "confirmed_result", "additions", "deletions"],
["path", "selection", "source"],
["pattern", "paths", "filters", "standard_input"],
["command", "kind", "swift_tests"],
["terminal", "summary"],
["terminal", "process"],
["terminal", "process"],
["bytes"],
["terminal", "status"],
["binding", "page"],
["binding", "interaction"],
["terminal", "bytes"],
["binding", "items", "error"],
["binding", "records"],
["terminal", "offset", "max", "viewport"],
["binding", "state"],
["terminal", "bytes"],
["backend", "key", "nodes", "layouts", "focus"]
]

import math
import struct

DEPTH = 512
_symbols = {name: index for index, name in enumerate(SYMBOLS)}

def encode(value):
    out = bytearray(SCHEMA)
    def text(value):
        data = value.encode("utf-8")
        out.extend(struct.pack("<I", len(data)))
        out.extend(data)
    def write(value, depth):
        if depth == 0:
            raise ValueError("binary nesting limit")
        if value is None:
            out.append(0)
        elif isinstance(value, bool):
            out.append(2 if value else 1)
        elif isinstance(value, int):
            out.append(3 if value >= 0 else 4)
            out.extend(struct.pack("<Q" if value >= 0 else "<q", value))
        elif isinstance(value, float) and math.isfinite(value):
            out.append(5)
            out.extend(struct.pack("<d", value))
        elif isinstance(value, str):
            if value in _symbols:
                out.append(9)
                out.extend(struct.pack("<H", _symbols[value]))
            else:
                out.append(6)
                text(value)
        elif isinstance(value, (list, tuple)):
            out.append(7)
            out.extend(struct.pack("<I", len(value)))
            for item in value:
                write(item, depth - 1)
        elif isinstance(value, dict):
            fields = list(value)
            if fields in RECORDS:
                out.append(10)
                out.extend(struct.pack("<H", RECORDS.index(fields)))
                for item in value.values():
                    write(item, depth - 1)
                return
            out.append(8)
            out.extend(struct.pack("<I", len(value)))
            for key, item in value.items():
                if not isinstance(key, str):
                    raise ValueError("binary keys must be strings")
                index = _symbols.get(key, 65535)
                out.extend(struct.pack("<H", index))
                if index == 65535:
                    text(key)
                write(item, depth - 1)
        else:
            raise ValueError("unsupported binary value")
    write(value, DEPTH)
    return bytes(out)

def decode(data, strings=None, numbers=None):
    view = memoryview(data)
    at = 0
    def take(count):
        nonlocal at
        if count < 0 or count > len(view) - at:
            raise ValueError("truncated binary value")
        result = view[at:at + count]
        at += count
        return result
    def number(shape):
        return struct.unpack(shape, take(struct.calcsize(shape)))[0]
    def text(collect=True):
        count = number("<I")
        begin = at
        value = bytes(take(count)).decode("utf-8")
        if collect and strings is not None:
            strings.append((begin, at))
        return value
    def symbol(index):
        if index >= len(SYMBOLS):
            raise ValueError("unknown binary field")
        return SYMBOLS[index]
    def read(depth, path=()):
        if depth == 0:
            raise ValueError("binary nesting limit")
        tag = number("<B")
        if tag == 0:
            return None
        if tag in (1, 2):
            return tag == 2
        if tag in (3, 4, 5):
            begin = at
            shape = {3: "<Q", 4: "<q", 5: "<d"}[tag]
            value = number(shape)
            if numbers is not None:
                numbers.append((begin, at, shape, path, value))
            if tag == 5 and not math.isfinite(value):
                raise ValueError("invalid binary number")
            return value
        if tag == 6:
            begin = at + 4
            value = text()
            if numbers is not None:
                numbers.append((begin, at, None, path, value))
            return value
        if tag == 9:
            return symbol(number("<H"))
        if tag == 10:
            index = number("<H")
            if index >= len(RECORDS):
                raise ValueError("unknown binary record")
            fields = RECORDS[index]
            if len(fields) > len(view) - at:
                raise ValueError("truncated binary record")
            result = {}
            for key in fields:
                result[key] = read(depth - 1, path + (key,))
            return result
        if tag in (7, 8):
            count = number("<I")
            if count > (len(view) - at) // (1 if tag == 7 else 3):
                raise ValueError("invalid binary count")
            if tag == 7:
                result = []
                for _ in range(count):
                    result.append(read(depth - 1, path + (len(result),)))
                return result
            fields = {}
            for _ in range(count):
                index = number("<H")
                key = text(False) if index == 65535 else symbol(index)
                if key in fields:
                    raise ValueError("duplicate binary field")
                fields[key] = read(depth - 1, path + (key,))
            return fields
        raise ValueError("unknown binary tag")
    if bytes(take(len(SCHEMA))) != SCHEMA:
        raise ValueError("helper binary schema mismatch")
    result = read(DEPTH)
    if at != len(view):
        raise ValueError("trailing binary bytes")
    return result


class Frames:
    """Incremental binary frame decoder; lengths include kind and the u64 ID."""
    def __init__(self, limit=12_000_013):
        self.limit = limit
        self.bytes = bytearray()

    def feed(self, data):
        self.bytes.extend(data)
        frames = []
        at = 0
        for _ in range(len(self.bytes) // 13 + 1):
            if len(self.bytes) - at < 4:
                break
            length = struct.unpack_from("<I", self.bytes, at)[0]
            if length < 9 or length - 9 > self.limit:
                raise ValueError("invalid frame length")
            if len(self.bytes) - at < length + 4:
                break
            kind, identifier = struct.unpack_from("<BQ", self.bytes, at + 4)
            if kind not in (1, 2, 3, 4, 5):
                raise ValueError("invalid frame kind")
            frames.append((kind, identifier, bytes(self.bytes[at + 13:at + 4 + length])))
            at += length + 4
        del self.bytes[:at]
        return frames

    def finish(self):
        if self.bytes:
            raise ValueError("truncated frame")


def frame(kind, identifier, value):
    body = b"" if kind == 4 else encode(value)
    return struct.pack("<IBQ", len(body) + 9, kind, identifier) + body


class Collector:
    """Per-request assembly. Chunk sizes come from hello; budgets come from the caller."""
    def __init__(self, limit, chunk_kind, chunk_limit):
        self.limit = limit
        self.chunk_kind = chunk_kind
        self.chunk_limit = chunk_limit
        self.pending = {}

    def push(self, kind, identifier, body):
        if kind == self.chunk_kind:
            if not 8 < len(body) <= self.chunk_limit + 8:
                raise ValueError("invalid chunk size")
            sequence = struct.unpack_from("<Q", body)[0]
            count, data = self.pending.setdefault(identifier, (0, bytearray()))
            if sequence != count or len(body) - 8 > self.limit - len(data):
                raise ValueError("chunk sequence or byte budget")
            data.extend(body[8:])
            self.pending[identifier] = count + 1, data
            return None
        if kind not in (2, 3):
            raise ValueError("invalid response kind")
        envelope = decode(body)
        stream = envelope.get("stream") if isinstance(envelope, dict) else None
        count, data = self.pending.pop(identifier, (0, bytearray()))
        if stream is None:
            if count or len(body) > self.limit:
                raise ValueError("missing stream metadata or byte budget")
            return kind, identifier, envelope, None
        if not isinstance(stream, dict) or type(stream.get("chunks")) is not int or type(stream.get("bytes")) is not int or stream["chunks"] != count or stream["bytes"] != len(data):
            raise ValueError("stream count mismatch")
        if "error" in envelope:
            return kind, identifier, envelope, None
        if stream.get("encoding") == "value":
            return kind, identifier, decode(data), None
        if stream.get("encoding") == "binary" and "result" in envelope:
            return kind, identifier, envelope["result"], bytes(data)
        raise ValueError("unknown stream encoding")

    def cancel(self, identifier):
        self.pending.pop(identifier, None)

    def finish(self):
        if self.pending:
            raise ValueError("unfinished stream")
