#!/usr/bin/env python3
"""Build the mockup apps and screenshot their screens in the simulator.

    python3 mockups/shoot.py build [phone|ipad|watch]      # XcodeGen, xcodebuild, simctl install
    python3 mockups/shoot.py rotate                        # once per iPad simulator boot: landscape
    python3 mockups/shoot.py H2-review [dark|light]        # one screen; both schemes by default
    python3 mockups/shoot.py all [phone|ipad|watch]        # every screen of the platform, then its sheets
    python3 mockups/shoot.py sheets [phone|ipad|watch]     # contact sheets from existing shots
    python3 mockups/shoot.py list                          # the screen ids by group

Shots land in mockups/shots/<id>-<scheme>.png (watch: <id>.png), contact sheets in mockups/sheets/<group>-<scheme>.png.
The simulator is the booted one whose name fits the platform, else the newest available, which is booted;
MOCKUPS_DEVICE=<name or UDID> overrides. MOCKUPS_SETTLE seconds (default 3) wait before each screenshot.
"""
import json, os, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent

# Screen ids by contact-sheet group; the platform decides the simulator and the sheet layout.
GROUPS = {
    'phone': {
        'tab': ['H0-terminal', 'H1-files', 'H2-review', 'H3-commits'],
        'graph': ['H3x-commits-status', 'H3d-commits-vivid', 'H3e-commits-saturated', 'H3f-commits-vivid-blue', 'H3g-commits-vivid-rose', 'H3h-commits-vivid-cyan', 'H3i-commits-vivid-gray', 'H3a-commits-tint', 'H3b-commits-hues', 'H3c-commits-ink'],
        'review': ['R2-diff-comments', 'R3-diff-select', 'R4-diff-compose', 'R5-review-sheet', 'R5b-review-sheet-swipe',
                   'R5c-review-sheet-noagent'],
        'pushed': ['F2-file', 'C2-commit'],
        'spaces': ['P1-spaces', 'P1b-spaces-needs-you', 'P2-space', 'P2b-space-swipe', 'P2c-space-menu', 'P2d-space-edit',
                   'P2e-space-new-tab', 'P3-space-switcher'],
        'host': ['W0-spaces-tree', 'W0b-offline-collapsed', 'W0c-offline-menu', 'W1a-host-small', 'W1b-host-dragging',
                 'W1c-host-small-offline', 'W1-host-cpu', 'W2-host-mem', 'W3-host-scrub', 'W4-host-detail', 'W5-host-stale',
                 'W6-host-plain', 'W7-host-lowpower'],
        'states': ['S1-no-helper', 'S2-no-grant', 'S3-offline', 'S4-review-sent', 'S5-diff-fold-outdated', 'S6-chat-entry'],
        'settings': ['G1-settings', 'G2-terminal-font', 'G3-chat-font', 'G4-theme', 'G5-notifications'],
        'terminal': ['T1-terminal-search', 'T2-terminal-menu'],
        'chat': ['C1-chat-search', 'C2-chat-slash', 'C3-chat-side', 'C4-chat-goal', 'C4b-chat-goal-sheet',
                 'C5-chat-conversation', 'C6-chat-jump'],
    },
    'ipad': {
        'ipad': ['I1-split-files', 'I2-split-review', 'I2b-split-review-empty', 'I3-split-commits', 'I3b-split-commits-empty',
                 'I4-split-chat', 'I5-host-popover', 'I7-full-width-terminal', 'I8-sidebar-hidden'],
        'ipad-half': ['I6-half-width', 'I6b-half-width-spaces'],
    },
    'watch': {
        'watch': ['K1-list', 'K1b-list-scrolled', 'K2-thread', 'K3-approval', 'K4-question', 'K5-reply', 'K6-host',
                  'K6b-host-offline', 'K7-complication', 'K8-review'],
    },
}
PLATFORMS = {
    'phone': dict(scheme='Mockups', sdk='iphonesimulator', product='Debug-iphonesimulator/Mockups.app',
                  bundle='dev.dispatch.mockups.Mockups', match=r'^iPhone', schemes=['dark', 'light'], cols='6', scale='0.25'),
    'ipad': dict(scheme='Mockups', sdk='iphonesimulator', product='Debug-iphonesimulator/Mockups.app',
                 bundle='dev.dispatch.mockups.Mockups', match=r'^iPad', schemes=['dark', 'light'], cols='3', scale='0.25'),
    'watch': dict(scheme='MockupsWatch', sdk='watchsimulator', product='Debug-watchsimulator/MockupsWatch.app',
                  bundle='dev.dispatch.mockups.MockupsWatch', match=r'^Apple Watch', schemes=[None], cols='6', scale='1'),
}


def platform_of(screen):
    for platform, groups in GROUPS.items():
        if any(screen in ids for ids in groups.values()):
            return platform
    sys.exit(f'unknown screen {screen}; see `shoot.py list`')


def run(*cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, text=True, **kw)


def device(platform):
    """The simulator's UDID: MOCKUPS_DEVICE, else a booted one that fits, else the newest available (booted here)."""
    want = os.environ.get('MOCKUPS_DEVICE')
    data = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j', capture_output=True).stdout)
    devices = [(runtime, d) for runtime, ds in data['devices'].items() for d in ds]
    pattern = re.compile(PLATFORMS[platform]['match'])
    fits = [(r, d) for r, d in devices if (want in (d['udid'], d['name']) if want else pattern.match(d['name']))]
    if not fits:
        sys.exit(f'no {platform} simulator available' + (f' matching {want}' if want else ''))
    # Among booted ones, a plain device first: not a fold (the Duo opens to a 2853-pixel inner screen) and the shortest
    # name wins ("iPhone 17" before "iPhone 17 Pro Max"), so the shots keep one size across runs.
    booted = sorted((d for _, d in fits if d['state'] == 'Booted' and not want), key=lambda d: ('Duo' in d['name'], len(d['name']), d['name']))
    if want:
        booted = [d for _, d in fits if d['state'] == 'Booted']
    if booted:
        return booted[0]['udid']
    runtime, chosen = sorted(fits, key=lambda rd: rd[0])[-1]
    run('xcrun', 'simctl', 'boot', chosen['udid'], check=False, capture_output=True)
    print(f"booted {chosen['name']} ({runtime.rsplit('.', 1)[-1]})")
    return chosen['udid']


def build(platform):
    p = PLATFORMS[platform]
    xcodegen = run('python3', 'scripts/setup-build-tools.py', 'xcodegen', '--offline', cwd=REPO, capture_output=True).stdout.strip()
    run(xcodegen, 'generate', '--spec', 'project.yml', '--quiet', cwd=ROOT)
    udid = device(platform)
    result = run('xcodebuild', '-project', 'Mockups.xcodeproj', '-scheme', p['scheme'], '-configuration', 'Debug', '-sdk', p['sdk'],
                 '-destination', f'id={udid}', '-derivedDataPath', 'build', '-quiet', 'build', cwd=ROOT, check=False,
                 capture_output=True)
    errors = [line for line in result.stdout.splitlines() + result.stderr.splitlines() if 'error:' in line]
    if result.returncode or errors:
        sys.exit('\n'.join(errors) or result.stderr)
    run('xcrun', 'simctl', 'install', udid, str(ROOT / 'build/Build/Products' / p['product']))
    contact = ROOT / 'build/contact'
    if not contact.exists():
        run('swiftc', '-O', 'contact.swift', '-o', str(contact), cwd=ROOT)
    return udid


def rotate():
    udid = device('ipad')
    result = run('xcodebuild', 'test', '-project', 'Mockups.xcodeproj', '-scheme', 'Mockups', '-destination', f'id={udid}',
                 '-derivedDataPath', 'build', '-only-testing:MockupsRotate', '-quiet', cwd=ROOT, check=False, capture_output=True)
    print('landscape' if result.returncode == 0 else result.stdout[-2000:] + result.stderr[-2000:])


def shot(screen, scheme, udid=None):
    platform = platform_of(screen)
    p = PLATFORMS[platform]
    udid = udid or device(platform)
    (ROOT / 'shots').mkdir(exist_ok=True)
    run('xcrun', 'simctl', 'terminate', udid, p['bundle'], check=False, capture_output=True)
    args = ['-screen', screen] + (['-scheme', scheme] if scheme else [])
    run('xcrun', 'simctl', 'launch', udid, p['bundle'], *args, capture_output=True)
    time.sleep(float(os.environ.get('MOCKUPS_SETTLE', '3')))
    out = ROOT / 'shots' / (f'{screen}-{scheme}.png' if scheme else f'{screen}.png')
    run('xcrun', 'simctl', 'io', udid, 'screenshot', str(out), capture_output=True)
    print(out.relative_to(REPO))


def sheets(platform):
    p = PLATFORMS[platform]
    (ROOT / 'sheets').mkdir(exist_ok=True)
    env = dict(os.environ, CONTACT_COLS=p['cols'], CONTACT_SCALE=p['scale'])
    for group, ids in GROUPS[platform].items():
        for scheme in p['schemes']:
            out = ROOT / 'sheets' / (f'{group}-{scheme}.png' if scheme else f'{group}.png')
            panels = [f"{i.replace('-', ' ')}:{ROOT / 'shots' / (f'{i}-{scheme}.png' if scheme else f'{i}.png')}" for i in ids]
            run(str(ROOT / 'build/contact'), str(out), *panels, env=env)
            print(out.relative_to(REPO))


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__); return
    cmd, rest = argv[0], argv[1:]
    if cmd == 'list':
        for platform, groups in GROUPS.items():
            for group, ids in groups.items():
                print(f'{platform:5} {group:10} ' + ' '.join(ids))
    elif cmd == 'build':
        for platform in rest or ['phone']:
            build(platform)
    elif cmd == 'rotate':
        rotate()
    elif cmd == 'all':
        for platform in rest or ['phone']:
            udid = device(platform)
            for ids in GROUPS[platform].values():
                for screen in ids:
                    for scheme in PLATFORMS[platform]['schemes']:
                        shot(screen, scheme, udid)
            sheets(platform)
    elif cmd == 'sheets':
        for platform in rest or ['phone']:
            sheets(platform)
    else:
        platform = platform_of(cmd)
        for scheme in (rest or PLATFORMS[platform]['schemes']):
            shot(cmd, None if scheme in ('none', None) else scheme)


if __name__ == '__main__':
    main(sys.argv[1:])
