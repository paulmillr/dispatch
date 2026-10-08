#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
# Validate and show selection before dependency preparation. --list and --help
# return here without touching builds, tool caches, or desktop dependencies.
python3 test/xcode.py --list "$@" > /dev/null
for argument in "$@"; do
    if [[ "$argument" == --list || "$argument" == --help || "$argument" == -h ]]; then
        exec python3 test/xcode.py "$@"
    fi
done
mkdir -p build/test-tools
rm -f build/TestProfile.json
if [[ "${DISPATCH_TEST_SETUP:-0}" == 1 ]]; then
    bash scripts/setup.sh
    python3 scripts/setup-test-tools.py
else
    DISPATCH_SETUP_OFFLINE=1 bash scripts/setup.sh
fi
export PATH="$PWD/build/test-tools/bin:$PATH"
python3 scripts/generate-project.py
# Desktop tests skip themselves once the screen locks. Their synthetic input is
# not user activity, so keep the display (and the lock) off as the VM guest does.
exec caffeinate -di python3 test/xcode.py "$@"
