#!/usr/bin/env python3
"""SSH servers in a Lima Linux VM for the Swift SSH engine's interoperability tests.

`provision` prepares the VM (create it first: `python3 scripts/ssh-vm.py NAME`): Ubuntu's build tools and its
packaged Dropbear, older Dropbear and OpenSSH releases built from the publishers' tarballs (SHA-256 pinned below and
checked on the host and again in the guest before anything is built) into /opt/dispatch-interop/<release>, three
fictional test accounts with a generated password, and generated user keys of every type the engine supports.
`start` (re)starts every server as a process of its own (pid file; only what this script started is ever stopped), each
on a free loopback port with its own generated host keys, and writes the profile the tests read
(build/ssh-interop/profile.json). `stop` stops them. Idempotent; never touches the guest's system sshd on port 22.

Lima forwards a port a guest process listens on at 127.0.0.1 to the same port on the host's 127.0.0.1, so the servers
are reachable from this Mac only. Secrets, keys and ports stay in the ignored build/ssh-interop.
"""

import argparse
import hashlib
import json
from pathlib import Path
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from setup_consent import load_script  # noqa: E402

STATE = ROOT / "build/ssh-interop"
PROFILE = STATE / "profile.json"
GUEST = "/opt/dispatch-interop"
USER = "interop"
# Logs in with a key and then a password or keyboard-interactive (OpenSSH's AuthenticationMethods), one session at a
# time and no PTY: the refusals.
MFA_USER = "interop-mfa"
# Sees a pre-login banner with a Latin-1 byte (OpenSSH's Match; real servers send such banners). Everyone else's
# banner is UTF-8.
LATIN1_USER = "interop-latin1"
OPENSSL = "openssl-3.0.22"
PACKAGES = ["build-essential", "zlib1g-dev", "libssl-dev", "libpam0g-dev", "libcrypt-dev", "dropbear-bin"]
# Old sources predate C23 (GCC 15's default), -fno-common (GCC 10's) and GCC 14's errors for implicit declarations.
OLD_CFLAGS = ("-O2 -std=gnu17 -fcommon -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types "
              "-Wno-error=int-conversion")

# Releases built from source. OpenSSH digests: https://www.openssh.com/releasenotes.html (base64 there, hex here).
# Dropbear digests: https://matt.ucc.asn.au/dropbear/releases/SHA256SUM.asc (the author's signed list). OpenSSL's:
# openssl-3.0.22.tar.gz.sha256 beside the tarball (https://www.openssl.org/source/ and the GitHub release).
SOURCES = {
    # OpenSSH 9.5p1 and 8.9p1 refuse the guest's OpenSSL 3.5 by version (their configure takes 3.0 and 3.1): they link
    # this one statically, built into its own prefix.
    "openssl-3.0.22": {
        "url": "https://github.com/openssl/openssl/releases/download/openssl-3.0.22/openssl-3.0.22.tar.gz",
        "sha256": "67ebca7e50d17383028045486653492195b83db95f8558709701bb47b5c1ef81",
    },
    "openssh-9.5p1": {
        "url": "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.5p1.tar.gz",
        "sha256": "f026e7b79ba7fb540f75182af96dc8a8f1db395f922bbc9f6ca603672686086b",
    },
    "openssh-8.9p1": {
        "url": "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-8.9p1.tar.gz",
        "sha256": "fd497654b7ab1686dac672fb83dfb4ba4096e8b5ffcdaccd262380ae58bec5e7",
    },
    "openssh-7.9p1": {
        "url": "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-7.9p1.tar.gz",
        "sha256": "6b4b3ba2253d84ed3771c8050728d597c91cfce898713beb7b64a305b6f11aad",
    },
    "dropbear-2022.83": {
        "url": "https://matt.ucc.asn.au/dropbear/releases/dropbear-2022.83.tar.bz2",
        "sha256": "bc5a121ffbc94b5171ad5ebe01be42746d50aa797c9549a4639894a16749443b",
    },
}

# Every server: how it is built or found, and what it can do. `openssl: False` is OpenSSH's --without-openssl (7.x
# takes no OpenSSL 3): only Ed25519 keys, curve25519 key exchange, ChaCha20-Poly1305 and AES-CTR with the HMAC-SHA2 MACs
# remain (no RSA, no ECDSA, no NIST curves, no AES-GCM).
SERVERS = [
    {"name": "openssh-system", "kind": "openssh", "release": "system", "openssl": True, "sshd": "/usr/sbin/sshd",
     "keygen": "/usr/bin/ssh-keygen"},
    {"name": "openssh-9.5p1", "kind": "openssh", "release": "openssh-9.5p1", "openssl": True},
    {"name": "openssh-8.9p1", "kind": "openssh", "release": "openssh-8.9p1", "openssl": True},
    {"name": "openssh-7.9p1", "kind": "openssh", "release": "openssh-7.9p1", "openssl": False},
    {"name": "dropbear-system", "kind": "dropbear", "release": "system", "dropbear": "/usr/sbin/dropbear",
     "keygen": "/usr/bin/dropbearkey"},
    {"name": "dropbear-2022.83", "kind": "dropbear", "release": "dropbear-2022.83"},
]

# Dropbear's build-time options (localoptions.h, its documented way to configure a build) for the release built here:
# a server-started re-exchange after 1 MiB. Its algorithms stay the release's defaults (no AES-GCM).
DROPBEAR_LOCAL_OPTIONS = """#define KEX_REKEY_DATA (1<<20)
"""

# Host keys a server gets (`server_host_keys`).
HOST_KEYS = [("ed25519", "ed25519", None), ("ecdsa256", "ecdsa", 256), ("ecdsa384", "ecdsa", 384),
             ("ecdsa521", "ecdsa", 521), ("rsa", "rsa", 3072)]
# User keys made on the host; `stranger` is never authorized.
USER_KEYS = [("ed25519", "ed25519", None), ("ecdsa256", "ecdsa", 256), ("ecdsa384", "ecdsa", 384),
             ("ecdsa521", "ecdsa", 521), ("rsa2048", "rsa", 2048), ("rsa3072", "rsa", 3072),
             ("rsa4096", "rsa", 4096), ("stranger", "ed25519", None)]
BANNER = "Dispatch interop test server (fictional).\nUTF-8: caf\u00e9.\n".encode("utf-8")
LATIN1_BANNER = "Dispatch interop test server (fictional).\nLatin-1: caf\u00e9.\n".encode("latin-1")

# Signals the processes serving one connection: `interop-signal SERVER PID SIGNAL` takes the pid of a process whose
# ancestors include SERVER's listener (the pid in its pid file) and signals it and its ancestors below the listener,
# nothing else. The tests find the pid with `echo $PPID` over the connection.
SIGNAL_HELPER = r'''#!/usr/bin/python3 -I
import os, signal, sys
server, pid, name = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if not server.replace("-", "").replace(".", "").isalnum() or name not in ("TERM", "KILL", "STOP", "CONT"):
    sys.exit("usage: interop-signal SERVER PID TERM|KILL|STOP|CONT")
listener = int(open(f"/opt/dispatch-interop/run/{server}/server.pid").read().split()[0])
def parent(p):
    with open(f"/proc/{p}/stat") as stat:
        return int(stat.read().rsplit(")", 1)[1].split()[1])
chain, current = [], pid
while current not in (listener, 0, 1):
    chain.append(current)
    current = parent(current)
if current != listener or not chain:
    sys.exit(f"{pid} is not served by {server}'s listener {listener}")
number = getattr(signal, "SIG" + name)
for p in chain:
    os.kill(p, number)
print(" ".join(map(str, chain)))
'''


def instance(name):
    output = subprocess.check_output(["limactl", "list", "--json"], text=True)
    for line in output.splitlines():
        if line.strip():
            item = json.loads(line)
            if item["name"] == name:
                return item
    raise SystemExit(f"No Lima VM {name}: create it with python3 scripts/ssh-vm.py {name}")


class Guest:
    def __init__(self, name):
        self.name = name
        vm = instance(name)
        if vm["status"] != "Running":
            raise SystemExit(f"{name} is {vm['status']}: start it with limactl start {name}")
        if self.run("uname -s", capture=True).strip() != "Linux":
            raise SystemExit("The interop VM must be Linux.")

    def run(self, script, *arguments, capture=False, stdin=None, check=True):
        command = ["limactl", "shell", "--workdir", "/", self.name, "--", "/bin/sh", "-c", script, "dispatch-interop",
                   *arguments]
        if isinstance(stdin, str):
            stdin = stdin.encode()
        result = subprocess.run(command, check=check, input=stdin, stdout=subprocess.PIPE if capture else None)
        return result.stdout.decode() if capture else result

    def write(self, path, content, mode="644", owner="root:root"):
        """Writes `content` (text or bytes) to `path` as root (through stdin: nothing secret on a command line)."""
        self.run('set -eu; tmp=$(mktemp); cat > "$tmp"; sudo -n install -m "$2" -o "${3%:*}" -g "${3#*:}" "$tmp" "$1"; '
                 'rm -f "$tmp"', path, mode, owner, stdin=content)


# MARK: Provisioning

def secrets_file():
    path = STATE / "secrets.json"
    if path.exists():
        return json.loads(path.read_text())
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = {"password": secrets.token_urlsafe(18)}
    path.write_text(json.dumps(data, indent=2) + "\n")
    path.chmod(0o600)
    return data


def user_keys():
    """Generates the user keys once (fictional comments, no passphrase); returns name -> (private path, public line)."""
    directory = STATE / "keys"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    keys = {}
    for name, kind, bits in USER_KEYS:
        private = directory / name
        if not private.exists():
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", kind, *(["-b", str(bits)] if bits else []), "-N", "",
                            "-C", f"interop-{name}@example.invalid", "-f", str(private)], check=True)
        keys[name] = (str(private), (directory / (name + ".pub")).read_text().strip())
    return keys


def install_packages(guest):
    missing = guest.run('for p in "$@"; do dpkg-query -W -f=\'${Status}\\n\' "$p" 2>/dev/null | grep -q "ok installed" '
                        '|| echo "$p"; done', *PACKAGES, capture=True).split()
    if missing:
        print("Installing " + " ".join(missing))
        guest.run('set -eu; sudo -n DEBIAN_FRONTEND=noninteractive apt-get update -qq; '
                  'sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"', *missing)


def build(guest, release):
    record = SOURCES[release]
    prefix = f"{GUEST}/{release}"
    marker = json.dumps({"name": release, "url": record["url"], "sha256": record["sha256"]}, indent=2)
    present = guest.run('cat "$1/source.json" 2>/dev/null || true', prefix, capture=True)
    if present.strip() == marker.strip():
        print(f"{release}: already built")
        return
    archive = load_script("setup-build-tools").download(record, ROOT / "build/downloads")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != record["sha256"]:
        raise SystemExit(f"Checksum mismatch: {archive}")
    staging = guest.run("mktemp -d /tmp/dispatch-interop-XXXXXXXX", capture=True).strip()
    try:
        subprocess.run(["limactl", "copy", str(archive), f"{guest.name}:{staging}/{archive.name}"], check=True)
        if release.startswith("openssl"):
            steps = ('./Configure --prefix="$3" --libdir=lib no-shared no-tests\nmake -j2\n'
                     'sudo -n rm -rf "$3"\nsudo -n make install_sw')
        elif release.startswith("openssh"):
            openssl = next(s for s in SERVERS if s["release"] == release)["openssl"]
            configure = (f'./configure --prefix="$3" --sysconfdir="$3/etc" --with-privsep-path={GUEST}/empty '
                         f'--with-privsep-user=sshd --with-pam --with-sandbox=no --disable-strip '
                         + (f"--with-ssl-dir={GUEST}/{OPENSSL} " if openssl else "--without-openssl ")
                         + f'CFLAGS="{OLD_CFLAGS}"')
            steps = f'{configure}\nmake -j2\nsudo -n rm -rf "$3"\nsudo -n make install-nokeys'
        else:
            steps = (f'printf "%s" "$5" > localoptions.h\n./configure --prefix="$3" --disable-pam --disable-lastlog '
                     f'--disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx CFLAGS="{OLD_CFLAGS}"\n'
                     'make -j2 PROGRAMS="dropbear dropbearkey"\nsudo -n rm -rf "$3"\n'
                     'sudo -n make PROGRAMS="dropbear dropbearkey" install')
        guest.run(f'''
set -eu
cd "$1"
echo "$4  $2" | sha256sum -c -
mkdir src
tar -xf "$2" -C src --strip-components=1
cd src
{steps}
printf '%s\\n' "$6" | sudo -n tee "$3/source.json" >/dev/null
''', staging, archive.name, prefix, record["sha256"], DROPBEAR_LOCAL_OPTIONS, marker)
    finally:
        guest.run('rm -rf -- "$1"', staging)
    print(f"{release}: built into {prefix}")


def provision(guest):
    install_packages(guest)
    guest.run(f'set -eu; sudo -n mkdir -p {GUEST}/bin {GUEST}/run {GUEST}/empty; sudo -n chmod 755 {GUEST}/empty')
    for release in SOURCES:
        build(guest, release)
    guest.write(f"{GUEST}/bin/interop-signal", SIGNAL_HELPER, mode="755")
    password = secrets_file()["password"]
    keys = user_keys()
    authorized = "".join(line + "\n" for name, (_, line) in keys.items() if name != "stranger")
    for account in (USER, MFA_USER, LATIN1_USER):
        guest.run('set -eu; id -u "$1" >/dev/null 2>&1 || sudo -n useradd --create-home --shell /bin/bash "$1"',
                  account)
        guest.run('sudo -n chpasswd', stdin=f"{account}:{password}\n")
        guest.run('set -eu; sudo -n install -d -m 700 -o "$1" -g "$1" "/home/$1/.ssh"', account)
        guest.write(f"/home/{account}/.ssh/authorized_keys", authorized, mode="600", owner=f"{account}:{account}")
    for server in SERVERS:
        host_keys(guest, server)
    print("Provisioned " + guest.name + "; start the servers with: python3 scripts/ssh-interop-vm.py start")


def tools(server):
    if server["release"] == "system":
        return server.get("sshd") or server["dropbear"], server["keygen"]
    prefix = f"{GUEST}/{server['release']}"
    if server["kind"] == "openssh":
        return prefix + "/sbin/sshd", prefix + "/bin/ssh-keygen"
    return prefix + "/sbin/dropbear", prefix + "/bin/dropbearkey"


def server_host_keys(server):
    """OpenSSH without OpenSSL: Ed25519 only. Dropbear loads at most 4 host key files (MAX_HOSTKEYS): no P-384."""
    if server["kind"] == "dropbear":
        return [entry for entry in HOST_KEYS if entry[0] != "ecdsa384"]
    return [entry for entry in HOST_KEYS if server.get("openssl", True) or entry[1] == "ed25519"]


def host_keys(guest, server):
    """Generates the server's host keys once, with its own key tool."""
    run = f"{GUEST}/run/{server['name']}"
    _, keygen = tools(server)
    guest.run('sudo -n install -d -m 700 "$1"', run)
    for name, kind, bits in server_host_keys(server):
        path = f"{run}/host_{name}"
        if server["kind"] == "openssh":
            command = f'{keygen} -q -t {kind} {f"-b {bits}" if bits else ""} -N "" -C "" -f "$1"'
        else:
            command = f'{keygen} -t {kind} {f"-s {bits}" if bits else ""} -f "$1" >/dev/null'
        guest.run(f'set -eu; sudo -n test -e "$1" || sudo -n {command}', path)


# MARK: Servers

def openssh_config(server, port, run, version):
    major, minor = version
    keys = [f"HostKey {run}/host_{name}" for name, _, _ in server_host_keys(server)]
    kbd = "KbdInteractiveAuthentication yes" if (major, minor) >= (8, 7) else "ChallengeResponseAuthentication yes"
    lines = ["ListenAddress 127.0.0.1", f"Port {port}", *keys, f"PidFile {run}/server.pid", "UsePAM yes",
             "PasswordAuthentication yes", kbd, "PubkeyAuthentication yes",
             f"AllowUsers {USER} {MFA_USER} {LATIN1_USER}", "PermitRootLogin no", "MaxAuthTries 3",
             "MaxSessions 64", "MaxStartups 100", "LoginGraceTime 30",
             "ClientAliveInterval 2", "ClientAliveCountMax 2", "RekeyLimit 1M", f"Banner {run}/banner", "UseDNS no",
             "PrintMotd no", "PrintLastLog no", "X11Forwarding no", "AllowTcpForwarding no",
             "AllowAgentForwarding no", "PermitUserEnvironment no", "LogLevel VERBOSE"]
    if (major, minor) >= (9, 8):
        # Every connection comes from 127.0.0.1 (Lima's forwarder), and many end unauthenticated on purpose.
        lines.append("PerSourcePenalties no")
    lines += [f"Match User {MFA_USER}", "  AuthenticationMethods publickey,password publickey,keyboard-interactive",
              "  MaxSessions 1", "  PermitTTY no", f"Match User {LATIN1_USER}", f"  Banner {run}/banner-latin1"]
    return "\n".join(lines) + "\n"


def guest_ports_in_use(guest):
    output = guest.run("ss -Htln", capture=True)
    return {int(fields[3].rsplit(":", 1)[1]) for fields in (line.split() for line in output.splitlines()) if fields}


def host_port_free(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def stop(guest):
    for server in SERVERS:
        run = f"{GUEST}/run/{server['name']}"
        stopped = guest.run(f'''
pidfile="$1/server.pid"
sudo -n test -f "$pidfile" || exit 0
pid=$(sudo -n cat "$pidfile" | head -n 1)
case "$pid" in ''|*[!0-9]*) sudo -n rm -f "$pidfile"; exit 0;; esac
if sudo -n test -r "/proc/$pid/cmdline" && sudo -n tr '\\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "$1/"; then
  sudo -n kill -TERM "$pid"
  for i in $(seq 50); do sudo -n kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  echo "$pid"
fi
sudo -n rm -f "$pidfile"
''', run, capture=True).strip()
        if stopped:
            print(f"{server['name']}: stopped {stopped}")


def identification(port, deadline):
    """The server's SSH identification line through Lima's forwarding (which may take a few seconds to appear)."""
    while True:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=3) as connection:
                data = b""
                while b"\n" not in data:
                    chunk = connection.recv(256)
                    if not chunk:
                        break
                    data += chunk
                line = data.split(b"\n", 1)[0].strip().decode("ascii", "replace")
                if line.startswith("SSH-"):
                    return line
        except OSError:
            pass
        if time.monotonic() > deadline:
            raise SystemExit(f"No SSH server answered on 127.0.0.1:{port}")
        time.sleep(0.5)


def public_lines(guest, server, run):
    lines = {}
    _, keygen = tools(server)
    for name, _, _ in server_host_keys(server):
        if server["kind"] == "openssh":
            text = guest.run('sudo -n cat "$1.pub"', f"{run}/host_{name}", capture=True)
        else:
            text = guest.run(f'sudo -n {keygen} -y -f "$1"', f"{run}/host_{name}", capture=True)
        line = next(l for l in text.splitlines() if l.startswith(("ssh-", "ecdsa-")))
        lines[name] = " ".join(line.split()[:2])
    return lines


# The distribution's sshd separates privileges in /run/sshd, which belongs to the guest's own ssh.service (its
# RuntimeDirectory): systemd removes it whenever that service stops (a package upgrade does it), and from then on the
# interop server on the same binary ends every connection before the login ("chroot("/run/sshd"): No such file or
# directory"). The drop-in keeps the directory across the service's stops; a reboot empties /run, and `start` makes it.
PRIVSEP = "/run/sshd"
PRIVSEP_DROP_IN = "/etc/systemd/system/ssh.service.d/dispatch-interop.conf"


def keep_privsep_directory(guest):
    guest.run('set -eu; sudo -n install -d -m 755 -o root -g root "$1" "$2"', str(Path(PRIVSEP_DROP_IN).parent), PRIVSEP)
    guest.write(PRIVSEP_DROP_IN, "[Service]\nRuntimeDirectoryPreserve=yes\n")
    guest.run("sudo -n systemctl daemon-reload")


def start(guest, base_port):
    stop(guest)
    guest.write(f"{GUEST}/bin/interop-signal", SIGNAL_HELPER, mode="755")
    keep_privsep_directory(guest)
    used = guest_ports_in_use(guest)
    port = base_port
    profile_servers = []
    for server in SERVERS:
        while port in used or not host_port_free(port):
            port += 1
        run = f"{GUEST}/run/{server['name']}"
        binary, _ = tools(server)
        guest.write(f"{run}/banner", BANNER, mode="644")
        guest.write(f"{run}/banner-latin1", LATIN1_BANNER, mode="644")
        if server["kind"] == "openssh":
            version_text = guest.run(f'{binary} -V 2>&1 || true', capture=True)
            number = version_text.split("OpenSSH_", 1)[1].split("p", 1)[0].split(",")[0]
            version = tuple(int(part) for part in number.split(".")[:2])
            guest.write(f"{run}/sshd_config", openssh_config(server, port, run, version), mode="600")
            guest.run(f'set -eu; sudo -n {binary} -t -f "$1/sshd_config"; '
                      f'sudo -n {binary} -f "$1/sshd_config" -E "$1/server.log"', run)
        else:
            # In the foreground (-F) of a session of its own, logging to its file (-E); it still writes the pid file.
            keys = " ".join(f'-r "$1/host_{name}"' for name, _, _ in server_host_keys(server))
            guest.run('set -eu; sudo -n sh -c \'log="$1"; shift; setsid -f "$@" </dev/null >>"$log" 2>&1\' sh '
                      f'"$1/server.log" {binary} -F -E -p 127.0.0.1:{port} {keys} -P "$1/server.pid" '
                      '-b "$1/banner" -T 3 -K 2 -w -j -k', run)
        line = identification(port, time.monotonic() + 30)
        profile_servers.append({
            "name": server["name"], "implementation": server["kind"], "release": server["release"],
            "identification": line, "port": port, "openssl": server.get("openssl", True),
            "hostKeys": public_lines(guest, server, run),
            "keyboardInteractive": server["kind"] == "openssh",
            "multiFactorUser": MFA_USER if server["kind"] == "openssh" else None,
            "latin1BannerUser": LATIN1_USER if server["kind"] == "openssh" else None,
            "serverRekeys": server["kind"] == "openssh" or server["release"] != "system",
            "maxAuthTries": 3, "serverKeepaliveSeconds": 2,
        })
        print(f"{server['name']}: 127.0.0.1:{port}  {line}")
        used.add(port)
        port += 1
    keys = user_keys()
    profile = {
        "vm": guest.name,
        "user": USER, "multiFactorUser": MFA_USER, "password": secrets_file()["password"],
        "banner": BANNER.decode("utf-8"),
        "keys": {name: {"path": path, "public": line} for name, (path, line) in keys.items()},
        "signal": [shutil.which("limactl") or "limactl", "shell", "--workdir", "/", guest.name, "--",
                   "sudo", "-n", f"{GUEST}/bin/interop-signal"],
        "servers": profile_servers,
    }
    PROFILE.write_text(json.dumps(profile, indent=2) + "\n")
    PROFILE.chmod(0o600)
    print(f"Profile: {PROFILE}")
    print("Run: cd Mobile/Transport && swift test --scratch-path ../../build/spm --filter 'Interop(Engine|Session)Tests'")


def status(guest):
    for server in SERVERS:
        run = f"{GUEST}/run/{server['name']}"
        pid = guest.run('sudo -n cat "$1/server.pid" 2>/dev/null | head -n 1', run, capture=True).strip()
        alive = pid and guest.run(f'sudo -n kill -0 {shlex.quote(pid)} 2>/dev/null && echo up || true', capture=True)
        print(f"{server['name']}: {'running, pid ' + pid if alive and alive.strip() else 'stopped'}")
    if not guest.run('sudo -n test -d "$1" && echo there || true', PRIVSEP, capture=True).strip():
        print(f"{PRIVSEP} is missing: openssh-system ends every connection before the login. Run `start` again.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vm", default="dispatch-swift-ssh-interop", help="Lima instance name")
    parser.add_argument("--base-port", type=int, default=42200, help="first port to try (guest and host loopback)")
    parser.add_argument("command", choices=["provision", "start", "stop", "status"])
    args = parser.parse_args()
    if not 1024 < args.base_port < 65000:
        parser.error("Choose a base port between 1025 and 64999")
    guest = Guest(args.vm)
    {"provision": lambda: provision(guest), "start": lambda: start(guest, args.base_port),
     "stop": lambda: stop(guest), "status": lambda: status(guest)}[args.command]()


if __name__ == "__main__":
    main()
