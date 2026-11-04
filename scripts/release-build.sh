#!/bin/bash
# The release build, run the same way by both builders (docs/releasing.md): GitHub Actions
# (.github/workflows/release.yml) and a throwaway VM on the signing machine (scripts/release-vm-build.sh).
#
#   scripts/release-build.sh OUT --commit SHA --build-number N [--stable]
#
# Builds from a fresh source tree at /private/tmp/dispatch-build, a fixed path because source paths end up in the
# binaries and both builders must make the same files, with the Xcode that DEVELOPER_DIR or xcode-select selects:
#   the Mac app      ./run.sh --prod --just-build, signed ad hoc by Xcode
#   the iPhone app   ./run.sh --archive, with its watch app, built unsigned and signed ad hoc here with each target's
#                    entitlements (Xcode signs iOS code only with a team)
# Every app gets CFBundleVersion N. OUT gets Dispatch-Pilot-unsigned.zip (--stable: Dispatch-unsigned.zip),
# Dispatch.app.dSYM.zip, DispatchMobile.xcarchive.zip and build.json: the variant, version, build number, commit,
# builder, Xcode and macOS builds, and each zip's bundle id and SHA-256. Nothing here holds a key or talks to Apple.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_ROOT=/private/tmp/dispatch-build

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: scripts/release-build.sh OUT --commit SHA --build-number N [--stable]"; }

# Xcode signs iOS code only with a team, so the archive is built unsigned; this signs it ad hoc, innermost first, with
# each target's entitlements (the watch's App Group, named after the phone app), which the signing machine's export
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

out="" commit="" number="" stable=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) [[ $# -ge 2 ]] || usage; commit="$2"; shift ;;
    --build-number) [[ $# -ge 2 ]] || usage; number="$2"; shift ;;
    --stable) stable=1 ;;
    -*) usage ;;
    *) [[ -z "$out" ]] || usage; out="$1" ;;
  esac
  shift
done
[[ -n "$out" ]] || usage
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "--commit takes the full 40-character commit SHA"
[[ "$number" =~ ^[0-9]{8}\.[0-9]{4}$ ]] || fail "--build-number takes the commit's UTC time, YYYYMMDD.HHMM"
[[ "$ROOT" == "$BUILD_ROOT" ]] || fail "the source must be at $BUILD_ROOT (paths end up in the binaries), not $ROOT"
[[ ! -e "$ROOT/build" ]] || fail "$ROOT/build exists: a release builds from a fresh tree"
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
[[ -z "$(ls -A "$out")" ]] || fail "$out is not empty"
variant=pilot zip=Dispatch-Pilot-unsigned.zip
[[ -z "$stable" ]] || { variant=stable; zip=Dispatch-unsigned.zip; }

cd "$ROOT"
versions="$(sed -nE 's/^ *MARKETING_VERSION: "([0-9.]+)"$/\1/p' project.yml | sort -u)"
[[ "$versions" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "the apps' MARKETING_VERSION disagree or are missing: $versions"
echo "Dispatch $versions ($variant) build $number from $commit"
xcodebuild -version

# setup.sh asks once before its downloads, all pinned and SHA-256-checked (scripts/build.lock.json); after it, run.sh
# finds nothing missing and asks nothing.
echo y | bash scripts/setup.sh
./run.sh --prod --just-build ${stable:+--stable} --build-number "$number" < /dev/null
work="$ROOT/build/release"
mkdir -p "$work"
./run.sh --archive "$work/DispatchMobile.xcarchive" ${stable:+--stable} --build-number "$number" < /dev/null
sign_archive "$work/DispatchMobile.xcarchive"

products="$ROOT/build/Build/Products/Release"
pack() { ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$1" "$out/$2"; }
pack "$products/Dispatch.app" "$zip"
pack "$products/Dispatch.app.dSYM" Dispatch.app.dSYM.zip
pack "$work/DispatchMobile.xcarchive" DispatchMobile.xcarchive.zip

python3 -I - "$out" "$variant" "$versions" "$number" "$commit" "$zip" "$products/Dispatch.app" \
  "$work/DispatchMobile.xcarchive/Products/Applications/DispatchMobile.app" <<'PY'
import hashlib, json, os, plistlib, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
out, variant, version, number, commit, zip_name, mac, phone = sys.argv[1:]
out = Path(out)
def digest(name): return hashlib.sha256((out / name).read_bytes()).hexdigest()
def info(app, inner): return plistlib.loads((Path(app) / inner).read_bytes())
def run(*command): return subprocess.run(command, check=True, capture_output=True, text=True).stdout
xcode = run('xcodebuild', '-version')
mac_info, phone_info = info(mac, 'Contents/Info.plist'), info(phone, 'Info.plist')
for name, app in (('Mac', mac_info), ('iPhone', phone_info)):
    if (app['CFBundleShortVersionString'], app['CFBundleVersion']) != (version, number):
        sys.exit(f'error: the {name} app is {app["CFBundleShortVersionString"]} ({app["CFBundleVersion"]}), '
                 f'not {version} ({number})')
build = {
    'variant': variant, 'version': version, 'build': number, 'commit': commit,
    'builder': os.environ.get('DISPATCH_BUILDER', 'local'),
    'created': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'xcode': {'version': re.search(r'Xcode (\S+)', xcode).group(1), 'build': re.search(r'Build version (\S+)', xcode).group(1)},
    'macos': {'version': run('sw_vers', '-productVersion').strip(), 'build': run('sw_vers', '-buildVersion').strip()},
    'mac': {'bundle_id': mac_info['CFBundleIdentifier'], 'file': zip_name, 'sha256': digest(zip_name),
            'dsym': 'Dispatch.app.dSYM.zip', 'dsym_sha256': digest('Dispatch.app.dSYM.zip')},
    'ios': {'bundle_id': phone_info['CFBundleIdentifier'], 'file': 'DispatchMobile.xcarchive.zip',
            'sha256': digest('DispatchMobile.xcarchive.zip')},
}
(out / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
print(json.dumps(build, indent=2))
PY
for file in "$out"/*.zip; do
  # GitHub takes files up to 2 GB as release assets and artifacts; anything near that is a broken build.
  [[ "$(stat -f %z "$file")" -lt $((1024 * 1024 * 1024)) ]] || fail "$file is over 1 GB"
done
echo "Release build in $out"
