#!/bin/bash
# Release, step 2 (signer). Self-contained: needs only this file, Xcode's command line tools, a
# Developer ID Application identity and a notarytool keychain profile, stored once with
#   xcrun notarytool store-credentials dispatch-notary --apple-id APPLE_ID --team-id TEAMID
#
#   scripts/release-notarize.sh Dispatch-unsigned.zip --identity 'Developer ID Application: NAME (TEAMID)'
#
# First it shows the zip's SHA-256: continue only if it matches the hash the maintainer sent over a
# separate channel. Everything it makes goes to Dispatch-signed/, next to the zip.
# Re-signs the maintainer's build (never rebuilds it): every Mach-O, deepest first, then the app,
# with the hardened runtime, a secure timestamp, no entitlements and each binary's own identifier
# (yachts.dispatch.app, yachts.dispatch.helper). Notarizes and staples the app,
# so it launches offline once copied out, then packs it into an LZMA DMG with an Applications link,
# signs, notarizes and staples that. Send back Dispatch-signed/Dispatch-<version>.dmg exactly as it is: it is
# the release download, and repacking it (a Finder zip, say) adds junk and discards nothing useful.
#
# Each Apple submission is uploaded once and its ID saved in Dispatch-signed/ before waiting. If anything is
# interrupted, run the same command again: it resumes, and never uploads a step twice.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: release-notarize.sh Dispatch-unsigned.zip --identity 'Developer ID Application: NAME (TEAMID)'"; }
# The credentials stored in the one-time setup above.
PROFILE=dispatch-notary

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
  codesign --force --sign "$identity" --options runtime --timestamp "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
}

# Uploads $2 once (the ID goes to $1 first), then waits for Apple's verdict; reruns wait on the saved ID.
notarize() {
  local receipt="$1" file="$2" id status
  if [[ ! -f "$receipt" ]]; then
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --output-format json > "$receipt.next"
    mv "$receipt.next" "$receipt"
  fi
  id="$(plutil -extract id raw "$receipt")"
  echo "Notarizing $(basename "$file"): submission $id"
  xcrun notarytool wait "$id" --keychain-profile "$PROFILE" --output-format json > "$receipt.status" || true
  status="$(plutil -extract status raw "$receipt.status" 2>/dev/null || echo unknown)"
  [[ "$status" == Accepted ]] ||
    fail "notarization of $(basename "$file") is $status (submission $id). See: xcrun notarytool log $id --keychain-profile $PROFILE. Rerun this command to resume; do not upload again by hand."
}

[[ $# == 3 && "$2" == --identity && -f "$1" ]] || usage
ARCHIVE="$1"
IDENTITY="$(identity_hash "$3")"

echo "SHA-256 of $(basename "$ARCHIVE"): $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
read -r -p "Does it match the hash the maintainer sent separately? Type yes to continue: " answer < /dev/tty
[[ "$answer" == yes ]] || fail "stopped: sign only the build whose hash the maintainer sent"
# Credentials work before anything is signed; no password or key on the command line.
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json > /dev/null ||
  fail "no working notarytool credentials named $PROFILE; store them as shown at the top of this script"
OUTPUT="$(cd "$(dirname "$ARCHIVE")" && pwd)/Dispatch-signed"
mkdir -p "$OUTPUT"
app="$OUTPUT/Dispatch.app"

# 1. Sign a fresh copy of the maintainer's app. Published only once completely signed.
if [[ ! -d "$app" ]]; then
  rm -rf "$OUTPUT/unpacked" "$app.signing"
  mkdir "$OUTPUT/unpacked"
  ditto -x -k "$ARCHIVE" "$OUTPUT/unpacked"
  [[ "$(ls "$OUTPUT/unpacked")" == Dispatch.app ]] || fail "$ARCHIVE must contain exactly Dispatch.app"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$OUTPUT/unpacked/Dispatch.app/Contents/Info.plist")" == APPL ]] ||
    fail "$ARCHIVE does not contain a macOS application"
  mv "$OUTPUT/unpacked/Dispatch.app" "$app.signing"
  rmdir "$OUTPUT/unpacked"
  sign_app "$app.signing" "$IDENTITY"
  mv "$app.signing" "$app"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$OUTPUT/Dispatch-$version.dmg"

# 2. Notarize and staple the app itself: Gatekeeper accepts it offline after it leaves the DMG.
if ! xcrun stapler validate -q "$app" 2>/dev/null; then
  [[ -f "$OUTPUT/app-submission.zip" ]] || ditto -c -k --keepParent "$app" "$OUTPUT/app-submission.zip"
  notarize "$OUTPUT/app-notarization.json" "$OUTPUT/app-submission.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi
spctl --assess --type execute --verbose=2 "$app"

# 3. The download: an LZMA-compressed DMG of the stapled app, signed with the same identity.
if [[ ! -f "$dmg" ]]; then
  stage="$OUTPUT/dmg-contents"
  rm -rf "$stage" "$OUTPUT/Dispatch.next.dmg"
  mkdir "$stage"
  ditto "$app" "$stage/Dispatch.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname Dispatch -srcfolder "$stage" -fs HFS+ -format ULMO "$OUTPUT/Dispatch.next.dmg"
  codesign --sign "$IDENTITY" --timestamp "$OUTPUT/Dispatch.next.dmg"
  codesign --verify --strict --verbose=2 "$OUTPUT/Dispatch.next.dmg"
  rm -rf "$stage"
  mv "$OUTPUT/Dispatch.next.dmg" "$dmg"
fi

# 4. Notarize and staple the DMG: it opens without a network check too.
if ! xcrun stapler validate -q "$dmg" 2>/dev/null; then
  notarize "$OUTPUT/dmg-notarization.json" "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
echo "$digest  $(basename "$dmg")" > "$OUTPUT/SHA256SUMS"
echo
echo "Notarized and stapled: $dmg"
echo "SHA-256 $digest"
echo "Send back $(basename "$dmg") as is. Keep the *-notarization.json receipts."
