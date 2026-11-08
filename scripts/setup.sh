#!/bin/bash
set -euo pipefail
# The Mac app's tools; with --mobile also the iPhone app's SSH engine (scripts/setup_consent.py).
exec python3 -B "$(dirname "$0")/setup_consent.py" --setup "$@"
