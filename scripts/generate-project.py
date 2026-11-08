#!/usr/bin/env python3
"""Generate the tracked Xcode projects with the pinned XcodeGen: Dispatch.xcodeproj (the Mac app) from project.yml
and DispatchMobile.xcodeproj (the iPhone and Watch apps) from project-mobile.yml, both including project-shared.yml.

usage: generate-project.py

Builds, tests and benchmarks all generate through here, each spec with its own cache: XcodeGen skips writing a
project when its cache matches the spec.
"""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
# (spec, cache): the projects are named by the specs (`name:`), Dispatch and DispatchMobile.
SPECS = (('project.yml', 'build/xcodegen-cache'), ('project-mobile.yml', 'build/xcodegen-cache-mobile'))

if sys.argv[1:]:
    sys.exit(__doc__.strip())
tool = subprocess.check_output(['python3', 'scripts/setup-build-tools.py', 'xcodegen', '--offline'], cwd=ROOT, text=True).strip()
for spec, cache in SPECS:
    subprocess.run([tool, 'generate', '--spec', spec, '--use-cache', '--cache-path', cache], cwd=ROOT, check=True)
