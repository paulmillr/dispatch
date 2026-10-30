#!/usr/bin/env python3
"""Exercise the vendored shell integrations with hostile directory names."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


INTEGRATION = Path(__file__).resolve().parents[1] / "Vendor/Term/Resources/ghostty/shell-integration"


class ShellIntegrationTests(unittest.TestCase):
    def check_directory(self, shell):
        script = (
            'source "$1"; HOSTNAME="$2"; __ghostty_precmd'
            if shell == "bash" else
            'source "$1"; _ghostty_fd=1; _ghostty_deferred_init >/dev/null; '
            'HOST="$2"; _ghostty_report_pwd'
        )
        source = INTEGRATION / shell / ("ghostty.bash" if shell == "bash" else "ghostty-integration")
        flags = ["--noprofile", "--norc", "-ic"] if shell == "bash" else ["-dfi", "-c"]
        host = "host\x07\x1b]52;c;YmFk\x07"
        names = [r"literal\a\e]52;c;YmFk\a", "raw\x07\x1b]52;c;YmFk\x07\n\r\t\x7f"]
        with tempfile.TemporaryDirectory(prefix="dispatch-shell-") as temporary:
            for name in names:
                with self.subTest(shell=shell, name=name):
                    directory = Path(temporary).resolve() / name
                    directory.mkdir()
                    result = subprocess.run(
                        ["/bin/" + shell, *flags, script, shell, str(source), host],
                        cwd=directory, env={"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        timeout=10, check=True,
                    )
                    clean = re.sub(rb"[\x00-\x1f\x7f]", b"", (host + str(directory)).encode())
                    reports = re.findall(rb"\x1b\]7;[^\x07]*\x07", result.stdout)
                    self.assertEqual(reports, [b"\x1b]7;kitty-shell-cwd://" + clean + b"\x07"])
                    self.assertNotIn(b"\x1b]52;", result.stdout)

    def test_bash_directory_cannot_inject_terminal_sequences(self):
        self.check_directory("bash")

    def test_zsh_directory_cannot_inject_terminal_sequences(self):
        self.check_directory("zsh")


if __name__ == "__main__":
    unittest.main()
