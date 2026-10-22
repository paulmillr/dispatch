#!/usr/bin/env python3
"""Build and launch Dispatch with a compact console and a complete local log."""
import argparse
import codecs
import json
from collections import deque
from datetime import datetime
from functools import partial
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from ios_simulator import find_simulator, is_ipad
from setup_consent import environment
from watch_simulator import find_pair

ROOT = Path(__file__).resolve().parent.parent
# The iPhone app's DerivedData: its own build database, so an iPhone build never waits on (or locks) the Mac's in build/.
IOS_DERIVED_DATA = 'build/ios'


CLEAN_PATHS = (
    'build', 'com.apple.DeveloperTools', 'helper/target',
)


def clean_build():
    # Explicit generated paths only. Unlink symlinks instead of following them,
    # and reject redirected parents before deleting anything.
    targets = [ROOT / relative for relative in CLEAN_PATHS]
    for target in targets:
        if not target.parent.resolve().is_relative_to(ROOT.resolve()):
            raise RuntimeError(f'Refusing to clean through an external parent: {target}')
    print('\n  … Removing build artifacts, downloaded tools and caches', flush=True)
    for target in targets:
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.is_dir():
            shutil.rmtree(target)
        else:
            continue
        print(f'    Removed {target.relative_to(ROOT)}', flush=True)
    print('  ✓ Clean complete (removed files are not recoverable; dependencies will be prepared again)', flush=True)


class SetupOutput:
    """Preserve the approval prompt, then reuse one line for setup activity."""
    def __init__(self, terminal):
        self.terminal = terminal
        self.pending = ''
        self.printed = 0
        self.compact = False

    def render(self, line, end=''):
        if line.startswith('    … '):
            self.compact = True
        if not self.compact:
            print(line[self.printed:], end=end, flush=True)
            self.printed = len(line) if not end else 0
        elif self.terminal:
            clean = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', line).strip()
            clean = ''.join(character for character in clean if character.isprintable())
            if clean:
                width = max(1, min(96, shutil.get_terminal_size((80, 24)).columns - 5))
                if len(clean) > width:
                    clean = clean[:width - 1] + '…'
                print('\r\033[2K    ' + clean, end='', flush=True)
        elif end and line.startswith(('    … ', '    ✓ ', '    ✗ ')):
            # Redirected output cannot redraw; retain stage summaries only.
            print(line, flush=True)

    def write(self, text):
        parts = re.split(r'([\r\n])', self.pending + text)
        for index in range(0, len(parts) - 1, 2):
            self.render(parts[index], parts[index + 1])
        self.pending = parts[-1]
        if self.pending:
            self.render(self.pending)

    def finish(self):
        if self.compact and self.terminal:
            print('\r\033[2K', end='', flush=True)


class BuildUI:
    def __init__(self, log):
        self.log = log
        self.terminal = sys.stdout.isatty() and os.environ.get('TERM') != 'dumb'
        self.color = self.terminal and 'NO_COLOR' not in os.environ

    def style(self, text, code):
        return f'\033[{code}m{text}\033[0m' if self.color else text

    def line(self, marker, label, elapsed=None):
        suffix = f'  {elapsed:.1f}s' if elapsed is not None else ''
        print(f'  {marker} {label}{self.style(suffix, "2")}', flush=True)

    def step(self, label, command, env, interactive=False, capture=False, allowed=(0,), next_stage=None):
        self.log.write(f'\n--- {label} ---\n')
        self.log.flush()
        started = time.monotonic()
        animate = self.terminal and not interactive
        if animate:
            print(f'  {self.style("⠋", "36")} {label}', end='', flush=True)
        else:
            self.line(self.style('…', '36'), label)

        def advance_stage():
            nonlocal label, started, next_stage
            if next_stage is None or not next_stage[0].is_file():
                return
            if animate:
                print('\r\033[2K', end='', flush=True)
            self.line(self.style('✓', '32'), label, time.monotonic() - started)
            label = next_stage[1]
            next_stage = None
            started = time.monotonic()
            self.log.write(f'\n--- {label} ---\n')
            self.log.flush()
            if not animate:
                self.line(self.style('…', '36'), label)

        # Setup keeps stdin for confirmation. Log every byte while rendering its
        # activity on one console line, including output without trailing newlines.
        stream = interactive and not capture
        child_env = dict(env)
        if stream:
            child_env.pop('DISPATCH_SETUP_UI_FD', None)
            child_env['PYTHONUNBUFFERED'] = '1'
            child_env['DISPATCH_SETUP_TTY'] = '1' if self.terminal else '0'
        decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
        setup_output = SetupOutput(self.terminal)

        def relay_output(final=False):
            while True:
                try:
                    chunk = os.read(process.stdout.fileno(), 65536)
                except BlockingIOError:
                    break
                if not chunk:
                    break
                text = decoder.decode(chunk)
                self.log.write(text)
                setup_output.write(text)
            if final:
                text = decoder.decode(b'', final=True)
                self.log.write(text)
                setup_output.write(text)
            self.log.flush()

        process = None
        try:
            process = subprocess.Popen(
                command, cwd=ROOT, env=child_env,
                stdout=subprocess.PIPE if capture or stream else self.log,
                stderr=subprocess.STDOUT if stream else self.log,
                stdin=None if interactive else subprocess.DEVNULL,
                start_new_session=not interactive,
            )
            if stream:
                os.set_blocking(process.stdout.fileno(), False)
            if capture:
                output, _ = process.communicate()
                self.log.write(output.decode(errors='replace'))
            else:
                frames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
                frame = 0
                while process.poll() is None:
                    if stream:
                        relay_output()
                    advance_stage()
                    if animate:
                        elapsed = time.monotonic() - started
                        print(f'\r\033[2K  {self.style(frames[frame % len(frames)], "36")} '
                              f'{label}  {self.style(f"{elapsed:.1f}s", "2")}', end='', flush=True)
                        frame += 1
                    time.sleep(0.1)
                advance_stage()
                if stream:
                    relay_output(final=True)
                output = b''
        except BaseException:
            if process is not None:
                # SIGTERM, 3 s, then SIGKILL (to the child's whole session unless interactive), reaped
                # with waitpid: an interrupt inside Popen.poll or communicate can leave Popen's own wait
                # lock held, and Popen.wait would then block forever. A signal goes out only to a child
                # still running and unreaped: once reaped (here or by Popen), its PID may be another's.
                send = partial(os.kill if interactive else os.killpg, process.pid)
                try:
                    for sig, deadline in ((signal.SIGTERM, time.monotonic() + 3), (signal.SIGKILL, float('inf'))):
                        if os.waitpid(process.pid, os.WNOHANG)[0]:
                            break
                        send(sig)
                        while not os.waitpid(process.pid, os.WNOHANG)[0] and time.monotonic() < deadline:
                            time.sleep(0.01)
                except (ProcessLookupError, ChildProcessError):
                    pass   # gone, or already reaped
            raise
        finally:
            if stream:
                setup_output.finish()
            if process is not None and process.stdout is not None:
                process.stdout.close()
            if animate:
                print('\r\033[2K', end='', flush=True)
        elapsed = time.monotonic() - started
        success = process.returncode in allowed
        self.line(self.style('✓' if success else '✗', '32' if success else '31'), label, elapsed)
        if not success:
            raise subprocess.CalledProcessError(process.returncode, command)
        return output.decode().strip(), process.returncode


def launch_app(ui, app, env):
    # Never stop a running instance: it may own live shells, SSH sessions and agent conversations.
    # LaunchServices would only activate it anyway, so the new build takes effect on its next launch.
    running = subprocess.run(['pgrep', '-u', str(os.getuid()), '-x', 'Dispatch'], stdout=ui.log, stderr=ui.log)
    if running.returncode == 0:
        ui.line(ui.style('–', '33'), 'Dispatch is already running; quit and reopen it to use this build')
        return
    ui.step('Launching Dispatch', ['open', str(app)], env)


def ios_target(args, phone=None, simulator=None):
    """The iOS run destination: (xcodebuild destination, products folder). A phone (udid, name) is the destination
    itself, so automatic signing registers it with the team; without one a device build is generic. The simulator
    (udid, description) goes by UDID: its name may match several (scripts/ios_simulator.py)."""
    if args.ios_device is not None:
        return (f'platform=iOS,id={phone[0]}' if phone else 'generic/platform=iOS'), 'iphoneos'
    return f'platform=iOS Simulator,id={simulator[0]}', 'iphonesimulator'


def paired_iphones(document):
    """[(udid, name)] of the real iPhones and iPads in `devicectl list devices --json-output` (Xcode 27 lists the
    simulators there too), connected ones first. The UDID is what both xcodebuild's destination and devicectl's --device
    take."""
    phones = []
    for device in document.get('result', {}).get('devices', []):
        properties = device.get('properties') or {}
        hardware = properties.get('hardware') or device.get('hardwareProperties') or {}
        if hardware.get('reality') != 'physical' or hardware.get('platform') != 'iOS':
            continue
        if hardware.get('deviceType', 'iPhone') not in ('iPhone', 'iPad'):
            continue
        name = (properties.get('state') or {}).get('name') or (device.get('deviceProperties') or {}).get('name')
        connection = properties.get('connection') or device.get('connectionProperties') or {}
        connected = connection.get('state') == 'connected' or connection.get('tunnelState') == 'connected'
        phones.append((not connected, hardware.get('udid') or device.get('identifier'), name or 'iPhone'))
    return [(udid, name) for _, udid, name in sorted(phones, key=lambda phone: phone[0]) if udid]


def choose_iphone(phones, wanted):
    """The phone --ios-device names (its name, any case, or its UDID), else the first; None when there is none."""
    if not wanted:
        return phones[0] if phones else None
    return next((phone for phone in phones if wanted.lower() in (phone[0].lower(), phone[1].lower())), None)


def find_iphone(ui, args, env):
    listing, _ = ui.step('Finding a paired iPhone', ['xcrun', 'devicectl', 'list', 'devices', '--json-output', '-'],
                         env, capture=True)
    phone = choose_iphone(paired_iphones(json.loads(listing or '{}')), args.ios_device)
    if phone is None and not args.just_build:
        raise OSError(f'No paired iPhone or iPad{" named " + args.ios_device if args.ios_device else ""}: connect it by '
                      'cable once and trust this Mac (docs/ios.md, Signing and a device)')
    return phone


def signing_problem(path=None):
    """Why a device build cannot sign (build/signing.xcconfig, scripts/ios-signing.py), or None."""
    import importlib.util
    spec = importlib.util.spec_from_file_location('ios_signing', ROOT / 'scripts/ios-signing.py')
    signing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(signing)
    path = path or signing.CONFIG
    if not path.is_file():
        return ('no build/signing.xcconfig: write it once with python3 scripts/ios-signing.py <TEAM ID> '
                '[--suffix .yourname] (docs/ios.md, Signing and a device)')
    found = signing.problems(*signing.parse(path.read_text()))
    return 'build/signing.xcconfig: ' + '; '.join(found) if found else None


def bundle_identifier(app):
    return subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', str(app / 'Info.plist')],
                          capture_output=True, text=True, check=True).stdout.strip()


def boot_simulator(ui, env, simulator):
    # Booting a booted simulator fails harmlessly ("Unable to boot device in current state: Booted").
    udid, description = simulator
    ui.step(f'Booting {description}', ['xcrun', 'simctl', 'boot', udid], env, allowed=(0, 149))


def open_simulator_window(ui):
    # The simulator's window: Xcode 27's DeviceHub, which took over from Simulator.app (the simulator runs without
    # either).
    if not any(subprocess.run(['open', '-b', bundle], stdout=ui.log, stderr=ui.log).returncode == 0
               for bundle in ('com.apple.dt.Devices', 'com.apple.iphonesimulator')):
        ui.line(ui.style('–', '33'), 'Neither DeviceHub nor Simulator.app is installed; the app runs headless '
                                    '(xcrun simctl io booted screenshot)')


def launch_ios(ui, app, args, env, phone=None, simulator=None):
    """Install and launch the iPhone app: in the simulator (booted if needed), or on a device through devicectl."""
    bundle = bundle_identifier(app)
    if args.ios_device is None:
        udid, _ = simulator
        boot_simulator(ui, env, simulator)
        open_simulator_window(ui)
        ui.step('Installing Dispatch for iPhone', ['xcrun', 'simctl', 'install', udid, str(app)], env)
        # --demo: the simulator demo's hosts (Mobile/Demo, Debug only); a running copy restarts into it.
        demo = ['--terminate-running-process', udid, bundle, '-DispatchDemo', 'YES'] if args.demo else [udid, bundle]
        ui.step('Launching Dispatch for iPhone' + (' (demo)' if args.demo else ''), ['xcrun', 'simctl', 'launch', *demo], env)
        return
    # docs/ios.md: a paired phone with Developer Mode on, signed with build/signing.xcconfig's team.
    device, name = phone
    ui.step(f'Installing on {name}', ['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app)], env)
    ui.step(f'Launching on {name}', ['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing',
                                     '--device', device, bundle], env)


def launch_watch(ui, app, env, simulator, watch):
    """Install the iPhone app on the paired phone and its embedded watch app on the watch, then launch both (the
    phone app first: it is the watch's data source)."""
    watch_app = app / 'Watch/DispatchWatch.app'
    boot_simulator(ui, env, simulator)
    boot_simulator(ui, env, watch)
    open_simulator_window(ui)
    ui.step('Installing Dispatch for iPhone', ['xcrun', 'simctl', 'install', simulator[0], str(app)], env)
    # A simulator does not install a phone app's embedded watch app on its paired watch, as a device does.
    ui.step('Installing Dispatch for Apple Watch', ['xcrun', 'simctl', 'install', watch[0], str(watch_app)], env)
    ui.step('Launching Dispatch for iPhone', ['xcrun', 'simctl', 'launch', simulator[0], bundle_identifier(app)], env)
    ui.step('Launching Dispatch for Apple Watch', ['xcrun', 'simctl', 'launch', watch[0], bundle_identifier(watch_app)],
            env)


def main():
    rest = sys.argv[1:]
    if rest[:1] == ['--test']:
        os.chdir(ROOT)
        os.execvpe('bash', ['bash', 'test/run.sh', *rest[1:]], dict(environment(), DISPATCH_TEST_SETUP='1'))
    parser = argparse.ArgumentParser(prog='./run.sh', description=__doc__, allow_abbrev=False, epilog=
        'Full logs: build/logs/latest.log. Set DISPATCH_SETUP_OFFLINE=1 to prohibit downloads; '
        'NO_COLOR disables color. Builds Debug by default and launches it unless --just-build is set; '
        'a running Dispatch is never stopped, so the new build takes effect when it is next opened. '
        './run.sh --test [test options] prepares local test tools and runs the fast suite by default; '
        'use --test --suite full for full coverage or --test --help for selection options.')
    configurations = parser.add_mutually_exclusive_group()
    configurations.add_argument('-d', '--debug', action='store_true',
                                help='use the Debug configuration (the default; the terminal engine is still optimized)')
    configurations.add_argument('-p', '--prod', '--production', action='store_true',
                                help='use the optimized Release configuration')
    parser.add_argument('--just-build', action='store_true',
                        help='build without launching the app (Debug or Release)')
    parser.add_argument('--clean', action='store_true',
                        help='remove local build artifacts, logs, downloaded tools and caches, then rebuild')
    parser.add_argument('--ios', action='store_true',
                        help='build Dispatch for iPhone and iPad (docs/ios.md) and run it in the simulator')
    parser.add_argument('--simulator', default=os.environ.get('DISPATCH_IOS_SIMULATOR', 'iPhone Air'), metavar='NAME',
                        help='the simulator --ios runs in, an iPhone or an iPad ("iPad Pro 11-inch (M5)"), by name or '
                             'UDID; a booted one, then the newest runtime, when several share the name (default: '
                             'DISPATCH_IOS_SIMULATOR, else iPhone Air; --watch uses the watch\'s paired iPhone)')
    parser.add_argument('--watch', action='store_true',
                        help='build Dispatch for iPhone with Dispatch for Apple Watch (docs/watch.md) and run both on '
                             'a paired iPhone and watch simulator')
    parser.add_argument('--watch-simulator', default=os.environ.get('DISPATCH_WATCH_SIMULATOR',
                                                                    'Apple Watch Series 12 (46mm)'), metavar='NAME',
                        help='the watch simulator --watch runs on, by name or UDID, with the iPhone it is paired with; '
                             'without one it is paired with a "Dispatch Watch iPhone" simulator, made once '
                             '(default: Apple Watch Series 12 (46mm))')
    parser.add_argument('--demo', action='store_true',
                        help='with --ios: launch the simulator demo (three demo hosts with spaces, agents and terminals; '
                             'Debug only, nothing reaches a host)')
    parser.add_argument('--ios-device', nargs='?', const='', default=None, metavar='NAME',
                        help='build Dispatch for a device and install it there with devicectl '
                             '(default: the first paired iPhone or iPad; needs a team in build/signing.xcconfig: '
                             'scripts/ios-signing.py; add --prod for the build to keep on the phone)')
    args = parser.parse_args()
    if args.demo:
        if args.ios_device is not None or args.prod:
            parser.error('--demo runs in the simulator, in Debug (the demo is compiled out of Release)')
        args.ios = True
    if args.watch:
        if args.ios_device is not None:
            parser.error('--watch runs in the simulator; --ios-device installs on a phone')
        args.ios = True
    if args.ios_device is not None:
        args.ios = True
        problem = signing_problem()
        if problem:
            print(f'Cannot sign for a device: {problem}', file=sys.stderr)
            return 1
    configuration = ('Debug' if args.debug else 'Release' if args.prod else
                     os.environ.get('CONFIGURATION', 'Debug'))
    env = dict(environment(), CONFIGURATION=configuration,
               DISPATCH_SETUP_OFFLINE=os.environ.get('DISPATCH_SETUP_OFFLINE', '0'))
    # The production build is the one shipped: size-optimized helpers and a stripped app (dSYM beside it).
    production = configuration == 'Release'
    if production:
        env.setdefault('DISPATCH_HELPER_PROFILE', 'release')
    if sys.version_info < (3, 9):
        parser.error('Python 3.9 or newer is required; use the Python provided with current Xcode.')
    if args.clean:
        try:
            clean_build()
        except (OSError, RuntimeError) as error:
            print(f'Clean failed: {error}', file=sys.stderr)
            return 1
    directory = ROOT / 'build/logs'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f'{datetime.now():%Y%m%d-%H%M%S}-{os.getpid()}.log'
    display_path = os.path.relpath(path)
    started = time.monotonic()
    with path.open('w', buffering=1) as log:
        # Atomic replacement keeps latest.log readable, including during simultaneous runs.
        link = directory / f'.latest-{os.getpid()}'
        link.symlink_to(path.name)
        link.replace(directory / 'latest.log')
        ui = BuildUI(log)
        title = 'Dispatch for Apple Watch' if args.watch else 'Dispatch for iPhone' if args.ios else 'Dispatch'
        print(f'\n  {ui.style(title, "1")}  {ui.style(configuration, "36")}')
        hint = ('./run.sh  # to get debug build' if configuration == 'Release' else
                './run.sh --production  # to get faster release build')
        print(f'  {ui.style(hint, "2")}\n')
        print(f'  Log  {display_path}\n', flush=True)
        log.write(f'Dispatch {configuration} — {datetime.now().isoformat()}\n')
        try:
            ui.step('Preparing dependencies', ['bash', 'scripts/setup.sh'], env, interactive=True)
            ui.step('Generating Xcode project',
                    ['python3', 'scripts/generate-project.py'], env)
            if args.ios:
                # SwiftPM resolves the SSH engine's binary target before any build script: prepare it first.
                ui.step('Preparing the iPhone SSH engine', ['python3', 'scripts/setup_mobile.py'], env)
                phone = find_iphone(ui, args, env) if args.ios_device is not None else None
                watch = None
                if args.watch:
                    simulator, watch = find_pair(args.watch_simulator)
                    ui.line(ui.style('✓', '32'), f'Paired simulators: {simulator[1]} and {watch[1]}')
                else:
                    simulator = find_simulator(args.simulator) if args.ios_device is None else None
                destination, platform = ios_target(args, phone, simulator)
                command = ['xcodebuild', '-project', 'Dispatch.xcodeproj', '-scheme', 'DispatchMobile',
                           '-configuration', configuration, '-destination', destination,
                           '-derivedDataPath', IOS_DERIVED_DATA, 'build']
                if args.ios_device is not None:
                    # Automatic signing from the command line: Xcode's account makes or renews the certificate and
                    # the profile (7 days for a free Apple ID) and registers the phone with the team.
                    command[-1:-1] = ['-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration']
                if env.get('DISPATCH_BUILD_JOBS'):
                    command += ['-jobs', env['DISPATCH_BUILD_JOBS']]
                    env['CARGO_BUILD_JOBS'] = env['DISPATCH_BUILD_JOBS']
                device = 'iPad' if simulator and is_ipad(simulator[1]) else 'iPhone'
                ui.step(f'Building Dispatch for {device}', command, env)
                app = ROOT / IOS_DERIVED_DATA / 'Build/Products' / f'{configuration}-{platform}' / 'DispatchMobile.app'
                if not args.just_build and args.watch:
                    launch_watch(ui, app, env, simulator, watch)
                elif not args.just_build:
                    launch_ios(ui, app, args, env, phone, simulator)
                print(f'\n  {ui.style("Ready", "32")} in {time.monotonic() - started:.1f}s')
                print(f'  App  {os.path.relpath(app)}' + ('' if args.watch else '\n'))
                if args.watch:
                    print(f'  Watch  {os.path.relpath(app / "Watch/DispatchWatch.app")}\n')
                return 0
            with tempfile.TemporaryDirectory(prefix='.progress-', dir=directory) as progress:
                helper_complete = Path(progress) / 'helper-complete'
                command = ['xcodebuild', '-project', 'Dispatch.xcodeproj',
                        '-scheme', 'Dispatch', '-configuration', configuration,
                        '-derivedDataPath', 'build', 'build']
                # Environment, not a build setting: a per-run command-line setting changes every target's build
                # description, so each build recompiled everything from scratch.
                env['DISPATCH_HELPER_BUILD_COMPLETE'] = str(helper_complete)
                if production:
                    command.append('DISPATCH_STRIP_APP=YES')
                if env.get('DISPATCH_BUILD_JOBS'):
                    command += ['-jobs', env['DISPATCH_BUILD_JOBS']]
                    env['CARGO_BUILD_JOBS'] = env['DISPATCH_BUILD_JOBS']
                ui.step('Building SSH helper', command, env,
                        next_stage=(helper_complete, 'Building Dispatch macOS app'))
            app = ROOT / 'build/Build/Products' / configuration / 'Dispatch.app'
            if not args.just_build:
                launch_app(ui, app, env)
        except KeyboardInterrupt:
            print(f'\n  Cancelled. Full log: {display_path}', file=sys.stderr)
            return 130
        except (OSError, subprocess.CalledProcessError) as error:
            log.write(f'\n{error}\n')
            log.flush()
            print(f'\n  {ui.style("Build stopped", "31")} — last log lines:', file=sys.stderr)
            width = max(40, min(160, shutil.get_terminal_size((100, 24)).columns - 4))
            with path.open(errors='replace') as saved:
                for line in deque(saved, maxlen=12):
                    line = line.rstrip()
                    print('  ' + (line[:width - 1] + '…' if len(line) > width else line), file=sys.stderr)
            print(f'\n  Full log: {display_path}', file=sys.stderr)
            return max(1, error.returncode) if isinstance(error, subprocess.CalledProcessError) else 1
        print(f'\n  {ui.style("Ready", "32")} in {time.monotonic() - started:.1f}s')
        print(f'  App  {os.path.relpath(app)}\n')
    return 0


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())
