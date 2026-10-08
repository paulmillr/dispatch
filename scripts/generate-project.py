#!/usr/bin/env python3
"""Generate the tracked Dispatch.xcodeproj from project.yml with the pinned XcodeGen.

usage: generate-project.py

Builds, tests and benchmarks all generate through here with one cache: XcodeGen skips writing the
project when its cache matches the spec.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

if sys.argv[1:]:
    sys.exit(__doc__.strip())
tool = subprocess.check_output(['python3', 'scripts/setup-build-tools.py', 'xcodegen', '--offline'], cwd=ROOT, text=True).strip()
subprocess.run([tool, 'generate', '--spec', 'project.yml', '--use-cache', '--cache-path', 'build/xcodegen-cache'], cwd=ROOT, check=True)
