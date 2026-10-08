#!/usr/bin/env python3
"""Launch an agent that exits after paste and record any subsequent shell input."""
import argparse
import os
from pathlib import Path
import select
import subprocess
import termios
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    args.state.mkdir(mode=0o700, parents=True, exist_ok=False)
    original = termios.tcgetattr(0)
    try:
        environment = {**os.environ, "DISPATCH_SUBMISSION_CAPTURE": str(args.state / "paste.bin")}
        result = subprocess.run([args.binary], env=environment)
        (args.state / "exit-status").write_text(str(result.returncode))
        # This is the raw input that the resumed shell would otherwise consume.
        # Observe beyond both production Return delays and chat discovery ticks.
        unexpected = bytearray()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
                data = os.read(0, 4096)
                if not data:
                    break
                unexpected.extend(data)
        (args.state / "shell.bin").write_bytes(unexpected)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, original)
    print("\r\nDISPATCH_SHELL_INPUT_GUARD_DONE", flush=True)


if __name__ == "__main__":
    main()
