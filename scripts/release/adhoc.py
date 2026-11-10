#!/usr/bin/env python3
"""The Ad Hoc iPhone build's helpers, for scripts/release/iphone.sh (docs/releasing.md, Ad Hoc builds).

  adhoc.py profiles FOLDER TEAM PHONE OPTIONS   FOLDER's Ad Hoc profiles of the phone app PHONE, its watch app and the
                                                watch's widgets, checked (team, kind, unexpired, the App Group on the
                                                watch ones, made for this Mac's Apple Distribution certificate of
                                                TEAM); installed where Xcode looks, and export options OPTIONS that name
                                                them. Prints one line: until when, how many devices
  adhoc.py label VERSION NUMBER                 the build's name, 0.1.7-20261110
  adhoc.py page FOLDER BASE BUNDLE VERSION NUMBER
                                                FOLDER/manifest.plist, the manifest itms-services reads, and
                                                FOLDER/index.html, the install page with its link; both name their
                                                final addresses, BASE/Dispatch.ipa and BASE/manifest.plist. The build
                                                is named VERSION-<date>, the date of the build NUMBER (label)"""
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
    """0.1.7-20261110: the version and the version commit's UTC date, the build number's first half."""
    return f'{version}-{number.partition(".")[0]}'


def page(folder, base, bundle, version, number):
    folder = Path(folder)
    name = html.escape(label(version, number))
    (folder / 'manifest.plist').write_bytes(plistlib.dumps({'items': [{
        'assets': [{'kind': 'software-package', 'url': f'{base}/Dispatch.ipa'}],
        'metadata': {'bundle-identifier': bundle, 'bundle-version': version, 'kind': 'software', 'title': 'Dispatch'},
    }]}))
    link = html.escape(f'itms-services://?action=download-manifest&url={base}/manifest.plist')
    (folder / 'index.html').write_text(f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dispatch {name}</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:32em;margin:3em auto;padding:0 1em;line-height:1.5}}
a.install{{display:inline-block;padding:.8em 1.4em;border-radius:.8em;background:#0a84ff;color:#fff;text-decoration:none;font-weight:600}}</style>
</head><body>
<h1>Dispatch for iPhone</h1>
<p>{name}</p>
<p><a class="install" href="{link}">Install</a></p>
<p>Open this page in Safari on your iPhone. It installs only on iPhones registered for this build; the Apple Watch app
installs on registered watches too.</p>
</body></html>
''')


if __name__ == '__main__':
    command, arguments = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if command == 'profiles' and len(arguments) == 4:
        profiles(*arguments)
    elif command == 'page' and len(arguments) == 5:
        page(*arguments)
    elif command == 'label' and len(arguments) == 2:
        print(label(*arguments))
    else:
        sys.exit(__doc__)
