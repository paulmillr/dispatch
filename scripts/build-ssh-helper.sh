#!/bin/bash
set -euo pipefail
python3 "$(dirname "$0")/build-ssh-helper.py" "$@"
if [[ -n "${DISPATCH_HELPER_BUILD_COMPLETE:-}" ]]; then
    touch "$DISPATCH_HELPER_BUILD_COMPLETE"
fi
