#!/usr/bin/env python3
"""Reuse the manual SSH VM, or create another from the preserved local image."""

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'test'))
from environment import load as load_test_environment


LOCAL_ENVIRONMENT = load_test_environment()
IMAGE = Path(LOCAL_ENVIRONMENT.get("linux_image", str(Path.home() / "VM-Archives/dispatch/ubuntu-26.04-arm64.raw")))
DIGEST = "sha256:7efd5db211147e80053e3e998ab232845b3c10a5aa4e76b6f2c575a84608c863"
HERDR = Path(LOCAL_ENVIRONMENT.get("linux_herdr", str(IMAGE.parent / "herdr-0.9.3-linux-aarch64")))
HERDR_DIGEST = "4de7aa3e25678812e92960de64f7c2aaa1bca1f0f80a3c5e559837e231e1f5c0"


def instances():
    output = subprocess.check_output(["limactl", "list", "--json"], text=True)
    return {item["name"]: item for line in output.splitlines()
            if line.strip() for item in [json.loads(line)]}


def ensure_herdr(vm):
    ssh = ["ssh", "-F", vm["sshConfigFile"], "-o", "BatchMode=yes", vm["hostname"]]
    result = subprocess.run(ssh + [
        "if command -v herdr >/dev/null 2>&1; then "
        "echo 'herdr already installed; leaving it unchanged'; herdr --version; "
        "else exit 44; fi"
    ])
    if result.returncode == 0:
        return
    if result.returncode != 44:
        result.check_returncode()
    if not HERDR.is_file():
        raise SystemExit(f"Local herdr binary missing: {HERDR}. No download will be attempted.")
    if hashlib.sha256(HERDR.read_bytes()).hexdigest() != HERDR_DIGEST:
        raise SystemExit(f"Checksum mismatch: {HERDR}. Refusing to install.")
    with HERDR.open("rb") as binary:
        subprocess.run(ssh + [
            "set -eu; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT; "
            "cat > \"$tmp\"; sudo install -m 755 \"$tmp\" /usr/local/bin/herdr; herdr --version"
        ], stdin=binary, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name", nargs="?", default=LOCAL_ENVIRONMENT.get("manual_ssh_vm", "dispatch-manual-ssh"))
    parser.add_argument("--cpus", type=int, help="CPU count for a new independent test VM")
    parser.add_argument("--memory-gib", type=int, help="Memory in GiB for a new independent test VM")
    args = parser.parse_args()
    if args.cpus is not None and not 1 <= args.cpus <= 16:
        parser.error("Choose 1–16 CPUs")
    if args.memory_gib is not None and not 1 <= args.memory_gib <= 32:
        parser.error("Choose 1–32 GiB of memory")
    existing = instances().get(args.name)
    if existing:
        if (args.cpus is not None and existing["cpus"] != args.cpus) or (args.memory_gib is not None and existing["memory"] != args.memory_gib * 1024**3):
            parser.error("Resource options only provision a new VM; the existing VM is unchanged")
        subprocess.run(["limactl", "start", "-y", args.name], check=True)
    else:
        if not IMAGE.is_file():
            parser.error(f"Local image missing: {IMAGE}. No download will be attempted.")
        config = {
            "minimumLimaVersion": "2.0.0",
            "param": {"internal_netplanOptional": "true"},
            "vmType": "vz", "arch": "aarch64", "cpus": args.cpus or 1,
            "memory": f"{args.memory_gib or 1}GiB", "disk": "8GiB", "mounts": [],
            "images": [{"location": str(IMAGE), "arch": "aarch64", "digest": DIGEST}],
            "containerd": {"system": False, "user": False},
            "ssh": {"loadDotSSHPubKeys": False, "forwardAgent": False},
            "upgradePackages": False,
        }
        with tempfile.TemporaryDirectory(prefix="dispatch-ssh-") as temporary:
            template = Path(temporary) / "vm.yaml"
            template.write_text(json.dumps(config))
            subprocess.run(["limactl", "start", "-y", "--name", args.name,
                            str(template)], check=True)
    vm = instances()[args.name]
    ensure_herdr(vm)
    print("Connect: " + shlex.join([
        "ssh", "-i", vm["IdentityFile"], "-p", str(vm["sshLocalPort"]),
        vm["config"]["user"]["name"] + "@" + vm["sshAddress"],
    ]))


if __name__ == "__main__":
    main()
