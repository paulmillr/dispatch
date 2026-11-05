#!/bin/bash
# Checks a published Mac release from anywhere, the maintainer's Mac included (docs/releasing.md, Checking a release):
#
#   scripts/release/verify.sh X.Y.Z [--team TEAMID] [--reproduce]
#
# Downloads NAME-X.Y.Z.dmg (scripts/release/app.json names the app) from the GitHub release and the GitHub builder's files
# of that tag (with gh, logged in: a token that reads public repositories is enough), checks their attestation (built
# by .github/workflows/release.yml from the tag's commit on a GitHub-hosted runner), then checks the DMG as the signing
# machine did before publishing: an LZMA DMG with NAME.app and an Applications link, both signed by TEAMID's Developer
# ID (without --team, by whichever team signed the DMG, which it names), notarized, stapled and accepted by Gatekeeper, and its app the GitHub build with only signatures and the stapled
# ticket changed (scripts/release/compare.py --signed). Then that the Homebrew cask, the updater's feed, names this
# version and DMG.
#
# --reproduce: first, that the tag's commit is the version commit of X.Y.Z on main (the newest commit setting the app
# to X.Y.Z), signed by the commit key scripts/release/app.json pins (this checkout's: commit_key, the public key in
# scripts/release/commit-key.asc);
# last, the same build here as the signing machine's (scripts/release/rebuild.sh): the commit's tree with its own
# scripts/release/build.sh, the Xcode build its release/app.json pins (found in /Applications by its build; `xcodes install
# VERSION` when missing), as you or, with --build-as-user, as another user. Identical zips; the same app in zips that
# differ is a warning; different apps fail. About five minutes. Works in tmp/release-verify/X.Y.Z.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPOSITORY="$(python3 -I "$ROOT/scripts/release/config.py" get repository)"
WORKFLOW=.github/workflows/release.yml

fail() { echo "error: $*" >&2; exit 1; }

check_authority() {
  local details; details="$(codesign -dvv "$1" 2>&1)"
  grep -q "^Authority=Developer ID Application: .*($2)\$" <<< "$details" || fail "$1 is not signed by Developer ID $2"
  grep -qx "TeamIdentifier=$2" <<< "$details" || fail "$1: TeamIdentifier is not $2"
  grep -E '^(Authority=Developer ID Application|TeamIdentifier|Timestamp)' <<< "$details"
}

# check_dmg DMG TEAM BUILD_APP COMPARE: the DMG is the release download of the unsigned BUILD_APP (NAME.app), signed by TEAM.
# COMPARE is release/compare.py (the caller's, from the verified source).
check_dmg() {
  local dmg="$1" team="$2" build="$3" compare="$4" app="$(basename "$3")"
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
    [[ "$(ls "$mount" | tr '\n' ' ')" == "Applications $app " ]] || fail "the DMG holds $(ls "$mount" | tr '\n' ' ')"
    [[ "$(readlink "$mount/Applications")" == /Applications ]] || fail "the DMG's Applications is not a link to /Applications"
    python3 -I "$compare" --signed "$build" "$mount/$app"
    codesign --verify --deep --strict --verbose=2 "$mount/$app"
    check_authority "$mount/$app" "$team"
    xcrun stapler validate "$mount/$app"
    spctl --assess --type execute --verbose=2 "$mount/$app"
  ) || result=$?
  hdiutil detach -quiet "$mount" || hdiutil detach -force -quiet "$mount"
  rmdir "$mount"
  [[ $result == 0 ]] || fail "$dmg is not the signed build"
}

# github_build VERSION COMMIT VARIANT DIR: the GitHub builder's files of VERSION (the artifact CASK-VARIANT-VERSION,
# from a successful run on COMMIT, the version commit) into DIR, each checked against its attestation: made by WORKFLOW
# in REPOSITORY, on a GitHub-hosted runner, from COMMIT (pushed to main, or run by hand from main or the version tag;
# only a version commit's run there attests).
github_build() {
  local version="$1" commit="$2" variant="$3" dir="$4" runs id artifact
  artifact="$(python3 -I "$ROOT/scripts/release/config.py" get cask)-$variant-$version"
  runs="$(gh run list -R "$REPOSITORY" --workflow "$(basename "$WORKFLOW")" --commit "$commit" --status success \
    --json databaseId --limit 50 --jq '.[].databaseId')"
  [[ -n "$runs" ]] || fail "no successful GitHub build of $version (${commit:0:8}) yet: gh run list -R $REPOSITORY --workflow $(basename "$WORKFLOW") --commit $commit"
  rm -rf "$dir"
  for id in $runs; do
    gh run download "$id" -R "$REPOSITORY" -n "$artifact" -D "$dir" > /dev/null 2>&1 && break
    rm -rf "$dir"
  done
  [[ -f "$dir/build.json" ]] || fail "no GitHub run of $version kept $artifact (runs: $(echo $runs))"
  local file
  for file in "$dir"/*; do
    gh attestation verify "$file" -R "$REPOSITORY" --signer-workflow "$REPOSITORY/$WORKFLOW" \
      --source-digest "$commit" --deny-self-hosted-runners > /dev/null ||
      fail "$(basename "$file") from GitHub run $id has no valid attestation from $WORKFLOW at ${commit:0:8}"
  done
  echo "$id" > "$dir.run"
  echo "GitHub build (run $id): $(ls "$dir" | tr '\n' ' ')attested"
}

# Sourced (scripts/release-publish.sh): the functions only.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

SELF="$ROOT/scripts"
source "$SELF/release/ui.sh"
config() { python3 -I "$SELF/release/config.py" "$@"; }
usage="usage: scripts/release/verify.sh X.Y.Z [--team TEAMID] [--reproduce [--build-as-user USER]]"
version="" team="" reproduce="" build_user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) [[ $# -ge 2 ]] || die "$usage"; team="$2"; shift ;;
    --build-as-user) [[ $# -ge 2 ]] || die "$usage"; build_user="$2"; shift ;;
    --reproduce) reproduce=1 ;;
    [0-9]*) [[ -z "$version" ]] || die "$usage"; version="$1" ;;
    *) die "$usage" ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ( -z "$team" || "$team" =~ ^[A-Z0-9]{10}$ ) ]] || die "$usage"
[[ -n "$reproduce" || -z "$build_user" ]] || die "--build-as-user goes with --reproduce"
cd "$ROOT"
name="$(config get name)"
work="$ROOT/tmp/release-verify/$version"
# A failed check: its checklist line, then stop.
stop() { bad "$1"; exit 1; }
title "$name $version" "$([[ -n "$reproduce" ]] && echo "the published release, and rebuilt here" || echo "the published release")"

tools="gh python3 curl"
[[ -z "$reproduce" ]] || tools+=" git gpg xcodebuild"
pending "tools"
missing=""
for tool in $tools; do command -v "$tool" > /dev/null || missing+=" $tool"; done
[[ -z "$missing" ]] || stop "missing:$missing"
ok "${tools// /, }"
pending "gh"
gh auth status > /dev/null 2>&1 || stop "gh is not logged in; run: gh auth login"
ok "gh logged in"
rm -rf "$work"
mkdir -p "$work"

pending "tag $version"
commit="$(gh api "repos/$REPOSITORY/commits/refs/tags/$version" --jq .sha 2> /dev/null)" || stop "no tag $version in $REPOSITORY"
if [[ -z "$reproduce" ]]; then
  variant="$(config variant)"
  ok "tag $version" "commit ${commit:0:8}"
else
  # The commit key this checkout pins, in a keyring of its own; main in a ref of its own.
  key="$(config get commit_key)"
  gnupg="$work/gnupg"
  mkdir -m 700 "$gnupg"
  clone="$ROOT"
  trap 'git update-ref -d refs/release-verify/main 2> /dev/null; gpgconf --homedir "$gnupg" --kill all 2> /dev/null || true' EXIT
  gpg --homedir "$gnupg" --batch --quiet --import "$SELF/release/commit-key.asc" 2> /dev/null || true
  keys="$(gpg --homedir "$gnupg" --with-colons --list-keys 2> /dev/null | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }')"
  [[ "$keys" == "$key" ]] || stop "scripts/release/commit-key.asc is not the one key release/app.json pins, $key"
  source "$SELF/release/source.sh"
  signed_commit "$gnupg" "$key" "https://github.com/$REPOSITORY.git" refs/release-verify/main "$commit"
  [[ -n "$commit" ]] || exit 1
  git cat-file -e "$commit:scripts/release/rebuild.sh" 2> /dev/null ||
    stop "$version predates byte-reproducible release builds (scripts/release/rebuild.sh): verify it without --reproduce"
  # The commit's settings, not this checkout's.
  variant="$(config --commit "$commit" variant)"
  xcode="$(config --commit "$commit" get xcode_build)"
  xcode_version="$(config --commit "$commit" get xcode)"
  source "$SELF/release/rebuild.sh"
  rebuild_checks "$build_user"
fi
[[ -z "$failed" ]] || die "stopped; nothing was checked"

started=$SECONDS
pending "GitHub build"
logged "$work/github.log" github_build "$version" "$commit" "$variant" "$work/github"
if [[ $status != 0 ]]; then
  bad "no attested GitHub build of $version"
  note "$(tail -3 "$work/github.log")"
  exit 1
fi
ok "GitHub build" "run $(cat "$work/github.run"), attested"
file="$(plutil -extract mac.file raw "$work/github/build.json")"
mkdir "$work/github.unpacked"
ditto -x -k "$work/github/$file" "$work/github.unpacked"

pending "DMG"
dmg="$work/$name-$version.dmg"
curl -fsSL --proto =https -o "$dmg" "https://github.com/$REPOSITORY/releases/download/$version/$name-$version.dmg" ||
  stop "no $name-$version.dmg in the GitHub release $version"
pinned="$team"
if [[ -z "$team" ]]; then
  # Not pinned: the DMG's own team, named below.
  team="$(codesign -dvv "$dmg" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || stop "the DMG is not signed by a Developer ID team"
fi
logged "$work/dmg.log" check_dmg "$dmg" "$team" "$work/github.unpacked/$name.app" "$SELF/release/compare.py"
if [[ $status != 0 ]]; then
  bad "the DMG is not GitHub's build signed by $team"
  note "$(tail -8 "$work/dmg.log")"
  note "log: $work/dmg.log"
  exit 1
fi
digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
if [[ -n "$pinned" ]]; then
  ok "DMG" "GitHub's build, signed by $team's Developer ID, notarized, stapled"
else
  authority="$(codesign -dvv "$dmg" 2>&1 | sed -n 's/^Authority=Developer ID Application: //p' || true)"
  ok "DMG" "GitHub's build, signed by $authority, notarized, stapled; --team $team requires that team"
fi

pending "Homebrew cask"
cask="$(curl -fsSL --proto =https "https://raw.githubusercontent.com/$(config get tap)/HEAD/Casks/$(config get cask).rb" || true)"
cask_version="$(sed -nE 's/^ *version "([^"]+)"$/\1/p' <<< "$cask")"
cask_digest="$(sed -nE 's/^ *sha256 "([0-9a-f]{64})"$/\1/p' <<< "$cask")"
if [[ "$cask_version" == "$version" && "$cask_digest" == "$digest" ]]; then
  ok "Homebrew cask" "names this DMG (the updater's feed)"
else
  bad "the Homebrew cask names ${cask_version:-nothing} (${cask_digest:-no sha256}), not this DMG (GitHub's raw files lag up to 5 minutes)"
fi

summary="$dmg
SHA-256 $digest"
if [[ -n "$reproduce" ]]; then
  mkdir "$work/source"
  git archive "$commit" | tar -x -C "$work/source"
  # The commit's own build scripts, as on the signing machine.
  rebuild "$work/source/scripts" "$work/source" "$work/local" "$build_user"
  rebuild_compare "$work/github" "$work/local" "$SELF/release/compare.py"
  summary+=$'\n'"rebuilt here: $work/local/$file"
fi
[[ -z "$failed" ]] || die "not verified"
block "verified" "$summary"
printf '\n  %sdone in %s%s\n\n' "$gray" "$(since "$started")" "$reset"
