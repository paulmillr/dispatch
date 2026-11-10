#!/usr/bin/env python3
"""The Ad Hoc iPhone build's helpers, for scripts/release/iphone.sh (docs/releasing.md, Ad Hoc builds).

  adhoc.py profiles FOLDER TEAM PHONE OPTIONS   FOLDER's Ad Hoc profiles of the phone app PHONE, its watch app and the
                                                watch's widgets, checked (team, kind, unexpired, the App Group on the
                                                watch ones, made for this Mac's Apple Distribution certificate of
                                                TEAM); installed where Xcode looks, and export options OPTIONS that name
                                                them. Prints one line: until when, how many devices
  adhoc.py label VERSION NUMBER                 the build's name, 0.1.7-20261110.1432: the version and the build
                                                number (the commit's UTC time)
  adhoc.py site SITE PHONE [IPA VERSION LABEL]  the install site SITE, the maintainer's own (index.html, manifest.plist
                                                and what they show), checked: the manifest installs PHONE from an https
                                                address ending in .ipa, and the page says the version once
                                                (<span>version …</span>). With IPA, the build goes in: the .ipa under
                                                that name, the manifest's bundle-version VERSION, the page's LABEL; the
                                                addresses stay as the site has them"""
from datetime import datetime, timezone
import hashlib
import html
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

# Xcode 16 and later keep profiles in the first folder, older ones in the second.
XCODE = [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
         Path.home() / 'Library/MobileDevice/Provisioning Profiles']


def profiles(folder, team, phone, options):
    folder = Path(folder)
    bundles = [phone, phone + '.watchkitapp', phone + '.watchkitapp.widgets']
    group = 'group.' + phone
    identities = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'],
                                capture_output=True, text=True).stdout
    ours = set(re.findall(rf'([0-9A-F]{{40}}) "Apple Distribution: .*\({team}\)"', identities))
    if not ours:
        sys.exit(f'no valid Apple Distribution identity of team {team} in the keychain')
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    found, problems = {}, []
    for path in sorted(folder.glob('*.mobileprovision')) if folder.is_dir() else []:
        # The decoded plist is what counts: the exit status also reflects whether this Mac trusts the signer.
        try:
            profile = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', str(path)],
                                                    capture_output=True).stdout)
        except Exception:
            problems.append(f'{path.name}: not a provisioning profile')
            continue
        entitlements = profile.get('Entitlements', {})
        bundle = entitlements.get('application-identifier', '').partition('.')[2]
        if bundle not in bundles or team not in profile.get('TeamIdentifier', []):
            continue
        certificates = {hashlib.sha1(der).hexdigest().upper() for der in profile.get('DeveloperCertificates', [])}
        if entitlements.get('get-task-allow') or profile.get('ProvisionsAllDevices') or not profile.get('ProvisionedDevices'):
            problems.append(f'{path.name} ({bundle}): not a Distribution, Ad Hoc profile')
        elif profile['ExpirationDate'] < now:
            problems.append(f'{path.name} ({bundle}): expired on {profile["ExpirationDate"]:%Y-%m-%d}')
        elif bundle != phone and group not in entitlements.get('com.apple.security.application-groups', []):
            problems.append(f'{path.name}: no App Group {group}; give the App ID {bundle} that group, then make the '
                            'profile again')
        elif not certificates & ours:
            problems.append(f'{path.name} ({bundle}): made for another certificate; in the developer portal edit the '
                            'profile, choose this Mac\'s Apple Distribution certificate, download it')
        elif profile.get('IsXcodeManaged') or profile.get('Name', '').startswith('iOS Team '):
            # Xcode refuses its own profiles for manual signing: only ones made in the developer portal serve.
            problems.append(f'{path.name} ({bundle}): "{profile.get("Name")}" is Xcode-managed, which manual signing '
                            'refuses; make one in the developer portal (Profiles, +, Distribution: Ad Hoc)')
        elif bundle not in found or profile['CreationDate'] > found[bundle]['CreationDate']:
            found[bundle] = dict(profile, path=path)
    missing = [bundle for bundle in bundles if bundle not in found]
    if missing:
        sys.exit('\n'.join(problems + [f'no usable Ad Hoc profile for {", ".join(missing)} in {folder}. In the '
                                       'developer portal: Profiles, +, Distribution: Ad Hoc, one per bundle id, '
                                       f'certificate Apple Distribution, the devices; download them into {folder}']))
    for profile in found.values():
        for target in XCODE:
            target.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(profile['path'], target / f'{profile["UUID"]}.mobileprovision')
    Path(options).write_bytes(plistlib.dumps({
        'method': 'release-testing', 'destination': 'export', 'thinning': '<none>',
        'teamID': team, 'signingStyle': 'manual', 'signingCertificate': 'Apple Distribution',
        'provisioningProfiles': {bundle: found[bundle]['UUID'] for bundle in bundles},
        'manageAppVersionAndBuildNumber': False}))
    devices = len(found[phone]['ProvisionedDevices'])
    until = min(profile['ExpirationDate'] for profile in found.values())
    print(f'{len(found)} profiles, until {until:%Y-%m-%d}, {devices} device{"" if devices == 1 else "s"}')


def label(version, number):
    """0.1.7-20261110.1432: the version and the build number, the commit's UTC time; builds of one version differ."""
    return f'{version}-{number}'


VERSION = re.compile(r'(<span>version )[^<]*(</span>)')


def site(folder, phone, ipa=None, version=None, name=None):
    folder = Path(folder)
    manifest_path, page_path = folder / 'manifest.plist', folder / 'index.html'
    if not manifest_path.is_file() or not page_path.is_file():
        sys.exit(f'{folder} needs index.html and manifest.plist (docs/releasing.md, Ad Hoc builds)')
    manifest = plistlib.loads(manifest_path.read_bytes())
    try:
        item, = manifest['items']
        package, = [asset for asset in item['assets'] if asset.get('kind') == 'software-package']
    except (KeyError, TypeError, ValueError):
        sys.exit(f'{manifest_path} must list one item with one software-package asset')
    address = package.get('url', '')
    if not re.fullmatch(r'https://[^\s/]+/\S*\.ipa', address):
        sys.exit(f'{manifest_path}: the software-package must be an https:// address ending in .ipa')
    if item.get('metadata', {}).get('bundle-identifier') != phone:
        sys.exit(f'{manifest_path}: the bundle-identifier must be {phone}')
    page = page_path.read_text()
    if len(VERSION.findall(page)) != 1:
        sys.exit(f'{page_path} must say the version once, as <span>version …</span>')
    if ipa is None:
        print(f'installs {address.rsplit("/", 1)[1]}, from {len(list(folder.iterdir()))} files')
        return
    shutil.copyfile(ipa, folder / address.rsplit('/', 1)[1])
    item['metadata']['bundle-version'] = version
    manifest_path.write_bytes(plistlib.dumps(manifest))
    page_path.write_text(VERSION.sub(lambda match: match[1] + html.escape(name) + match[2], page))


if __name__ == '__main__':
    command, arguments = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if command == 'profiles' and len(arguments) == 4:
        profiles(*arguments)
    elif command == 'label' and len(arguments) == 2:
        print(label(*arguments))
    elif command == 'site' and len(arguments) in (2, 5):
        site(*arguments)
    else:
        sys.exit(__doc__)
