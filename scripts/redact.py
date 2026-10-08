#!/usr/bin/env python3
"""What a capture, slice or fixture writer stores: the bytes masked by the repository's one
redaction tool (Helpers/helper4/tools/private.py; needles from DISPATCH_PRIVATE_PATTERNS and this
machine), refused if masking them again would still change something."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("private", ROOT / "Helpers/helper4/tools/private.py")
private = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(private)
_scrubber = private.Scrubber(str(ROOT))


def clean(data: bytes) -> bytes:
    masked = _scrubber.scrub(data)
    if _scrubber.scrub(masked) != masked:
        raise ValueError("private data left after redaction")
    return masked
