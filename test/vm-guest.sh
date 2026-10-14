#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The loopback SSH fixture's sshd runs as the user, as on a host (test/xcode.py's default): recordings made on a
# host name that fixture, so a root sshd (DISPATCH_UNPRIVILEGED_SSHD=0, needs passwordless sudo) replays none of them.
export DISPATCH_UNPRIVILEGED_SSHD="${DISPATCH_UNPRIVILEGED_SSHD:-1}"

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
# Runner options outside the selection (--live) belong to xcode.py.
args, _ = parser.parse_known_args()
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
# Recordings name each agent and multiplexer by the checkout's build/test-tools/bin path (TestSupport.tool), as a
# host run that prepared its tools sees them: link the VM's own there, in TestSupport.tool's fallback order.
mkdir -p build/test-tools/bin
for tool in claude codex herdr pi tmux; do
  if [[ -x "build/test-tools/bin/$tool" ]]; then continue; fi
  candidates=("/Users/admin/dispatch-tests/test-tools/$tool")
  if [[ "$tool" == codex ]]; then
    candidates+=(/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex)
  fi
  candidates+=("/opt/homebrew/bin/$tool")
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then ln -sfn "$candidate" "build/test-tools/bin/$tool"; break; fi
  done
done
DISPATCH_SETUP_OFFLINE=1 timed guest_dependencies bash scripts/setup.sh
timed project_generation xcodegen generate --spec project.yml --use-cache --cache-path build/test-tools/xcodegen-cache
exec python3 test/xcode.py "$@"
