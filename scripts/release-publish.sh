#!/bin/bash
# Release, signing machine side (README.md, a copy of docs/releasing.md). Runs from a clone of dispatch-release, where
# scripts/release-prepare.sh puts it as bin/release-publish.sh, after bin/release-signer-setup.sh:
#
#   bin/release-publish.sh [pilot/20261030.1345] [--mac-only | --ios-only] [--no-push]
#
# Pulls, then takes the newest release folder without published.json (or the one named) and checks both zips against
# its release.json, and that their bundle ids are the variant's. Then:
#   Mac     bin/release-notarize.sh signs the app with Developer ID, notarizes and staples it and its DMG; the DMG is
#           copied into the release folder.
#   iPhone  xcodebuild -exportArchive signs the archive (phone, watch, widgets) with Apple Distribution and uploads it to
#           App Store Connect. Signing is automatic through the App Store Connect API key: Xcode registers the bundle
#           ids and the App Group and makes the App Store profiles as needed. The build shows up in TestFlight once
#           Apple has processed it.
# Writes published.json, commits it with the DMG and pushes. Rerun after a failure: notarization resumes where it
# stopped, and a finished part is skipped (markers in the release folder's export/, which git ignores).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${DISPATCH_RELEASE_CONFIG:-$HOME/.config/dispatch-release}"

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: bin/release-publish.sh [VARIANT/BUILD] [--mac-only | --ios-only] [--no-push]"; }

folder="" mac=1 ios=1 push=1
for argument in "$@"; do
  case "$argument" in
    --mac-only) ios="" ;;
    --ios-only) mac="" ;;
    --no-push) push="" ;;
    -*) usage ;;
    *) [[ -z "$folder" ]] || usage; folder="${argument%/}" ;;
  esac
done
[[ -n "$mac$ios" ]] || usage
cd "$REPO"
[[ -z "$push" ]] || git pull --ff-only --quiet
if [[ -z "$folder" ]]; then
  shopt -s nullglob
  # Build numbers are UTC times, so they sort as text.
  folder="$(for release in */*/release.json; do
    [[ -f "${release%/release.json}/published.json" ]] || echo "${release%/release.json}"
  done | sort -t/ -k2,2 | tail -1)"
  shopt -u nullglob
  [[ -n "$folder" ]] || { echo "Nothing to publish: every release folder has its published.json."; exit 0; }
fi
[[ -f "$folder/release.json" ]] || fail "no release.json in $folder"
field() { plutil -extract "$1" raw "$folder/release.json"; }
variant="$(field variant)" number="$(field build)"
echo "Publishing $variant build $number (commit $(field commit | cut -c1-8)), from $folder"

settings="$CONFIG/$variant.env"
[[ -f "$settings" ]] || fail "no $settings: run bin/release-signer-setup.sh $variant first"
# DISPATCH_TEAM, DISPATCH_MAC_IDENTITY, DISPATCH_NOTARY_PROFILE, DISPATCH_ASC_KEY, DISPATCH_ASC_KEY_ID, DISPATCH_ASC_ISSUER
source "$settings"

# Each account signs only its own apps.
case "$variant" in
  pilot) prefix=yachts.dispatch.pilot ;;
  stable) prefix=yachts.dispatch ;;
  *) fail "unknown variant $variant" ;;
esac
[[ "$(field mac.bundle_id)" == "$prefix.app" ]] || fail "the Mac app is $(field mac.bundle_id), not $prefix.app"
[[ "$(field ios.bundle_id)" == "$prefix.mobile" ]] || fail "the iPhone app is $(field ios.bundle_id), not $prefix.mobile"
for part in mac ios; do
  file="$folder/$(field "$part.file")"
  [[ -f "$file" ]] || fail "missing $file"
  [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$(field "$part.sha256")" ]] || fail "$file does not match release.json"
done

# Signing over SSH needs the login keychain unlocked; macOS cannot ask in a dialog there.
keychain="$HOME/Library/Keychains/login.keychain-db"
security show-keychain-info "$keychain" > /dev/null 2>&1 || {
  echo "Unlocking the login keychain (your macOS password)"
  security unlock-keychain "$keychain"
}

work="$folder/export"
mkdir -p "$work"
if [[ -n "$mac" ]]; then
  if [[ ! -f "$work/mac.done" ]]; then
    zip="$folder/$(field mac.file)"
    "$REPO/bin/release-notarize.sh" "$zip" --identity "$DISPATCH_MAC_IDENTITY" --profile "$DISPATCH_NOTARY_PROFILE" \
      --sha256 "$(field mac.sha256)"
    name="$(basename "$zip" .zip)"
    cp "$folder/${name%-unsigned}-signed/Dispatch-$(field mac.version).dmg" "$folder/"
    echo "Dispatch-$(field mac.version).dmg" > "$work/mac.done"
  fi
fi
# What either run finished: a --mac-only and a later --ios-only run of one build both end up in published.json.
dmg=""
if [[ -f "$work/mac.done" ]]; then dmg="$(cat "$work/mac.done")"; fi

if [[ -n "$ios" && ! -f "$work/ios.done" ]]; then
  rm -rf "$work/DispatchMobile.xcarchive" "$work/upload"
  ditto -x -k "$folder/$(field ios.file)" "$work"
  cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$DISPATCH_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
  echo "Signing and uploading Dispatch for iPhone $(field ios.version) ($number) to App Store Connect"
  xcodebuild -exportArchive -archivePath "$work/DispatchMobile.xcarchive" -exportOptionsPlist "$work/ExportOptions.plist" \
    -exportPath "$work/upload" -allowProvisioningUpdates -authenticationKeyPath "$DISPATCH_ASC_KEY" \
    -authenticationKeyID "$DISPATCH_ASC_KEY_ID" -authenticationKeyIssuerID "$DISPATCH_ASC_ISSUER" > "$work/export.log" 2>&1 ||
    { tail -30 "$work/export.log" >&2; fail "export or upload failed; full log: $work/export.log"; }
  date -u +%Y-%m-%dT%H:%M:%SZ > "$work/ios.done"
fi

uploaded=""
if [[ -f "$work/ios.done" ]]; then uploaded="$(cat "$work/ios.done")"; fi
mac_json=null ios_json=null
[[ -z "$dmg" ]] || mac_json="{\"dmg\": \"$dmg\", \"sha256\": \"$(shasum -a 256 "$folder/$dmg" | cut -d' ' -f1)\"}"
[[ -z "$uploaded" ]] || ios_json="{\"uploaded\": \"$uploaded\", \"version\": \"$(field ios.version)\", \"build\": \"$number\"}"
cat > "$folder/published.json" <<EOF
{
  "variant": "$variant",
  "build": "$number",
  "team": "$DISPATCH_TEAM",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "mac": $mac_json,
  "ios": $ios_json
}
EOF
git add "$folder/published.json" ${dmg:+"$folder/$dmg"}
TZ=UTC git commit --quiet -m "Publish $variant $number"
[[ -z "$push" ]] || git push --quiet
echo
echo "Published $variant build $number$([[ -n "$push" ]] && echo ", pushed" || echo ", committed (not pushed)")"
[[ -z "$dmg" ]] || echo "  Mac     $folder/$dmg"
[[ -z "$uploaded" ]] || echo "  iPhone  uploaded; in TestFlight once App Store Connect has processed it"
