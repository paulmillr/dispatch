#!/bin/bash
set -euo pipefail
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/dispatch-helper"
# Always the helper this build produced, never one named by the environment: Dispatch's own
# terminals export DISPATCH_HELPER4_EXECUTABLE (the running app's helper), and a build started
# there would otherwise bundle and sign that binary.
source="$(dirname "$destination")/helper4/darwin-universal"
if [[ "${1:-}" == --dry-run ]]; then
  printf 'Bundle and sign %s -> %s (atomic replacement)\n' "$source" "$destination"
  exit 0
fi
[[ $# == 0 ]] || { echo 'Usage: build-helper4.sh [--dry-run]' >&2; exit 1; }
mkdir -p "$(dirname "$destination")"
staging="${destination}.next"
trap 'rm -f "$staging"' EXIT
cp "$source" "$staging"
chmod 700 "$staging"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$staging"
mv -f "$staging" "$destination"
