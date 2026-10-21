"""The iOS simulator a --simulator NAME means: run.py, test/ios.py and test/ios-release.py run on it by UDID. Watch
simulators (platform watchOS) are found the same way (scripts/watch_simulator.py, test/ios.py --platform watch).

A name alone is ambiguous once two simulators share it (two runtimes, or a duplicate on one runtime): xcodebuild's
-destination name= then refuses to build ("multiple devices matched the request") and simctl picks one at random.
iPhones and iPads are chosen alike; the description names the family (from the device type) when the simulator's own
name does not, so a run on "dispatch-ipad" says it is an iPad."""
import json
import re
import subprocess


# The variable that names each platform's simulator, for the error message.
VARIABLES = {'iOS': 'DISPATCH_IOS_SIMULATOR', 'watchOS': 'DISPATCH_WATCH_SIMULATOR'}


def family(device_type):
    """'iPad', 'iPhone' or '' from a simctl deviceTypeIdentifier (com.apple.CoreSimulator.SimDeviceType.iPad-Pro-…)."""
    name = (device_type or '').rsplit('.', 1)[-1]
    return next((kind for kind in ('iPad', 'iPhone') if name.startswith(kind)), '')


def simulators(document, platform='iOS'):
    """[(udid, name, runtime label, booted, runtime version, family)] of the available simulators of `platform` (iOS
    or watchOS) in `xcrun simctl list devices available --json`."""
    found = []
    for runtime, devices in (document.get('devices') or {}).items():
        match = re.search(r'\.' + platform + r'-(\d+)-(\d+)(?:-(\d+))?$', runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        label = f'{platform} {version[0]}.{version[1]}' + (f'.{version[2]}' if version[2] else '')
        for device in devices:
            if device.get('isAvailable', True) and device.get('udid'):
                found.append((device['udid'], device.get('name', ''), label, device.get('state') == 'Booted', version,
                              family(device.get('deviceTypeIdentifier'))))
    return found


def choose_simulator(document, wanted, platform='iOS'):
    """(udid, description) of the simulator `wanted` names (its name, any case, or its UDID): a booted one first, then
    the newest runtime; None when none matches."""
    matches = [device for device in simulators(document, platform)
               if wanted.lower() in (device[0].lower(), device[1].lower())]
    if not matches:
        return None
    udid, name, label, booted, _, kind = min(matches, key=lambda device: (not device[3], tuple(-part for part in device[4])))
    named = kind and not name.lower().startswith(kind.lower())
    return udid, f'{name} ({kind + ", " if named else ""}{label}{", booted" if booted else ""})'


def is_ipad(description):
    """Whether a `choose_simulator` description is an iPad's."""
    return description.lower().startswith('ipad') or '(ipad, ' in description.lower()


def find_simulator(wanted, run=subprocess.run, platform='iOS'):
    listing = run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], capture_output=True, text=True,
                  check=True).stdout
    simulator = choose_simulator(json.loads(listing or '{}'), wanted, platform)
    if simulator is None:
        raise OSError(f'No available {platform} simulator named {wanted}: pick one from `xcrun simctl list devices '
                      f'available` (--simulator NAME or UDID, or {VARIABLES[platform]})')
    return simulator
