#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Direct builds stay offline; the root launcher opts into setup before building.
DISPATCH_SETUP_OFFLINE="${DISPATCH_SETUP_OFFLINE:-1}" bash scripts/setup.sh
python3 scripts/generate-project.py
xcodebuild -project Dispatch.xcodeproj -scheme Dispatch -configuration "${CONFIGURATION:-Debug}" -derivedDataPath build build "$@"
