#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The dedicated VM has passwordless sudo: keep the loopback SSH fixture behind a
# root sshd so the helper's privileged-monitor check stays tested.
export DISPATCH_UNPRIVILEGED_SSHD="${DISPATCH_UNPRIVILEGED_SSHD:-0}"

python3 test/xcode.py --list "$@" > /dev/null
for argument in "$@"; do
    if [[ "$argument" == --list || "$argument" == --help || "$argument" == -h ]]; then
        exec python3 test/xcode.py "$@"
    fi
done
suite="$(python3 - "$@" <<'PYSELECT'
import argparse, os, sys
sys.path.insert(0, 'test')
from selection import add_arguments, resolve
parser = argparse.ArgumentParser()
add_arguments(parser)
args = parser.parse_args()
print(resolve(args.tests, args.skip, args.suite, args.benchmarks or os.environ.get('DISPATCH_TEST_BENCHMARKS') == '1')['suite'])
PYSELECT
)"
[[ "$(id -un)" == admin ]] || { echo 'Run this inside the dedicated Tart VM.' >&2; exit 1; }
mkdir -p build
rm -rf build/TestResults.xcresult build/TestSummary.json build/TestProfile.json build/TestTimings.json build/TestCases.json build/TestPreflight.json build/*audit* build/*validation*
timed() { python3 test/profile.py build/TestProfile.json "$@"; }
mkdir -p build/test-tools
if [[ "$suite" != fast ]]; then
preflight_key="$(shasum -a 256 scripts/vm-preflight.swift; xcrun swiftc --version)"
if [[ ! -x build/test-tools/vm-preflight || ! -f build/test-tools/vm-preflight.key || "$(cat build/test-tools/vm-preflight.key)" != "$preflight_key" ]]; then
    timed desktop_preflight_build xcrun swiftc scripts/vm-preflight.swift -o build/test-tools/vm-preflight
    printf '%s\n' "$preflight_key" > build/test-tools/vm-preflight.key
fi
timed desktop_preflight build/test-tools/vm-preflight
fi
for binary in /opt/homebrew/bin/xcodegen /opt/homebrew/bin/tmux /opt/homebrew/bin/herdr; do
  [[ -x "$binary" ]] || { echo "Missing test dependency: $binary. Run VM setup first." >&2; exit 1; }
done
DISPATCH_SETUP_OFFLINE=1 timed guest_dependencies bash scripts/setup.sh
timed project_generation xcodegen generate --spec project.yml --use-cache --cache-path build/test-tools/xcodegen-cache
exec python3 test/xcode.py "$@"
