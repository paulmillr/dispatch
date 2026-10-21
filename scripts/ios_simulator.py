"""The iOS simulator a --simulator NAME means: run.py, test/ios.py and test/ios-release.py run on it by UDID.

A name alone is ambiguous once two simulators share it (two runtimes, or a duplicate on one runtime): xcodebuild's
-destination name= then refuses to build ("multiple devices matched the request") and simctl picks one at random."""
import json
import re
import subprocess


def simulators(document):
    """[(udid, name, runtime label, booted, runtime version)] of the available iOS simulators in
    `xcrun simctl list devices available --json`."""
    found = []
    for runtime, devices in (document.get('devices') or {}).items():
        match = re.search(r'\.iOS-(\d+)-(\d+)(?:-(\d+))?$', runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        label = f'iOS {version[0]}.{version[1]}' + (f'.{version[2]}' if version[2] else '')
        for device in devices:
            if device.get('isAvailable', True) and device.get('udid'):
                found.append((device['udid'], device.get('name', ''), label, device.get('state') == 'Booted', version))
    return found


def choose_simulator(document, wanted):
    """(udid, description) of the simulator `wanted` names (its name, any case, or its UDID): a booted one first, then
    the newest runtime; None when none matches."""
    matches = [device for device in simulators(document) if wanted.lower() in (device[0].lower(), device[1].lower())]
    if not matches:
        return None
    udid, name, label, booted, _ = min(matches, key=lambda device: (not device[3], tuple(-part for part in device[4])))
    return udid, f'{name} ({label}{", booted" if booted else ""})'


def find_simulator(wanted, run=subprocess.run):
    listing = run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], capture_output=True, text=True,
                  check=True).stdout
    simulator = choose_simulator(json.loads(listing or '{}'), wanted)
    if simulator is None:
        raise OSError(f'No available iOS simulator named {wanted}: pick one from `xcrun simctl list devices available` '
                      '(--simulator NAME or UDID, or DISPATCH_IOS_SIMULATOR)')
    return simulator
