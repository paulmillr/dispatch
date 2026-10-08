#!/usr/bin/env python3
"""Deterministic PTY animation with a visible, checksummed frame number."""
import json
import os
from pathlib import Path
import sys
import time

mode, report = sys.argv[1:]
columns, rows = os.get_terminal_size(1)
columns -= 1  # Avoid wrapping at the right edge.
frames = []
for phase in range(2):
    parts = []
    for y in range(1, rows):
        parts.append(f'\033[{y + 1};1H\033[48;2;255;255;255m')
        for x in range(columns):
            index = y * columns + x if mode == 'unique' else x // 12 % 16
            r, g, b = 160 + index % 96, 160 + index // 96 % 96, 80 + index // 9216 % 160
            if mode == 'unique' or x % 12 == 0:
                parts.append(f'\033[38;2;{r};{g};{b}m')
            parts.append('M' if (x + y + phase) % 2 else 'W')
    frames.append(''.join(parts).encode())
os.write(1, b'\033[2J\033[?25l')
times = []
start = time.monotonic()
number = 0
deadline = start
try:
    while True:
        bits = '10110110' + f'{number & 65535:016b}' + f'{(~number) & 65535:016b}'
        marker = ''.join(('\033[48;2;255;255;255m' if bit == '1' else '\033[48;2;0;0;0m') + ' ' for bit in bits)
        payload = b'\033[?2026h\033[H' + marker.encode() + frames[number % 2] + b'\033[0m\033[?2026l'
        view = memoryview(payload)
        while view:
            view = view[os.write(1, view):]
        times.append(time.monotonic())
        number += 1
        if number % 120 == 0:
            Path(report).write_text(json.dumps({'columns': columns, 'rows': rows, 'completedWrites': times}))
        # Do not burst to catch up after a stall.
        deadline = max(deadline + 1 / 120, times[-1])
        time.sleep(max(0, deadline - time.monotonic()))
except (BrokenPipeError, OSError):
    pass
