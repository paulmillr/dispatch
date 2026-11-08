#!/bin/bash
# Dispatch's part of the release build: scripts/release/build.sh runs it in a fresh tree (docs/releasing.md, Two
# builders). For RELEASE_VARIANT (pilot, the only one), with CFBundleVersion RELEASE_BUILD_NUMBER, it leaves in
# RELEASE_PRODUCTS:
#   RELEASE_PLATFORM=mac   Dispatch.app and Dispatch.app.dSYM, the Mac app
#   RELEASE_PLATFORM=ios   DispatchMobile.xcarchive, the iPhone app with its watch app (no flow publishes it
#                          for now), built unsigned and signed ad hoc here with each target's
#                          entitlements: Xcode signs iOS code only with a team, and the signing machine's export keeps
#                          them (the watch's App Group)
# Another app has its own release/app.sh; the rest of the release scripts are the same.
set -euo pipefail
cd "$(dirname "$0")/../.."
# setup.sh asks once before its downloads, all pinned and SHA-256-checked (scripts/build.lock.json); after it, run.sh
# finds nothing missing and asks nothing. The Mac app's project needs no iPhone SSH engine: only the iPhone build
# prepares it (--mobile).
if [[ "${RELEASE_PLATFORM:-mac}" == mac ]]; then echo y | bash scripts/setup.sh; else echo y | bash scripts/setup.sh --mobile; fi
[[ "$RELEASE_VARIANT" == pilot ]] || { echo "error: no variant $RELEASE_VARIANT (scripts/release/app.json)" >&2; exit 1; }
flags=(--build-number "$RELEASE_BUILD_NUMBER")

if [[ "${RELEASE_PLATFORM:-mac}" == mac ]]; then
  ./run.sh --prod --just-build "${flags[@]}" < /dev/null
  mv build/Build/Products/Release/Dispatch.app build/Build/Products/Release/Dispatch.app.dSYM "$RELEASE_PRODUCTS/"
  exit 0
fi

archive="$RELEASE_PRODUCTS/DispatchMobile.xcarchive"
./run.sh --archive "$archive" "${flags[@]}" < /dev/null
# Innermost first. The watch's entitlements name the App Group after the phone app: group.<its bundle id>.
app="$archive/Products/Applications/DispatchMobile.app"
group="group.$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
entitlements="$(mktemp)"
sed "s/\$(DISPATCH_APP_GROUP)/$group/" Watch/Widgets/DispatchWatchWidgets.entitlements > "$entitlements"
codesign --force --sign - --generate-entitlement-der --entitlements "$entitlements" \
  "$app/Watch/DispatchWatch.app/PlugIns/DispatchWatchWidgets.appex"
sed "s/\$(DISPATCH_APP_GROUP)/$group/" Watch/App/DispatchWatch.entitlements > "$entitlements"
codesign --force --sign - --generate-entitlement-der --entitlements "$entitlements" "$app/Watch/DispatchWatch.app"
codesign --force --sign - --generate-entitlement-der "$app"
rm "$entitlements"
codesign --verify --deep --strict "$app"
