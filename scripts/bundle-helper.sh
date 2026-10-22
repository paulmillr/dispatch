#!/bin/bash
set -euo pipefail
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/dispatch-helper"
# Always the helper this build produced, never one named by the environment: Dispatch's own
# terminals export DISPATCH_HELPER_EXECUTABLE (the running app's helper), and a build started
# there would otherwise bundle and sign that binary.
source="$SRCROOT/build/helper-rust/bin/darwin-arm64"
# The macOS SSH upload reads helper/darwin-arm64: a link to this one signed copy, not a second one.
alias="$(dirname "$destination")/helper/darwin-arm64"
if [[ "${1:-}" == --dry-run ]]; then
  printf 'Bundle and sign %s -> %s (atomic replacement), link %s\n' "$source" "$destination" "$alias"
  exit 0
fi
[[ $# == 0 ]] || { echo 'Usage: bundle-helper.sh [--dry-run]' >&2; exit 1; }
mkdir -p "$(dirname "$alias")"
staging="${destination}.next"
link="${alias}.next"
trap 'rm -f "$staging" "$link"' EXIT
cp "$source" "$staging"
chmod 700 "$staging"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier yachts.dispatch.helper "$staging"
mv -f "$staging" "$destination"
ln -sfn ../dispatch-helper "$link"
mv -fh "$link" "$alias"
