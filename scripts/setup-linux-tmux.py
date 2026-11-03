#!/usr/bin/env python3
"""Build the pinned tmux beside system tmux in the Lima Linux test VM.

The release and its SHA-256 are the macOS pin's (scripts/test-tools.lock.json `tmux`), downloaded once into
build/downloads and verified there. Requires gcc, make, pkg-config, libevent-dev and libncurses-dev in the guest.
Never changes /usr/bin/tmux, herdr, or VM images; replaces only /opt/dispatch-test-tools/tmux.
"""

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "/opt/dispatch-test-tools/tmux"
sys.path.insert(0, str(ROOT / "scripts"))
from setup_consent import load_script  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="dispatch-rust-ssh-validation", help="Lima instance name")
    args = parser.parse_args()
    record = json.loads((ROOT / "scripts/test-tools.lock.json").read_text())["tmux"]
    artifact = record["archives"]["arm64"]
    archive = load_script("setup-build-tools").download(artifact, ROOT / "build/downloads")
    directory = Path(artifact["binary"]).parts[0]

    def guest(script, *arguments, **kwargs):
        command = ["limactl", "shell", args.server, "--", "/bin/sh", "-c", script, "dispatch-tmux-build", *arguments]
        return subprocess.run(command, check=True, **kwargs)

    if guest("uname -s", capture_output=True, text=True).stdout.strip() != "Linux":
        parser.error("The test VM must be Linux.")
    staging = guest("mktemp -d /tmp/dispatch-tmux-XXXXXXXX", capture_output=True, text=True).stdout.strip()
    try:
        subprocess.run(["limactl", "copy", str(archive), f"{args.server}:{staging}/source.tar.gz"], check=True)
        source = json.dumps({"name": "tmux", "url": artifact["url"], "sha256": artifact["sha256"], "archive": True}, indent=2)
        guest('''
set -eu
cd "$1"
tar -xzf source.tar.gz
cd "$2"
./configure --prefix="$3"
make -j2
sudo -n rm -rf "$3"
sudo -n make install
printf '%s\\n' "$4" | sudo -n tee "$3/source.json" >/dev/null
"$3/bin/tmux" -V
/usr/bin/tmux -V
herdr --version
''', staging, directory, PREFIX, source)
    finally:
        guest('rm -rf -- "$1"', staging)
    print("Installed tmux " + record["version"] + " at " + shlex.quote(PREFIX + "/bin/tmux"))


if __name__ == "__main__":
    main()
