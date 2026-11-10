#!/bin/bash
# The iPhone build, Ad Hoc, on the signing machine (docs/releasing.md, Ad Hoc builds); by hand, from any commit you
# pushed, a version commit or not: no version to bump, as many builds as you like.
#
#   scripts/release/iphone.sh [BRANCH|COMMIT] [--variant NAME] [--no-push] [--build-as-user USER]
#
# 1. Checks, every problem listed at once: the commit (origin's main by default; a branch of origin, or a commit on
#    one), and whether the pinned commit key signed it: for now only a warning (scripts/release/source.sh, signed_ref);
#    then, run from that commit's tree (exported to the work folder, work/<variant>/iphone/<commit>): <variant>.env's
#    team, the keychain, the Apple Distribution identity, the Ad Hoc profiles in <variant>-adhoc-profiles/
#    (scripts/release/adhoc.py), the release record (<cask>-release, a private clone next to this one; RELEASE_RECORD
#    in release.env moves it) and its install site, adhoc-site/ there, the folder it is served from and the deploy
#    command (RELEASE_ADHOC_SITE and RELEASE_ADHOC_DEPLOY in <variant>-adhoc.env), the pinned Xcode and the build user.
# 2. The build: scripts/release/builder.sh --platform ios, as you or, with --build-as-user, as a macOS user without
#    keys: an .xcarchive signed ad hoc with each target's entitlements. The version is the commit's (the Mac app's), the
#    build number its UTC time, and the build's name both: 0.1.7-20261110.1432. One build: GitHub builds no iPhone
#    app, and nobody can check an Ad Hoc build against one (its .ipa lists the testers' devices).
# 3. On yes: the archive exported with Apple Distribution and the profiles (Dispatch.ipa, checked). Then the build goes
#    into the record: the site's .ipa, its manifest's version and its page's (adhoc.py site; the addresses stay as the
#    site has them), and <variant>/<name>/ with the .ipa and build.json, committed and pushed; then the site copied
#    into the folder it is served from, if it has one (pushed, if a clone), and the deploy command run there (or in
#    adhoc-site/). Nothing goes to Apple.
#
# --no-push: everything but the record and the deploy. Rerun after a failure: finished steps are skipped (markers in the
# work folder).
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$SELF/release/ui.sh"
config() { python3 -I "$SELF/release/config.py" "$@"; }
NAME="$(config get name)"
REPOSITORY="$(config get repository)"
CASK="$(config get cask)"
CONFIG="${RELEASE_CONFIG:-$HOME/.config/$CASK-release}"
interrupted() { printf '\n'; die "interrupted. Rerun to go on: finished steps are kept"; }
trap interrupted INT TERM

# version stays empty: source_checks then checks the commit ref names (signed_ref), which sets it.
version="" ref="" variant="" push=1 build_user="" options=() usage=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) variant="${2:-}"; [[ $# -ge 2 ]] || usage=1; options+=("$1" "$variant"); shift ;;
    --build-as-user) build_user="${2:-}"; [[ $# -ge 2 ]] || usage=1; options+=("$1" "$build_user"); shift ;;
    --no-push) push=""; options+=("$1") ;;
    -*) usage=1 ;;
    *) if [[ -z "$ref" ]]; then ref="$1"; else usage=1; fi ;;
  esac
  shift
done
ref="${ref:-main}"
[[ -z "$usage" && "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] ||
  die "usage: scripts/release/iphone.sh [BRANCH|COMMIT] [--variant NAME] [--no-push] [--build-as-user USER]"
variant="$(config variant "$variant" 2>&1)" || die "$variant"
phone="$(config get "variants.$variant.ios_bundle_id")"
source "$SELF/release/source.sh"
# One work folder per commit. The clone's copy names a branch or a short commit here, and moves to the commit's folder
# once it knows it; the commit's copy gets the full commit, so it is quiet only in the clone.
source_start "$variant/iphone/${ref//\//-}"

# 1. The source, then everything the signing and publishing need, before anything long starts.
if [[ -z "$push" ]]; then subtitle="$variant · Ad Hoc · --no-push: nothing is published"
else subtitle="$variant · Ad Hoc"; fi
[[ -n "$quiet" ]] || title "$NAME for iPhone, ${ref:0:8}" "$subtitle"
source_checks git gpg python3 curl
work="$(dirname "$work")/$commit"
arguments=("$commit" ${options[@]+"${options[@]}"})
source_hand_over
scripts="$work/source/scripts"
adhoc() { python3 -I "$scripts/release/adhoc.py" "$@"; }
# The build's name: 0.1.7-20261110.1432, the version and the build number (the commit's UTC time).
label="$(adhoc label "$version" "$number")"

team=""
if [[ -f "$CONFIG/$variant.env" ]]; then
  # RELEASE_TEAM (written by release/signer-setup.sh; DISPATCH_TEAM before).
  source "$CONFIG/$variant.env"
  team="${RELEASE_TEAM:-${DISPATCH_TEAM:-}}"
fi
[[ -n "$team" ]] || bad "no team in $CONFIG/$variant.env; run: scripts/release/signer-setup.sh $variant KEYS_DIR AuthKey_ID.p8 ISSUER_ID"

# Where the build goes: the release record, a private clone next to this one, and its install site (docs/releasing.md,
# Ad Hoc builds).
# The .ipa lists the testers' UDIDs: never into a repository anyone can read.
public() {
  [[ "$1" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] &&
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}")" == 200 ]]
}
record="${RELEASE_RECORD:-$(dirname "$clone")/$CASK-release}"
site="$record/adhoc-site" page=""
# Where it goes online, from <variant>-adhoc.env (docs/releasing.md, Ad Hoc builds; the old flow's DISPATCH_ADHOC_*
# count too): RELEASE_ADHOC_URL, the address it is served at, written into the manifest (without it, the manifest's own
# addresses stay); RELEASE_ADHOC_SITE, the folder served there, when not adhoc-site/ itself: a plain one, or in a clone
# of a private repository; RELEASE_ADHOC_DEPLOY, the command that puts it online, run in that clone (or folder).
[[ ! -f "$CONFIG/$variant-adhoc.env" ]] || source "$CONFIG/$variant-adhoc.env"
url="${RELEASE_ADHOC_URL:-${DISPATCH_ADHOC_URL:-}}"
served="${RELEASE_ADHOC_SITE:-${DISPATCH_ADHOC_SITE:-}}" served_root=""
deploy="${RELEASE_ADHOC_DEPLOY:-${DISPATCH_ADHOC_DEPLOY:-}}"
moved=()
[[ -z "$url" ]] || moved=(--url "$url")
pending "release record"
origin="$(git -C "$record" remote get-url origin 2> /dev/null || true)"
if [[ ! -d "$record" || "$(git -C "$record" rev-parse --show-toplevel 2> /dev/null || true)" != "$(cd "$record" && pwd -P)" ]]; then
  bad "no clone of the release record at $record (RELEASE_RECORD in release.env moves it)"
elif [[ -z "$(git -C "$record" branch --show-current)" || -n "$(git -C "$record" status --porcelain)" ]]; then
  bad "$record: not on a branch, or uncommitted changes"
elif [[ -z "$(git -C "$record" config user.name)" || -z "$(git -C "$record" config user.email)" ]]; then
  bad "git has no user.name or user.email to commit to $record with"
elif public "$origin"; then
  bad "$record's origin is a public GitHub repository, and the .ipa lists your testers' devices: use a private one"
elif [[ -n "$push" ]] && ! git -C "$record" push --dry-run --quiet origin HEAD:refs/heads/release-push-check > /dev/null 2>&1; then
  bad "git cannot push to $record's origin"
elif ! result="$(adhoc site "$site" "$phone" ${moved[@]+"${moved[@]}"} 2>&1)"; then
  bad "the install site, $site"
  note "$result"
else
  ok "release record and install site" "$site: $result"
  page="$(adhoc address "$site" ${moved[@]+"${moved[@]}"})"
fi

if [[ -n "$served" ]]; then
  pending "served folder"
  served_root="$(git -C "$served" rev-parse --show-toplevel 2> /dev/null || true)"
  if [[ ! -d "$served" ]]; then
    bad "no folder $served (RELEASE_ADHOC_SITE in $CONFIG/$variant-adhoc.env)"
  elif [[ -n "$served_root" ]] &&
       [[ -z "$(git -C "$served_root" branch --show-current)" || -n "$(git -C "$served_root" status --porcelain)" ]]; then
    bad "$served_root: not on a branch, or uncommitted changes"
  elif [[ -n "$served_root" ]] && public "$(git -C "$served_root" remote get-url origin 2> /dev/null || true)"; then
    bad "$served_root's origin is a public GitHub repository, and the .ipa lists your testers' devices: use a private one"
  elif [[ -n "$served_root" && -n "$push" ]] &&
       ! git -C "$served_root" push --dry-run --quiet origin HEAD:refs/heads/release-push-check > /dev/null 2>&1; then
    bad "git cannot push to $served_root's origin"
  else
    ok "served from" "$served${served_root:+, a clone (committed and pushed)}"
  fi
fi
if [[ -n "$deploy" ]]; then ok "deploy command" "$deploy"
elif [[ -n "$served_root" ]]; then ok "deploy command" "none: pushing $served_root deploys it"
else warn "deploy command" "no RELEASE_ADHOC_DEPLOY in $CONFIG/$variant-adhoc.env: deploy ${served:-$site} yourself"; fi

# Signing over SSH needs the login keychain unlocked, and macOS cannot ask in a dialog there: asked now, not later.
keychain="$HOME/Library/Keychains/login.keychain-db"
if ! security show-keychain-info "$keychain" > /dev/null 2>&1; then
  printf '  %s· the login keychain is locked; your macOS password:%s\n' "$gray" "$reset"
  security unlock-keychain "$keychain" || bad "the login keychain stays locked"
fi
if [[ -n "$team" ]]; then
  pending "Ad Hoc profiles"
  if result="$(adhoc profiles "$CONFIG/$variant-adhoc-profiles" "$team" "$phone" "$work/ExportOptions.plist" 2>&1)"; then
    ok "Apple Distribution, Ad Hoc profiles" "$result"
  else
    bad "no Ad Hoc signing for $phone"
    note "$result"
  fi
fi

xcode="$(python3 -I "$scripts/release/config.py" get xcode_build)"
xcode_version="$(python3 -I "$scripts/release/config.py" get xcode)"
# rebuild_checks: the pinned Xcode (sets developer) and the build user.
source "$scripts/release/rebuild.sh"
REBUILD_AS_YOU="the build runs with access to your keys (--build-as-user builder keeps them apart)"
rebuild_checks "$build_user"
[[ -z "$failed" ]] || die "stopped; nothing was built or signed"

# 2. The build.
field() { plutil -extract "$2" raw "$1/build.json"; }
if [[ -f "$work/build/build.json" ]]; then
  skipped "build" "done earlier"
else
  rm -rf "$work/build"
  step "build${build_user:+ as $build_user}" "$work/build-run.log" bash "$scripts/release/builder.sh" "$work/source" \
    "$work/build" --commit "$commit" --build-number "$number" --xcode-build "$xcode" --variant "$variant" \
    --platform ios ${build_user:+--user "$build_user"}
fi
file="$work/build/$(field "$work/build" ios.file)"
[[ "$(field "$work/build" commit)" == "$commit" && "$(field "$work/build" version)" == "$version" &&
   "$(field "$work/build" build)" == "$number" && "$(field "$work/build" platform)" == ios &&
   "$(field "$work/build" ios.bundle_id)" == "$phone" && "$(field "$work/build" xcode.build)" == "$xcode" && -f "$file" &&
   "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$(field "$work/build" ios.sha256)" ]] ||
  die "build.json is not the iPhone build of $variant $version ($number) at ${commit:0:8} with Xcode $xcode"

# 3. Sign, then record and deploy.
plan="sign $phone $label (build $number) with Apple Distribution and the Ad Hoc profiles"
if [[ -z "$push" ]]; then plan+=$'\n'"recorded and deployed nowhere (--no-push)"
else
  plan+=$'\n'"into $site and $record/$variant/$label, committed and pushed"
  [[ -z "$served" ]] || plan+=$'\n'"copied into $served${served_root:+, committed and pushed}"
  [[ -z "$deploy" ]] || plan+=$'\n'"then, in ${served_root:-${served:-$site}}: $deploy"
  plan+=$'\n'"installed from $page"
fi
block "plan" "$plan"
ask "$([[ -n "$push" ]] && echo ship || echo sign)" "$label for iPhone" || die "stopped; nothing was signed"
started=$SECONDS

ipa="$work/adhoc/Dispatch.ipa"
export_build() {
  rm -rf "$work/archive" "$work/export" "$work/adhoc"
  mkdir -p "$work/archive" "$work/adhoc"
  ditto -x -k "$file" "$work/archive"
  local archives=("$work"/archive/*.xcarchive)
  [[ ${#archives[@]} == 1 && -d "${archives[0]}" ]] || { echo "no single .xcarchive in $file"; return 1; }
  DEVELOPER_DIR="$developer/Contents/Developer" xcodebuild -exportArchive -archivePath "${archives[0]}" \
    -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export"
  local ipas=("$work"/export/*.ipa)
  [[ ${#ipas[@]} == 1 && -f "${ipas[0]}" ]] || { echo "the export made no single .ipa"; return 1; }
  # Checked as an iPhone checks it: the signature, the profile in it, this version and build.
  rm -rf "$work/check"
  mkdir "$work/check"
  ditto -x -k "${ipas[0]}" "$work/check"
  local app="$work/check/Payload/DispatchMobile.app"
  codesign --verify --deep --strict "$app"
  [[ -f "$app/embedded.mobileprovision" ]] || { echo "no embedded.mobileprovision in the .ipa"; return 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" == "$phone" &&
     "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")" == "$version" &&
     "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" == "$number" ]] ||
    { echo "the .ipa is not $phone $version ($number)"; return 1; }
  rm -rf "$work/check"
  mv "${ipas[0]}" "$ipa"
}
if [[ -f "$work/export.done" ]]; then
  skipped "signed" "done earlier"
else
  step "signed" "$work/export.log" export_build
  touch "$work/export.done"
fi

# A new commit, never an amended one; already made by an interrupted run, it is only pushed.
publish_record() {
  git -C "$record" pull --ff-only --quiet
  adhoc site "$site" "$phone" ${moved[@]+"${moved[@]}"} "$ipa" "$version" "$label"
  mkdir -p "$record/$variant/$label"
  cp "$ipa" "$work/build/build.json" "$record/$variant/$label/"
  git -C "$record" add -A -- adhoc-site "$variant/$label"
  git -C "$record" diff --cached --quiet || TZ=UTC git -C "$record" commit --quiet -m "$NAME for iPhone $label"
  git -C "$record" push --quiet
}
# The served folder gets the site's files over its own; the old flow's <variant>/<build>/ folders go. A clone gets one
# commit with no parent, force-pushed: the site's history would keep every .ipa.
serve_site() {
  # A rerun after a failed push holds the commit already, which no longer fast-forwards: the push then replaces it.
  [[ -z "$served_root" ]] || git -C "$served_root" pull --ff-only --quiet || true
  rm -rf "${served:?}/$variant"
  cp -R "$site/." "$served/"
  [[ -n "$served_root" ]] || return 0
  local branch old new
  branch="$(git -C "$served_root" branch --show-current)"
  git -C "$served" add -A .
  old="$(git -C "$served_root" rev-parse HEAD)"
  if ! git -C "$served_root" diff --cached --quiet; then
    new="$(TZ=UTC git -C "$served_root" commit-tree "$(git -C "$served_root" write-tree)" -m "Site, with $NAME for iPhone $label")"
    git -C "$served_root" update-ref "refs/heads/$branch" "$new" "$old"
    git -C "$served_root" reset --quiet
  fi
  git -C "$served_root" push --quiet --force-with-lease="$branch" origin "$branch"
}
if [[ -z "$push" ]]; then
  skipped "recorded, deployed" "--no-push"
else
  if [[ -f "$work/record.done" ]]; then skipped "recorded" "done earlier"
  else step "recorded" "$work/record.log" publish_record; touch "$work/record.done"; fi
  if [[ -z "$served" ]]; then :
  elif [[ -f "$work/served.done" ]]; then skipped "served" "done earlier"
  else step "copied into $served" "$work/served.log" serve_site; touch "$work/served.done"; fi
  if [[ -z "$deploy" ]]; then [[ -n "$served_root" ]] || skipped "deployed" "no deploy command: deploy ${served:-$site} yourself"
  elif [[ -f "$work/deploy.done" ]]; then skipped "deployed" "done earlier"
  else
    step "deployed" "$work/deploy.log" bash -c 'cd "$1" && bash -c "$2"' _ "${served_root:-${served:-$site}}" "$deploy"
    touch "$work/deploy.done"
  fi
fi

summary="$ipa
SHA-256 $(shasum -a 256 "$ipa" | cut -d' ' -f1)"
[[ ! -f "$work/record.done" ]] || summary+=$'\n'"record: $record/$variant/$label, $(git -C "$record" log -1 --format=%h)"
online=""
[[ ! -f "$work/deploy.done" ]] && [[ -z "$served_root" || ! -f "$work/served.done" ]] || online=1
if [[ -n "$online" ]]; then summary+=$'\n'"online from ${served:-$site}"$'\n'"install: $page"
elif [[ -f "$work/record.done" ]]; then summary+=$'\n'"install, once ${served:-$site} is deployed: $page"; fi
block "$label $([[ -n "$online" ]] && echo published || echo "signed, not published")" "$summary"
printf '\n  %sdone in %s%s\n\n' "$gray" "$(since "$started")" "$reset"
