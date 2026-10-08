#!/usr/bin/env python3
"""Build cached tmux 3.7c beside system tmux in an existing Linux test VM.

Requires gcc, make, autoconf, automake, bison, pkg-config, libevent-dev and
libncurses-dev in the guest. Never changes /usr/bin/tmux, herdr, or VM images.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
REVISION = "e476c1230b958df0cb12977517d24b3dc931375b"
PREFIX = "/opt/dispatch-test-tools/tmux"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="linux-ssh-tests")
    parser.add_argument("--source", type=Path, default=ROOT / "tmp/tmux")
    args = parser.parse_args()
    subprocess.run(["git", "-C", str(args.source), "cat-file", "-e", REVISION + "^{commit}"], check=True)

    def guest(*command, **kwargs):
        return subprocess.run(["tart", "exec", args.server, *command], check=True, **kwargs)

    if guest("/usr/bin/uname", "-s", capture_output=True, text=True).stdout.strip() != "Linux":
        parser.error("The running test VM must be Linux.")
    directory = guest("/usr/bin/mktemp", "-d", "/tmp/dispatch-tmux-XXXXXXXX", capture_output=True, text=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="dispatch-tmux-source-") as temporary:
        archive = Path(temporary) / "tmux.tar"
        subprocess.run(["git", "-C", str(args.source), "archive", "--format=tar", "--output=" + str(archive), REVISION], check=True)
        with archive.open("rb") as data:
            subprocess.run(["tart", "exec", "-i", args.server, "/bin/tar", "-xf", "-", "-C", directory], stdin=data, check=True)
    guest("/bin/sh", "-c", '''
set -eu
cd "$1"
sh autogen.sh
./configure --prefix="$2"
make -j2
sudo -n make install
printf '%s\\n' "$3" | sudo -n tee "$2/source-revision"
"$2/bin/tmux" -V
/usr/bin/tmux -V
herdr --version
''', "dispatch-tmux-build", directory, PREFIX, REVISION)
    guest("/bin/rm", "-rf", "--", directory)


if __name__ == "__main__":
    main()
