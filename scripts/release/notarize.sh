#!/bin/bash
# The signing part of scripts/release-publish.sh, on the signing machine (docs/releasing.md). Self-contained: needs
# only this file, Xcode's command line tools, a Developer ID Application identity and a notarytool keychain profile,
# stored once with
#   xcrun notarytool store-credentials NAME --apple-id APPLE_ID --team-id TEAMID
#
#   scripts/release/notarize.sh APP-VARIANT-unsigned.zip --identity 'Developer ID Application: NAME (TEAMID)' \
#     [--profile NAME] [--entitlements PLIST] [--sha256 HASH]
#
# The zip holds one app, NAME.app (scripts/release/build.sh makes it). First it shows the zip's SHA-256: on its own,
# continue only if it matches the hash you got over a separate channel; with --sha256 HASH it compares instead of
# asking (release-publish.sh passes the build it signs: its own, or GitHub's with --trust-ci). Everything it makes
# goes to APP-VARIANT-signed/, next to the zip.
# Re-signs the given build (never rebuilds it): every Mach-O, deepest first, then the app, with the hardened runtime, a
# secure timestamp and each binary's own identifier; the app alone gets the entitlements in --entitlements PLIST
# (release-publish.sh writes them from scripts/release/app.json), none without it. Notarizes and staples the app, so it
# launches offline once copied out, then packs it into an LZMA DMG with an Applications link, signs, notarizes and
# staples that. APP-VARIANT-signed/NAME-<version>.dmg is the release download as it is: repacking it (a Finder zip,
# say) adds junk and discards nothing useful.
#
# Each Apple submission is uploaded once and its ID saved before waiting. If anything is interrupted, run the same
# command again: it resumes, and never uploads a step twice.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: release/notarize.sh APP-VARIANT-unsigned.zip --identity 'Developer ID Application: NAME (TEAMID)' [--profile NAME] [--entitlements PLIST] [--sha256 HASH]"; }
# The credentials stored in the one-time setup above, unless --profile names others.
PROFILE=notary

is_macho() {
  case "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" in
    feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
  esac
  return 1
}

# One valid Developer ID Application identity, by full name or SHA-1; never a guess between teams.
identity_hash() {
  local matches
  matches="$(security find-identity -v -p codesigning | sed -nE 's/^ *[0-9]+\) ([0-9A-Fa-f]{40}) "(Developer ID Application: .*)"$/\1 \2/p' |
    awk -v id="$1" '{ hash = $1; name = substr($0, 42) } tolower(hash) == tolower(id) || name == id { print toupper(hash) }')"
  [[ -n "$matches" && "$(wc -l <<< "$matches" | tr -d ' ')" == 1 ]] ||
    fail "select one valid Developer ID Application identity by its full name or SHA-1 (security find-identity -v -p codesigning); Apple Development and ad-hoc identities cannot notarize"
  echo "$matches"
}

# The app's entitlements come from --entitlements, never from the build's own signature: the signer's identity vouches
# for exactly those. None by default.
ENTITLEMENTS='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>'

# Nested code before what encloses it: Mach-O files and bundles, deepest first, then the app.
sign_app() {
  local app="$1" identity="$2" target
  while IFS=$'\t' read -r _ target; do
    codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=identifier "$target"
  done < <(find "$app/Contents" \( -type f -o -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) \) -print |
    while IFS= read -r path; do
      if [[ -d "$path" ]] || is_macho "$path"; then
        depth="${path//[^\/]/}"; printf '%d\t%s\n' "${#depth}" "$path"
      fi
    done | sort -t$'\t' -k1,1nr -k2,2)
  # A file: codesign cannot read entitlements from a pipe.
  printf '%s\n' "$ENTITLEMENTS" > "$app.entitlements"
  codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$app.entitlements" "$app"
  rm "$app.entitlements"
  codesign --verify --deep --strict --verbose=2 "$app"
}

# A stage, in the log, and on the checklist line when release-publish.sh runs this (its progress function).
report() {
  echo "$1"
  if declare -F progress > /dev/null; then progress "$1"; fi
}

# Uploads $2, $3 (the app or the DMG), once (the ID goes to $1 first), then waits for Apple's verdict; reruns wait on
# the saved ID.
notarize() {
  local receipt="$1" file="$2" what="$3" id status
  if [[ ! -f "$receipt" ]]; then
    report "uploading $what to Apple's notary service"
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --output-format json > "$receipt.next"
    mv "$receipt.next" "$receipt"
  fi
  id="$(plutil -extract id raw "$receipt")"
  report "$what sent to Apple (submission $id), waiting for notarization: usually a few minutes"
  xcrun notarytool wait "$id" --keychain-profile "$PROFILE" --output-format json > "$receipt.status" || true
  status="$(plutil -extract status raw "$receipt.status" 2>/dev/null || echo unknown)"
  [[ "$status" == Accepted ]] ||
    fail "notarization of $(basename "$file") is $status (submission $id). See: xcrun notarytool log $id --keychain-profile $PROFILE. Rerun this command to resume; do not upload again by hand."
}

[[ $# -ge 3 && -f "$1" ]] || usage
ARCHIVE="$1"; shift
IDENTITY="" EXPECTED=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && -n "$2" ]] || usage
  case "$1" in
    --identity) IDENTITY="$(identity_hash "$2")" ;;
    --profile) PROFILE="$2" ;;
    --sha256) EXPECTED="$2" ;;
    --entitlements) [[ -f "$2" ]] || usage; ENTITLEMENTS="$(cat "$2")" ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$IDENTITY" ]] || usage

digest="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
echo "SHA-256 of $(basename "$ARCHIVE"): $digest"
if [[ -n "$EXPECTED" ]]; then
  [[ "$digest" == "$EXPECTED" ]] || fail "stopped: the zip is not the build whose hash is $EXPECTED"
else
  read -r -p "Does it match the hash you got separately? Type yes to continue: " answer < /dev/tty
  [[ "$answer" == yes ]] || fail "stopped: sign only a build whose hash you know"
fi
# Credentials work before anything is signed; no password or key on the command line.
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json > /dev/null ||
  fail "no working notarytool credentials named $PROFILE; store them as shown at the top of this script"
# APP-VARIANT-unsigned.zip signs into APP-VARIANT-signed/, next to it.
name="$(basename "$ARCHIVE" .zip)"
OUTPUT="$(cd "$(dirname "$ARCHIVE")" && pwd)/${name%-unsigned}-signed"
mkdir -p "$OUTPUT"
# The one app in the zip: NAME.app.
apps="$(zipinfo -1 "$ARCHIVE" | sed -nE 's#^([^/]+\.app)/.*#\1#p' | sort -u)"
[[ -n "$apps" && "$apps" != *$'\n'* ]] || fail "$ARCHIVE must hold exactly one app, not: ${apps:-none}"
app_name="${apps%.app}"
app="$OUTPUT/$app_name.app"

# 1. Sign a fresh copy of the build's app. Published only once completely signed.
if [[ ! -d "$app" ]]; then
  rm -rf "$OUTPUT/unpacked" "$app.signing"
  mkdir "$OUTPUT/unpacked"
  ditto -x -k "$ARCHIVE" "$OUTPUT/unpacked"
  [[ "$(ls "$OUTPUT/unpacked")" == "$app_name.app" ]] || fail "$ARCHIVE must contain exactly $app_name.app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$OUTPUT/unpacked/$app_name.app/Contents/Info.plist")" == APPL ]] ||
    fail "$ARCHIVE does not contain a macOS application"
  mv "$OUTPUT/unpacked/$app_name.app" "$app.signing"
  rmdir "$OUTPUT/unpacked"
  report "signing the app"
  sign_app "$app.signing" "$IDENTITY"
  mv "$app.signing" "$app"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$OUTPUT/$app_name-$version.dmg"

# 2. Notarize and staple the app itself: Gatekeeper accepts it offline after it leaves the DMG.
if ! xcrun stapler validate -q "$app" 2>/dev/null; then
  [[ -f "$OUTPUT/app-submission.zip" ]] || ditto -c -k --keepParent "$app" "$OUTPUT/app-submission.zip"
  notarize "$OUTPUT/app-notarization.json" "$OUTPUT/app-submission.zip" "the app"
  report "the app notarized, stapling it"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi
spctl --assess --type execute --verbose=2 "$app"

# 3. The download: an LZMA-compressed DMG of the stapled app, signed with the same identity.
if [[ ! -f "$dmg" ]]; then
  stage="$OUTPUT/dmg-contents"
  rm -rf "$stage" "$OUTPUT/$app_name.next.dmg"
  mkdir "$stage"
  ditto "$app" "$stage/$app_name.app"
  ln -s /Applications "$stage/Applications"
  report "packing and signing the DMG"
  hdiutil create -quiet -volname "$app_name" -srcfolder "$stage" -fs HFS+ -format ULMO "$OUTPUT/$app_name.next.dmg"
  codesign --sign "$IDENTITY" --timestamp "$OUTPUT/$app_name.next.dmg"
  codesign --verify --strict --verbose=2 "$OUTPUT/$app_name.next.dmg"
  rm -rf "$stage"
  mv "$OUTPUT/$app_name.next.dmg" "$dmg"
fi

# 4. Notarize and staple the DMG: it opens without a network check too.
if ! xcrun stapler validate -q "$dmg" 2>/dev/null; then
  notarize "$OUTPUT/dmg-notarization.json" "$dmg" "the DMG"
  report "the DMG notarized, stapling it"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
echo "$digest  $(basename "$dmg")" > "$OUTPUT/SHA256SUMS"
echo
echo "Notarized and stapled: $dmg"
echo "SHA-256 $digest"
echo "Publish $(basename "$dmg") as is. Keep the *-notarization.json receipts."
