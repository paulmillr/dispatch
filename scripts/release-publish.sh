#!/bin/bash
# Release, step 2, on the signing machine (docs/releasing.md, Signing machine), once scripts/release.sh has pushed the
# signed version commit; run here by hand (it waits for GitHub's build):
#
#   scripts/release-publish.sh X.Y.Z [--variant NAME] [--no-push] [--trust-ci] [--build-as-user USER]
#
# 1. Checks, every problem listed at once: the version commit of X.Y.Z on main (the newest commit setting the app to
#    X.Y.Z) signed by the commit key pinned in the signer's folder for this app, ~/.config/<cask>-release (release.env,
#    checked against its gnupg/, a keyring of that key alone); then, run from that commit's tree (exported to the work folder,
#    work/<variant>/X.Y.Z there: whatever touches the keys comes from a commit you signed), gh, the keychain, the
#    Developer ID identity, notarytool's credentials and the Homebrew tap.
# 2. GitHub's build (.github/workflows/release.yml), waited for, downloaded and checked against its attestation; then
#    the same build here (scripts/release/rebuild.sh, as scripts/release/verify.sh --reproduce does), with this Mac's
#    Xcode of the build scripts/release/app.json pins, as you or, with --build-as-user, as a macOS user without keys
#    (scripts/release/signer-setup.sh builder). Identical zips; the same app in zips that differ is a warning;
#    different apps stop it.
# 3. On yes: this machine's app signed with Developer ID and the entitlements release/app.json lists, notarized and stapled, in a
#    notarized DMG (scripts/release/notarize.sh), checked as scripts/release/verify.sh checks a release; then, for a
#    published variant, the GitHub release X.Y.Z with the DMG (a draft until the DMG is up; publishing it creates the
#    tag X.Y.Z at the version commit: no tag exists before its release does) and right after it a new commit to the
#    cask in the Homebrew tap's clone next to this one (the updater's feed), pushed. published.json in the work folder
#    records it.
#
# The variants come from release/app.json: the default is the first; one with "publish": false is signed, never published.
# --no-push: everything but publishing. --trust-ci: no build here; GitHub's attested build is signed as it is, and the
# release notes say it was not built twice. Each step's output goes to a log in the work folder; a failed step names it.
# Rerun after a failure: finished steps are skipped, and notarization resumes from its saved submissions.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SELF/release/ui.sh"
config() { python3 -I "$SELF/release/config.py" "$@"; }
NAME="$(config get name)"
REPOSITORY="$(config get repository)"
CASK="$(config get cask)"
CONFIG="${RELEASE_CONFIG:-$HOME/.config/$CASK-release}"
interrupted() { printf '\n'; die "interrupted. Rerun to go on: finished steps are kept"; }
trap interrupted INT TERM

arguments=("$@")
version="" variant="" push=1 trust_ci="" build_user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) variant="${2:-}"; [[ $# -ge 2 ]] || version=invalid; shift ;;
    --build-as-user) build_user="${2:-}"; [[ $# -ge 2 ]] || version=invalid; shift ;;
    --no-push) push="" ;;
    --trust-ci) trust_ci=1 ;;
    [0-9]*) if [[ -z "$version" ]]; then version="$1"; else version=invalid; fi ;;
    *) version=invalid ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release-publish.sh X.Y.Z [--variant NAME] [--no-push] [--trust-ci] [--build-as-user USER]"
variant="$(config variant "$variant" 2>&1)" || die "$variant"
bundle="$(config get "variants.$variant.bundle_id")"
publishes=""
config publishes "$variant" && publishes=1
zip="$NAME-$variant-unsigned.zip"
source "$SELF/release/source.sh"
source_start "$variant/$version"

# 1. The source: which commit is the version, and who signed it.
if [[ -z "$publishes" ]]; then subtitle="$variant · signed, never published"
elif [[ -z "$push" ]]; then subtitle="$variant · --no-push: nothing is published"
else subtitle="$variant"; fi
[[ -z "$trust_ci" ]] || subtitle+=" · --trust-ci: GitHub's build alone"
[[ -n "$quiet" ]] || title "$NAME $version" "$subtitle"
source_checks git gpg gh python3
source_hand_over
tap_repository="$(config get tap)"
tap="${RELEASE_TAP:-$(dirname "$clone")/${tap_repository#*/}}"
cask="Casks/$CASK.rb"
scripts="$work/source/scripts"
# check_dmg and github_build.
source "$scripts/release/verify.sh"

# The rest of the checks: everything the signing and publishing need, before anything long starts.
settings="$CONFIG/$variant.env"
if [[ -f "$settings" ]]; then
  # RELEASE_TEAM, RELEASE_MAC_IDENTITY, RELEASE_NOTARY_PROFILE (written by release/signer-setup.sh; DISPATCH_* before).
  source "$settings"
  team="${RELEASE_TEAM:-${DISPATCH_TEAM:-}}"
  identity="${RELEASE_MAC_IDENTITY:-${DISPATCH_MAC_IDENTITY:-}}"
  profile="${RELEASE_NOTARY_PROFILE:-${DISPATCH_NOTARY_PROFILE:-}}"
else
  bad "no $settings; run: scripts/release/signer-setup.sh $variant KEYS_DIR AuthKey_ID.p8 ISSUER_ID"
fi

pending "gh"
# A fine-grained token for the repository needs only these (docs/releasing.md, Signing machine).
token="a token for $REPOSITORY with Contents: read+write; Actions/Attestations: read"
if ! gh auth status > /dev/null 2>&1; then bad "gh is not logged in; run: gh auth login, with $token"
elif ! gh run list -R "$REPOSITORY" --workflow release.yml --limit 1 > /dev/null 2>&1; then bad "gh cannot read $REPOSITORY's Actions; it needs $token"
else ok "gh logged in, reads Actions"; fi

# Signing over SSH needs the login keychain unlocked, and macOS cannot ask in a dialog there: asked now, not later.
keychain="$HOME/Library/Keychains/login.keychain-db"
if ! security show-keychain-info "$keychain" > /dev/null 2>&1; then
  printf '  %s· the login keychain is locked; your macOS password:%s\n' "$gray" "$reset"
  security unlock-keychain "$keychain" || bad "the login keychain stays locked"
fi
if [[ -f "$settings" ]]; then
  pending "Developer ID"
  identities="$(security find-identity -v -p codesigning 2> /dev/null || true)"
  if [[ -n "$identity" ]] && grep -qF "\"$identity\"" <<< "$identities"; then
    ok "Developer ID in the keychain" "$identity"
  else
    bad "no valid identity \"$identity\" in the keychain (security find-identity -v -p codesigning)"
  fi
  pending "notarytool"
  if [[ -n "$profile" ]] && xcrun notarytool history --keychain-profile "$profile" --output-format json > /dev/null 2>&1; then
    ok "notarytool signed in" "$profile"
  else
    bad "notarytool's credentials ${profile:-(none)} do not work; run scripts/release/signer-setup.sh $variant again"
  fi
fi

if [[ -z "$publishes" ]]; then
  skipped "Homebrew tap" "$variant is not published"
elif [[ ! -f "$tap/$cask" ]]; then
  bad "no clone of $tap_repository with $cask at $tap (RELEASE_TAP in release.env moves it)"
elif [[ -n "$(git -C "$tap" status --porcelain)" ]]; then
  bad "$tap has uncommitted changes"
elif [[ -z "$(git -C "$tap" config user.name)" || -z "$(git -C "$tap" config user.email)" ]]; then
  bad "git has no user.name or user.email to commit to $tap with"
elif pending "Homebrew tap"; [[ -n "$push" ]] &&
     ! git -C "$tap" push --dry-run --quiet origin HEAD:refs/heads/release-push-check > /dev/null 2>&1; then
  # A dry run to a new name: GitHub checks write access, whatever the branch's state; nothing is created.
  bad "git cannot push to $tap's origin (gh auth setup-git, or an SSH key)"
else
  ok "Homebrew tap" "$tap"
fi

xcode="$(python3 -I "$scripts/release/config.py" get xcode_build)"
xcode_version="$(python3 -I "$scripts/release/config.py" get xcode)"
# The second build's Xcode and user (scripts/release/rebuild.sh, the version commit's).
source "$scripts/release/rebuild.sh"
if [[ -n "$trust_ci" ]]; then
  skipped "Xcode $xcode, build user" "--trust-ci: nothing is built here"
else
  REBUILD_AS_YOU="the build runs with access to your keys (--build-as-user builder keeps them apart)"
  rebuild_checks "$build_user"
fi
[[ -z "$failed" ]] || die "stopped; nothing was built or signed"

# 2. GitHub's build, then the same here.
field() { plutil -extract "$2" raw "$1/build.json"; }
check_build() {
  local dir="$1" file="$1/$(field "$1" mac.file)"
  [[ "$(field "$dir" commit)" == "$commit" && "$(field "$dir" version)" == "$version" && "$(field "$dir" build)" == "$number" &&
     "$(field "$dir" variant)" == "$variant" && "$(field "$dir" mac.bundle_id)" == "$bundle" &&
     "$(field "$dir" xcode.build)" == "$xcode" && "$(field "$dir" mac.file)" == "$zip" && -f "$file" &&
     "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$(field "$dir" mac.sha256)" ]]
}
started=$SECONDS
if [[ -f "$work/github.run" && -f "$work/github/build.json" ]]; then
  skipped "GitHub build" "run $(cat "$work/github.run"), downloaded earlier"
else
  pending "GitHub build (waiting for it)"
  # Runs of the version commit: wait for one to appear (up to 10 minutes after the push) and while one is queued or
  # running.
  waited=0
  while :; do
    runs="$(gh run list -R "$REPOSITORY" --workflow release.yml --commit "$commit" --limit 20 \
      --json status,conclusion,url --jq '.[] | "\(.status) \(.conclusion) \(.url)"' 2> /dev/null || true)"
    if [[ -z "$runs" ]]; then (( waited < 600 )) || break
    elif ! grep -qvE '^completed ' <<< "$runs"; then break; fi
    sleep 20
    waited=$((waited + 20))
  done
  logged "$work/github.log" github_build "$version" "$commit" "$variant" "$work/github"
  if [[ $status != 0 ]]; then
    bad "no attested GitHub build of $version for $variant"
    note "${runs:-no run of ${commit:0:8}}"
    note "$(tail -3 "$work/github.log")"
    if [[ "$variant" == "$(config variant)" ]]; then resume "gh run rerun --failed -R $REPOSITORY RUN_ID, then this again"
    else resume "gh workflow run release.yml -R $REPOSITORY --ref main -f variant=$variant (main's head must be the version commit; once released, --ref $version), then this again"; fi
    exit 1
  fi
  ok "GitHub build" "run $(cat "$work/github.run"), attested, $(since "$started")"
fi
check_build "$work/github" || die "GitHub's build.json is not $variant $version ($number) at ${commit:0:8} with Xcode $xcode"

if [[ -n "$trust_ci" ]]; then
  rm -rf "$work/github.unpacked"
  mkdir -p "$work/github.unpacked"
  ditto -x -k "$work/github/$zip" "$work/github.unpacked"
  skipped "the same build" "--trust-ci: GitHub's build is the only one"
else
  rebuild "$scripts" "$work/source" "$work/local" "$build_user"
  check_build "$work/local" || die "the local build.json is not $variant $version ($number) at ${commit:0:8} with Xcode $xcode"
  rebuild_compare "$work/github" "$work/local" "$scripts/release/compare.py"
fi

# 3. Sign, then publish. The build signed: this machine's, or GitHub's with --trust-ci; mac.done keeps which.
if [[ -s "$work/mac.done" ]]; then from="$(cat "$work/mac.done")"
elif [[ -f "$work/mac.done" ]]; then from=local
elif [[ -n "$trust_ci" ]]; then from=github
else from=local; fi
if [[ "$from" == github ]]; then plan="GitHub's attested build, not built here (--trust-ci)"$'\n'
else plan="this machine's build, the same as GitHub's"$'\n'; fi
plan+="sign with $identity
notarize and staple the app and its DMG, then check them"
if [[ -z "$publishes" ]]; then plan+=$'\n'"published nowhere ($variant)"
elif [[ -z "$push" ]]; then plan+=$'\n'"published nowhere (--no-push)"
else plan+=$'\n'"publish the GitHub release $version, then the Homebrew cask: every installed app updates to it"; fi
block "plan" "$plan"
ask "$([[ -n "$push" && -n "$publishes" ]] && echo ship || echo sign)" "$version" || die "stopped; nothing was signed"
started=$SECONDS

dmg="$work/$NAME-$version.dmg"
signed="$work/$from/${zip%-unsigned.zip}-signed/$NAME-$version.dmg"
if [[ -f "$work/mac.done" ]]; then
  skipped "signed and notarized" "done earlier"
else
  # The entitlements the signer vouches for: release/app.json's, from the signed version commit.
  python3 -I "$scripts/release/config.py" entitlements > "$work/entitlements.plist"
  step "signed and notarized" "$work/notarize.log" bash "$scripts/release/notarize.sh" "$work/$from/$zip" \
    --identity "$identity" --profile "$profile" --entitlements "$work/entitlements.plist" --sha256 "$(field "$work/$from" mac.sha256)"
  cp "$signed" "$dmg"
  step "DMG checked" "$work/check.log" check_dmg "$dmg" "$team" "$work/$from.unpacked/$NAME.app" "$scripts/release/compare.py"
  echo "$from" > "$work/mac.done"
fi
digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"

# The release, a draft until its DMG is up; publishing it creates the tag X.Y.Z at the version commit, which is checked.
release_state() {
  gh api "repos/$REPOSITORY/releases?per_page=100" --jq ".[] | select(.tag_name == \"$version\") |
    \"\(.id) \(.draft) \([.assets[] | select(.name == \"$NAME-$version.dmg\")] | length) \([.assets[] | select(.name == \"$NAME-$version.dmg\") | .digest // \"\"] | join(\"\"))\""
}
publish_release() {
  local state id draft assets existing tagged summary run_link built
  state="$(release_state)"
  if [[ -z "$state" ]]; then
    # The summary: the version commit's body (scripts/release.sh -m), signed with it. One line per paragraph: GitHub
    # shows every newline of the notes as a line break.
    summary="$(git -C "$clone" show -s --format=%b "$commit")"
    run_link="[GitHub Actions](https://github.com/$REPOSITORY/actions/runs/$(cat "$work/github.run"))"
    if [[ "$from" == github ]]; then built="Built once from signed commit $commit by $run_link, attested; not rebuilt before signing."
    else built="Built twice from signed commit $commit, by $run_link, attested, and on the signing machine; both builds matched."; fi
    {
      [[ -z "$summary" ]] || printf '%s\n\n---\n\n' "$summary"
      printf '`brew install --cask %s` or open `.dmg`.\n\n' "$(python3 -I "$scripts/release/config.py" brew)"
      printf '%s Check: `scripts/release/verify.sh %s`, add `--reproduce` to rebuild it.\n' "$built" "$version"
    } > "$work/notes.md"
    gh release create "$version" "$dmg" -R "$REPOSITORY" --draft --target "$commit" --title "$version" --notes-file "$work/notes.md"
    state="$(release_state)"
  fi
  read -r id draft assets existing <<< "$state"
  if [[ "$assets" == 0 ]]; then
    gh release upload "$version" "$dmg" -R "$REPOSITORY"
  elif [[ -n "$existing" && "$existing" != "sha256:$digest" ]]; then
    echo "the GitHub release $version has another $NAME-$version.dmg ($existing): delete that asset if this one replaces it"
    return 1
  fi
  [[ "$draft" != true ]] || gh api -X PATCH "repos/$REPOSITORY/releases/$id" -F draft=false > /dev/null
  tagged="$(gh api "repos/$REPOSITORY/commits/refs/tags/$version" --jq .sha)"
  [[ "$tagged" == "$commit" ]] || { echo "the tag $version is $tagged, not the version commit $commit"; return 1; }
}
publish_cask() {
  git -C "$tap" pull --ff-only --quiet
  python3 -I - "$tap/$cask" "$version" "$digest" "$NAME" <<'PY'
import re, sys
from pathlib import Path
path, version, digest, name = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
text = path.read_text()
# An updater reads these two literals and the URL (docs/releasing.md, Mac automatic updates).
text, versions = re.subn(r'^(\s*version )"[^"]*"$', rf'\g<1>"{version}"', text, flags=re.M)
text, digests = re.subn(r'^(\s*sha256 )"[0-9a-f]{64}"$', rf'\g<1>"{digest}"', text, flags=re.M)
if versions != 1 or digests != 1 or f'{name}-#{{version}}.dmg' not in text:
    sys.exit(f'{path} needs exactly one version "…" and one sha256 "…" line, and a url ending in {name}-#{{version}}.dmg')
path.write_text(text)
PY
  # A new commit, never an amended one; already made by an interrupted run, it is only pushed.
  git -C "$tap" diff --quiet || { git -C "$tap" add "$cask" && TZ=UTC git -C "$tap" commit --quiet -m "$NAME $version"; }
  git -C "$tap" push --quiet
}
if [[ -n "$publishes" && -n "$push" ]]; then
  if [[ -f "$work/release.done" ]]; then skipped "GitHub release" "done earlier"
  else step "GitHub release" "$work/release.log" publish_release; touch "$work/release.done"; fi
  if [[ -f "$work/tap.done" ]]; then skipped "Homebrew cask" "done earlier"
  else step "Homebrew cask" "$work/tap.log" publish_cask; touch "$work/tap.done"; fi
fi

released="" tapped=""
[[ ! -f "$work/release.done" ]] || released="https://github.com/$REPOSITORY/releases/tag/$version"
[[ ! -f "$work/tap.done" ]] || tapped="$(git -C "$tap" log -1 --format=%H -- "$cask")"
python3 -I - "$work/published.json" "$variant" "$version" "$number" "$commit" "$team" "$(cat "$work/github.run")" \
  "$digest" "$released" "$tapped" "$NAME-$version.dmg" "$from" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
path, variant, version, number, commit, team, run, digest, released, tapped, dmg, signed = sys.argv[1:]
path = Path(path)
published = json.loads(path.read_text()) if path.is_file() else {}
published.update(variant=variant, version=version, build=number, commit=commit, team=team, github_run=int(run),
                 published=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                 # The build signed: "local" (matched GitHub's) or "github" (--trust-ci, built once).
                 signed_build=signed,
                 mac={'dmg': dmg, 'sha256': digest, 'release': released or None, 'cask_commit': tapped or None})
path.write_text(json.dumps(published, indent=2) + '\n')
PY

summary="$dmg
SHA-256 $digest"
[[ -z "$released" ]] || summary+=$'\n'"$released"
[[ -z "$tapped" ]] || summary+=$'\n'"cask: ${tap_repository#*/} ${tapped:0:8}"
summary+=$'\n'"record: $work/published.json"
block "$([[ -n "$released" ]] && echo published || echo "signed, not published")" "$summary"
printf '\n  %sdone in %s%s\n\n' "$gray" "$(since "$started")" "$reset"
