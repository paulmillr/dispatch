#!/bin/bash
# The signing machine's own release build (docs/releasing.md, Two builders), run by scripts/release-publish.sh once
# GitHub has built the same version commit:
#
#   scripts/release/builder.sh SOURCE OUT --commit SHA --build-number N --xcode-build BUILD [--variant NAME]
#                              [--platform mac|ios] [--user USER]
#
# Builds SOURCE (the version commit's tree) with this Mac's Xcode whose build is BUILD: copies the tree to
# /private/tmp/release-build, runs scripts/release/build.sh there, copies the result to OUT and removes the build's
# files. As you, or with --user as USER, a standard macOS user without keys (scripts/release/signer-setup.sh builder
# makes one): on the signing machine, that user can read neither the login keychain nor the release settings, so
# nothing the build runs reaches a key. Its log is OUT.log. Used by release-publish.sh and release/verify.sh
# --reproduce (scripts/release/rebuild.sh).
set -euo pipefail
fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: scripts/release/builder.sh SOURCE OUT --commit SHA --build-number N --xcode-build BUILD [--variant NAME] [--platform mac|ios] [--user USER]"; }

source="" out="" commit="" number="" xcode="" variant="" platform=mac user="$(id -un)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit|--build-number|--xcode-build|--variant|--platform|--user)
      [[ $# -ge 2 ]] || usage
      case "$1" in
        --commit) commit="$2" ;; --build-number) number="$2" ;; --variant) variant="$2" ;; --platform) platform="$2" ;;
        --user) user="$2" ;; *) xcode="$2" ;;
      esac
      shift ;;
    -*) usage ;;
    *) if [[ -z "$source" ]]; then source="$1"; elif [[ -z "$out" ]]; then out="$1"; else usage; fi ;;
  esac
  shift
done
[[ -d "$source" && -n "$out" && -n "$commit" && -n "$number" && "$xcode" =~ ^[0-9A-Za-z]+$ ]] || usage
[[ ! -e "$out" ]] || fail "$out exists"
# As the build user; as yourself without sudo when that is you.
as_builder() {
  if [[ "$user" == "$(id -un)" ]]; then "$@"; else sudo -n -u "$user" "$@"; fi
}
log="$out.log"
mkdir -p "$(dirname "$out")"
: > "$log"
build=/private/tmp/release-build guest_out=/private/tmp/release-out

# This Mac's Xcode whose build is the pinned one: another one compiles different code.
selected=""
for app in /Applications/Xcode*.app; do
  [[ -L "$app" ]] && continue
  [[ "$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2> /dev/null | sed -n 's/^Build version //p')" == "$xcode" ]] &&
    { selected="$app/Contents/Developer"; break; }
done
[[ -n "$selected" ]] || fail "no Xcode build $xcode in /Applications; brew install xcodes, then xcodes install its version"
as_builder /usr/bin/true || fail "cannot run commands as $user; run: scripts/release/signer-setup.sh builder $user"

cleanup() { as_builder /bin/rm -rf "$build" "$build-home" "$build-products" "$guest_out" > /dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Left by another user (the build path is fixed), it cannot be removed by this one.
for path in "$build" "$build-home" "$build-products" "$guest_out"; do
  [[ ! -e "$path" || "$(stat -f %Su "$path")" == "$user" ]] || fail "$path belongs to $(stat -f %Su "$path"), not $user; remove it: sudo rm -rf $path"
done
cleanup

echo "Build as $user: Xcode $xcode at $selected" >> "$log"
tar --no-mac-metadata -C "$source" -cf - . | as_builder /bin/bash -c 'set -e; umask 022; mkdir "$1"; tar -xf - -C "$1"' _ "$build"
as_builder /usr/bin/env -i HOME=/var/empty USER="$user" LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  DEVELOPER_DIR="$selected" RELEASE_BUILDER=local /bin/bash -c 'umask 022; cd "$1" && shift && exec scripts/release/build.sh "$@"' \
  _ "$build" "$guest_out" --commit "$commit" --build-number "$number" --variant "$variant" --platform "$platform" >> "$log" 2>&1 ||
  { tail -40 "$log" >&2; fail "the build as $user failed (log: $log)"; }
rm -rf "$out.partial"
mkdir "$out.partial"
as_builder /usr/bin/tar -C "$guest_out" -cf - . | tar -xf - -C "$out.partial"
[[ -f "$out.partial/build.json" ]] || fail "the build left no build.json (log: $log)"
mv "$out.partial" "$out"
echo "Build as $user: done, in $out" >> "$log"
