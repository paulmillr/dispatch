#!/bin/bash
# Release, step 1, on the machine that signs commits (docs/releasing.md):
#
#   scripts/set-version.sh X.Y.Z
#
# Sets MARKETING_VERSION of every app (project.yml and Dispatch.xcodeproj/project.pbxproj, which must agree) to X.Y.Z,
# newer than the current one. Edits files only: commit, tag and push are yours, signed, as printed at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "error: $*" >&2; exit 1; }
[[ $# == 1 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/set-version.sh X.Y.Z (three numbers, no v)"
version="$1"
cd "$ROOT"
git diff --quiet HEAD -- project.yml Dispatch.xcodeproj/project.pbxproj ||
  fail "project.yml or project.pbxproj has uncommitted changes"

python3 -I - "$version" project.yml Dispatch.xcodeproj/project.pbxproj <<'PY'
import re, sys
from pathlib import Path
version, *paths = sys.argv[1:]
# project.yml: `MARKETING_VERSION: "0.1.3"`; project.pbxproj: `MARKETING_VERSION = 0.1.3;`.
pattern = re.compile(r'(MARKETING_VERSION(?::\s*"|\s*=\s*))([0-9]+(?:\.[0-9]+)*)("|;)')
texts = {path: Path(path).read_text() for path in paths}
found = {path: {match.group(2) for match in pattern.finditer(text)} for path, text in texts.items()}
current = set().union(*found.values())
for path, versions in found.items():
    if not versions:
        sys.exit(f'error: no MARKETING_VERSION in {path}')
if len(current) != 1:
    sys.exit(f'error: the apps disagree on MARKETING_VERSION ({", ".join(sorted(current))}); fix that first')
old = current.pop()
key = lambda text: tuple(int(part) for part in text.split('.'))
if key(version) <= key(old):
    sys.exit(f'error: {version} is not newer than the current {old}')
for path, text in texts.items():
    updated, count = pattern.subn(lambda match: match.group(1) + version + match.group(3), text)
    Path(path).write_text(updated)
    print(f'{path}: {count} × {old} → {version}')
PY

cat <<EOF

Review, then commit, tag and push, all signed:
  git diff
  git commit -S -m '$version' project.yml Dispatch.xcodeproj/project.pbxproj
  git tag -s '$version' -m 'Dispatch $version'
  git push origin HEAD:main '$version'
The tag starts the GitHub build (.github/workflows/release.yml); then, on the signing machine:
  scripts/release-publish.sh $version
EOF
