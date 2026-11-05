#!/bin/bash
# The release build, run the same way by both builders (docs/releasing.md, Two builders): GitHub Actions
# (.github/workflows/release.yml) and the signing machine, as its build user (scripts/release/builder.sh).
#
#   scripts/release/build.sh OUT --commit SHA --build-number N [--variant NAME] [--platform mac|ios]
#
# From a fresh tree at /private/tmp/release-build (a fixed path: source paths end up in the binaries, and both builders
# must make the same files), in a fixed environment, with the Xcode that DEVELOPER_DIR selects. The app's own
# scripts/release/app.sh builds <name>.app (and its dSYM) for the variant (scripts/release/app.json; the default is the
# first) with CFBundleVersion N; this checks them, removes what comes from the build machine (scripts/release/normalize.py)
# and packs them byte-reproducibly (scripts/release/zip.py): the same commit and Xcode build make the same
# <name>-<variant>-unsigned.zip on any Mac, SHA-256 included. OUT gets it, <name>.app.dSYM.zip (packed the same way, but
# its DWARF differs between builds) and build.json: variant, version, build number, commit, builder, the Xcode and macOS
# builds, the app's bundle id and the zips' SHA-256. With --platform ios (an iPhone build; no flow publishes one for now), release/app.sh leaves one
# .xcarchive instead, its apps signed ad hoc with their entitlements; OUT gets it zipped, and build.json its app's
# bundle id (the variant's ios_bundle_id) and SHA-256. Nothing here holds a key or talks to Apple.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BUILD_ROOT=/private/tmp/release-build

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: scripts/release/build.sh OUT --commit SHA --build-number N [--variant NAME] [--platform mac|ios]"; }
config() { python3 -I "$ROOT/scripts/release/config.py" "$@"; }

# Both builders build in this same environment, whatever they start with: these variables only, the system's tools
# first (python3 is Xcode's, not Homebrew's), a fresh HOME. GitHub's runner otherwise brings Homebrew, rustup, its
# own LANG and home folder settings, which the signing machine's build user lacks.
if [[ "${RELEASE_ENVIRONMENT:-}" != 1 ]]; then
  home="$BUILD_ROOT-home"
  rm -rf "$home"
  mkdir -m 700 "$home"
  exec /usr/bin/env -i RELEASE_ENVIRONMENT=1 HOME="$home" USER="$(id -un)" LOGNAME="$(id -un)" \
    LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin RELEASE_BUILDER="${RELEASE_BUILDER:-local}" \
    ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} /bin/bash "$ROOT/scripts/release/build.sh" "$@"
fi

out="" commit="" number="" variant="" platform=mac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) [[ $# -ge 2 ]] || usage; commit="$2"; shift ;;
    --build-number) [[ $# -ge 2 ]] || usage; number="$2"; shift ;;
    --variant) [[ $# -ge 2 ]] || usage; variant="$2"; shift ;;
    --platform) [[ $# -ge 2 && ( "$2" == mac || "$2" == ios ) ]] || usage; platform="$2"; shift ;;
    -*) usage ;;
    *) [[ -z "$out" ]] || usage; out="$1" ;;
  esac
  shift
done
# Permissions end up in the zip.
umask 022
[[ -n "$out" ]] || usage
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "--commit takes the full 40-character commit SHA"
[[ "$number" =~ ^[0-9]{8}\.[0-9]{4}$ ]] || fail "--build-number takes the commit's UTC time, YYYYMMDD.HHMM"
[[ "$ROOT" == "$BUILD_ROOT" ]] || fail "the source must be at $BUILD_ROOT (paths end up in the binaries), not $ROOT"
[[ ! -e "$ROOT/build" ]] || fail "$ROOT/build exists: a release builds from a fresh tree"
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
[[ -z "$(ls -A "$out")" ]] || fail "$out is not empty"
variant="$(config variant "$variant")"
name="$(config get name)"
bundle="$(config get "variants.$variant.$([[ $platform == mac ]] && echo bundle_id || echo ios_bundle_id)")"
version="$(config version)"
zip="$name-$variant-unsigned.zip"

cd "$ROOT"
echo "$name $version ($variant, $platform) build $number from $commit"
xcodebuild -version
products="$BUILD_ROOT-products"
rm -rf "$products"
mkdir "$products"
RELEASE_PLATFORM="$platform" RELEASE_VARIANT="$variant" RELEASE_BUILD_NUMBER="$number" RELEASE_PRODUCTS="$products" \
  bash scripts/release/app.sh
pack() { python3 -I "$ROOT/scripts/release/zip.py" "$1" "$out/$2" --time "$number"; }

if [[ "$platform" == ios ]]; then
  archives=("$products"/*.xcarchive)
  [[ ${#archives[@]} == 1 && -d "${archives[0]}" ]] || fail "scripts/release/app.sh left no single .xcarchive in $products"
  archive="$(basename "${archives[0]}")"
  pack "${archives[0]}" "$archive.zip"
  python3 -I - "$out" "$variant" "$version" "$number" "$commit" "${archives[0]}" "$bundle" <<'PY'
import hashlib, json, os, plistlib, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
out, variant, version, number, commit, archive, bundle = sys.argv[1:]
out, archive = Path(out), Path(archive)
apps = list((archive / 'Products/Applications').glob('*.app'))
if len(apps) != 1:
    sys.exit(f'error: {archive.name} holds {len(apps)} apps in Products/Applications, not one')
info = plistlib.loads((apps[0] / 'Info.plist').read_bytes())
built = (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion'])
if built != (bundle, version, number):
    sys.exit(f'error: the app is {built[0]} {built[1]} ({built[2]}), not {bundle} {version} ({number})')
def run(*command): return subprocess.run(command, check=True, capture_output=True, text=True).stdout
xcode = run('xcodebuild', '-version')
file = archive.name + '.zip'
build = {
    'variant': variant, 'version': version, 'build': number, 'commit': commit, 'platform': 'ios',
    'builder': os.environ.get('RELEASE_BUILDER', 'local'),
    'created': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'xcode': {'version': re.search(r'Xcode (\S+)', xcode).group(1), 'build': re.search(r'Build version (\S+)', xcode).group(1)},
    'macos': {'version': run('sw_vers', '-productVersion').strip(), 'build': run('sw_vers', '-buildVersion').strip()},
    'ios': {'bundle_id': bundle, 'app': apps[0].name, 'file': file,
            'sha256': hashlib.sha256((out / file).read_bytes()).hexdigest()},
}
(out / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
print(json.dumps(build, indent=2))
PY
  echo "Release build in $out"
  exit 0
fi
[[ -d "$products/$name.app" && -d "$products/$name.app.dSYM" ]] ||
  fail "scripts/release/app.sh left no $name.app and $name.app.dSYM in $products"
python3 -I "$ROOT/scripts/release/normalize.py" "$products/$name.app"
pack "$products/$name.app" "$zip"
pack "$products/$name.app.dSYM" "$name.app.dSYM.zip"

python3 -I - "$out" "$variant" "$version" "$number" "$commit" "$zip" "$products/$name.app" "$bundle" <<'PY'
import hashlib, json, os, plistlib, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
out, variant, version, number, commit, zip_name, app, bundle = sys.argv[1:]
out = Path(out)
def digest(name): return hashlib.sha256((out / name).read_bytes()).hexdigest()
def run(*command): return subprocess.run(command, check=True, capture_output=True, text=True).stdout
info = plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())
built = (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion'])
if built != (bundle, version, number):
    sys.exit(f'error: the app is {built[0]} {built[1]} ({built[2]}), not {bundle} {version} ({number})')
xcode = run('xcodebuild', '-version')
dsym = Path(app).name + '.dSYM.zip'
build = {
    'variant': variant, 'version': version, 'build': number, 'commit': commit,
    'builder': os.environ.get('RELEASE_BUILDER', 'local'),
    'created': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'xcode': {'version': re.search(r'Xcode (\S+)', xcode).group(1), 'build': re.search(r'Build version (\S+)', xcode).group(1)},
    'macos': {'version': run('sw_vers', '-productVersion').strip(), 'build': run('sw_vers', '-buildVersion').strip()},
    'mac': {'bundle_id': bundle, 'minimum_macos': info.get('LSMinimumSystemVersion', ''), 'file': zip_name,
            'sha256': digest(zip_name), 'dsym': dsym, 'dsym_sha256': digest(dsym)},
}
(out / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
print(json.dumps(build, indent=2))
PY
for file in "$out"/*.zip; do
  # GitHub takes files up to 2 GB as release assets and artifacts; anything near that is a broken build.
  [[ "$(stat -f %z "$file")" -lt $((1024 * 1024 * 1024)) ]] || fail "$file is over 1 GB"
done
echo "Release build in $out"
