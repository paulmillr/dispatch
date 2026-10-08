"""Deterministic full-screen application for native tmux integration tests."""
import os
import re
import select
import termios
import time
import tty

original = termios.tcgetattr(0)
tty.setraw(0)
try:
    os.write(1, b'\x1b[?1049h\x1b[2J\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[4;10HALT_READY\x1b[7;4H')
    pending = b''
    pastes = 0
    while True:
        value = os.read(0, 1)
        if not value or (not pending and value == b'q'):
            break
        if not pending and value == b'e':
            os.write(1, b'\x1b]2;PENDING')
        elif not pending and value == b'f':
            os.write(1, b'_TITLE\x07')
        elif not pending and value == b'd':
            os.write(1, b'\x1b[6n')
            deadline = time.monotonic() + .3
            replies = b''
            while time.monotonic() < deadline:
                if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
                    replies += os.read(0, 4096)
            os.write(1, b'\x1b[10;1HQUERY_REPLIES_' + str(replies.count(b'R')).encode() + b'\x1b[K')
        else:
            pending += value
            mouse = re.search(rb'\x1b\[<\d+;(\d+);(\d+)[Mm]', pending)
            if mouse:
                os.write(1, b'\x1b[14;1HMOUSE_OK_' + mouse[1] + b'_' + mouse[2])
                pending = pending[mouse.end():]
            if b'\x1b[201~' in pending:
                if b'\x1b[200~' in pending and b'hello' in pending and b'world' in pending:
                    pastes += 1
                    os.write(1, b'\x1b[12;1HPASTE_OK_' + str(pastes).encode())
                pending = b''
finally:
    os.write(1, b'\x1b[?1000l\x1b[?1006l\x1b[?2004l\x1b[?1049l')
    termios.tcsetattr(0, termios.TCSANOW, original)
