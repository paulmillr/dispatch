#!/bin/bash
# Release, signing machine side (README.md, a copy of docs/releasing.md). Runs from a clone of dispatch-release, where
# scripts/release-prepare.sh puts it as bin/release-publish.sh, after bin/release-signer-setup.sh:
#
#   bin/release-publish.sh [pilot/20261030.1345] [--mac-only | --ios-only] [--no-push] [--admin-key AuthKey_ID.p8]
#   bin/release-publish.sh [pilot/20261030.1345] --ad-hoc [--no-push]
#
# Pulls, then takes the newest release folder without published.json (or the one named) and checks both zips against
# its release.json, and that their bundle ids are the variant's. Then:
#   Mac     bin/release-notarize.sh signs the app with Developer ID, notarizes and staples it and its DMG; the DMG is
#           copied into the release folder.
#   iPhone  xcodebuild -exportArchive signs the archive (phone, watch, widgets) with Apple Distribution and the App Store
#           profiles in ~/.config/dispatch-release/<variant>-profiles (made by hand in the developer portal: signing is
#           manual, so the App Store Connect API key needs no Admin role), then uploads it with that key. The build
#           shows up in TestFlight once Apple has processed it.
#           Once, instead: --admin-key with an Admin API key signs automatically (Xcode registers the App IDs and the App
#           Group and makes the profiles), uploads, then keeps the profiles it made for the manual runs that follow.
#           Revoke that key afterwards.
#   Ad Hoc  --ad-hoc, on its own (default: the newest release folder): the same archive signed with Apple Distribution and
#           the Ad Hoc profiles in ~/.config/dispatch-release/<variant>-adhoc-profiles, for the devices they list; no Apple
#           review and nothing sent to Apple. The release folder's adhoc/ gets Dispatch.ipa, manifest.plist and an
#           install page, index.html, whose itms-services link installs it from Safari. They name their HTTPS
#           addresses: DISPATCH_ADHOC_URL/<variant>/<build>/ (~/.config/dispatch-release/<variant>-adhoc.env), where
#           the three files are to be served. The .ipa lists every registered device's UDID (embedded.mobileprovision),
#           so only from a host nobody can list or browse. With DISPATCH_ADHOC_SITE, the folder of a git clone served at
#           DISPATCH_ADHOC_URL, they are copied there as the variant's only build, with <variant>/index.html its install page too, and the
#           branch is rewritten to one commit and pushed (--force-with-lease), so no older .ipa stays in its history.
#           A public GitHub repository is refused. Each --ad-hoc run signs again (offline, quick): the files name their
#           addresses, which may have changed since.
# Writes published.json, commits it with the DMG and pushes. Rerun after a failure: notarization resumes where it
# stopped, and a finished part is skipped (markers in the release folder's export/, which git ignores).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${DISPATCH_RELEASE_CONFIG:-$HOME/.config/dispatch-release}"

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: bin/release-publish.sh [VARIANT/BUILD] [--mac-only | --ios-only | --ad-hoc] [--no-push] [--admin-key AuthKey_ID.p8]"; }

# The distribution profiles of the phone app $4 and its watch app and widgets (team $3), checked: their kind, unexpired,
# the watch ones with the App Group, and made for this Mac's Apple Distribution certificate.
#   signing_profiles use FOLDER TEAM PHONE OPTIONS     FOLDER's App Store profiles installed where Xcode looks, and export
#                                                      options OPTIONS that name them (manual signing, upload)
#   signing_profiles adhoc FOLDER TEAM PHONE OPTIONS   the same with Ad Hoc profiles (export to a .ipa); prints how many
#                                                      devices each lists
#   signing_profiles keep FOLDER TEAM PHONE            after an automatic --admin-key run: copies the App Store profiles
#                                                      Xcode made into FOLDER, for the manual runs that follow
signing_profiles() {
  python3 - "$@" <<'PY'
import hashlib, plistlib, re, shutil, subprocess, sys
from datetime import datetime
from pathlib import Path
mode, folder, team, phone = sys.argv[1:5]
folder = Path(folder)
bundles = [phone, phone + '.watchkitapp', phone + '.watchkitapp.widgets']
group = 'group.' + phone
# Xcode 16 and later keep profiles in the first folder, older ones in the second.
xcode = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
         Path.home() / 'Library/MobileDevice/Provisioning Profiles']
identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout
ours = set(re.findall(rf'([0-9A-F]{{40}}) "Apple Distribution: .*\({team}\)"', identities))
if not ours:
    sys.exit(f'error: no valid Apple Distribution identity of team {team} in the keychain')

found, problems = {}, []
adhoc = mode == 'adhoc'
kind = 'Ad Hoc' if adhoc else 'App Store Connect'
for path in [p for directory in ([xcode] if mode == 'keep' else [[folder]])[0] if directory.is_dir()
             for p in sorted(directory.glob('*.mobileprovision'))]:
    # The decoded plist is what counts: the exit status also reflects whether this Mac trusts the signer.
    try:
        profile = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True).stdout)
    except Exception:
        problems.append(f'{path.name}: not a provisioning profile')
        continue
    entitlements = profile.get('Entitlements', {})
    bundle = entitlements.get('application-identifier', '').partition('.')[2]
    if bundle not in bundles or team not in profile.get('TeamIdentifier', []):
        continue
    certificates = {hashlib.sha1(der).hexdigest().upper() for der in profile.get('DeveloperCertificates', [])}
    devices = profile.get('ProvisionedDevices') or []
    if entitlements.get('get-task-allow') or profile.get('ProvisionsAllDevices') or bool(devices) != adhoc:
        if mode != 'keep':
            problems.append(f'{path.name}: not a Distribution, {kind} profile')
    elif profile['ExpirationDate'] < datetime.utcnow():
        problems.append(f'{path.name}: expired on {profile["ExpirationDate"]:%Y-%m-%d}')
    elif bundle != phone and group not in entitlements.get('com.apple.security.application-groups', []):
        problems.append(f'{path.name}: no App Group {group}; give the App ID {bundle} that group, then regenerate the profile')
    elif not certificates & ours:
        problems.append(f'{path.name} ({bundle}): made for another certificate (Apple\'s cloud-managed one?); in the '
                        f'developer portal edit the profile, choose this Mac\'s Apple Distribution certificate, download it')
    elif bundle not in found or profile['CreationDate'] > found[bundle][0]['CreationDate']:
        found[bundle] = (profile, path)
missing = [bundle for bundle in bundles if bundle not in found]
if mode == 'keep':
    # Whatever is usable, even when one is not: only that one then needs the portal.
    folder.mkdir(parents=True, exist_ok=True)
    for bundle, (profile, path) in found.items():
        shutil.copyfile(path, folder / f'{bundle}.mobileprovision')
        print(f'Kept {profile["Name"]} ({bundle}), until {profile["ExpirationDate"]:%Y-%m-%d}, in {folder}')
if missing:
    for problem in problems:
        print('error: ' + problem, file=sys.stderr)
    where = 'Xcode\'s profiles' if mode == 'keep' else folder
    sys.exit(f'error: no usable {kind} profile for {", ".join(missing)} in {where}. In the developer portal: Profiles, '
             f'+, Distribution: {kind}, one per bundle id, certificate Apple Distribution'
             f'{", the devices" if adhoc else ""}; download into {folder}')

if mode == 'keep':
    sys.exit()
for profile, path in found.values():
    for target in xcode:
        target.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target / f'{profile["UUID"]}.mobileprovision')
    count = f', {len(profile["ProvisionedDevices"])} devices' if adhoc else ''
    print(f'Profile {profile["Name"]} ({profile["UUID"]}), until {profile["ExpirationDate"]:%Y-%m-%d}{count}')
options = {'teamID': team, 'signingStyle': 'manual', 'signingCertificate': 'Apple Distribution',
           'provisioningProfiles': {bundle: found[bundle][0]['UUID'] for bundle in bundles},
           'manageAppVersionAndBuildNumber': False}
if adhoc:
    options.update({'method': 'release-testing', 'destination': 'export', 'thinning': '<none>'})
else:
    options.update({'method': 'app-store-connect', 'destination': 'upload', 'uploadSymbols': True})
Path(sys.argv[5]).write_bytes(plistlib.dumps(options))
PY
}

folder="" mac=1 ios=1 adhoc="" push=1 admin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mac-only) ios="" ;;
    --ios-only) mac="" ;;
    --ad-hoc) adhoc=1 ;;
    --no-push) push="" ;;
    --admin-key) [[ $# -ge 2 && -f "$2" ]] || fail "--admin-key needs the Admin key's AuthKey_<KEY ID>.p8"
      admin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    -*) usage ;;
    *) [[ -z "$folder" ]] || usage; folder="${1%/}" ;;
  esac
  shift
done
[[ -n "$mac$ios" ]] || usage
if [[ -n "$adhoc" ]]; then
  [[ -n "$mac" && -n "$ios" && -z "$admin" ]] || fail "--ad-hoc runs on its own: no --mac-only, --ios-only or --admin-key"
  mac="" ios=""
fi
admin_id="$(basename "$admin" .p8)"; admin_id="${admin_id#AuthKey_}"
[[ -z "$admin" || "$admin_id" =~ ^[A-Z0-9]{10}$ ]] || fail "$admin: the key keeps Apple's name, AuthKey_<KEY ID>.p8"
cd "$REPO"
[[ -z "$push" ]] || git pull --ff-only --quiet
if [[ -z "$folder" ]]; then
  shopt -s nullglob
  # Build numbers are UTC times, so they sort as text. An Ad Hoc build is of the newest release, published or not.
  folder="$(for release in */*/release.json; do
    if [[ -n "$adhoc" || ! -f "${release%/release.json}/published.json" ]]; then echo "${release%/release.json}"; fi
  done | sort -t/ -k2,2 | tail -1)"
  shopt -u nullglob
  [[ -n "$folder" ]] || { echo "Nothing to publish: every release folder has its published.json."; exit 0; }
fi
[[ -f "$folder/release.json" ]] || fail "no release.json in $folder"
field() { plutil -extract "$1" raw "$folder/release.json"; }
variant="$(field variant)" number="$(field build)"
echo "Publishing $variant build $number (commit $(field commit | cut -c1-8)), from $folder"

settings="$CONFIG/$variant.env"
[[ -f "$settings" ]] || fail "no $settings: run bin/release-signer-setup.sh $variant first"
# DISPATCH_TEAM, DISPATCH_MAC_IDENTITY, DISPATCH_NOTARY_PROFILE, DISPATCH_ASC_KEY, DISPATCH_ASC_KEY_ID, DISPATCH_ASC_ISSUER
source "$settings"
# DISPATCH_ADHOC_URL and optionally DISPATCH_ADHOC_SITE, kept apart: bin/release-signer-setup.sh rewrites $settings.
adhoc_settings="$CONFIG/$variant-adhoc.env"
if [[ -n "$adhoc" ]]; then
  [[ -f "$adhoc_settings" ]] || fail "no $adhoc_settings: write DISPATCH_ADHOC_URL=https://… (where adhoc/ is served) into it"
  source "$adhoc_settings"
  [[ "${DISPATCH_ADHOC_URL:-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] ||
    fail "DISPATCH_ADHOC_URL in $adhoc_settings must be an https:// address (letters, digits, . _ ~ - /), not '${DISPATCH_ADHOC_URL:-}'"
  DISPATCH_ADHOC_URL="${DISPATCH_ADHOC_URL%/}"
fi

# Each account signs only its own apps.
case "$variant" in
  pilot) prefix=yachts.dispatch.pilot ;;
  stable) prefix=yachts.dispatch ;;
  *) fail "unknown variant $variant" ;;
esac
[[ "$(field mac.bundle_id)" == "$prefix.app" ]] || fail "the Mac app is $(field mac.bundle_id), not $prefix.app"
[[ "$(field ios.bundle_id)" == "$prefix.mobile" ]] || fail "the iPhone app is $(field ios.bundle_id), not $prefix.mobile"
for part in mac ios; do
  file="$folder/$(field "$part.file")"
  [[ -f "$file" ]] || fail "missing $file"
  [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$(field "$part.sha256")" ]] || fail "$file does not match release.json"
done

# Signing over SSH needs the login keychain unlocked; macOS cannot ask in a dialog there.
keychain="$HOME/Library/Keychains/login.keychain-db"
security show-keychain-info "$keychain" > /dev/null 2>&1 || {
  echo "Unlocking the login keychain (your macOS password)"
  security unlock-keychain "$keychain"
}

work="$folder/export"
mkdir -p "$work"
if [[ -n "$mac" ]]; then
  if [[ ! -f "$work/mac.done" ]]; then
    zip="$folder/$(field mac.file)"
    "$REPO/bin/release-notarize.sh" "$zip" --identity "$DISPATCH_MAC_IDENTITY" --profile "$DISPATCH_NOTARY_PROFILE" \
      --sha256 "$(field mac.sha256)"
    name="$(basename "$zip" .zip)"
    cp "$folder/${name%-unsigned}-signed/Dispatch-$(field mac.version).dmg" "$folder/"
    echo "Dispatch-$(field mac.version).dmg" > "$work/mac.done"
  fi
fi
# What either run finished: a --mac-only and a later --ios-only run of one build both end up in published.json.
dmg=""
if [[ -f "$work/mac.done" ]]; then dmg="$(cat "$work/mac.done")"; fi

if [[ -n "$ios" && ! -f "$work/ios.done" ]]; then
  rm -rf "$work/DispatchMobile.xcarchive" "$work/upload"
  ditto -x -k "$folder/$(field ios.file)" "$work"
  key=("$DISPATCH_ASC_KEY" "$DISPATCH_ASC_KEY_ID")
  if [[ -n "$admin" ]]; then
    # Automatic signing with this Mac's certificate, not Apple's cloud-managed one, so the profiles Xcode makes serve
    # the manual runs too.
    key=("$admin" "$admin_id")
    plutil -create xml1 "$work/ExportOptions.plist"
    for setting in "method -string app-store-connect" "destination -string upload" "teamID -string $DISPATCH_TEAM" \
      "signingStyle -string automatic" "signingCertificate -string Apple Distribution" "uploadSymbols -bool YES" \
      "manageAppVersionAndBuildNumber -bool NO"; do
      read -r name kind value <<< "$setting"
      plutil -insert "$name" "$kind" "$value" "$work/ExportOptions.plist"
    done
  else
    signing_profiles use "$CONFIG/$variant-profiles" "$DISPATCH_TEAM" "$(field ios.bundle_id)" "$work/ExportOptions.plist"
  fi
  echo "Signing and uploading Dispatch for iPhone $(field ios.version) ($number) to App Store Connect" \
    "${admin:+(automatic signing, Admin key $admin_id)}"
  xcodebuild -exportArchive -archivePath "$work/DispatchMobile.xcarchive" -exportOptionsPlist "$work/ExportOptions.plist" \
    -exportPath "$work/upload" ${admin:+-allowProvisioningUpdates} -authenticationKeyPath "${key[0]}" \
    -authenticationKeyID "${key[1]}" -authenticationKeyIssuerID "$DISPATCH_ASC_ISSUER" > "$work/export.log" 2>&1 ||
    { tail -30 "$work/export.log" >&2; fail "export or upload failed; full log: $work/export.log"; }
  date -u +%Y-%m-%dT%H:%M:%SZ > "$work/ios.done"
  if [[ -n "$admin" ]]; then
    signing_profiles keep "$CONFIG/$variant-profiles" "$DISPATCH_TEAM" "$(field ios.bundle_id)" ||
      echo "note: uploaded, but the profiles above need fixing before the next run without --admin-key"
    echo "Revoke the Admin key $admin_id in App Store Connect (Users and Access, Integrations) and delete $admin."
  fi
fi

if [[ -n "$adhoc" ]]; then
  rm -rf "$work/DispatchMobile.xcarchive" "$work/adhoc" "$folder/adhoc"
  ditto -x -k "$folder/$(field ios.file)" "$work"
  signing_profiles adhoc "$CONFIG/$variant-adhoc-profiles" "$DISPATCH_TEAM" "$(field ios.bundle_id)" "$work/AdHocOptions.plist"
  echo "Signing Dispatch for iPhone $(field ios.version) ($number) Ad Hoc"
  xcodebuild -exportArchive -archivePath "$work/DispatchMobile.xcarchive" -exportOptionsPlist "$work/AdHocOptions.plist" \
    -exportPath "$work/adhoc" > "$work/adhoc.log" 2>&1 ||
    { tail -30 "$work/adhoc.log" >&2; fail "Ad Hoc export failed; full log: $work/adhoc.log"; }
  ipas=("$work"/adhoc/*.ipa)
  [[ ${#ipas[@]} == 1 && -f "${ipas[0]}" ]] || fail "the Ad Hoc export made no single .ipa (see $work/adhoc.log)"
  mkdir -p "$folder/adhoc"
  mv "${ipas[0]}" "$folder/adhoc/Dispatch.ipa"
  base="$DISPATCH_ADHOC_URL/$variant/$number"
  # The manifest itms-services reads, and the page with its link: both name their own final addresses.
  python3 - "$folder/adhoc" "$base" "$(field ios.bundle_id)" "$(field ios.version)" "$number" <<'PY'
import html, plistlib, sys
from pathlib import Path
folder, base, bundle, version, number = sys.argv[1:]
folder = Path(folder)
(folder / 'manifest.plist').write_bytes(plistlib.dumps({'items': [{
    'assets': [{'kind': 'software-package', 'url': f'{base}/Dispatch.ipa'}],
    'metadata': {'bundle-identifier': bundle, 'bundle-version': version, 'kind': 'software', 'title': 'Dispatch'},
}]}))
link = html.escape(f'itms-services://?action=download-manifest&url={base}/manifest.plist')
(folder / 'index.html').write_text(f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dispatch {html.escape(version)} ({html.escape(number)})</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:32em;margin:3em auto;padding:0 1em;line-height:1.5}}
a.install{{display:inline-block;padding:.8em 1.4em;border-radius:.8em;background:#0a84ff;color:#fff;text-decoration:none;font-weight:600}}</style>
</head><body>
<h1>Dispatch for iPhone</h1>
<p>Version {html.escape(version)}, build {html.escape(number)}.</p>
<p><a class="install" href="{link}">Install</a></p>
<p>Open this page in Safari on your iPhone. It installs only on iPhones registered for this build; the Apple Watch app
installs on registered watches too.</p>
</body></html>
''')
PY
  echo "$base/index.html" > "$work/adhoc.done"
  if [[ -n "${DISPATCH_ADHOC_SITE:-}" ]]; then
    site="$DISPATCH_ADHOC_SITE"
    mkdir -p "$site"
    root="$(git -C "$site" rev-parse --show-toplevel 2> /dev/null)" || fail "DISPATCH_ADHOC_SITE $site is not in a git clone"
    branch="$(git -C "$root" branch --show-current)"
    [[ -n "$branch" && -z "$(git -C "$root" status --porcelain)" ]] || fail "$root: not on a branch, or uncommitted changes"
    # The .ipa lists the testers' UDIDs: never into a repository anyone can read.
    origin="$(git -C "$root" remote get-url origin)"
    if [[ "$origin" =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
      repository="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
      [[ "$(curl -s -o /dev/null -w '%{http_code}' "https://github.com/$repository")" != 200 ]] ||
        fail "$repository is public, and the .ipa lists your testers' UDIDs: use a private repository (README.md, Ad Hoc builds)"
    fi
    [[ -z "$push" ]] || git -C "$root" pull --ff-only --quiet
    rm -rf "${site:?}/$variant"
    mkdir -p "$site/$variant/$number"
    cp "$folder/adhoc/Dispatch.ipa" "$folder/adhoc/manifest.plist" "$folder/adhoc/index.html" "$site/$variant/$number/"
    cp "$folder/adhoc/index.html" "$site/$variant/index.html"
    git -C "$site" add -A .
    old="$(git -C "$root" rev-parse HEAD)"
    new="$(TZ=UTC git -C "$root" commit-tree "$(git -C "$root" write-tree)" -m "Site, with Dispatch $variant $number (Ad Hoc)")"
    git -C "$root" update-ref "refs/heads/$branch" "$new" "$old"
    git -C "$root" reset --quiet
    [[ -z "$push" ]] || git -C "$root" push --quiet --force-with-lease="$branch:$old" origin "$branch"
  fi
fi

uploaded="" install=""
if [[ -f "$work/ios.done" ]]; then uploaded="$(cat "$work/ios.done")"; fi
if [[ -f "$work/adhoc.done" ]]; then install="$(cat "$work/adhoc.done")"; fi
# What this machine finished (its export/ markers) over what published.json already records: a part done elsewhere, or
# before, is kept.
python3 - "$folder" "$variant" "$number" "$DISPATCH_TEAM" "$dmg" "$uploaded" "$(field ios.version)" "$install" <<'PY'
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path
folder, variant, number, team, dmg, uploaded, version, install = sys.argv[1:]
folder = Path(folder)
path = folder / 'published.json'
published = json.loads(path.read_text()) if path.is_file() else {}
digest = lambda name: hashlib.sha256((folder / name).read_bytes()).hexdigest()
published.update(variant=variant, build=number, team=team,
                 published=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
if dmg:
    published['mac'] = {'dmg': dmg, 'sha256': digest(dmg)}
if uploaded:
    published['ios'] = {'uploaded': uploaded, 'version': version, 'build': number}
if install:
    published['adhoc'] = {'ipa': 'adhoc/Dispatch.ipa', 'sha256': digest('adhoc/Dispatch.ipa'), 'install': install}
for part in ('mac', 'ios', 'adhoc'):
    published.setdefault(part, None)
path.write_text(json.dumps(published, indent=2) + '\n')
PY
git add "$folder/published.json" ${dmg:+"$folder/$dmg"} ${install:+"$folder/adhoc"}
TZ=UTC git commit --quiet -m "Publish $variant $number"
[[ -z "$push" ]] || git push --quiet
echo
echo "Published $variant build $number$([[ -n "$push" ]] && echo ", pushed" || echo ", committed (not pushed)")"
[[ -z "$dmg" ]] || echo "  Mac     $folder/$dmg"
[[ -z "$uploaded" ]] || echo "  iPhone  uploaded; in TestFlight once App Store Connect has processed it"
if [[ -n "$install" ]]; then
  echo "  Ad Hoc  $folder/adhoc: Dispatch.ipa, manifest.plist, index.html"
  [[ -n "${DISPATCH_ADHOC_SITE:-}" ]] && echo "          copied to $DISPATCH_ADHOC_SITE/$variant/$number" ||
    echo "          serve those three at $DISPATCH_ADHOC_URL/$variant/$number/"
  echo "          install page: $install (newest: $DISPATCH_ADHOC_URL/$variant/)"
fi
