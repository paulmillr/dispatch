#!/bin/bash
# The signing machine's own release build (docs/releasing.md, Two builders), run by scripts/release-publish.sh:
#
#   scripts/release-vm-build.sh SOURCE OUT --commit SHA --build-number N --xcode-build BUILD [--stable] [--keep]
#
# Clones a fresh Tart VM from the pinned image (scripts/release.lock.json's vm_image, or DISPATCH_BUILD_IMAGE), copies
# SOURCE (the verified commit's tree) to /private/tmp/dispatch-build in it, runs scripts/release-build.sh there with the
# guest's Xcode whose build is BUILD (the one GitHub's builder used), copies the result to OUT, then deletes the VM
# (--keep leaves it, stopped, for a look). Nothing from this machine (keys, keychain, settings) enters the VM; the guest
# downloads only the pinned build tools (scripts/build.lock.json). Its log is OUT.log.
set -euo pipefail
fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: scripts/release-vm-build.sh SOURCE OUT --commit SHA --build-number N --xcode-build BUILD [--stable] [--keep]"; }

source="" out="" commit="" number="" xcode="" stable="" keep=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit|--build-number|--xcode-build)
      [[ $# -ge 2 ]] || usage
      case "$1" in --commit) commit="$2" ;; --build-number) number="$2" ;; *) xcode="$2" ;; esac
      shift ;;
    --stable) stable=1 ;;
    --keep) keep=1 ;;
    -*) usage ;;
    *) if [[ -z "$source" ]]; then source="$1"; elif [[ -z "$out" ]]; then out="$1"; else usage; fi ;;
  esac
  shift
done
[[ -d "$source" && -n "$out" && -n "$commit" && -n "$number" && "$xcode" =~ ^[0-9A-Za-z]+$ ]] || usage
[[ ! -e "$out" ]] || fail "$out exists"
command -v tart > /dev/null || fail "Tart is not installed: brew install openai/tools/tart (docs/vm_testing.md)"
image="${DISPATCH_BUILD_IMAGE:-$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["vm_image"])' "$source/scripts/release.lock.json")}"
vm="dispatch-release-$number-$$"
log="$out.log"
mkdir -p "$(dirname "$out")"
: > "$log"

cleanup() {
  tart stop "$vm" > /dev/null 2>&1 || true
  if [[ -n "$keep" ]]; then echo "Kept the VM $vm (tart delete $vm when done)"; else tart delete "$vm" > /dev/null 2>&1 || true; fi
}
trap cleanup EXIT

echo "VM build: cloning $image (the first clone downloads it, about 60 GB)"
TART_NO_AUTO_PRUNE=1 tart clone "$image" "$vm"
cpus="$(sysctl -n hw.ncpu)"; cpus=$((cpus > 6 ? cpus - 2 : 4))
memory=$(( $(sysctl -n hw.memsize) / 1048576 / 2 )); memory=$((memory > 16384 ? 16384 : memory < 8192 ? 8192 : memory))
tart set "$vm" --cpu "$cpus" --memory "$memory"
tart run "$vm" --no-graphics --no-audio --no-clipboard >> "$log" 2>&1 &
deadline=$((SECONDS + 300))
until tart exec "$vm" /usr/bin/true > /dev/null 2>&1; do
  [[ $SECONDS -lt $deadline ]] || fail "the VM's guest agent did not answer within 5 minutes (log: $log)"
  sleep 3
done

# The guest's Xcode whose build is GitHub's: another one compiles different code.
developer="$(tart exec "$vm" /bin/bash -c 'for app in /Applications/Xcode*.app; do
  [[ -L "$app" ]] && continue
  build="$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2>/dev/null | sed -n "s/^Build version //p")"
  echo "$build $app/Contents/Developer"
done')"
selected="$(awk -v wanted="$xcode" '$1 == wanted { $1 = ""; sub(/^ /, ""); print; exit }' <<< "$developer")"
[[ -n "$selected" ]] || fail "the VM image has no Xcode build $xcode (GitHub's builder used it). It has:
$developer
Use an image with that Xcode build (DISPATCH_BUILD_IMAGE, or vm_image in scripts/release.lock.json)."
echo "VM build: Xcode $xcode at $selected, $cpus CPUs, $((memory / 1024)) GB"

guest_source=/private/tmp/dispatch-build guest_out=/private/tmp/dispatch-out
tar --no-mac-metadata -C "$source" -cf - . | tart exec -i "$vm" /bin/bash -c \
  'set -e; rm -rf "$1" "$2"; mkdir "$1"; tar -xf - -C "$1"' _ "$guest_source" "$guest_out"
arguments=("$guest_out" --commit "$commit" --build-number "$number")
[[ -z "$stable" ]] || arguments+=(--stable)
echo "VM build: building (log: $log)"
tart exec "$vm" /usr/bin/env -i HOME=/Users/admin USER=admin LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  DEVELOPER_DIR="$selected" DISPATCH_BUILDER=vm /bin/bash -c 'cd "$1" && shift && exec scripts/release-build.sh "$@"' \
  _ "$guest_source" "${arguments[@]}" >> "$log" 2>&1 ||
  { tail -40 "$log" >&2; fail "the VM build failed (log: $log)"; }
rm -rf "$out.partial"
mkdir "$out.partial"
tart exec "$vm" /usr/bin/tar -C "$guest_out" -cf - . | tar -xf - -C "$out.partial"
[[ -f "$out.partial/build.json" ]] || fail "the VM build left no build.json (log: $log)"
mv "$out.partial" "$out"
echo "VM build: done, in $out"
