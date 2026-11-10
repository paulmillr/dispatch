#!/bin/bash
# The iPhone release, Ad Hoc, on the signing machine (docs/releasing.md, Ad Hoc builds); by hand, after or apart from
# scripts/release-publish.sh, for the same version commit:
#
#   scripts/release/iphone.sh X.Y.Z [--variant NAME] [--no-push] [--build-as-user USER]
#
# 1. Checks, every problem listed at once: the version commit of X.Y.Z signed by the pinned commit key, as
#    release-publish.sh checks it (scripts/release/source.sh); then, run from that commit's tree (exported to the work
#    folder, work/<variant>/X.Y.Z/iphone), the settings: <variant>.env's team, <variant>-adhoc.env (RELEASE_ADHOC_URL;
#    optionally RELEASE_ADHOC_SITE and RELEASE_ADHOC_DEPLOY), the keychain, the Apple Distribution identity, the Ad Hoc
#    profiles in <variant>-adhoc-profiles/ (scripts/release/adhoc.py), the site's clone, the pinned Xcode and the build
#    user.
# 2. The build: scripts/release/builder.sh --platform ios, as you or, with --build-as-user, as a macOS user without
#    keys: an .xcarchive signed ad hoc with each target's entitlements. One build: GitHub builds no iPhone app, and
#    nobody can check an Ad Hoc build against one (its .ipa lists the testers' devices).
# 3. On yes: the archive exported with Apple Distribution and the profiles (Dispatch.ipa, checked), its manifest and
#    install page (adhoc.py page), all at RELEASE_ADHOC_URL/, one build at a time. Then published: copied into
#    RELEASE_ADHOC_SITE over the previous build, a git clone's branch rewritten to one commit and pushed
#    (--force-with-lease: no older .ipa stays in its history; a public GitHub repository is refused), and
#    RELEASE_ADHOC_DEPLOY run. Nothing goes to Apple.
#
# --no-push: everything but publishing. Rerun after a failure: finished steps are skipped (markers in the work folder).
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

arguments=("$@")
version="" variant="" push=1 build_user=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) variant="${2:-}"; [[ $# -ge 2 ]] || version=invalid; shift ;;
    --build-as-user) build_user="${2:-}"; [[ $# -ge 2 ]] || version=invalid; shift ;;
    --no-push) push="" ;;
    [0-9]*) if [[ -z "$version" ]]; then version="$1"; else version=invalid; fi ;;
    *) version=invalid ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release/iphone.sh X.Y.Z [--variant NAME] [--no-push] [--build-as-user USER]"
variant="$(config variant "$variant" 2>&1)" || die "$variant"
phone="$(config get "variants.$variant.ios_bundle_id")"
source "$SELF/release/source.sh"
source_start "$variant/$version/iphone"

# 1. The source, then everything the signing and publishing need, before anything long starts.
if [[ -z "$push" ]]; then subtitle="$variant · Ad Hoc · --no-push: nothing is published"
else subtitle="$variant · Ad Hoc"; fi
[[ -n "$quiet" ]] || title "$NAME for iPhone $version" "$subtitle"
source_checks git gpg python3 curl
source_hand_over
scripts="$work/source/scripts"
adhoc() { python3 -I "$scripts/release/adhoc.py" "$@"; }
# The build's name: 0.1.7-20261110, the version and the version commit's UTC date.
label="$(adhoc label "$version" "$number")"

team=""
if [[ -f "$CONFIG/$variant.env" ]]; then
  # RELEASE_TEAM (written by release/signer-setup.sh; DISPATCH_TEAM before).
  source "$CONFIG/$variant.env"
  team="${RELEASE_TEAM:-${DISPATCH_TEAM:-}}"
fi
[[ -n "$team" ]] || bad "no team in $CONFIG/$variant.env; run: scripts/release/signer-setup.sh $variant KEYS_DIR AuthKey_ID.p8 ISSUER_ID"

# Where the build goes: kept on this machine only, never in a repository (docs/releasing.md, Ad Hoc builds).
url="" site="" deploy="" site_root="" branch=""
if [[ -f "$CONFIG/$variant-adhoc.env" ]]; then
  source "$CONFIG/$variant-adhoc.env"
  url="${RELEASE_ADHOC_URL:-${DISPATCH_ADHOC_URL:-}}"
  site="${RELEASE_ADHOC_SITE:-${DISPATCH_ADHOC_SITE:-}}"
  deploy="${RELEASE_ADHOC_DEPLOY:-${DISPATCH_ADHOC_DEPLOY:-}}"
  url="${url%/}"
  if [[ ! "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    bad "RELEASE_ADHOC_URL in $CONFIG/$variant-adhoc.env must be an https:// address (letters, digits, . _ ~ - /)"
  elif [[ -z "$site" && -z "$deploy" ]]; then
    warn "Ad Hoc site" "neither RELEASE_ADHOC_SITE nor RELEASE_ADHOC_DEPLOY: you serve the files yourself"
  else
    ok "Ad Hoc site" "$url"
  fi
else
  bad "no $CONFIG/$variant-adhoc.env with RELEASE_ADHOC_URL (docs/releasing.md, Ad Hoc builds)"
fi

if [[ -n "$site" ]]; then
  pending "the site's clone"
  site_root="$(git -C "$site" rev-parse --show-toplevel 2> /dev/null || true)"
  if [[ -z "$site_root" ]]; then
    if [[ -d "$site" ]]; then ok "the site's folder" "$site, not a git clone"
    else bad "RELEASE_ADHOC_SITE $site is not a folder"; fi
  else
    branch="$(git -C "$site_root" branch --show-current)"
    origin="$(git -C "$site_root" remote get-url origin 2> /dev/null || true)"
    if [[ -z "$branch" || -n "$(git -C "$site_root" status --porcelain)" ]]; then
      bad "$site_root: not on a branch, or uncommitted changes"
    elif [[ "$origin" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] &&
         [[ "$(curl -s -o /dev/null -w '%{http_code}' "https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}")" == 200 ]]; then
      # The .ipa lists the testers' UDIDs: never into a repository anyone can read.
      bad "$site_root's origin is a public GitHub repository, and the .ipa lists your testers' devices: use a private one"
    else
      ok "the site's clone" "$site_root, $branch"
    fi
  fi
fi

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

# 3. Sign, then publish.
base="$url"
plan="sign $phone $label (build $number) with Apple Distribution and the Ad Hoc profiles"
if [[ -z "$push" ]]; then plan+=$'\n'"published nowhere (--no-push)"
else plan+=$'\n'"publish it at $base/${site:+ (from $site)}${deploy:+, then: $deploy}"; fi
block "plan" "$plan"
ask "$([[ -n "$push" ]] && echo ship || echo sign)" "$version for iPhone" || die "stopped; nothing was signed"
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
  adhoc page "$work/adhoc" "$base" "$phone" "$version" "$number"
}
if [[ -f "$work/export.done" ]]; then
  skipped "signed" "done earlier"
else
  step "signed" "$work/export.log" export_build
  touch "$work/export.done"
fi

publish_site() {
  if [[ -n "$site" ]]; then
    [[ -z "$site_root" ]] || git -C "$site_root" pull --ff-only --quiet
    # Builds were once in <variant>/X.Y.Z/: an older .ipa there would stay online.
    rm -rf "${site:?}/$variant"
    cp "$ipa" "$work/adhoc/manifest.plist" "$work/adhoc/index.html" "$site/"
    if [[ -n "$site_root" ]]; then
      # One commit, the site as it is now: no older .ipa stays in the branch's history.
      git -C "$site" add -A .
      local old new
      old="$(git -C "$site_root" rev-parse HEAD)"
      new="$(TZ=UTC git -C "$site_root" commit-tree "$(git -C "$site_root" write-tree)" -m "$NAME $label, Ad Hoc")"
      git -C "$site_root" update-ref "refs/heads/$branch" "$new" "$old"
      git -C "$site_root" reset --quiet
      git -C "$site_root" push --quiet --force-with-lease="$branch:$old" origin "$branch"
    fi
  fi
  [[ -z "$deploy" ]] || bash -c "$deploy"
}
if [[ -z "$push" ]]; then
  skipped "published" "--no-push"
elif [[ -f "$work/adhoc.done" ]]; then
  skipped "published" "done earlier"
elif [[ -z "$site" && -z "$deploy" ]]; then
  skipped "published" "no site: serve $work/adhoc at $base/"
else
  step "published" "$work/publish.log" publish_site
  echo "$base/index.html" > "$work/adhoc.done"
fi

summary="$ipa
SHA-256 $(shasum -a 256 "$ipa" | cut -d' ' -f1)"
[[ ! -f "$work/adhoc.done" ]] || summary+=$'\n'"install: $url/ in Safari on a registered iPhone"
block "$label $([[ -f "$work/adhoc.done" ]] && echo published || echo "signed, not published")" "$summary"
printf '\n  %sdone in %s%s\n\n' "$gray" "$(since "$started")" "$reset"
