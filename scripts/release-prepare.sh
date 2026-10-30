#!/bin/bash
# Release, maintainer side (docs/releasing.md). The signing machine runs release-publish.sh in between.
#
#   scripts/release-prepare.sh [--stable] [--no-push]
#       From a clean checkout, builds the Mac app (`./run.sh --prod`) and the iPhone app with its watch app
#       (`./run.sh --archive`, signed ad hoc: this Mac holds no team, certificate or key), stamped with one UTC build
#       number (20261030.1345). Keeps a reference copy in tmp/dispatch-release/<pilot|stable>/<build> (git-ignored):
#       Dispatch.app, its dSYM, the .xcarchive and COMMIT. Puts the two zips and release.json (versions, bundle ids,
#       SHA-256s) in ../dispatch-release/<pilot|stable>/<build>, refreshes its bin/ (the signing machine's scripts)
#       and README.md, commits and pushes. The signing machine pulls and runs bin/release-publish.sh.
#
#   scripts/release-prepare.sh --verify [DMG] --team TEAMID
#       After pulling ../dispatch-release, checks the signed DMG (default: the newest published one) against the
#       reference copy: only signatures and the stapled ticket differ, every executable is byte-identical without its
#       signature, and the DMG and the app are signed by TEAMID, notarized, stapled and accepted by Gatekeeper.
#       Prints the publish steps of a Pilot build: the GitHub release and the Homebrew cask.
#
#   Without --stable it is the Pilot account's (yachts.dispatch.pilot.*, Dispatch-Pilot-unsigned.zip): the GitHub and
#   Homebrew release, and TestFlight. --stable is the stable account's (yachts.dispatch.*), published nowhere yet. Both
#   are named Dispatch (docs/ios.md, Pilot and stable); --verify tells them apart by the DMG app's bundle id. DISPATCH_RELEASE_REPO overrides ../dispatch-release.
#
# Verification needs the reference copy: a build the signer makes from source differs (Xcode, SDK, paths).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASES="$ROOT/tmp/dispatch-release"
OUTBOX="${DISPATCH_RELEASE_REPO:-$(dirname "$ROOT")/dispatch-release}"
# GitHub refuses files over 100 MB.
LIMIT=$((95 * 1024 * 1024))

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: release-prepare.sh [--stable] [--no-push] | --verify [DMG] --team TEAMID"; }

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

# Xcode signs for iOS only with a team, so the archive is built unsigned; this signs it ad hoc, innermost first, with
# each target's entitlements (the watch's App Group, named after the phone app), which export on the signing machine
# keeps when it signs with Apple Distribution.
sign_archive() {
  local app="$1/Products/Applications/DispatchMobile.app" group entitlements
  group="group.$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
  entitlements="$(mktemp)"
  sed "s/\$(DISPATCH_APP_GROUP)/$group/" "$ROOT/Watch/Widgets/DispatchWatchWidgets.entitlements" > "$entitlements"
  codesign --force --sign - --generate-entitlement-der --entitlements "$entitlements" \
    "$app/Watch/DispatchWatch.app/PlugIns/DispatchWatchWidgets.appex"
  sed "s/\$(DISPATCH_APP_GROUP)/$group/" "$ROOT/Watch/App/DispatchWatch.entitlements" > "$entitlements"
  codesign --force --sign - --generate-entitlement-der --entitlements "$entitlements" "$app/Watch/DispatchWatch.app"
  codesign --force --sign - --generate-entitlement-der "$app"
  rm "$entitlements"
  codesign --verify --deep --strict "$app"
}

# release.json: what the signing machine checks and signs.
describe() {
  python3 - "$@" <<'PY'
import hashlib, json, plistlib, sys
from datetime import datetime, timezone
from pathlib import Path
outgoing, variant, number, commit, zip_name, output = sys.argv[1:]
outgoing, output = Path(outgoing), Path(output)
def digest(name): return hashlib.sha256((outgoing / name).read_bytes()).hexdigest()
mac = plistlib.loads((output / 'Dispatch.app/Contents/Info.plist').read_bytes())
ios = plistlib.loads((output / 'DispatchMobile.xcarchive/Products/Applications/DispatchMobile.app/Info.plist').read_bytes())
release = {
    'variant': variant, 'build': number, 'commit': commit,
    'created': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'mac': {'version': mac['CFBundleShortVersionString'], 'bundle_id': mac['CFBundleIdentifier'],
            'file': zip_name, 'sha256': digest(zip_name)},
    'ios': {'version': ios['CFBundleShortVersionString'], 'bundle_id': ios['CFBundleIdentifier'],
            'file': 'DispatchMobile.xcarchive.zip', 'sha256': digest('DispatchMobile.xcarchive.zip')},
}
(outgoing / 'release.json').write_text(json.dumps(release, indent=2) + '\n')
PY
}

build() {
  local stable="$1" push="$2" variant=pilot
  [[ -z "$stable" ]] || variant=stable
  cd "$ROOT"
  git diff --quiet HEAD -- || fail "tracked files have uncommitted changes; commit them first"
  git -C "$OUTBOX" rev-parse --git-dir > /dev/null 2>&1 || fail "$OUTBOX is not a clone of the release repository"
  [[ -z "$(git -C "$OUTBOX" status --porcelain)" ]] || fail "$OUTBOX has uncommitted changes"
  [[ -z "$push" ]] || git -C "$OUTBOX" pull --ff-only --quiet
  local number; number="$(date -u +%Y%m%d.%H%M)"
  local output="$RELEASES/$variant/$number" outgoing="$OUTBOX/$variant/$number"
  [[ ! -e "$output" && ! -e "$outgoing" ]] || fail "build $number exists; wait a minute"
  mkdir -p "$output"
  ./run.sh --prod --just-build ${stable:+--stable} --build-number "$number"
  ./run.sh --archive "$output/DispatchMobile.xcarchive" ${stable:+--stable} --build-number "$number"
  sign_archive "$output/DispatchMobile.xcarchive"
  local products="$ROOT/build/Build/Products/Release"
  ditto "$products/Dispatch.app" "$output/Dispatch.app"
  ditto "$products/Dispatch.app.dSYM" "$output/Dispatch.app.dSYM"
  git rev-parse HEAD > "$output/COMMIT"
  package "$variant" "$number" "$output" "$push"
}

# The release folder from the reference copy $3: the zips, release.json, the signing machine's scripts; committed, and
# pushed unless $4 is empty.
package() {
  local variant="$1" number="$2" output="$3" push="$4" zip=Dispatch-Pilot-unsigned.zip
  [[ "$variant" == pilot ]] || zip=Dispatch-unsigned.zip
  local outgoing="$OUTBOX/$variant/$number"
  mkdir -p "$outgoing"
  ditto -c -k --keepParent "$output/Dispatch.app" "$outgoing/$zip"
  ditto -c -k --keepParent "$output/DispatchMobile.xcarchive" "$outgoing/DispatchMobile.xcarchive.zip"
  local file
  for file in "$outgoing"/*.zip; do
    [[ "$(stat -f %z "$file")" -lt $LIMIT ]] || fail "$file is over 95 MB, more than GitHub takes"
  done
  describe "$outgoing" "$variant" "$number" "$(cat "$output/COMMIT")" "$zip" "$output"
  # The signing machine's side, as of this build.
  mkdir -p "$OUTBOX/bin"
  cp "$ROOT"/scripts/release-{publish,notarize,signer-setup}.sh "$OUTBOX/bin/"
  cp "$ROOT/docs/releasing.md" "$OUTBOX/README.md"
  printf '%s\n' '# Work folders of bin/release-publish.sh: only release.json, the zips, the DMG and published.json are kept.' \
    '*/*/*-signed/' '*/*/export/' > "$OUTBOX/.gitignore"
  local mac_version ios_version
  mac_version="$(plutil -extract mac.version raw "$outgoing/release.json")"
  ios_version="$(plutil -extract ios.version raw "$outgoing/release.json")"
  git -C "$OUTBOX" add -A
  TZ=UTC git -C "$OUTBOX" commit --quiet -m "$variant $number: Mac $mac_version, iPhone $ios_version ($(cut -c1-8 "$output/COMMIT"))"
  [[ -z "$push" ]] || git -C "$OUTBOX" push --quiet
  cat <<EOF

Dispatch $variant $number ($(cut -c1-8 "$output/COMMIT")): Mac $mac_version, iPhone $ios_version
  Reference copy  $output
  Release folder  $outgoing ($([[ -n "$push" ]] && echo pushed || echo "committed, not pushed"))
release.json SHA-256 $(shasum -a 256 "$outgoing/release.json" | cut -d' ' -f1)

On the signing machine:  git pull && bin/release-publish.sh
Then here:               git -C $OUTBOX pull && scripts/release-prepare.sh --verify --team TEAMID
EOF
}

verify() {
  local dmg="$1" team="$2"
  if [[ -z "$dmg" ]]; then
    # The newest published build of either variant: build numbers sort as text.
    local published
    published="$(cd "$OUTBOX" && ls -d */*/published.json 2>/dev/null | sort -t/ -k2,2 | tail -1 || true)"
    [[ -n "$published" ]] || fail "nothing published in $OUTBOX yet (git -C $OUTBOX pull)"
    dmg="$OUTBOX/$(dirname "$published")/$(plutil -extract mac.dmg raw "$OUTBOX/$published")"
  fi
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
  local number; number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$signed/Contents/Info.plist")"
  local variant
  case "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$signed/Contents/Info.plist")" in
    yachts.dispatch.pilot.app) variant=pilot ;;
    yachts.dispatch.app) variant=stable ;;
    *) fail "the DMG's app is neither yachts.dispatch.pilot.app nor yachts.dispatch.app" ;;
  esac
  local reference="$RELEASES/$variant/$number/Dispatch.app"
  [[ -d "$reference" ]] || fail "no reference copy for $variant build $number: $reference"

  # 1. Only signatures may differ: the Mach-O files, the resource seal and the stapled ticket.
  local executables; executables="$(macho_files "$reference")"
  local unexpected=0 line path
  while IFS= read -r line; do
    case "$line" in
      "Files $reference/"*" and $signed/"*" differ")
        path="${line#Files "$reference"/}"; path="${path%% and *}"
        [[ "$path" == Contents/_CodeSignature/CodeResources ]] && continue
        grep -qxF "$path" <<< "$executables" && continue
        # A link to an executable (helper/darwin-arm64) differs with its target; links are checked below.
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
  if [[ "$variant" == stable ]]; then
    printf '\nVerified Dispatch %s build %s (stable, yachts.dispatch.app): %s\nSHA-256 %s\n' "$version" "$number" "$dmg" "$digest"
    echo "It is the stable account's build: the GitHub release and the Homebrew cask are Pilot's."
    return
  fi
  [[ "$(basename "$dmg")" == "Dispatch-$version.dmg" ]] || echo "note: publish it as Dispatch-$version.dmg (the cask URL's name)"
  cat <<EOF

Verified Dispatch $version build $number (Pilot, yachts.dispatch.pilot.app): $dmg
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

# Sourced (a test of package): the functions only.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
if [[ "${1:-}" == --verify ]]; then
  case $# in
    3) [[ "$2" == --team ]] || usage; verify "" "$3" ;;
    4) [[ "$3" == --team ]] || usage; verify "$2" "$4" ;;
    *) usage ;;
  esac
  exit
fi
stable="" push=1
for argument in "$@"; do
  case "$argument" in
    --stable) stable=1 ;;
    --no-push) push="" ;;
    *) usage ;;
  esac
done
build "$stable" "$push"
