#!/usr/bin/env python3
"""Build the mockup apps and screenshot their screens in the simulator.

    python3 mockups/shoot.py build [phone|ipad|landscape|watch]   # XcodeGen, xcodebuild, simctl install
    python3 mockups/shoot.py rotate [ipad|landscape]       # once per simulator boot: landscape (the iPad, or an iPhone)
    python3 mockups/shoot.py H2-review [dark|light]        # one screen; both schemes by default
    python3 mockups/shoot.py all [phone|ipad|watch]        # every screen of the platform, then its sheets
    python3 mockups/shoot.py sheets [phone|ipad|watch]     # contact sheets from existing shots
    python3 mockups/shoot.py list                          # the screen ids by group

    python3 mockups/shoot.py mac [render|list|sheets] [--themes dark,light] [selector…]   # Mac screens (README, Mac)
    python3 mockups/shoot.py M1-main [dark|light|nautical]                            # one Mac screen
    python3 mockups/shoot.py all mac                       # every Mac screen, then its sheets

The Mac screens need no simulator: `mac` builds the Swift package in Mac/ (incremental, about a second) and draws them
offscreen into mockups/shots/mac/<id>-<theme>.png, sheets into mockups/sheets/mac-<group>-<theme>.png.
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
        'review': ['R2-diff-comments', 'R3-diff-select', 'R4-diff-compose', 'R5-review-sheet', 'R5b-review-sheet-swipe',
                   'R5c-review-sheet-noagent'],
        'pushed': ['F2-file', 'C2-commit'],
        'spaces': ['P1-spaces', 'P1b-spaces-needs-you', 'P2-space', 'P2b-space-swipe', 'P2c-space-menu', 'P2d-space-edit',
                   'P2e-space-new-tab', 'P3-space-switcher'],
        'host': ['W0-spaces-tree', 'W0b-offline-collapsed', 'W0c-offline-menu', 'W1a-host-small', 'W1b-host-dragging',
                 'W1c-host-small-offline', 'W1-host-cpu', 'W2-host-mem', 'W3-host-scrub', 'W5-host-stale',
                 'W6-host-plain', 'W7-host-lowpower'],
        'states': ['S1-no-helper', 'S2-no-grant', 'S3-offline', 'S4-review-sent', 'S5-diff-fold-outdated', 'S6d-chat-corner-time'],
        'settings': ['G1-settings', 'G2-terminal-font', 'G3-chat-font', 'G4-theme', 'G5-notifications'],
        'terminal': ['T1-terminal-search', 'T2-terminal-menu'],
        'chat': ['C1-chat-search', 'C2-chat-slash', 'C3-chat-side', 'C4-chat-goal', 'C4b-chat-goal-sheet',
                 'C5-chat-conversation', 'C6-chat-jump'],
        'queue': ['Q1-queue-capsule', 'Q1b-queue-capsule-open', 'Q6-queue-paused'],
        'message': ['M1-message-info', 'M1b-message-info-unfolded', 'M1c-message-info-short', 'M1d-message-info-stopped'],
        'mode-glyph': ['Z0-mode-glyph-compare', 'Z1-mode-glyph-soft-fill', 'Z2-mode-glyph-platter',
                       'Z3-mode-glyph-plain-bubble', 'Z4-mode-glyph-dot'],
        'new-glyph': ['N0-new-glyph-compare', 'N1-new-glyph-pill', 'N2-new-glyph-thread', 'N3-new-glyph-typing',
                      'N4-new-glyph-spark', 'N5-new-glyph-quote', 'N6-tab-list-today', 'N6b-tab-list-pill',
                      'N6c-tab-list-pill-menu', 'N7-chat-symbol-check'],
        'mode-host': ['B7-host-leading-chat', 'B7b-host-leading-terminal', 'B7c-host-leading-states'],
        'header': ['X9b-header-disc-ellipsis'],
        'chat-icon': ['Y5-chat-text-bubble'],
    },
    'ipad': {
        'ipad': ['I1-split-files', 'I2-split-review', 'I2b-split-review-empty', 'I3-split-commits', 'I3b-split-commits-empty',
                 'I4-split-chat', 'I5-host-popover', 'I7-full-width-terminal', 'I8-sidebar-hidden'],
        'ipad-half': ['I6-half-width', 'I6b-half-width-spaces'],
    },
    'landscape': {
        'onerail': ['L12-one-rail-chat', 'L12b-one-rail-chat-typing', 'L12c-one-rail-chat-draft', 'L13-one-rail-review',
                    'L14-one-rail-terminal', 'L14b-one-rail-terminal-typing', 'L14c-one-rail-terminal-keys',
                    'L15-edge-terminal', 'L15b-edge-chat'],
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
    'landscape': dict(scheme='Mockups', sdk='iphonesimulator', product='Debug-iphonesimulator/Mockups.app',
                      bundle='dev.dispatch.mockups.Mockups', match=r'^iPhone', schemes=['dark', 'light'], cols='3', scale='0.25'),
    'watch': dict(scheme='MockupsWatch', sdk='watchsimulator', product='Debug-watchsimulator/MockupsWatch.app',
                  bundle='dev.dispatch.mockups.MockupsWatch', match=r'^Apple Watch', schemes=[None], cols='6', scale='1'),
}


def platform_of(screen):
    for platform, groups in GROUPS.items():
        if any(screen in ids for ids in groups.values()):
            return platform
    if screen in mac_ids():
        return 'mac'
    sys.exit(f'unknown screen {screen}; see `shoot.py list`')


MAC_THEMES = {'dark', 'light', 'nautical'}


def mac(*args, capture=False):
    """Builds the Mac mockups (mockups/Mac, a Swift package) if a source changed, then runs them with `args`."""
    result = run('swift', 'build', '--package-path', str(ROOT / 'Mac'), '--scratch-path', str(ROOT / 'build/mac'), '--quiet',
                 check=False, capture_output=True)
    if result.returncode:
        # --quiet drops the compiler's diagnostics: build again without it to show them.
        result = run('swift', 'build', '--package-path', str(ROOT / 'Mac'), '--scratch-path', str(ROOT / 'build/mac'),
                     check=False, capture_output=True)
        output = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout + result.stderr)
        errors = [line for line in output.splitlines() if re.search(r'\.swift:\d+:\d+: error:', line)]
        sys.exit('\n'.join(dict.fromkeys(errors)) or output)
    result = run(str(ROOT / 'build/mac/debug/MacMockups'), *args, check=False, capture_output=capture)
    if result.returncode:
        sys.exit(result.returncode)
    return result.stdout


def mac_ids():
    return [line.split()[0] for line in mac('list', capture=True).splitlines() if line.strip()]


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


def rotate(platform='ipad'):
    udid = device(platform)
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
        print('mac   (mockups/Mac)')
        mac('list')
    elif cmd == 'mac':
        mac(*(rest or ['render']))
    elif cmd == 'build':
        for platform in rest or ['phone']:
            if platform == 'mac':
                mac('list', capture=True)
            else:
                build(platform)
    elif cmd == 'rotate':
        rotate(*rest[:1])
    elif cmd == 'all':
        for platform in rest or ['phone']:
            if platform == 'mac':
                mac('render'); mac('sheets')
                continue
            udid = device(platform)
            for ids in GROUPS[platform].values():
                for screen in ids:
                    for scheme in PLATFORMS[platform]['schemes']:
                        shot(screen, scheme, udid)
            sheets(platform)
    elif cmd == 'sheets':
        for platform in rest or ['phone']:
            if platform == 'mac':
                mac('sheets')
            else:
                sheets(platform)
    else:
        platform = platform_of(cmd)
        if platform == 'mac':
            themes = [t for t in rest if t in MAC_THEMES]
            mac('render', *(['--themes', ','.join(themes)] if themes else []), cmd)
            return
        for scheme in (rest or PLATFORMS[platform]['schemes']):
            shot(cmd, None if scheme in ('none', None) else scheme)


if __name__ == '__main__':
    main(sys.argv[1:])
