#!/usr/bin/env python3
"""Run host-detection tests from the macOS VM against an archived Linux SSH VM."""
import argparse
import fcntl
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("test_vm", ROOT / "test/vm.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vm", default="dispatch-tests")
    parser.add_argument("--server", default="dispatch-host-detection-tests")
    args = parser.parse_args()
    if args.server == "dispatch-manual-ssh":
        parser.error("The manual SSH VM is reserved for the user.")
    for name in (args.vm, args.server):
        if not name or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name):
            parser.error("Use simple VM names.")
    with (Path(tempfile.gettempdir()) / ("dispatch-vm-" + args.vm + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        subprocess.run([sys.executable, "scripts/ssh-vm.py", args.server], cwd=ROOT, check=True)
        entries = subprocess.check_output(["limactl", "list", "--json"], text=True).splitlines()
        vm = next(json.loads(line) for line in entries if json.loads(line)["name"] == args.server)

        def remote(*command, **kwargs):
            return subprocess.run(["ssh", "-F", vm["sshConfigFile"], "-o", "BatchMode=yes", vm["hostname"], shlex.join(command)], check=True, **kwargs)

        runner.start(args.vm)
        client = runner.GUEST + "/host-linux-ssh"
        runner.shell(args.vm, 'umask 077; mkdir -p "$1"; test -f "$1/key" || ssh-keygen -q -t ed25519 -N "" -f "$1/key"', client)
        public = runner.guest(args.vm, "/bin/cat", client + "/key.pub", capture_output=True, text=True).stdout.strip()
        remote("python3", "-c", """
import os,sys
from pathlib import Path
directory = Path.home() / '.ssh'
directory.mkdir(mode=0o700, exist_ok=True)
path = directory / 'authorized_keys'
lines = path.read_text().splitlines() if path.exists() else []
if sys.argv[1] not in lines:
    with path.open('a') as file: file.write(('\\n' if lines else '') + sys.argv[1] + '\\n')
os.chmod(path, 0o600)
""", public)
        host_key = remote("cat", "/etc/ssh/ssh_host_ed25519_key.pub", capture_output=True, text=True).stdout.strip()
        user = remote("id", "-un", capture_output=True, text=True).stdout.strip()
        remote("sh", "-c", "uname -s; herdr --version; tmux -V")
        with runner.ssh_bridge(args.vm, vm["sshAddress"], vm["sshLocalPort"]) as (gateway, port):
            options = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes",
                       "-o", "UserKnownHostsFile=" + client + "/known_hosts", "-i", client + "/key", "-p", str(port),
                       "-o", "HostName=" + gateway, "-o", "HostKeyAlias=dispatch-host-detection-linux", "-o", "ConnectTimeout=5"]
            profile = {"destination": user + "@dispatch-host-detection-linux", "options": options}
            runner.guest(args.vm, "/usr/bin/python3", "-c", """
import os,sys
from pathlib import Path
os.umask(0o077)
Path(sys.argv[1] + '/known_hosts').write_text(sys.argv[2] + '\\n')
Path(sys.argv[1] + '.json').write_text(sys.argv[3])
""", client, "dispatch-host-detection-linux " + host_key, json.dumps(profile))
            try:
                return runner.test_guest(args.vm, ["DispatchTests/HostLinuxIntegrationTests"])
            finally:
                runner.guest(args.vm, "/bin/rm", "-f", client + ".json")


if __name__ == "__main__":
    raise SystemExit(main())
