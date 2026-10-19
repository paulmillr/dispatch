#!/usr/bin/env python3
"""A loopback sshd for the iPhone transport's simulator tests (the simulator shares the Mac's network).

  start ROOT   create ROOT (short: /tmp/sim-…), keys, config; start sshd as the current user; print the
               profile path (ROOT/profile.json) for TEST_RUNNER_DMS_FIXTURE
  stop ROOT    stop that sshd (its pid file, checked against the command line) and remove ROOT

Same configuration as Mobile/Transport/Tests/MobileTransportTests/SSHFixture.swift: a private HOME, helper
test root and tmux/herdr socket paths under ROOT, so nothing touches the account's own."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time


def keygen(path, kind="ed25519"):
    subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", kind, "-N", "", "-f", str(path)], check=True)


def start(root):
    if not str(root).startswith("/tmp/sim-"):
        sys.exit("ROOT must be a short /tmp/sim-… path")
    if root.exists():
        sys.exit(f"{root} exists")
    root.mkdir(mode=0o700)
    home = root / "home"
    home.mkdir(mode=0o700)
    keygen(root / "host_ed25519")
    keygen(root / "user_ed25519")
    (root / "authorized_keys").write_text((root / "user_ed25519.pub").read_text())
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    (root / "sshd_config").write_text("\n".join([
        "ListenAddress 127.0.0.1", f"Port {port}", f"HostKey {root}/host_ed25519",
        f"AuthorizedKeysFile {root}/authorized_keys", f"PidFile {root}/sshd.pid", "StrictModes no", "UsePAM no",
        "PasswordAuthentication no", "KbdInteractiveAuthentication no", "PubkeyAuthentication yes",
        f"SetEnv HOME={home} DISPATCH_TEST_ROOT={root}/dt TMUX_TMPDIR={root} HERDR_SOCKET_PATH={root}/herdr.sock "
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin TZ=UTC",
        "LogLevel ERROR", ""]))
    # Without -D sshd forks into the background and writes its pid file.
    subprocess.run(["/usr/sbin/sshd", "-f", str(root / "sshd_config"), "-E", str(root / "sshd.log")], check=True)
    for _ in range(200):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.05)
    host_key = " ".join((root / "host_ed25519.pub").read_text().split()[:2])
    profile = {"host": "127.0.0.1", "port": port, "user": os.environ.get("USER") or os.getlogin(),
               "hostKey": host_key, "keyFile": str(root / "user_ed25519"),
               "helpers": str(Path(__file__).resolve().parent.parent / "build/helper-rust/bin"), "home": str(home)}
    (root / "profile.json").write_text(json.dumps(profile, indent=2))
    print(root / "profile.json")


def stop(root):
    pid_file = root / "sshd.pid"
    if pid_file.is_file():
        pid = int(pid_file.read_text().split()[0])
        command = subprocess.run(["/bin/ps", "-ww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        # sshd retitles itself; the title keeps the config path's start.
        if "sshd" in command and str(root) in command:
            os.kill(pid, 15)
    if str(root).startswith("/tmp/sim-"):
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("start", "stop"):
        sys.exit(__doc__)
    (start if sys.argv[1] == "start" else stop)(Path(sys.argv[2]))
