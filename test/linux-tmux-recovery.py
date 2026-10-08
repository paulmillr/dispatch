#!/usr/bin/env python3
"""Exercise production tmux recovery lookup over SSH in an existing test VM."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", default="dsptch_vm-rust-ssh-validation")
    parser.add_argument("--helper", type=Path, required=True)
    args = parser.parse_args()
    if "manual" in args.server:
        parser.error("Manual SSH VMs are reserved for the user.")
    entries = subprocess.check_output(["limactl", "list", "--json"], text=True)
    vm = next(json.loads(line) for line in entries.splitlines() if json.loads(line)["name"] == args.server)
    if vm["status"] != "Running":
        parser.error("Start the dedicated validation VM first.")
    ssh = ["ssh", "-F", vm["sshConfigFile"], "-o", "BatchMode=yes", vm["hostname"]]

    def remote(*command, check=True, **kwargs):
        return subprocess.run(ssh + [shlex.join(command)], check=check, capture_output=True, timeout=15, **kwargs)

    root = remote("mktemp", "-d", "/tmp/dispatch-recovery-XXXXXXXX").stdout.decode().strip()
    helper = root + "/helper"
    tokens = []
    sockets = [root + "/first.sock", root + "/other.sock"]
    try:
        data = args.helper.read_bytes()
        remote("python3", "-c", "import os,sys; p=sys.argv[1]; open(p,'wb').write(sys.stdin.buffer.read()); os.chmod(p,0o700)", helper, input=data)
        system = remote("uname", "-sm").stdout.decode().strip()
        assert system == "Linux aarch64", system
        tmux = remote("sh", "-c", "command -v tmux").stdout.decode().strip()
        marker = str(uuid.uuid4())

        def native(socket, *command):
            return remote(tmux, "-S", socket, "-f", "/dev/null", *command).stdout.decode().strip()

        marked = []
        for socket in sockets:
            native(socket, "new-session", "-d", "-s", "fixture", "sleep 120")
            marked.append(native(socket, "new-window", "-d", "-P", "-F", "#{pane_pid}",
                                 "-e", "DISPATCH_TMUX_CREATION=" + marker,
                                 "-e", "SECRET=must-not-be-returned", "sleep 120"))
        identity = native(sockets[0], "display-message", "-p", "#{pid} #{session_id} #{pane_pid}").split()
        identity[2] = marked[0]
        other = marked[1]
        token = remote(helper, "remember-tmux", sockets[0], identity[0], identity[1].removeprefix("$")).stdout.decode()
        tokens.append(token)
        result = remote(helper, "tmux-creations", token, identity[2] + "," + other)
        assert json.loads(result.stdout) == {identity[2]: marker}, result.stdout
        # Running from an arbitrary remote process must not bypass the direct
        # SSH origin requirement, even with a valid account-private token.
        remote("python3", "-c",
                           "import subprocess,sys; p=subprocess.run(sys.argv[1:],capture_output=True); "
                           "assert p.returncode != 0 and not p.stdout", helper, "tmux-creations", token, identity[2])
        pids = native(sockets[0], "list-panes", "-a", "-F", "#{pane_pid}").splitlines()
        result = remote(helper, "tmux-creations", token, ",".join(pids))
        assert json.loads(result.stdout) == {identity[2]: marker}, result.stdout
        for invalid in ["0", "-1", "abc", ",".join([identity[2]] * 1025)]:
            assert remote(helper, "tmux-creations", token, invalid, check=False).returncode != 0
        # Probe durable command identity independently of the process's live
        # environment. This hook belongs only to this disposable fixture.
        native(sockets[0], "set-hook", "-g", "after-new-window[0]",
               'set-option -wF @creation-test "#{hook_flag_e_0}"')
        cleared_window, cleared_pid = native(sockets[0], "new-window", "-d", "-P", "-F", "#{window_id} #{pane_pid}",
                                            "-e", "DISPATCH_TMUX_CREATION=" + marker,
                                            "/usr/bin/env", "-i", "/bin/sleep", "120").split()
        # The native client completes after its synchronous hook; confirm the
        # actual pane is running sleep with no marker, not still starting env.
        remote("python3", "-c", "import pathlib,sys,time; p=pathlib.Path('/proc')/sys.argv[1]; "
               "deadline=time.monotonic()+3\nwhile p.joinpath('comm').read_text().strip() != 'sleep' and time.monotonic()<deadline: time.sleep(.01)\n"
               "assert p.joinpath('comm').read_text().strip() == 'sleep'\n"
               "assert b'DISPATCH_TMUX_CREATION=' not in p.joinpath('environ').read_bytes()", cleared_pid)
        assert json.loads(remote(helper, "tmux-creations", token, cleared_pid).stdout) == {}
        assert native(sockets[0], "show-options", "-wv", "-t", cleared_window, "@creation-test") == "DISPATCH_TMUX_CREATION=" + marker
        # Test a server-owned creation job: its client writes the creation
        # reply to disk while an unchanged user hook is still waiting.
        receipt, started, finished = (root + "/" + name for name in ("creation-reply", "hook-started", "hook-finished"))
        hook = "touch " + shlex.quote(started) + "; sleep 2; touch " + shlex.quote(finished)
        native(sockets[0], "set-hook", "-g", "after-new-window", "run-shell " + shlex.quote(hook))
        before_panes = set(native(sockets[0], "list-panes", "-a", "-F", "#{pane_id}").splitlines())
        create = shlex.join([tmux, "-S", sockets[0], "new-window", "-d", "-P", "-F", "#{window_id}|#{pane_id}",
                            "/usr/bin/env", "-i", "/bin/sleep", "120"])
        save = ("IFS='|' read -r window pane; " + shlex.join([tmux, "-S", sockets[0], "set-option", "-w", "-t"])
                + ' "$window" @creation-test ' + shlex.quote(marker)
                + '; printf \'%s|%s\\n\' "$window" "$pane" > ' + shlex.quote(receipt))
        # run-shell performs its own format expansion before invoking sh. Keep
        # the inner client's new-window format intact until it has a new target.
        native(sockets[0], "run-shell", "-b", (create + " | { " + save + "; }").replace("#", "##"))
        remote("python3", "-c", "import pathlib,sys,time; reply,start,finish=map(pathlib.Path,sys.argv[1:]); "
               "deadline=time.monotonic()+1.5\nwhile (not reply.exists() or not reply.read_text().strip() or not start.exists()) and time.monotonic()<deadline: time.sleep(.01)\n"
               "assert reply.read_text().strip().startswith('@')\nassert start.exists() and not finish.exists()", receipt, started, finished)
        recorded_window, recorded_pane = remote("cat", receipt).stdout.decode().strip().split("|")
        assert recorded_pane not in before_panes
        assert native(sockets[0], "display-message", "-p", "-t", recorded_pane, "#{window_id}") == recorded_window
        assert native(sockets[0], "show-options", "-wv", "-t", recorded_window, "@creation-test") == marker
        remote("python3", "-c", "import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); deadline=time.monotonic()+4\n"
               "while not p.exists() and time.monotonic()<deadline: time.sleep(.01)\nassert p.exists()", finished)
        affinity = base64.b64encode(json.dumps({"version": 1, "group": str(uuid.uuid4()), "name": "worker fixture",
                                               "order": 0, "creation": marker}).encode()).decode()
        worker = [helper, "create-tmux-window", token, recorded_window.removeprefix("@"), "/tmp", marker, affinity]
        before_worker = native(sockets[0], "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}")
        assert remote(*worker, check=False).returncode != 0
        assert native(sockets[0], "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}") == before_worker
        native(sockets[0], "run-shell", shlex.join(worker) + " >/dev/null 2>&1; exit 0")
        options = native(sockets[0], "list-windows", "-F", "#{@dispatch-window}").splitlines()
        assert options.count(affinity) == 1, options
        assert len(native(sockets[0], "list-panes", "-a", "-F", "#{pane_id}").splitlines()) == len(before_worker.splitlines()) + 1
        native(sockets[0], "kill-server")
        assert remote(helper, "tmux-creations", token, identity[2], check=False).returncode != 0
        # Reuse the socket, session name, numeric session ID, and marker. Only
        # the verified server process identity distinguishes this new work.
        native(sockets[0], "new-session", "-d", "-s", "fixture", "sleep 120")
        replacement = native(sockets[0], "new-window", "-d", "-P", "-F", "#{pane_pid}",
                             "-e", "DISPATCH_TMUX_CREATION=" + marker, "sleep 120")
        server, session = native(sockets[0], "display-message", "-p", "#{pid} #{session_id}").split()
        assert server != identity[0] and session == identity[1]
        processes = native(sockets[0], "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}")
        for command in [("tmux-creations", token, replacement), ("reattach-tmux", token)]:
            result = remote(helper, *command, check=False)
            assert result.returncode != 0 and not result.stdout, result.stdout
        replacement_token = remote(helper, "remember-tmux", sockets[0], server, session.removeprefix("$")).stdout.decode()
        tokens.append(replacement_token)
        result = remote(helper, "tmux-creations", replacement_token, replacement)
        assert json.loads(result.stdout) == {replacement: marker}, result.stdout
        attached = remote(helper, "reattach-tmux", replacement_token, input=b"detach-client\n")
        assert b"%session-changed" in attached.stdout and b"%exit" in attached.stdout, attached.stdout
        assert native(sockets[0], "list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}") == processes
        print(json.dumps({"system": system, "helper_sha256": hashlib.sha256(data).hexdigest(),
                          "checks": ["creation UUID", "other server excluded", "unmarked pane excluded",
                                     "untrusted caller rejected", "invalid PID requests rejected", "stale server rejected",
                                     "hook argument survives cleared pane environment",
                                     "server-owned creation reply saved before yielding hook finishes",
                                     "production creation worker requires server origin and saves metadata",
                                     "replacement server rejects old lookup and reattach", "fresh replacement token works",
                                     "fresh control attach and detach", "replacement processes preserved"], "passed": True}, indent=2))
    finally:
        for socket in sockets:
            remote("tmux", "-S", socket, "kill-server", check=False)
        for token in tokens:
            if len(token) == 64 and all(c in "0123456789abcdef" for c in token):
                remote("python3", "-c", "from pathlib import Path; import sys; (Path.home()/'.dispatch-ssh/recovery'/sys.argv[1]).unlink(missing_ok=True)", token)
        remote("rm", "-rf", "--", root)


if __name__ == "__main__":
    main()
