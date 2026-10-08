"""Optional local VM/cache inventory; never committed or copied to guests."""
import json
from pathlib import Path


def load():
    path = Path(__file__).resolve().parent.parent / "build/test-environment.json"
    if not path.exists():
        return {}
    if path.stat().st_size > 16384:
        raise RuntimeError("Local test environment configuration is too large")
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or any(not isinstance(value, str) for value in data.values()):
        raise RuntimeError("Local test environment configuration must map names to strings")
    return data
