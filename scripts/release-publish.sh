#!/bin/bash
# Release, signing machine (docs/releasing.md). Runs from this machine's clone of paulmillr/dispatch, after
# scripts/release-signer-setup.sh:
#
#   scripts/release-publish.sh X.Y.Z [--stable] [--no-push] [--yes] [--no-ad-hoc] [--testflight [--admin-key AuthKey_ID.p8]]
#
# 1. Source. Fetches main and the tag X.Y.Z from GitHub. The tag and its commit must be signed by the commit key pinned
#    in ~/.config/dispatch-release/release.env (DISPATCH_COMMIT_KEY, checked against the keyring in
#    ~/.config/dispatch-release/gnupg, which holds only that key), the commit must be on main and its apps must be
#    X.Y.Z. Then the commit's own copy of this script carries on (the tree goes to the release repository's work/,
#    git-ignored): whatever runs with the keys comes from a commit you signed, not from this clone's checkout.
# 2. Two builds. GitHub's (.github/workflows/release.yml, started by the tag): downloaded and checked against its
#    attestation (that workflow, a GitHub-hosted runner, this tag and commit). This machine's: the same commit built in
#    a throwaway Tart VM with the same Xcode build (scripts/release-vm-build.sh). The two Mac apps and the two iPhone
#    apps must be the same build (scripts/release-compare.py); then it shows what it is about to sign and asks for the
#    version to be typed (--yes skips that).
# 3. Mac. scripts/release-notarize.sh signs the VM's app with Developer ID, notarizes and staples it and its DMG; the
#    DMG is checked as scripts/release-verify.sh checks a release. Pilot only, then: the GitHub release X.Y.Z with the
#    DMG, and a new commit in the homebrew-tap clone (the cask's version and sha256: the updater's feed), pushed.
# 4. iPhone. Ad Hoc (unless --no-ad-hoc, or without ~/.config/dispatch-release/<variant>-adhoc.env): the VM's archive
#    signed with Apple Distribution and the Ad Hoc profiles in ~/.config/dispatch-release/<variant>-adhoc-profiles, for
#    the devices they list; no Apple review and nothing sent to Apple. Dispatch.ipa, manifest.plist and an install page
#    (index.html, an itms-services link) name their addresses, DISPATCH_ADHOC_URL/<variant>/<version>/. The .ipa lists
#    every registered device's UDID (embedded.mobileprovision), so only on a host nobody can list or browse: with
#    DISPATCH_ADHOC_SITE (a git clone or a plain folder served at DISPATCH_ADHOC_URL) they are copied there as the
#    variant's only build, <variant>/index.html its install page too; a git clone's branch is rewritten to one commit
#    and pushed (--force-with-lease), so no older .ipa stays in its history, and a public GitHub repository is refused.
#    DISPATCH_ADHOC_DEPLOY, a shell command, runs after that: a host deployed from the folder.
#    TestFlight (--testflight): the archive signed with the App Store profiles in
#    ~/.config/dispatch-release/<variant>-profiles (made in the developer portal) and uploaded with the API key. Once,
#    instead: --admin-key with an Admin API key signs automatically and uploads; manual runs after it still need
#    profiles made in the portal (Xcode refuses its own for manual signing). Revoke that key afterwards.
# 5. Record. <variant>/<version>/ in the release repository (dispatch-release, next to this clone, or
#    DISPATCH_RELEASE_REPO): both builders' build.json, published.json and adhoc/; committed and pushed.
#
# --no-push makes and checks everything but publishes nothing: no GitHub release, no push of the tap or the record, no
# Ad Hoc deploy. Rerun after a failure: notarization resumes where it stopped, and a finished part is skipped (markers in
# work/<variant>/<version>/; delete adhoc.done there to sign the Ad Hoc build again).
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG="${DISPATCH_RELEASE_CONFIG:-$HOME/.config/dispatch-release}"
REPOSITORY=paulmillr/dispatch

fail() { echo "error: $*" >&2; exit 1; }
usage() { fail "usage: scripts/release-publish.sh X.Y.Z [--stable] [--no-push] [--yes] [--no-ad-hoc] [--testflight [--admin-key AuthKey_ID.p8]]"; }

# The distribution profiles of the phone app $4 and its watch app and widgets (team $3), checked: their kind, unexpired,
# the watch ones with the App Group, and made for this Mac's Apple Distribution certificate.
#   signing_profiles use FOLDER TEAM PHONE OPTIONS     FOLDER's App Store profiles installed where Xcode looks, and export
#                                                      options OPTIONS that name them (manual signing, upload)
#   signing_profiles adhoc FOLDER TEAM PHONE OPTIONS   the same with Ad Hoc profiles (export to a .ipa); prints how many
#                                                      devices each lists
#   signing_profiles keep FOLDER TEAM PHONE            after an automatic --admin-key run: copies usable App Store
#                                                      profiles into FOLDER (never Xcode's own: manual signing refuses
#                                                      them, so after an automatic run it names what the portal must make)
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
    elif profile.get('IsXcodeManaged') or profile.get('Name', '').startswith('iOS Team '):
        # Xcode refuses its own profiles for manual signing ("Xcode managed, but signing settings require a manually
        # managed profile"): only ones made in the developer portal serve.
        problems.append(f'{path.name} ({bundle}): "{profile.get("Name")}" is Xcode-managed, which manual signing refuses; '
                        f'make one in the developer portal (Profiles, +, Distribution: {kind})')
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

arguments=("$@")
version="" variant=pilot push=1 confirm=1 adhoc=1 testflight="" admin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stable) variant=stable ;;
    --no-push) push="" ;;
    --yes) confirm="" ;;
    --no-ad-hoc) adhoc="" ;;
    --testflight) testflight=1 ;;
    --admin-key) [[ $# -ge 2 && -f "$2" ]] || fail "--admin-key needs the Admin key's AuthKey_<KEY ID>.p8"
      admin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift ;;
    -*) usage ;;
    *) [[ -z "$version" ]] || usage; version="$1" ;;
  esac
  shift
done
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ -z "$admin" || -n "$testflight" ]] || fail "--admin-key goes with --testflight"
admin_id="$(basename "$admin" .p8)"; admin_id="${admin_id#AuthKey_}"
[[ -z "$admin" || "$admin_id" =~ ^[A-Z0-9]{10}$ ]] || fail "$admin: the key keeps Apple's name, AuthKey_<KEY ID>.p8"

# 1. Source: this machine's clone, the commit key, the tag.
[[ -f "$CONFIG/release.env" ]] || fail "no $CONFIG/release.env: run scripts/release-signer-setup.sh trust first"
# DISPATCH_COMMIT_KEY, and optionally DISPATCH_RELEASE_REPO, DISPATCH_TAP, DISPATCH_BUILD_IMAGE
source "$CONFIG/release.env"
[[ "${DISPATCH_COMMIT_KEY:-}" =~ ^[0-9A-F]{40}$ ]] || fail "DISPATCH_COMMIT_KEY in $CONFIG/release.env is not a 40-digit fingerprint"
clone="${DISPATCH_PUBLISH_CLONE:-$(git -C "$SELF/.." rev-parse --show-toplevel 2> /dev/null || true)}"
[[ -n "$clone" && -d "$clone/.git" ]] || fail "run this from a clone of $REPOSITORY"
[[ "$(git -C "$clone" config --get remote.origin.url)" =~ github\.com[:/]paulmillr/dispatch(\.git)?$ ]] ||
  fail "$clone's origin is not $REPOSITORY"
release_repo="${DISPATCH_RELEASE_REPO:-$(dirname "$clone")/dispatch-release}"
tap="${DISPATCH_TAP:-$(dirname "$clone")/homebrew-tap}"
git -C "$release_repo" rev-parse --git-dir > /dev/null 2>&1 || fail "$release_repo is not a clone of the release repository"
# Physical, as $SELF is: the test below tells the commit's copy of this script from the clone's.
release_repo="$(cd "$release_repo" && pwd -P)"
work="$release_repo/work/$variant/$version"
folder="$release_repo/$variant/$version"

git -C "$clone" fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" \
  "+refs/tags/$version:refs/tags/$version" || fail "no tag $version on GitHub yet (scripts/set-version.sh prints the steps)"
# The signature's key, from gpg's status lines: VALIDSIG <key> … <primary key>; any other key is refused.
signed_by_commit_key() {
  local kind="$1" object="$2" status
  [[ -d "$CONFIG/gnupg" ]] || fail "no $CONFIG/gnupg: run scripts/release-signer-setup.sh trust first"
  status="$(GNUPGHOME="$CONFIG/gnupg" git -C "$clone" "verify-$kind" --raw "$object" 2>&1 > /dev/null)" ||
    fail "$kind $object: no valid signature$([[ $kind == tag ]] && echo ' (an annotated tag made with git tag -s)'):
$status"
  grep -q '^\[GNUPG:\] GOODSIG ' <<< "$status" || fail "$kind $object: no good signature"
  awk '$2 == "VALIDSIG" { print $3; print $NF }' <<< "$status" | grep -qx "$DISPATCH_COMMIT_KEY" ||
    fail "$kind $object is not signed by the commit key $DISPATCH_COMMIT_KEY"
}
[[ "$(git -C "$clone" cat-file -t "refs/tags/$version")" == tag ]] || fail "tag $version is not annotated: make it with git tag -s"
signed_by_commit_key tag "$version"
commit="$(git -C "$clone" rev-parse "refs/tags/$version^{commit}")"
signed_by_commit_key commit "$commit"
git -C "$clone" merge-base --is-ancestor "$commit" origin/main || fail "$commit (tag $version) is not on main"
apps="$(git -C "$clone" show "$commit:project.yml" | sed -nE 's/^ *MARKETING_VERSION: "([0-9.]+)"$/\1/p' | sort -u)"
[[ "$apps" == "$version" ]] || fail "the apps at $commit are ${apps//$'\n'/, }, not $version"
number="$(TZ=UTC git -C "$clone" show -s --format=%cd --date=format-local:%Y%m%d.%H%M "$commit")"

# The rest runs from the commit's own tree.
if [[ "$SELF" != "$work/source/scripts" ]]; then
  if [[ -f "$work/commit" && "$(cat "$work/commit")" != "$commit" ]]; then
    fail "$work was made for $(cat "$work/commit"), but tag $version is now $commit: a tag must never move. Find out why; move $work away to start over."
  fi
  mkdir -p "$work"
  echo "$commit" > "$work/commit"
  rm -rf "$work/source"
  mkdir "$work/source"
  git -C "$clone" archive "$commit" | tar -x -C "$work/source"
  grep -qx '/work/' "$release_repo/.gitignore" 2> /dev/null || echo '/work/' >> "$release_repo/.gitignore"
  echo "Dispatch $version, $variant: tag and commit $commit signed by $DISPATCH_COMMIT_KEY; continuing with its scripts"
  DISPATCH_PUBLISH_CLONE="$clone" exec bash "$work/source/scripts/release-publish.sh" "${arguments[@]}"
fi
scripts="$work/source/scripts"
source "$scripts/release-verify.sh"

settings="$CONFIG/$variant.env"
[[ -f "$settings" ]] || fail "no $settings: run scripts/release-signer-setup.sh $variant first"
# DISPATCH_TEAM, DISPATCH_MAC_IDENTITY, DISPATCH_NOTARY_PROFILE, DISPATCH_ASC_KEY, DISPATCH_ASC_KEY_ID, DISPATCH_ASC_ISSUER
source "$settings"
case "$variant" in pilot) prefix=yachts.dispatch.pilot zip=Dispatch-Pilot-unsigned.zip ;; *) prefix=yachts.dispatch zip=Dispatch-unsigned.zip ;; esac
adhoc_settings="$CONFIG/$variant-adhoc.env"
if [[ -n "$adhoc" && ! -f "$adhoc_settings" ]]; then
  echo "note: no $adhoc_settings, so no Ad Hoc build"
  adhoc=""
fi
if [[ -n "$adhoc" ]]; then
  # DISPATCH_ADHOC_URL, and optionally DISPATCH_ADHOC_SITE and DISPATCH_ADHOC_DEPLOY
  source "$adhoc_settings"
  [[ "${DISPATCH_ADHOC_URL:-}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] ||
    fail "DISPATCH_ADHOC_URL in $adhoc_settings must be an https:// address (letters, digits, . _ ~ - /), not '${DISPATCH_ADHOC_URL:-}'"
  DISPATCH_ADHOC_URL="${DISPATCH_ADHOC_URL%/}"
fi
command -v gh > /dev/null && gh auth status > /dev/null 2>&1 || fail "gh is not logged in (gh auth login)"
[[ -z "$push" ]] || git -C "$release_repo" pull --ff-only --quiet

# 2. The two builds.
field() { plutil -extract "$2" raw "$1/build.json"; }
check_build() {
  local dir="$1" who="$2" part file
  [[ "$(field "$dir" commit)" == "$commit" && "$(field "$dir" version)" == "$version" && "$(field "$dir" build)" == "$number" &&
     "$(field "$dir" variant)" == "$variant" ]] || fail "$who's build.json is not $variant $version ($number) at $commit"
  [[ "$(field "$dir" mac.bundle_id)" == "$prefix.app" && "$(field "$dir" ios.bundle_id)" == "$prefix.mobile" ]] ||
    fail "$who's apps are $(field "$dir" mac.bundle_id) and $(field "$dir" ios.bundle_id), not $prefix.app and $prefix.mobile"
  for part in mac ios; do
    file="$dir/$(field "$dir" "$part.file")"
    [[ -f "$file" && "$(shasum -a 256 "$file" | cut -d' ' -f1)" == "$(field "$dir" "$part.sha256")" ]] ||
      fail "$who's $(basename "$file") does not match its build.json"
  done
}
unpack() {
  local dir="$1"
  rm -rf "$dir.unpacked"
  mkdir -p "$dir.unpacked/mac" "$dir.unpacked/ios"
  ditto -x -k "$dir/$(field "$dir" mac.file)" "$dir.unpacked/mac"
  ditto -x -k "$dir/$(field "$dir" ios.file)" "$dir.unpacked/ios"
}
if [[ ! -f "$work/github.run" || ! -f "$work/github/build.json" ]]; then
  github_build "$version" "$commit" "$variant" "$work/github"
fi
check_build "$work/github" GitHub
xcode="$(field "$work/github" xcode.build)"
if [[ ! -f "$work/vm/build.json" ]]; then
  rm -rf "$work/vm"
  vm_arguments=(--commit "$commit" --build-number "$number" --xcode-build "$xcode")
  [[ "$variant" == pilot ]] || vm_arguments+=(--stable)
  bash "$scripts/release-vm-build.sh" "$work/source" "$work/vm" "${vm_arguments[@]}"
fi
check_build "$work/vm" "the VM"
[[ "$(field "$work/vm" xcode.build)" == "$xcode" ]] || fail "the builds used Xcode $xcode and $(field "$work/vm" xcode.build)"
unpack "$work/github"
unpack "$work/vm"
python3 -I "$scripts/release-compare.py" "$work/github.unpacked/mac/Dispatch.app" "$work/vm.unpacked/mac/Dispatch.app" ||
  fail "the Mac apps of GitHub's build and the VM's differ: nothing is signed"
phone=DispatchMobile.xcarchive/Products/Applications/DispatchMobile.app
python3 -I "$scripts/release-compare.py" "$work/github.unpacked/ios/$phone" "$work/vm.unpacked/ios/$phone" ||
  fail "the iPhone apps of GitHub's build and the VM's differ: nothing is signed"

cat <<EOF

  Dispatch $version ($variant, build $number)
  Commit   $commit, tag and commit signed by $DISPATCH_COMMIT_KEY
  Builds   GitHub run $(cat "$work/github.run") (attested) and this machine's VM, the same, Xcode $xcode
  Signing  $DISPATCH_MAC_IDENTITY; Apple Distribution, team $DISPATCH_TEAM
  Then     $([[ "$variant" == pilot ]] && echo "the GitHub release and the Homebrew cask, " || true)$([[ -n "$adhoc" ]] && echo "Ad Hoc, " || true)$([[ -n "$testflight" ]] && echo "TestFlight, " || true)the record$([[ -n "$push" ]] || echo " (--no-push: nothing published)")

EOF
if [[ -n "$confirm" ]]; then
  read -r -p "Type $version to sign and publish it: " answer < /dev/tty
  [[ "$answer" == "$version" ]] || fail "stopped; nothing was signed"
fi

# Signing over SSH needs the login keychain unlocked; macOS cannot ask in a dialog there.
keychain="$HOME/Library/Keychains/login.keychain-db"
security show-keychain-info "$keychain" > /dev/null 2>&1 || {
  echo "Unlocking the login keychain (your macOS password)"
  security unlock-keychain "$keychain"
}

# 3. Mac.
dmg="$work/Dispatch-$version.dmg"
if [[ ! -f "$work/mac.done" ]]; then
  bash "$scripts/release-notarize.sh" "$work/vm/$zip" --identity "$DISPATCH_MAC_IDENTITY" --profile "$DISPATCH_NOTARY_PROFILE" \
    --sha256 "$(field "$work/vm" mac.sha256)"
  name="$(basename "$zip" .zip)"
  cp "$work/vm/${name%-unsigned}-signed/Dispatch-$version.dmg" "$dmg"
  check_dmg "$dmg" "$DISPATCH_TEAM" "$work/vm.unpacked/mac/Dispatch.app" "$scripts/release-compare.py"
  touch "$work/mac.done"
fi
digest="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"

if [[ "$variant" == pilot && ! -f "$work/release.done" ]]; then
  if [[ -z "$push" ]]; then
    echo "note: --no-push, so no GitHub release"
  else
    existing="$(gh api "repos/$REPOSITORY/releases/tags/$version" --jq ".assets[] | select(.name == \"Dispatch-$version.dmg\") | .digest" 2> /dev/null || echo none)"
    if [[ "$existing" == none ]]; then
      run_url="https://github.com/$REPOSITORY/actions/runs/$(cat "$work/github.run")"
      cat > "$work/notes.md" <<EOF
Dispatch.app for macOS 14 and later, notarized. \`brew install --cask paulmillr/tap/dispatch\`, or open the DMG.

SHA-256 of Dispatch-$version.dmg: \`$digest\`

Built from the signed tag $version ($commit) twice, by [GitHub Actions]($run_url) (attested: \`gh attestation verify\`) and
independently in a clean VM; the two builds matched before signing. \`scripts/release-verify.sh $version --team $DISPATCH_TEAM\`
checks this DMG against GitHub's build.
EOF
      gh release create "$version" "$dmg" -R "$REPOSITORY" --verify-tag --title "Dispatch $version" --notes-file "$work/notes.md"
    elif [[ "$existing" == "sha256:$digest" ]]; then
      echo "The GitHub release $version already has this DMG"
    elif [[ -z "$existing" ]]; then
      gh release upload "$version" "$dmg" -R "$REPOSITORY"
    else
      fail "the GitHub release $version has another Dispatch-$version.dmg ($existing): delete that asset first if this one replaces it"
    fi
    touch "$work/release.done"
  fi
fi

if [[ "$variant" == pilot && ! -f "$work/tap.done" ]]; then
  cask="$tap/Casks/dispatch.rb"
  [[ -f "$cask" ]] || fail "no $cask: clone paulmillr/homebrew-tap next to $clone (or set DISPATCH_TAP)"
  [[ -z "$(git -C "$tap" status --porcelain)" ]] || fail "$tap has uncommitted changes"
  [[ -z "$push" ]] || git -C "$tap" pull --ff-only --quiet
  python3 -I - "$cask" "$version" "$digest" <<'PY'
import re, sys
from pathlib import Path
path, version, digest = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
# The updater reads these two literals and the URL (docs/releasing.md, Mac automatic updates).
text, versions = re.subn(r'^(\s*version )"[^"]*"$', rf'\g<1>"{version}"', text, flags=re.M)
text, digests = re.subn(r'^(\s*sha256 )"[0-9a-f]{64}"$', rf'\g<1>"{digest}"', text, flags=re.M)
if versions != 1 or digests != 1 or 'Dispatch-#{version}.dmg' not in text:
    sys.exit(f'error: {path} needs exactly one version "…" and one sha256 "…" line, and a url ending in Dispatch-#{{version}}.dmg')
path.write_text(text)
PY
  if git -C "$tap" diff --quiet; then
    echo "The cask already names Dispatch $version"
  else
    git -C "$tap" add Casks/dispatch.rb
    TZ=UTC git -C "$tap" commit --quiet -m "Dispatch $version"
  fi
  if [[ -n "$push" ]]; then
    git -C "$tap" push --quiet
    touch "$work/tap.done"
  else
    echo "note: --no-push, so the cask commit stays in $tap"
  fi
fi

# 4. iPhone.
archive_from_vm() {
  rm -rf "$work/DispatchMobile.xcarchive"
  ditto -x -k "$work/vm/$(field "$work/vm" ios.file)" "$work"
}
mkdir -p "$folder"
if [[ -n "$adhoc" && ! -f "$work/adhoc.done" ]]; then
  archive_from_vm
  rm -rf "$work/adhoc" "$folder/adhoc"
  signing_profiles adhoc "$CONFIG/$variant-adhoc-profiles" "$DISPATCH_TEAM" "$prefix.mobile" "$work/AdHocOptions.plist"
  echo "Signing Dispatch for iPhone $version ($number) Ad Hoc"
  xcodebuild -exportArchive -archivePath "$work/DispatchMobile.xcarchive" -exportOptionsPlist "$work/AdHocOptions.plist" \
    -exportPath "$work/adhoc" > "$work/adhoc.log" 2>&1 ||
    { tail -30 "$work/adhoc.log" >&2; fail "Ad Hoc export failed; full log: $work/adhoc.log"; }
  ipas=("$work"/adhoc/*.ipa)
  [[ ${#ipas[@]} == 1 && -f "${ipas[0]}" ]] || fail "the Ad Hoc export made no single .ipa (see $work/adhoc.log)"
  mkdir -p "$folder/adhoc"
  mv "${ipas[0]}" "$folder/adhoc/Dispatch.ipa"
  base="$DISPATCH_ADHOC_URL/$variant/$version"
  # The manifest itms-services reads, and the page with its link: both name their own final addresses.
  python3 -I - "$folder/adhoc" "$base" "$prefix.mobile" "$version" "$number" <<'PY'
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
  if [[ -n "${DISPATCH_ADHOC_SITE:-}" ]]; then
    site="$DISPATCH_ADHOC_SITE"
    mkdir -p "$site"
    root="$(git -C "$site" rev-parse --show-toplevel 2> /dev/null || true)"
    if [[ -n "$root" ]]; then
      branch="$(git -C "$root" branch --show-current)"
      [[ -n "$branch" && -z "$(git -C "$root" status --porcelain)" ]] || fail "$root: not on a branch, or uncommitted changes"
      # The .ipa lists the testers' UDIDs: never into a repository anyone can read.
      origin="$(git -C "$root" remote get-url origin)"
      if [[ "$origin" =~ github\.com[:/]([^/]+)/([^/]+)$ ]]; then
        repository="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
        [[ "$(curl -s -o /dev/null -w '%{http_code}' "https://github.com/$repository")" != 200 ]] ||
          fail "$repository is public, and the .ipa lists your testers' UDIDs: use a private repository (docs/releasing.md, Ad Hoc builds)"
      fi
      [[ -z "$push" ]] || git -C "$root" pull --ff-only --quiet
    fi
    rm -rf "${site:?}/$variant"
    mkdir -p "$site/$variant/$version"
    cp "$folder/adhoc/Dispatch.ipa" "$folder/adhoc/manifest.plist" "$folder/adhoc/index.html" "$site/$variant/$version/"
    cp "$folder/adhoc/index.html" "$site/$variant/index.html"
    if [[ -n "$root" ]]; then
      git -C "$site" add -A .
      old="$(git -C "$root" rev-parse HEAD)"
      new="$(TZ=UTC git -C "$root" commit-tree "$(git -C "$root" write-tree)" -m "Site, with Dispatch $variant $version (Ad Hoc)")"
      git -C "$root" update-ref "refs/heads/$branch" "$new" "$old"
      git -C "$root" reset --quiet
      [[ -z "$push" ]] || git -C "$root" push --quiet --force-with-lease="$branch:$old" origin "$branch"
    fi
  fi
  # A host deployed from a folder rather than a repository: its command, run once the files are in place.
  if [[ -n "${DISPATCH_ADHOC_DEPLOY:-}" ]]; then
    if [[ -n "$push" ]]; then
      echo "Deploying: $DISPATCH_ADHOC_DEPLOY"
      bash -c "$DISPATCH_ADHOC_DEPLOY" || fail "the deploy command failed; the files are in ${DISPATCH_ADHOC_SITE:-$folder/adhoc}"
    else
      echo "note: --no-push, so not deploying ($DISPATCH_ADHOC_DEPLOY)"
    fi
  fi
  # Under --no-push nothing went online: the next run signs and deploys again.
  [[ -z "$push" ]] || echo "$base/index.html" > "$work/adhoc.done"
fi

if [[ -n "$testflight" && ! -f "$work/ios.done" ]]; then
  archive_from_vm
  rm -rf "$work/upload"
  key=("$DISPATCH_ASC_KEY" "$DISPATCH_ASC_KEY_ID")
  if [[ -n "$admin" ]]; then
    # Automatic signing with this Mac's certificate, not Apple's cloud-managed one.
    key=("$admin" "$admin_id")
    plutil -create xml1 "$work/ExportOptions.plist"
    for setting in "method -string app-store-connect" "destination -string upload" "teamID -string $DISPATCH_TEAM" \
      "signingStyle -string automatic" "signingCertificate -string Apple Distribution" "uploadSymbols -bool YES" \
      "manageAppVersionAndBuildNumber -bool NO"; do
      read -r name kind value <<< "$setting"
      plutil -insert "$name" "$kind" "$value" "$work/ExportOptions.plist"
    done
  else
    signing_profiles use "$CONFIG/$variant-profiles" "$DISPATCH_TEAM" "$prefix.mobile" "$work/ExportOptions.plist"
  fi
  if [[ -z "$push" ]]; then
    echo "note: --no-push, so no TestFlight upload"
  else
    echo "Signing and uploading Dispatch for iPhone $version ($number) to App Store Connect" \
      "${admin:+(automatic signing, Admin key $admin_id)}"
    xcodebuild -exportArchive -archivePath "$work/DispatchMobile.xcarchive" -exportOptionsPlist "$work/ExportOptions.plist" \
      -exportPath "$work/upload" ${admin:+-allowProvisioningUpdates} -authenticationKeyPath "${key[0]}" \
      -authenticationKeyID "${key[1]}" -authenticationKeyIssuerID "$DISPATCH_ASC_ISSUER" > "$work/export.log" 2>&1 ||
      { tail -30 "$work/export.log" >&2; fail "export or upload failed; full log: $work/export.log"; }
    date -u +%Y-%m-%dT%H:%M:%SZ > "$work/ios.done"
    if [[ -n "$admin" ]]; then
      signing_profiles keep "$CONFIG/$variant-profiles" "$DISPATCH_TEAM" "$prefix.mobile" ||
        echo "note: uploaded; the next run without --admin-key needs the App Store profiles above, made in the portal"
      echo "Revoke the Admin key $admin_id in App Store Connect (Users and Access, Integrations) and delete $admin."
    fi
  fi
fi

# 5. Record.
cp "$work/github/build.json" "$folder/github-build.json"
cp "$work/vm/build.json" "$folder/vm-build.json"
released="" tapped="" uploaded="" install=""
[[ ! -f "$work/release.done" ]] || released="https://github.com/$REPOSITORY/releases/tag/$version"
[[ ! -f "$work/tap.done" ]] || tapped="$(git -C "$tap" log -1 --format=%H -- Casks/dispatch.rb)"
[[ ! -f "$work/ios.done" ]] || uploaded="$(cat "$work/ios.done")"
[[ ! -f "$work/adhoc.done" ]] || install="$(cat "$work/adhoc.done")"
python3 -I - "$folder" "$variant" "$version" "$number" "$commit" "$DISPATCH_TEAM" "$(cat "$work/github.run")" "$digest" \
  "$released" "$tapped" "$uploaded" "$install" <<'PY'
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path
folder, variant, version, number, commit, team, run, digest, released, tapped, uploaded, install = sys.argv[1:]
folder = Path(folder)
path = folder / 'published.json'
published = json.loads(path.read_text()) if path.is_file() else {}
published.update(variant=variant, version=version, build=number, commit=commit, team=team, github_run=int(run),
                 published=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                 mac={'dmg': f'Dispatch-{version}.dmg', 'sha256': digest, 'release': released or None,
                      'cask_commit': tapped or None})
if uploaded:
    published['ios'] = {'uploaded': uploaded}
if install:
    published['adhoc'] = {'ipa': 'adhoc/Dispatch.ipa',
                          'sha256': hashlib.sha256((folder / 'adhoc/Dispatch.ipa').read_bytes()).hexdigest(),
                          'install': install}
for part in ('ios', 'adhoc'):
    published.setdefault(part, None)
path.write_text(json.dumps(published, indent=2) + '\n')
PY
git -C "$release_repo" add .gitignore "$variant/$version"
if ! git -C "$release_repo" diff --cached --quiet; then
  TZ=UTC git -C "$release_repo" commit --quiet -m "Publish $variant $version ($number, $(cut -c1-8 <<< "$commit"))"
fi
[[ -z "$push" ]] || git -C "$release_repo" push --quiet

echo
echo "Dispatch $version ($variant, build $number)$([[ -n "$push" ]] && echo ", published" || echo ": checked and signed, nothing published (--no-push)")"
echo "  Mac     $dmg"
echo "          SHA-256 $digest"
[[ -z "$released" ]] || echo "          $released"
[[ -z "$tapped" ]] || echo "          cask: homebrew-tap $(cut -c1-8 <<< "$tapped")"
[[ -z "$uploaded" ]] || echo "  iPhone  uploaded; in TestFlight once App Store Connect has processed it"
if [[ -n "$install" ]]; then
  echo "  Ad Hoc  $folder/adhoc: Dispatch.ipa, manifest.plist, index.html"
  [[ -n "${DISPATCH_ADHOC_SITE:-}" ]] && echo "          copied to $DISPATCH_ADHOC_SITE/$variant/$version" ||
    echo "          serve those three at $DISPATCH_ADHOC_URL/$variant/$version/"
  echo "          install page: $install"
fi
