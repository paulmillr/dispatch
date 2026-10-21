"""The paired iPhone and Apple Watch simulators `./run.sh --watch` runs on (docs/watch.md, Building and running).

The watch is found by name or UDID as scripts/ios_simulator.py finds an iPhone. Its phone is the one it is paired
with; a watch without a pair is paired with a simulator of our own, "Dispatch Watch iPhone" (an iPhone 18 Pro, made
once), never with an existing phone that another run may be using. A phone can hold several watches but shows one:
the pair is made active. simctl pairs only a phone and a watch of compatible runtimes, and a runtime may support few
device types (Xcode 27's iOS 27.1 is the iPhone Duo's alone), so the phone is made on the newest iOS runtime that
supports its device type."""
import json
import re
import subprocess
from ios_simulator import choose_simulator, simulators

PHONE_NAME = 'Dispatch Watch iPhone'
PHONE_TYPE = 'iPhone 18 Pro'


def pair_of(pairs, watch):
    """(pair id, phone udid, active) of the pair `watch` (a UDID) is in, from `simctl list pairs --json`; None."""
    for identifier, pair in (pairs.get('pairs') or {}).items():
        if (pair.get('watch') or {}).get('udid') == watch:
            # "(active, connected)", "(inactive, disconnected)", …
            active = pair.get('state', '').lstrip('(').startswith('active')
            return identifier, (pair.get('phone') or {}).get('udid'), active
    return None


def phone_runtime(runtimes, device_type=PHONE_TYPE):
    """(device type identifier, runtime identifier): the newest available iOS runtime that supports `device_type`
    (by name), from `simctl list runtimes --json`; None when none does."""
    found = []
    for runtime in runtimes.get('runtimes') or []:
        if runtime.get('platform', 'iOS') != 'iOS' or not runtime.get('isAvailable', True):
            continue
        for kind in runtime.get('supportedDeviceTypes') or []:
            if kind.get('name') == device_type:
                version = tuple(int(part) for part in re.findall(r'\d+', runtime.get('version', '')))
                found.append((version, kind['identifier'], runtime['identifier']))
    return max(found)[1:] if found else None


def describe(devices, udid):
    """(udid, description) of the iPhone simulator `udid`, as choose_simulator describes one."""
    return choose_simulator(devices, udid) or (udid, udid)


def find_pair(wanted, run=subprocess.run):
    """((phone udid, description), (watch udid, description)): the watch `wanted` names and its paired phone, pairing
    it with our own phone (made when missing) when it has none, and making the pair active."""
    def simctl(*arguments, output=True):
        result = run(['xcrun', 'simctl', *arguments], capture_output=True, text=True, check=True)
        return result.stdout.strip() if output else None

    devices = json.loads(simctl('list', 'devices', 'available', '--json') or '{}')
    watch = choose_simulator(devices, wanted, 'watchOS')
    if watch is None:
        raise OSError(f'No available watchOS simulator named {wanted}: pick one from `xcrun simctl list devices '
                      'available` (--watch-simulator NAME or UDID, or DISPATCH_WATCH_SIMULATOR)')
    pairs = lambda: json.loads(simctl('list', 'pairs', '--json') or '{}')
    paired = pair_of(pairs(), watch[0])
    if paired is None:
        ours = [device for device in simulators(devices) if device[1] == PHONE_NAME]
        if ours:
            phone = max(ours, key=lambda device: device[4])[0]
        else:
            chosen = phone_runtime(json.loads(simctl('list', 'runtimes', '--json') or '{}'))
            if chosen is None:
                raise OSError(f'No iOS simulator runtime supports {PHONE_TYPE}: install one in Xcode, Settings, '
                              'Components')
            phone = simctl('create', PHONE_NAME, *chosen)
            devices = json.loads(simctl('list', 'devices', 'available', '--json') or '{}')
        simctl('pair', watch[0], phone, output=False)
        paired = pair_of(pairs(), watch[0])
    identifier, phone, active = paired
    # simctl refuses to activate an active pair ("This pair is already active", 37).
    if not active:
        simctl('pair_activate', identifier, output=False)
    return describe(devices, phone), watch
