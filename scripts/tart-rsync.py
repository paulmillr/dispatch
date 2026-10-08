#!/usr/bin/env python3
"""Use Tart's authenticated guest agent as rsync's bidirectional transport."""
import os
import sys

vm, *command = sys.argv[1:]
if not command or command[0] not in ('rsync', '/usr/bin/rsync') or '--server' not in command:
    raise SystemExit('Expected an rsync server command')
os.execvp('tart', ['tart', 'exec', '-i', vm, *command])
