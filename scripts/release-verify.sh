#!/bin/bash
# Checks a published Mac release from anywhere, the maintainer's Mac included (docs/releasing.md, Checking a release):
#
#   scripts/release-verify.sh X.Y.Z --team TEAMID
#
# Downloads Dispatch-X.Y.Z.dmg from the GitHub release and the GitHub builder's files of that tag (with gh, logged in:
# a token that reads public repositories is enough), checks their attestation (built by .github/workflows/release.yml
# from the tag's commit on a GitHub-hosted runner), then checks the DMG as the signing machine did before publishing:
# an LZMA DMG with Dispatch.app and an Applications link, both signed by TEAMID's Developer ID, notarized, stapled and
# accepted by Gatekeeper, and its app the GitHub build with only signatures and the stapled ticket changed
# (scripts/release-compare.py --signed). Then that the Homebrew cask, the updater's feed, names this version and DMG.
# Works in tmp/release-verify/X.Y.Z.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY=paulmillr/dispatch
WORKFLOW=.github/workflows/release.yml
CASK=https://raw.githubusercontent.com/paulmillr/homebrew-tap/HEAD/Casks/dispatch.rb

fail() { echo "error: $*" >&2; exit 1; }

check_authority() {
  local details; details="$(codesign -dvv "$1" 2>&1)"
  grep -q "^Authority=Developer ID Application: .*($2)\$" <<< "$details" || fail "$1 is not signed by Developer ID $2"
  grep -qx "TeamIdentifier=$2" <<< "$details" || fail "$1: TeamIdentifier is not $2"
  grep -E '^(Authority=Developer ID Application|TeamIdentifier|Timestamp)' <<< "$details"
}

# check_dmg DMG TEAM BUILD_APP COMPARE: the DMG is the release download of the unsigned BUILD_APP, signed by TEAM.
# COMPARE is release-compare.py (the caller's, from the verified source).
check_dmg() {
  local dmg="$1" team="$2" build="$3" compare="$4"
  # hdiutil, not `diskutil image` (macOS 26+): it also runs on older Macs. Its deprecation notices are noise.
  local format; format="$(hdiutil imageinfo -plist "$dmg" 2>/dev/null | plutil -extract Format raw -)"
  [[ "$format" == ULMO ]] || fail "DMG format is $format, expected ULMO (LZMA)"
  codesign --verify --strict --verbose=2 "$dmg"
  check_authority "$dmg" "$team"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  local mount; mount="$(mktemp -d)"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" > /dev/null 2>&1 || fail "cannot mount $dmg"
  local result=0
  (
    set -e
    [[ "$(ls "$mount" | tr '\n' ' ')" == "Applications Dispatch.app " ]] || fail "the DMG holds $(ls "$mount" | tr '\n' ' ')"
    [[ "$(readlink "$mount/Applications")" == /Applications ]] || fail "the DMG's Applications is not a link to /Applications"
    python3 -I "$compare" --signed "$build" "$mount/Dispatch.app"
    codesign --verify --deep --strict --verbose=2 "$mount/Dispatch.app"
    check_authority "$mount/Dispatch.app" "$team"
    xcrun stapler validate "$mount/Dispatch.app"
    spctl --assess --type execute --verbose=2 "$mount/Dispatch.app"
  ) || result=$?
  hdiutil detach -quiet "$mount" || hdiutil detach -force -quiet "$mount"
  rmdir "$mount"
  [[ $result == 0 ]] || fail "$dmg is not the signed build"
}

# github_build VERSION COMMIT VARIANT DIR: the GitHub builder's files of VERSION into DIR, each checked against its
# attestation: made by WORKFLOW in REPOSITORY, on a GitHub-hosted runner, from refs/tags/VERSION at COMMIT.
github_build() {
  local version="$1" commit="$2" variant="$3" dir="$4" runs id
  runs="$(gh run list -R "$REPOSITORY" --workflow "$(basename "$WORKFLOW")" --commit "$commit" --status success \
    --json databaseId,headBranch --limit 50 --jq ".[] | select(.headBranch == \"$version\") | .databaseId")"
  [[ -n "$runs" ]] || fail "no successful GitHub build of $version ($commit) yet: gh run list -R $REPOSITORY --workflow $(basename "$WORKFLOW")"
  rm -rf "$dir"
  for id in $runs; do
    gh run download "$id" -R "$REPOSITORY" -n "dispatch-$variant-$version" -D "$dir" > /dev/null 2>&1 && break
    rm -rf "$dir"
  done
  [[ -f "$dir/build.json" ]] || fail "no GitHub run of $version kept dispatch-$variant-$version (runs: $(echo $runs))"
  local file
  for file in "$dir"/*; do
    gh attestation verify "$file" -R "$REPOSITORY" --signer-workflow "$REPOSITORY/$WORKFLOW" \
      --source-ref "refs/tags/$version" --source-digest "$commit" --deny-self-hosted-runners > /dev/null ||
      fail "$(basename "$file") from GitHub run $id has no valid attestation from $WORKFLOW at $version ($commit)"
  done
  echo "$id" > "$dir.run"
  echo "GitHub build (run $id): $(ls "$dir" | tr '\n' ' ')attested"
}

# Sourced (scripts/release-publish.sh): the functions only.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

[[ $# == 3 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$2" == --team && "$3" =~ ^[A-Z0-9]{10}$ ]] ||
  fail "usage: scripts/release-verify.sh X.Y.Z --team TEAMID"
version="$1" team="$3"
command -v gh > /dev/null && gh auth status > /dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
work="$ROOT/tmp/release-verify/$version"
mkdir -p "$work"
commit="$(gh api "repos/$REPOSITORY/commits/refs/tags/$version" --jq .sha)"
echo "Dispatch $version: tag $version is $commit"
github_build "$version" "$commit" pilot "$work/github"
rm -rf "$work/app"
mkdir "$work/app"
ditto -x -k "$work/github/$(plutil -extract mac.file raw "$work/github/build.json")" "$work/app"

dmg="$work/Dispatch-$version.dmg"
curl -fsSL --proto =https -o "$dmg" "https://github.com/$REPOSITORY/releases/download/$version/Dispatch-$version.dmg" ||
  fail "no Dispatch-$version.dmg in the GitHub release $version"
check_dmg "$dmg" "$team" "$work/app/Dispatch.app" "$ROOT/scripts/release-compare.py"
digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"

cask="$(curl -fsSL --proto =https "$CASK")"
cask_version="$(sed -nE 's/^ *version "([^"]+)"$/\1/p' <<< "$cask")"
cask_digest="$(sed -nE 's/^ *sha256 "([0-9a-f]{64})"$/\1/p' <<< "$cask")"
echo
echo "Verified Dispatch $version: $dmg"
echo "SHA-256 $digest"
if [[ "$cask_version" == "$version" && "$cask_digest" == "$digest" ]]; then
  echo "The Homebrew cask (the updater's feed) names it."
else
  echo "warning: the Homebrew cask names $cask_version ($cask_digest), not this DMG (GitHub's raw files lag up to 5 minutes)" >&2
  exit 1
fi
