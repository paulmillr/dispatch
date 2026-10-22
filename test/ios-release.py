#!/usr/bin/env python3
"""Release check for Dispatch for iPhone and iPad (docs/ios.md, Release).

usage: python3 test/ios-release.py [--simulator NAME] [--helper-profile release|local] [--skip-build] [--no-launch]
                                   [--with-fast-suite]

Builds Release for the simulator and for devices (unsigned, CODE_SIGNING_ALLOWED=NO, with a link map), into
build/dd, then checks both bundles: the three helper binaries with their architectures, `version` (the hash of the
three) and `protocol-version` (HelperBinary.version); Info.plist's device keys (the prompts, background refresh, iPhone
and iPad families and orientations); the privacy manifest's form, and that every required-reason API the device
executable imports is declared there; and the same for the embedded watch app (docs/watch.md) against
Watch/App/PrivacyInfo.xcprivacy, which it needs only once it uses such an API. It launches the Release simulator build
once (it must still run after five seconds; a screenshot lands in build/release-check) and prints the size table.

The fast suite cannot run against Release: the tests import the app with @testable (Release has no testability) and
use the Debug-only demos (ChatDemo, CodeDemo, TabsSample). --with-fast-suite runs it on the same simulator in Debug
(test/ios.py) after the Release checks. Offline after setup: the helper, the SSH engine and the project generator
are local (scripts/setup_mobile.py --offline) and the Swift package has no remote dependency.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from ios_simulator import find_simulator  # noqa: E402
PRODUCTS = ROOT / 'build/dd/Build/Products'
APP = 'DispatchMobile.app'
EXECUTABLE = 'DispatchMobile'
WATCH_EXECUTABLE = 'Watch/DispatchWatch.app/DispatchWatch'
WATCH_MANIFEST = ROOT / 'Watch/App/PrivacyInfo.xcprivacy'
MAPS = ROOT / 'build/dd/maps'
OUTPUT = ROOT / 'build/release-check'
HELPERS = ('darwin-arm64', 'linux-aarch64', 'linux-x86_64')
# ELF e_machine values of the two Linux helpers.
ELF_MACHINES = {'linux-aarch64': 183, 'linux-x86_64': 62}
# Intel Macs are hosts: the Mac helper keeps both slices.
MAC_ARCHS = {'arm64'}

# Apple's required-reason APIs (developer.apple.com, "Describing use of required reason API"): per category the
# reasons that exist, and how the executable shows a use: an imported symbol or an Objective-C selector.
CATEGORIES = {
    'NSPrivacyAccessedAPICategoryFileTimestamp': dict(
        reasons={'DDA9.1', 'C617.1', '3B52.1', '0A2A.1'},
        symbols={'_stat', '_fstat', '_lstat', '_fstatat', '_getattrlist', '_getattrlistbulk', '_fgetattrlist',
                 '_getattrlistat', '_NSFileCreationDate', '_NSFileModificationDate', '_NSURLContentModificationDateKey',
                 '_NSURLCreationDateKey'},
        selectors={'creationDate', 'modificationDate', 'fileModificationDate'}),
    'NSPrivacyAccessedAPICategorySystemBootTime': dict(
        reasons={'35F9.1', '8FFB.1', '3D61.1'}, symbols={'_mach_absolute_time'}, selectors={'systemUptime'}),
    'NSPrivacyAccessedAPICategoryDiskSpace': dict(
        reasons={'85F4.1', 'E174.1', '7D9E.1', 'B728.1'},
        symbols={'_statfs', '_statvfs', '_fstatfs', '_fstatvfs', '_NSURLVolumeAvailableCapacityKey',
                 '_NSURLVolumeAvailableCapacityForImportantUsageKey',
                 '_NSURLVolumeAvailableCapacityForOpportunisticUsageKey', '_NSURLVolumeTotalCapacityKey',
                 '_NSFileSystemFreeSize', '_NSFileSystemSize'},
        selectors=set()),
    'NSPrivacyAccessedAPICategoryActiveKeyboards': dict(
        reasons={'3EC4.1', '54BD.1'}, symbols=set(), selectors={'activeInputModes'}),
    'NSPrivacyAccessedAPICategoryUserDefaults': dict(
        reasons={'CA92.1', '1C8F.1', 'C56D.1', 'AC6B.1'}, symbols={'_OBJC_CLASS_$_NSUserDefaults'}, selectors=set()),
}


# Checks (pure: test/ios-release.test.py covers them)

def helper_version(directory):
    """The helper build's `version`: SHA-256 over the three binaries' SHA-256 digests (scripts/build-ssh-helper.py)."""
    digest = b''.join(hashlib.sha256((directory / name).read_bytes()).digest() for name in HELPERS)
    return hashlib.sha256(digest).hexdigest()


def elf_machine(path):
    with path.open('rb') as file:
        header = file.read(20)
    if header[:4] != b'\x7fELF' or len(header) < 20:
        return None
    return int.from_bytes(header[18:20], 'little' if header[5] == 1 else 'big')


def helper_problems(app, protocol, mac_archs, built_version=None):
    """What is wrong with the bundled helpers: `mac_archs(path)` gives the Mac helper's slices (lipo)."""
    directory = app / 'helper'
    problems = [f'missing helper/{name}' for name in (*HELPERS, 'version', 'protocol-version')
                if not (directory / name).is_file()]
    if problems:
        return problems
    for name in HELPERS:
        if not os.access(directory / name, os.X_OK):
            problems.append(f'helper/{name} is not executable')
    archs = set(mac_archs(directory / 'darwin-arm64'))
    if archs != MAC_ARCHS:
        problems.append(f'helper/darwin-arm64 has {sorted(archs)}, not {sorted(MAC_ARCHS)}')
    for name, machine in ELF_MACHINES.items():
        found = elf_machine(directory / name)
        if found != machine:
            problems.append(f'helper/{name} is not an ELF for machine {machine} (found {found})')
    version = (directory / 'version').read_text().strip()
    if version != helper_version(directory):
        problems.append('helper/version is not the hash of the bundled binaries')
    if built_version is not None and version != built_version:
        problems.append('helper/version differs from build/helper-rust/bin/version')
    if (directory / 'protocol-version').read_text().strip() != str(protocol):
        problems.append(f'helper/protocol-version is not HelperBinary.version ({protocol})')
    return problems


def protocol_version(source):
    match = re.search(r'static let version: UInt64 = (\d+)', source)
    return int(match[1]) if match else None


def privacy_problems(manifest):
    """The manifest's form: no tracking, nothing collected, known categories with reasons that exist for them."""
    problems = []
    if manifest.get('NSPrivacyTracking') is not False:
        problems.append('NSPrivacyTracking must be false')
    if manifest.get('NSPrivacyTrackingDomains', []) != []:
        problems.append('NSPrivacyTrackingDomains must be empty')
    if manifest.get('NSPrivacyCollectedDataTypes') != []:
        problems.append('NSPrivacyCollectedDataTypes must be an empty array')
    entries = manifest.get('NSPrivacyAccessedAPITypes')
    if not isinstance(entries, list):
        return problems + ['NSPrivacyAccessedAPITypes must be an array']
    seen = set()
    for entry in entries:
        category = entry.get('NSPrivacyAccessedAPIType') if isinstance(entry, dict) else None
        if category not in CATEGORIES:
            problems.append(f'unknown required-reason category {category!r}')
            continue
        if category in seen:
            problems.append(f'{category} is declared twice')
        seen.add(category)
        reasons = entry.get('NSPrivacyAccessedAPITypeReasons')
        if not isinstance(reasons, list) or not reasons:
            problems.append(f'{category} has no reasons')
            continue
        problems += [f'{category}: {reason!r} is not one of its reasons' for reason in reasons
                     if reason not in CATEGORIES[category]['reasons']]
    unknown = set(manifest) - {'NSPrivacyTracking', 'NSPrivacyTrackingDomains', 'NSPrivacyCollectedDataTypes',
                               'NSPrivacyAccessedAPITypes'}
    problems += [f'unknown key {key}' for key in sorted(unknown)]
    return problems


def declared(manifest):
    return {entry.get('NSPrivacyAccessedAPIType') for entry in manifest.get('NSPrivacyAccessedAPITypes', [])
            if isinstance(entry, dict)}


def used_categories(symbols, selectors):
    """{category: the evidence} for the required-reason APIs among imported symbols and Objective-C selectors."""
    used = {}
    for category, apis in CATEGORIES.items():
        evidence = sorted((apis['symbols'] & set(symbols)) | (apis['selectors'] & set(selectors)))
        if evidence:
            used[category] = evidence
    return used


# The orientations each family turns to (UISupportedInterfaceOrientations and its ~ipad variant): never upside down
# on an iPhone, every way on an iPad.
IPHONE_ORIENTATIONS = {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft',
                       'UIInterfaceOrientationLandscapeRight'}
IPAD_ORIENTATIONS = IPHONE_ORIENTATIONS | {'UIInterfaceOrientationPortraitUpsideDown'}
# The prompts the app can show: Face ID for the Keychain keys, the local network, and dictation's two.
USAGE_KEYS = ('NSFaceIDUsageDescription', 'NSLocalNetworkUsageDescription', 'NSMicrophoneUsageDescription',
              'NSSpeechRecognitionUsageDescription')


def info_problems(info):
    """The Info.plist keys a device needs: the prompts' texts (which show on an iPad too, so they name no device), background
    refresh, both device families (UIDeviceFamily 1 and 2, from TARGETED_DEVICE_FAMILY), each family's orientations, and
    iPad multitasking (Split View, Slide Over and Stage Manager need UIRequiresFullScreen off)."""
    problems = []
    for key in USAGE_KEYS:
        text = str(info.get(key, '')).strip()
        if not text:
            problems.append(f'Info.plist has no {key}')
        elif 'iPhone' in text or 'iPad' in text:
            problems.append(f'{key} names a device (it shows on iPhones and iPads): {text}')
    if sorted(info.get('UIDeviceFamily', [])) != [1, 2]:
        problems.append(f'UIDeviceFamily is {info.get("UIDeviceFamily")}, not [1, 2] (iPhone and iPad)')
    for key, expected in (('UISupportedInterfaceOrientations', IPHONE_ORIENTATIONS),
                          ('UISupportedInterfaceOrientations~ipad', IPAD_ORIENTATIONS)):
        found = set(info.get(key, []))
        if found != expected:
            problems.append(f'{key} is {sorted(found)}, not {sorted(expected)}')
    if info.get('UIRequiresFullScreen') is True:
        problems.append('UIRequiresFullScreen is set: the iPad would lose Split View, Slide Over and Stage Manager')
    identifier = info.get('CFBundleIdentifier', '')
    if identifier + '.refresh' not in info.get('BGTaskSchedulerPermittedIdentifiers', []):
        problems.append(f'BGTaskSchedulerPermittedIdentifiers lacks {identifier}.refresh')
    if 'fetch' not in info.get('UIBackgroundModes', []):
        problems.append('UIBackgroundModes lacks fetch')
    return problems


def parse_link_map(text):
    """{object file path: bytes of its live symbols} from an ld link map (dead-stripped symbols are not counted)."""
    files, sizes, mode = {}, {}, None
    for line in text.splitlines():
        if line.startswith('#'):
            mode = {'# Object files:': 'objects', '# Symbols:': 'symbols', '# Sections:': None,
                    '# Dead Stripped Symbols:': None}.get(line.strip(), mode)
            continue
        if mode == 'objects':
            match = re.match(r'\[\s*(\d+)\] (.*)', line)
            if match:
                files[int(match[1])] = match[2]
        elif mode == 'symbols':
            match = re.match(r'0x[0-9A-Fa-f]+\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]', line)
            if match:
                path = files.get(int(match[2]), '?')
                sizes[path] = sizes.get(path, 0) + int(match[1], 16)
    return sizes


def code_group(path):
    if 'libdispatch_mobile_ssh.a' in path:
        return 'SSH engine (Rust russh, ring, tokio)'
    if 'MobileTransport' in path:
        return 'MobileTransport (Swift)'
    if 'TermApple' in path:
        return 'TermApple (renderer)'
    if '/Term.' in path or 'Term.framework' in path or '/Term.build/' in path:
        return 'Term (emulator)'
    if 'DispatchMobile.build' in path:
        return 'App code (Mobile/ and shared Dispatch/)'
    return 'Linker and system stubs'


def tree_size(path):
    if path.is_file():
        return path.stat().st_size
    return sum(item.stat().st_size for item in path.rglob('*') if item.is_file() and not item.is_symlink())


def size_rows(app, link_sizes=None):
    """(label, bytes, indented) rows: the bundle, its parts, and the executable's code by origin."""
    total = tree_size(app)
    helpers = [(f'helper/{name}', tree_size(app / 'helper' / name), True) for name in HELPERS]
    parts = [(f'Helpers (three binaries, uploaded to hosts)', tree_size(app / 'helper'), False), *helpers,
             (f'Executable ({EXECUTABLE})', tree_size(app / EXECUTABLE), False)]
    if link_sizes:
        groups = {}
        for path, size in link_sizes.items():
            groups[code_group(path)] = groups.get(code_group(path), 0) + size
        parts += [(label, size, True) for label, size in sorted(groups.items(), key=lambda item: -item[1])]
    parts += [('Terminal fonts (TermFonts)', tree_size(app / 'TermFonts'), False),
              ('Licences (ThirdPartyLicenses)', tree_size(app / 'ThirdPartyLicenses'), False),
              ('Apple Watch app (Watch)', tree_size(app / 'Watch'), False)]
    counted = sum(size for label, size, indented in parts if not indented)
    parts.append(('The rest (assets, themes, plists, icons)', total - counted, False))
    return [('Bundle total', total, False), *parts]


def format_rows(rows):
    return '\n'.join(f'{"  " if indented else ""}{label:<{48 if indented else 50}} {size / 1e6:8.2f} MB'
                     for label, size, indented in rows)


# Running

def run(command, log, env=None, check=True, **kwargs):
    with log.open('a') as stream:
        stream.write('\n$ ' + ' '.join(map(str, command)) + '\n')
        stream.flush()
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT, **kwargs)
    if check and result.returncode:
        raise SystemExit(f'failed ({result.returncode}): {" ".join(map(str, command))}; log: {os.path.relpath(log, ROOT)}')
    return result


def output(command):
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout


def lipo_archs(path):
    return output(['xcrun', 'lipo', '-archs', str(path)]).split()


def imported_symbols(executable):
    return {line.strip() for line in output(['xcrun', 'nm', '-u', str(executable)]).splitlines()}


def selectors(executable):
    text = output(['xcrun', 'otool', '-v', '-s', '__TEXT', '__objc_methname', str(executable)])
    return {match[1] for match in re.finditer(r'^[0-9a-f]+\s+(\S+)$', text, re.M)}


def build(destination, log, env, extra=()):
    command = ['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'DispatchMobile', '-configuration', 'Release',
               '-destination', destination, '-derivedDataPath', 'build/dd', *extra, 'build']
    started = time.monotonic()
    run(command, log, env)
    return time.monotonic() - started


def launch(app, simulator, log):
    """Install and launch the Release simulator build; it must still run five seconds later."""
    bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
    run(['xcrun', 'simctl', 'boot', simulator], log, check=False)
    run(['xcrun', 'simctl', 'bootstatus', simulator], log)
    run(['xcrun', 'simctl', 'install', simulator, str(app)], log)
    launched = subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', simulator, bundle],
                              capture_output=True, text=True)
    match = re.search(r':\s*(\d+)\s*$', launched.stdout.strip())
    if launched.returncode or not match:
        return [f'simctl launch failed: {launched.stdout.strip()} {launched.stderr.strip()}']
    pid = match[1]
    time.sleep(5)
    alive = subprocess.run(['ps', '-o', 'command=', '-p', pid], capture_output=True, text=True).stdout
    OUTPUT.mkdir(parents=True, exist_ok=True)
    run(['xcrun', 'simctl', 'io', simulator, 'screenshot', str(OUTPUT / 'launch.png')], log, check=False)
    run(['xcrun', 'simctl', 'terminate', simulator, bundle], log, check=False)
    return [] if EXECUTABLE in alive else [f'the Release app (pid {pid}) is not running five seconds after launch']


def check_bundle(app, protocol, built_version, log_name):
    problems = [f'{log_name}: {problem}' for problem in helper_problems(app, protocol, lipo_archs, built_version)]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    problems += [f'{log_name}: {problem}' for problem in info_problems(info)]
    bundled = app / 'PrivacyInfo.xcprivacy'
    if not bundled.is_file():
        problems.append(f'{log_name}: PrivacyInfo.xcprivacy is not in the bundle')
    elif bundled.read_bytes() != (ROOT / 'Mobile/App/PrivacyInfo.xcprivacy').read_bytes():
        problems.append(f'{log_name}: the bundled PrivacyInfo.xcprivacy is not Mobile/App/PrivacyInfo.xcprivacy')
    return problems


def main(arguments=None):
    parser = argparse.ArgumentParser(prog='test/ios-release.py', description=__doc__.split('\n\n')[0],
                                     epilog=__doc__.split('\n\n', 2)[2], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--simulator', default=os.environ.get('DISPATCH_IOS_SIMULATOR', 'iPhone Air'), metavar='NAME',
                        help='name or UDID; a booted one, then the newest runtime, when several share the name')
    parser.add_argument('--helper-profile', choices=('release', 'local'), default='release',
                        help="the helpers' Cargo profile (default release: fat LTO, what ./run.sh --prod ships)")
    parser.add_argument('--skip-build', action='store_true', help='check the existing Release builds in build/dd')
    parser.add_argument('--no-launch', action='store_true', help='do not launch the Release app in the simulator')
    parser.add_argument('--with-fast-suite', action='store_true', help='then run the fast suite (Debug) on the simulator')
    args = parser.parse_args(arguments)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    log = OUTPUT / f'release-check-{time.strftime("%Y%m%d-%H%M%S")}.log'
    log.write_text('')
    env = dict(os.environ, DISPATCH_HELPER_PROFILE=args.helper_profile, DISPATCH_SETUP_OFFLINE='1')
    print(f'Log: {os.path.relpath(log, ROOT)}', flush=True)
    problems = []
    manifest_path = ROOT / 'Mobile/App/PrivacyInfo.xcprivacy'
    lint = subprocess.run(['plutil', '-lint', str(manifest_path)], capture_output=True, text=True)
    if lint.returncode:
        problems.append('privacy manifest: ' + lint.stdout.strip())
        manifest = {}
    else:
        manifest = plistlib.loads(manifest_path.read_bytes())
        problems += ['privacy manifest: ' + problem for problem in privacy_problems(manifest)]
    simulator_app = PRODUCTS / 'Release-iphonesimulator' / APP
    device_app = PRODUCTS / 'Release-iphoneos' / APP

    def simulator():
        # By UDID, looked up only when a step needs it (--skip-build --no-launch needs none).
        return find_simulator(args.simulator)[0]

    if not args.skip_build:
        run([sys.executable, 'scripts/setup_mobile.py', '--offline'], log, env)
        run([sys.executable, 'scripts/generate-project.py'], log, env)
        seconds = build(f'platform=iOS Simulator,id={simulator()}', log, env)
        print(f'Built Release for the simulator in {seconds:.0f}s', flush=True)
        seconds = build('generic/platform=iOS', log, env, [
            'CODE_SIGNING_ALLOWED=NO', 'LD_GENERATE_MAP_FILE=YES',
            # Absolute: every target links with this setting, and a package target's SRCROOT is its package.
            f'LD_MAP_FILE_PATH={MAPS}/$(TARGET_NAME)-$(CURRENT_VARIANT)-$(CURRENT_ARCH).txt'])
        print(f'Built Release for devices (unsigned) in {seconds:.0f}s', flush=True)
    protocol = protocol_version((ROOT / 'Dispatch/Helper/HelperBinary.swift').read_text())
    version_file = ROOT / 'build/helper-rust/bin/version'
    built_version = version_file.read_text().strip() if version_file.is_file() else None
    for app, name in ((simulator_app, 'simulator'), (device_app, 'device')):
        if not app.is_dir():
            problems.append(f'{name}: no Release build at {os.path.relpath(app, ROOT)}')
            continue
        problems += check_bundle(app, protocol, built_version, name)
    executable = device_app / EXECUTABLE
    if executable.is_file():
        used = used_categories(imported_symbols(executable), selectors(executable))
        for category, evidence in sorted(used.items()):
            state = 'declared' if category in declared(manifest) else 'NOT DECLARED'
            print(f'Required-reason API: {category.removeprefix("NSPrivacyAccessedAPICategory")} ({", ".join(evidence)}): {state}')
            if category not in declared(manifest):
                problems.append(f'privacy manifest: {category} is used ({", ".join(evidence)}) but not declared')
        unused = declared(manifest) - set(used)
        for category in sorted(unused):
            print(f'note: {category} is declared but the executable imports none of its APIs')
        if 'LC_CODE_SIGNATURE' in output(['xcrun', 'otool', '-l', str(executable)]):
            print('note: the device build is signed; sizes include the signature')
        symbols = subprocess.run(['xcrun', 'nm', str(executable)], capture_output=True, text=True).stdout.count('\n')
        print(f'Device executable: {symbols} symbols left (a stripped Release keeps only what dyld needs)')
    watch = device_app / WATCH_EXECUTABLE
    if device_app.is_dir() and not watch.is_file():
        problems.append(f'device: no embedded watch app ({WATCH_EXECUTABLE})')
    elif watch.is_file():
        watch_manifest = plistlib.loads(WATCH_MANIFEST.read_bytes()) if WATCH_MANIFEST.is_file() else {}
        if WATCH_MANIFEST.is_file():
            problems += ['watch privacy manifest: ' + problem for problem in privacy_problems(watch_manifest)]
            if not (watch.parent / 'PrivacyInfo.xcprivacy').is_file():
                problems.append('device: the watch app has no PrivacyInfo.xcprivacy')
        used = used_categories(imported_symbols(watch), selectors(watch))
        print('Watch app required-reason APIs: ' + (', '.join(sorted(used)) or 'none'))
        problems += [f'watch privacy manifest: {category} is used ({", ".join(evidence)}) but not declared in '
                     f'{os.path.relpath(WATCH_MANIFEST, ROOT)}'
                     for category, evidence in sorted(used.items()) if category not in declared(watch_manifest)]
    if not args.no_launch and simulator_app.is_dir():
        problems += launch(simulator_app, simulator(), log)
        print(f'Launched the Release simulator build: screenshot {os.path.relpath(OUTPUT / "launch.png", ROOT)}')
    if device_app.is_dir():
        maps = sorted(MAPS.glob('DispatchMobile-normal-arm64.txt'))
        link_sizes = parse_link_map(maps[0].read_text(errors='replace')) if maps else None
        print('\nRelease device build (' + args.helper_profile + ' helpers), dSYM not included:')
        print(format_rows(size_rows(device_app, link_sizes)))
        if link_sizes:
            print('  (code rows: live symbols in the link map after dead-stripping; the executable adds headers, '
                  'tables and padding)')
    if args.with_fast_suite:
        status = subprocess.run([sys.executable, 'test/ios.py', '--simulator', simulator()], cwd=ROOT).returncode
        if status:
            problems.append(f'the fast suite failed ({status})')
    for problem in problems:
        print('FAILED ' + problem)
    print('Release check: ' + ('passed' if not problems else f'{len(problems)} problem(s)'))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
