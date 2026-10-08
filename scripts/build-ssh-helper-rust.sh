#!/bin/bash
# Build helper artifacts without copying app resources (release unless overridden).
set -euo pipefail
exec python3 "$(dirname "$0")/build-ssh-helper.py" --build-only "$@"
