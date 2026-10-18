#!/usr/bin/env python3
"""Write and check build/signing.xcconfig, the git-ignored signing settings of Dispatch for iPhone (docs/ios.md,
Signing and a device). Mobile/Config/Signing.xcconfig includes it; simulator builds need none of it.

  python3 scripts/ios-signing.py ABCDE12345 [--suffix .yourname]   write it (a free Apple ID needs a suffix)
  python3 scripts/ios-signing.py --check [--xcode]                  validate it; --xcode asks xcodebuild too
  python3 scripts/ios-signing.py --teams                            teams this Mac knows (Xcode accounts, certificates)
  python3 scripts/ios-signing.py --remove                           delete it

The team id is the ten characters Xcode shows under Settings, Accounts (a free Apple ID's is its "Personal Team").
Nothing here talks to Apple: xcodebuild does, with -allowProvisioningUpdates (`./run.sh --ios-device`)."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'build/signing.xcconfig'
BUNDLE_ID = 'yachts.dispatch.mobile'
KNOWN = ('DEVELOPMENT_TEAM', 'DISPATCH_BUNDLE_ID_SUFFIX')
TEAM = re.compile(r'[A-Z0-9]{10}')
# One or more bundle id components, each led by a dot: letters, digits and hyphens (CFBundleIdentifier's alphabet).
SUFFIX = re.compile(r'(\.[A-Za-z0-9-]+)+')
HEADER = ('// Signing for Dispatch for iPhone, written by scripts/ios-signing.py (docs/ios.md). Git-ignored;\n'
          '// Mobile/Config/Signing.xcconfig includes it.\n')


def parse(text):
    """`KEY = value` lines of an xcconfig: {key: value}, and the lines that are neither that, a comment nor blank."""
    settings, other = {}, []
    for line in text.splitlines():
        stripped = line.split('//', 1)[0].strip()
        if not stripped:
            continue
        match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])*)\s*=\s*(.*?)\s*;?', stripped)
        if match:
            settings[match[1]] = match[2]
        elif not stripped.startswith('#include'):
            other.append(line)
    return settings, other


def problems(settings, other=()):
    """What is wrong with these settings for a device build; empty when they sign."""
    found = []
    team = settings.get('DEVELOPMENT_TEAM', '')
    if not team:
        found.append('DEVELOPMENT_TEAM is missing: device builds have no team to sign with')
    elif not TEAM.fullmatch(team):
        found.append(f'DEVELOPMENT_TEAM {team!r} is not a team id (ten capital letters and digits)')
    suffix = settings.get('DISPATCH_BUNDLE_ID_SUFFIX', '')
    if suffix and not SUFFIX.fullmatch(suffix):
        found.append(f'DISPATCH_BUNDLE_ID_SUFFIX {suffix!r} must be one or more ".component" parts '
                     '(letters, digits, hyphens), e.g. ".yourname"')
    found += [f'not an xcconfig setting: {line.strip()}' for line in other]
    return found


def render(team, suffix=''):
    text = HEADER + f'DEVELOPMENT_TEAM = {team}\n'
    if suffix:
        text += f'DISPATCH_BUNDLE_ID_SUFFIX = {suffix}\n'
    return text


def bundle_id(settings):
    return BUNDLE_ID + settings.get('DISPATCH_BUNDLE_ID_SUFFIX', '')


def write(team, suffix='', path=CONFIG):
    settings = {'DEVELOPMENT_TEAM': team, **({'DISPATCH_BUNDLE_ID_SUFFIX': suffix} if suffix else {})}
    found = problems(settings)
    if found:
        raise ValueError('; '.join(found))
    previous = parse(path.read_text())[0] if path.is_file() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(render(team, suffix))
    temporary.replace(path)
    return previous


def certificate_teams(run=subprocess.run):
    """{team id: certificate common name} of the Apple Development certificates in the keychains (the subject's OU is
    the team; the name's parenthesis is the person, not the team)."""
    listing = run(['security', 'find-certificate', '-a', '-c', 'Apple Development', '-p'], capture_output=True, text=True)
    teams = {}
    for pem in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', listing.stdout or '', re.S):
        subject = run(['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'], input=pem,
                      capture_output=True, text=True).stdout
        unit = re.search(r'(?:^|[,=\s])OU=([A-Z0-9]{10})(?:,|$)', subject.strip().removeprefix('subject='))
        name = re.search(r'CN=([^,]+)', subject)
        if unit:
            teams[unit[1]] = name[1] if name else 'Apple Development'
    return teams


def xcode_teams(plist):
    """{team id: name} from Xcode's preferences (com.apple.dt.Xcode), whichever of its two layouts this Xcode wrote."""
    teams = {}
    for key in ('IDEProvisioningTeamByIdentifier', 'IDEProvisioningTeams'):
        accounts = plist.get(key)
        if not isinstance(accounts, dict):
            continue
        for entries in accounts.values():
            for entry in entries if isinstance(entries, list) else []:
                if isinstance(entry, dict) and TEAM.fullmatch(str(entry.get('teamID', ''))):
                    free = ' (free: 7-day profiles)' if entry.get('isFreeProvisioningTeam') else ''
                    teams[entry['teamID']] = str(entry.get('teamName', '')) + free
    return teams


def known_teams():
    teams = {}
    exported = subprocess.run(['defaults', 'export', 'com.apple.dt.Xcode', '-'], capture_output=True)
    if exported.returncode == 0 and exported.stdout:
        try:
            teams.update(xcode_teams(plistlib.loads(exported.stdout)))
        except plistlib.InvalidFileException:
            pass
    for team, name in certificate_teams().items():
        teams.setdefault(team, name)
    return teams


def resolved(sdk='iphoneos'):
    """The signing settings xcodebuild resolves for the app with this file in place."""
    output = subprocess.run(['xcodebuild', '-project', 'Dispatch.xcodeproj', '-target', 'DispatchMobile', '-configuration',
                             'Release', '-sdk', sdk, '-showBuildSettings'], cwd=ROOT, capture_output=True, text=True)
    wanted = ('DEVELOPMENT_TEAM', 'PRODUCT_BUNDLE_IDENTIFIER', 'CODE_SIGN_STYLE', 'CODE_SIGN_IDENTITY')
    values = {}
    for line in output.stdout.splitlines():
        key, _, value = line.strip().partition(' = ')
        if key in wanted:
            values[key] = value
    return values


def check(path=CONFIG, xcode=False):
    if not path.is_file():
        print(f'{os.path.relpath(path, ROOT)} does not exist: device builds cannot sign. '
              'Write it with: python3 scripts/ios-signing.py <TEAM ID> [--suffix .yourname]')
        return 1
    settings, other = parse(path.read_text())
    found = problems(settings, other)
    for problem in found:
        print('error: ' + problem)
    if found:
        return 1
    print(f'Team {settings["DEVELOPMENT_TEAM"]}, bundle id {bundle_id(settings)}')
    teams = known_teams()
    team = settings['DEVELOPMENT_TEAM']
    if team in teams:
        print(f'This Mac knows the team: {teams[team]}')
    else:
        print('note: no Xcode account or Apple Development certificate on this Mac names this team yet; sign in under '
              'Xcode, Settings, Accounts (xcodebuild -allowProvisioningUpdates then makes the certificate and profile)')
    if xcode:
        values = resolved()
        print('xcodebuild resolves: ' + ', '.join(f'{key} = {value}' for key, value in sorted(values.items())))
        if values.get('DEVELOPMENT_TEAM') != team or values.get('PRODUCT_BUNDLE_IDENTIFIER') != bundle_id(settings):
            print('error: xcodebuild does not see these settings (is Mobile/Config/Signing.xcconfig the target\'s '
                  'configuration file? run python3 scripts/generate-project.py)')
            return 1
    return 0


def main(arguments=None):
    parser = argparse.ArgumentParser(prog='scripts/ios-signing.py', description=__doc__.split('\n\n')[0],
                                     epilog=__doc__.split('\n\n', 1)[1], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('team', nargs='?', help='the team id to sign with (ten characters)')
    parser.add_argument('--suffix', default='', help='appended to yachts.dispatch.mobile, e.g. .yourname')
    parser.add_argument('--check', action='store_true', help='validate build/signing.xcconfig')
    parser.add_argument('--xcode', action='store_true', help='with --check: confirm what xcodebuild resolves')
    parser.add_argument('--teams', action='store_true', help='list the teams this Mac knows')
    parser.add_argument('--remove', action='store_true', help='delete build/signing.xcconfig')
    parser.add_argument('--path', type=Path, default=CONFIG, help=argparse.SUPPRESS)
    args = parser.parse_args(arguments)
    if sum(map(bool, (args.team, args.check, args.teams, args.remove))) != 1:
        parser.error('give a team id, or one of --check, --teams, --remove')
    if args.teams:
        teams = known_teams()
        for team, name in sorted(teams.items()):
            print(f'{team}  {name}')
        if not teams:
            print('No team found: add your Apple ID under Xcode, Settings, Accounts (a free one gets a Personal Team).')
        return 0
    if args.remove:
        if args.path.is_file():
            args.path.unlink()
            print(f'Removed {os.path.relpath(args.path, ROOT)}')
        return 0
    if args.check:
        return check(args.path, args.xcode)
    try:
        previous = write(args.team, args.suffix, args.path)
    except ValueError as error:
        parser.error(str(error))
    if previous:
        print('Replaced ' + ', '.join(f'{key} = {value}' for key, value in sorted(previous.items())))
    print(f'Wrote {os.path.relpath(args.path, ROOT)}: team {args.team}, bundle id {BUNDLE_ID + args.suffix}')
    return check(args.path)


if __name__ == '__main__':
    sys.exit(main())
