#!/bin/bash
# Release, step 1 and 3 (maintainer). The signer runs scripts/release-notarize.sh in between.
#
#   scripts/release-prepare.sh
#       Builds `./run.sh --prod` from a clean checkout and keeps a reference copy in
#       tmp/dispatch-release/<version> (git-ignored): Dispatch.app, its dSYM and
#       Dispatch-unsigned.zip for the signer. Send the zip; send its SHA-256 over another channel.
#
#   scripts/release-prepare.sh --verify Dispatch-<version>.dmg --team TEAMID
#       Checks the signer's DMG against that reference copy: only signatures and the stapled ticket
#       differ, every executable is byte-identical without its signature, and the DMG and the app are
#       signed by TEAMID, notarized, stapled and accepted by Gatekeeper. Prints the release steps.
#
# docs/distribution.md has the whole procedure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES="$ROOT/tmp/dispatch-release"

fail() { echo "error: $*" >&2; exit 1; }

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }

is_macho() {
  case "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" in
    feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
  esac
  return 1
}

# Prints every Mach-O file under $1 (symbolic links excluded), relative to $1.
macho_files() {
  (cd "$1" && find . -type f -print0 | while IFS= read -r -d '' file; do
    if is_macho "$file"; then echo "${file#./}"; fi
  done)
}

build() {
  cd "$ROOT"
  git diff --quiet HEAD -- || fail "tracked files have uncommitted changes; commit them first"
  ./run.sh --prod --just-build
  local products="$ROOT/build/Build/Products/Release"
  local version; version="$(version_of "$products/Dispatch.app")"
  local output="$RELEASES/$version"
  [[ ! -e "$output" ]] || fail "$output exists; bump MARKETING_VERSION or move it away"
  mkdir -p "$output"
  ditto "$products/Dispatch.app" "$output/Dispatch.app"
  ditto "$products/Dispatch.app.dSYM" "$output/Dispatch.app.dSYM"
  git rev-parse HEAD > "$output/COMMIT"
  ditto -c -k --keepParent "$output/Dispatch.app" "$output/Dispatch-unsigned.zip"
  local digest; digest="$(shasum -a 256 "$output/Dispatch-unsigned.zip" | cut -d' ' -f1)"
  cat <<EOF

Dispatch $version ($(cut -c1-8 "$output/COMMIT")): $output
  Dispatch.app        reference copy, for --verify
  Dispatch.app.dSYM   symbols for crash reports; keep it
  Dispatch-unsigned.zip
SHA-256 $digest

Send Dispatch-unsigned.zip and scripts/release-notarize.sh to the signer, and the SHA-256 over a
separate channel. They run, and confirm that hash when asked:
  scripts/release-notarize.sh Dispatch-unsigned.zip --identity 'Developer ID Application: NAME (TEAMID)'
Then check what they send back:
  scripts/release-prepare.sh --verify Dispatch-$version.dmg --team TEAMID
EOF
}

verify() {
  local dmg="$1" team="$2"
  [[ -f "$dmg" ]] || fail "no such file: $dmg"
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || fail "--team needs the signer's 10-character Team ID"
  # hdiutil, not `diskutil image` (macOS 26+): it also runs on older Macs. Its deprecation notices are noise.
  local format; format="$(hdiutil imageinfo -plist "$dmg" 2>/dev/null | plutil -extract Format raw -)"
  [[ "$format" == ULMO ]] || fail "DMG format is $format, expected ULMO (LZMA)"
  codesign --verify --strict --verbose=2 "$dmg"
  check_authority "$dmg" "$team"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

  local work; work="$(mktemp -d)"
  local mount="$work/mount"
  mkdir "$mount"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" > /dev/null 2>&1 || fail "cannot mount $dmg"
  trap "hdiutil detach -quiet '$mount' || hdiutil detach -force -quiet '$mount'; rm -rf '$work'" EXIT
  local signed="$mount/Dispatch.app"
  [[ -d "$signed" ]] || fail "the DMG has no Dispatch.app"
  [[ "$(readlink "$mount/Applications")" == /Applications ]] || fail "the DMG has no Applications link"
  local version; version="$(version_of "$signed")"
  local reference="$RELEASES/$version/Dispatch.app"
  [[ -d "$reference" ]] || fail "no reference copy for $version: $reference"

  # 1. Only signatures may differ: the Mach-O files, the resource seal and the stapled ticket.
  local executables; executables="$(macho_files "$reference")"
  local unexpected=0 line path
  while IFS= read -r line; do
    case "$line" in
      "Files $reference/"*" and $signed/"*" differ")
        path="${line#Files "$reference"/}"; path="${path%% and *}"
        [[ "$path" == Contents/_CodeSignature/CodeResources ]] && continue
        grep -qxF "$path" <<< "$executables" && continue
        # A link to an executable (helper/darwin-universal) differs with its target; links are checked below.
        [[ -L "$reference/$path" ]] && is_macho "$reference/$path" && continue ;;
      "Only in $signed/Contents: CodeResources") continue ;;
    esac
    echo "unexpected: $line" >&2; unexpected=1
  done < <(/usr/bin/diff -rq "$reference" "$signed" || true)
  [[ $unexpected == 0 ]] || fail "the signed app is not the reference build"
  local link
  while IFS= read -r -d '' link; do
    [[ "$(readlink "$signed/${link#./}")" == "$(readlink "$reference/${link#./}")" ]] || fail "link changed: ${link#./}"
  done < <(cd "$reference" && find . -type l -print0)

  # 2. Every executable is byte-identical once both signatures are removed.
  while IFS= read -r path; do
    cp "$reference/$path" "$work/a"; cp "$signed/$path" "$work/b"
    codesign --remove-signature "$work/a"; codesign --remove-signature "$work/b"
    cmp -s "$work/a" "$work/b" || fail "executable differs beyond its signature: $path"
    echo "identical: $path"
  done <<< "$executables"

  # 3. Signer, notarization and Gatekeeper.
  codesign --verify --deep --strict --verbose=2 "$signed"
  check_authority "$signed" "$team"
  xcrun stapler validate "$signed"
  spctl --assess --type execute --verbose=2 "$signed"
  local digest; digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  [[ "$(basename "$dmg")" == "Dispatch-$version.dmg" ]] || echo "note: publish it as Dispatch-$version.dmg (the cask URL's name)"
  cat <<EOF

Verified Dispatch $version: $dmg
SHA-256 $digest

Publish the file unchanged (tags are X.Y.Z, no v):
  gh release create $version '$dmg' -R paulmillr/dispatch --title 'Dispatch $version'
In homebrew-tap Casks/dispatch.rb: version "$version", sha256 "$digest", and the url ends in
Dispatch-#{version}.dmg.
EOF
}

check_authority() {
  local details; details="$(codesign -dvv "$1" 2>&1)"
  grep -q "^Authority=Developer ID Application: .*($2)\$" <<< "$details" || fail "$1 is not signed by Developer ID $2"
  grep -qx "TeamIdentifier=$2" <<< "$details" || fail "$1: TeamIdentifier is not $2"
  grep -E '^(Authority=Developer ID Application|TeamIdentifier|Timestamp)' <<< "$details"
}

case "${1:-}" in
  "") build ;;
  --verify)
    [[ $# == 4 && "$3" == --team ]] || fail "usage: release-prepare.sh --verify Dispatch-VERSION.dmg --team TEAMID"
    verify "$2" "$4" ;;
  *) fail "usage: release-prepare.sh [--verify Dispatch-VERSION.dmg --team TEAMID]" ;;
esac
