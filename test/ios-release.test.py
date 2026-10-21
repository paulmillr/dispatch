#!/usr/bin/env python3
"""Unit tests of the iPhone release tooling: scripts/ios-signing.py, the release check (test/ios-release.py) and the
device and simulator discovery of scripts/run.py. No Xcode, network or device; test/ios.py runs them in the iPhone suites
(test/suites.json: DispatchMobileScripts/<Class>/<test>)."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load('ios_signing', 'scripts/ios-signing.py')
release = load('ios_release', 'test/ios-release.py')
sys.path.insert(0, str(ROOT / 'scripts'))
runner = load('run_script', 'scripts/run.py')
simulators = load('ios_simulator', 'scripts/ios_simulator.py')
setup_mobile = load('setup_mobile', 'scripts/setup_mobile.py')


class SigningConfigTests(unittest.TestCase):
    def test_writes_a_config_the_check_accepts_and_reports_what_it_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'build/signing.xcconfig'
            self.assertIsNone(signing.write('ABCDE12345', '.paul', path))
            settings, other = signing.parse(path.read_text())
            self.assertEqual(settings, {'DEVELOPMENT_TEAM': 'ABCDE12345', 'DISPATCH_BUNDLE_ID_SUFFIX': '.paul'})
            self.assertEqual(signing.problems(settings, other), [])
            self.assertEqual(signing.bundle_id(settings), 'yachts.dispatch.mobile.paul')
            previous = signing.write('ZYXWV98765', '', path)
            self.assertEqual(previous['DEVELOPMENT_TEAM'], 'ABCDE12345')
            self.assertEqual(signing.parse(path.read_text())[0], {'DEVELOPMENT_TEAM': 'ZYXWV98765'})
            self.assertEqual(list(Path(directory, 'build').iterdir()), [path])

    def test_refuses_what_cannot_sign(self):
        for team, suffix in (('abcde12345', ''), ('ABCDE1234', ''), ('', ''), ('ABCDE12345', 'paul'),
                             ('ABCDE12345', '.pa ul'), ('ABCDE12345', '.'), ('ABCDE12345', '.a..b')):
            with self.subTest(team=team, suffix=suffix), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    signing.write(team, suffix, Path(directory) / 'signing.xcconfig')

    def test_parses_comments_conditions_and_includes_and_flags_other_lines(self):
        text = ('// a comment\n#include? "other.xcconfig"\nDEVELOPMENT_TEAM = ABCDE12345 // trailing\n'
                'CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Development\nnot a setting\n')
        settings, other = signing.parse(text)
        self.assertEqual(settings['DEVELOPMENT_TEAM'], 'ABCDE12345')
        self.assertEqual(settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'], 'Apple Development')
        self.assertEqual(other, ['not a setting'])
        self.assertEqual(signing.problems(settings, other), ['not an xcconfig setting: not a setting'])
        self.assertIn('DEVELOPMENT_TEAM is missing', signing.problems({})[0])

    def test_check_fails_without_a_config_and_passes_with_one(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'signing.xcconfig'
            signing.known_teams, original = (lambda: {}), signing.known_teams
            try:
                with contextlib.redirect_stdout(io.StringIO()) as printed:
                    self.assertEqual(signing.check(path), 1)
                    path.write_text('DEVELOPMENT_TEAM = nope\n')
                    self.assertEqual(signing.check(path), 1)
                    signing.write('ABCDE12345', '', path)
                    self.assertEqual(signing.check(path), 0)
                self.assertIn('Team ABCDE12345, bundle id yachts.dispatch.mobile', printed.getvalue())
            finally:
                signing.known_teams = original

    def test_the_tracked_xcconfig_includes_the_written_one_and_names_the_suffix(self):
        tracked = (ROOT / 'Mobile/Config/Signing.xcconfig').read_text()
        self.assertIn('#include? "../../build/signing.xcconfig"', tracked)
        self.assertEqual(signing.parse(tracked)[0], {'DISPATCH_BUNDLE_ID_SUFFIX': ''})
        project = (ROOT / 'project.yml').read_text()
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: yachts.dispatch.mobile$(DISPATCH_BUNDLE_ID_SUFFIX)', project)


class SigningTeamTests(unittest.TestCase):
    def test_reads_both_layouts_of_xcodes_teams(self):
        plist = {'IDEProvisioningTeams': {'me@example.com': [
                     {'teamID': 'ABCDE12345', 'teamName': 'Paul (Personal Team)', 'isFreeProvisioningTeam': True}]},
                 'IDEProvisioningTeamByIdentifier': {'x': [{'teamID': 'ZYXWV98765', 'teamName': 'Company'},
                                                           {'teamID': 'bad'}]}}
        self.assertEqual(signing.xcode_teams(plist), {'ABCDE12345': 'Paul (Personal Team) (free: 7-day profiles)',
                                                      'ZYXWV98765': 'Company'})
        self.assertEqual(signing.xcode_teams({}), {})

    def test_a_certificates_team_is_its_organisational_unit_not_the_name(self):
        pem = '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n'

        def run(command, **kwargs):
            if command[0] == 'security':
                return subprocess.CompletedProcess(command, 0, pem * 2, '')
            subject = 'subject=UID=XYZ,CN=Apple Development: Paul (PERSON1234),OU=ABCDE12345,O=Paul,C=US\n'
            return subprocess.CompletedProcess(command, 0, subject, '')

        self.assertEqual(signing.certificate_teams(run), {'ABCDE12345': 'Apple Development: Paul (PERSON1234)'})


class DeviceDiscoveryTests(unittest.TestCase):
    def device(self, name, reality, connected=True, platform='iOS', kind='iPhone', udid=None):
        return {'identifier': 'core-' + name, 'properties': {
            'hardware': {'reality': reality, 'platform': platform, 'deviceType': kind, 'udid': udid or 'udid-' + name},
            'state': {'name': name}, 'connection': {'state': 'connected' if connected else 'disconnected'}}}

    def test_lists_real_iphones_only_connected_first(self):
        document = {'result': {'devices': [
            self.device('dispatch-release', 'simulated'), self.device('Old phone', 'physical', connected=False),
            self.device("Paul's iPhone", 'physical'), self.device('Mac', 'physical', platform='macOS', kind='Mac'),
            self.device('iPad', 'physical', kind='iPad')]}}
        self.assertEqual(runner.paired_iphones(document),
                         [("udid-Paul's iPhone", "Paul's iPhone"), ('udid-Old phone', 'Old phone')])
        self.assertEqual(runner.paired_iphones({}), [])

    def test_this_xcodes_simulator_listing_has_no_phone(self):
        # The shape devicectl 642 prints for a simulator (Xcode 27): listed, but never a device to install on.
        simulator = {'identifier': '24B1', 'hardwareProperties': {'reality': 'simulated', 'platform': 'iOS'},
                     'properties': {'hardware': {'reality': 'simulated', 'platform': 'iOS', 'deviceType': 'iPhone',
                                                 'udid': '24B1'}, 'state': {'name': 'iPhone 17'}}}
        self.assertEqual(runner.paired_iphones({'result': {'devices': [simulator]}}), [])

    def test_chooses_by_name_or_udid_else_the_first(self):
        phones = [('udid-a', "Paul's iPhone"), ('udid-b', 'Work')]
        self.assertEqual(runner.choose_iphone(phones, ''), phones[0])
        self.assertEqual(runner.choose_iphone(phones, 'work'), phones[1])
        self.assertEqual(runner.choose_iphone(phones, 'UDID-B'), phones[1])
        self.assertIsNone(runner.choose_iphone(phones, 'other'))
        self.assertIsNone(runner.choose_iphone([], ''))

    def test_a_phone_is_the_destination_so_signing_can_register_it(self):
        args = type('Args', (), {'ios_device': '', 'simulator': 'iPhone Air'})()
        self.assertEqual(runner.ios_target(args, ('udid-a', 'Paul')), ('platform=iOS,id=udid-a', 'iphoneos'))
        self.assertEqual(runner.ios_target(args), ('generic/platform=iOS', 'iphoneos'))
        args.ios_device = None
        self.assertEqual(runner.ios_target(args, simulator=('SIM-A', 'iPhone Air (iOS 27.0)')),
                         ('platform=iOS Simulator,id=SIM-A', 'iphonesimulator'))

    def test_a_shared_simulator_name_picks_the_booted_one_then_the_newest_runtime(self):
        def device(udid, name='iPhone Air', state='Shutdown', available=True):
            return {'udid': udid, 'name': name, 'state': state, 'isAvailable': available}
        prefix = 'com.apple.CoreSimulator.SimRuntime.'
        # Two of one name on one runtime: what xcodebuild's name= destination refuses.
        document = {'devices': {prefix + 'iOS-27-0': [device('SIM-A'), device('SIM-B', state='Booted')]}}
        self.assertEqual(simulators.choose_simulator(document, 'iPhone Air'), ('SIM-B', 'iPhone Air (iOS 27.0, booted)'))
        document = {'devices': {
            prefix + 'iOS-26-2': [device('SIM-OLD')], prefix + 'iOS-27-0-1': [device('SIM-NEW')],
            prefix + 'iOS-27-0': [device('SIM-MID'), device('SIM-GONE', available=False)],
            prefix + 'watchOS-26-0': [device('SIM-WATCH', name='iPhone Air', state='Booted')],
            prefix + 'xrOS-26-0': [device('SIM-VISION', name='Apple Vision Pro')]}}
        self.assertEqual(simulators.choose_simulator(document, 'iphone air'), ('SIM-NEW', 'iPhone Air (iOS 27.0.1)'))
        self.assertEqual(simulators.choose_simulator(document, 'sim-old'), ('SIM-OLD', 'iPhone Air (iOS 26.2)'))
        self.assertIsNone(simulators.choose_simulator(document, 'SIM-GONE'))
        self.assertIsNone(simulators.choose_simulator(document, 'Apple Vision Pro'))
        self.assertIsNone(simulators.choose_simulator({}, 'iPhone Air'))

    def test_an_unknown_simulator_stops_before_the_build(self):
        def run(command, **kwargs):
            self.assertEqual(command, ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'])
            return subprocess.CompletedProcess(command, 0, stdout='{"devices": {}}')
        with self.assertRaisesRegex(OSError, 'No available iOS simulator named iPhone 99'):
            simulators.find_simulator('iPhone 99', run)

    def test_a_device_build_stops_early_without_a_valid_config(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'signing.xcconfig'
            self.assertIn('scripts/ios-signing.py', runner.signing_problem(path))
            path.write_text('DEVELOPMENT_TEAM = x\n')
            self.assertIn('not a team id', runner.signing_problem(path))
            signing.write('ABCDE12345', '', path)
            self.assertIsNone(runner.signing_problem(path))


class EngineFrameworkTests(unittest.TestCase):
    def test_a_changed_header_makes_the_built_engine_stale(self):
        # The package compiles against the XCFramework before the app's pre-build script runs: a pull that adds to
        # the C header must rebuild it during setup, or Swift cannot find the new names.
        with tempfile.TemporaryDirectory() as directory:
            headers, framework = Path(directory) / 'include', Path(directory) / 'Engine.xcframework'
            headers.mkdir()
            (headers / 'engine.h').write_text('#define DMS_REFUSED (-10)\n')
            (headers / 'module.modulemap').write_text('module Engine {}\n')
            self.assertFalse(setup_mobile.current(framework, headers))
            for platform in ('ios-arm64', 'ios-arm64-simulator'):
                (framework / platform).mkdir(parents=True)
                shutil.copytree(headers, framework / platform / 'Headers')
            self.assertTrue(setup_mobile.current(framework, headers))
            (headers / 'engine.h').write_text('#define DMS_REFUSED (-10)\n#define DMS_HOST_NOT_FOUND (-11)\n')
            self.assertFalse(setup_mobile.current(framework, headers))
            shutil.copy(headers / 'engine.h', framework / 'ios-arm64/Headers')
            self.assertFalse(setup_mobile.current(framework, headers))
            shutil.copy(headers / 'engine.h', framework / 'ios-arm64-simulator/Headers')
            self.assertTrue(setup_mobile.current(framework, headers))
            (framework / 'ios-arm64/Headers/module.modulemap').unlink()
            self.assertFalse(setup_mobile.current(framework, headers))


def elf(machine):
    return b'\x7fELF\x02\x01\x01' + bytes(11) + machine.to_bytes(2, 'little') + bytes(40)


class ReleaseBundleTests(unittest.TestCase):
    def bundle(self, directory, protocol=42):
        helper = Path(directory) / 'DispatchMobile.app/helper'
        helper.mkdir(parents=True)
        (helper / 'darwin-universal').write_bytes(b'\xca\xfe\xba\xbe mac')
        (helper / 'linux-aarch64').write_bytes(elf(183))
        (helper / 'linux-x86_64').write_bytes(elf(62))
        for name in release.HELPERS:
            (helper / name).chmod(0o755)
        digest = b''.join(hashlib.sha256((helper / name).read_bytes()).digest() for name in release.HELPERS)
        (helper / 'version').write_text(hashlib.sha256(digest).hexdigest() + '\n')
        (helper / 'protocol-version').write_text(f'{protocol}\n')
        return helper.parent

    def test_a_complete_bundle_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            version = (app / 'helper/version').read_text().strip()
            self.assertEqual(release.helper_problems(app, 42, lambda _: ['x86_64', 'arm64'], version), [])

    def test_names_every_helper_fault(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            (app / 'helper/linux-x86_64').write_bytes(elf(183))
            problems = release.helper_problems(app, 7, lambda _: ['arm64'], 'other')
            self.assertTrue(any('darwin-universal has' in problem for problem in problems), problems)
            self.assertTrue(any('linux-x86_64 is not an ELF for machine 62' in problem for problem in problems))
            self.assertTrue(any('not the hash of the bundled binaries' in problem for problem in problems))
            self.assertTrue(any('differs from build/helper-rust' in problem for problem in problems))
            self.assertTrue(any('protocol-version' in problem for problem in problems))
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            (app / 'helper/linux-aarch64').unlink()
            self.assertEqual(release.helper_problems(app, 42, lambda _: []), ['missing helper/linux-aarch64'])

    def test_reads_the_protocol_version_from_the_swift_source(self):
        self.assertEqual(release.protocol_version('    public static let version: UInt64 = 1347\n'), 1347)
        source = (ROOT / 'Dispatch/Helper/HelperBinary.swift').read_text()
        self.assertIsNotNone(release.protocol_version(source))

    def test_info_plist_needs_face_id_local_network_and_refresh(self):
        info = {'CFBundleIdentifier': 'yachts.dispatch.mobile', 'NSFaceIDUsageDescription': 'Keys',
                'NSLocalNetworkUsageDescription': 'Hosts', 'UIBackgroundModes': ['fetch'],
                'BGTaskSchedulerPermittedIdentifiers': ['yachts.dispatch.mobile.refresh']}
        self.assertEqual(release.info_problems(info), [])
        self.assertEqual(len(release.info_problems({'CFBundleIdentifier': 'x'})), 4)
        source = plistlib.loads((ROOT / 'Mobile/App/Info.plist').read_bytes())
        source['CFBundleIdentifier'] = 'yachts.dispatch.mobile'
        source['BGTaskSchedulerPermittedIdentifiers'] = ['yachts.dispatch.mobile.refresh']
        self.assertEqual(release.info_problems(source), [])


class PrivacyManifestTests(unittest.TestCase):
    def test_the_apps_manifest_is_well_formed(self):
        manifest = plistlib.loads((ROOT / 'Mobile/App/PrivacyInfo.xcprivacy').read_bytes())
        self.assertEqual(release.privacy_problems(manifest), [])
        self.assertIs(manifest['NSPrivacyTracking'], False)
        self.assertEqual(manifest['NSPrivacyCollectedDataTypes'], [])
        self.assertEqual(release.declared(manifest), {'NSPrivacyAccessedAPICategoryUserDefaults',
                                                      'NSPrivacyAccessedAPICategoryFileTimestamp'})

    def test_flags_tracking_collection_and_wrong_reasons(self):
        manifest = {'NSPrivacyTracking': True, 'NSPrivacyTrackingDomains': ['x.com'],
                    'NSPrivacyCollectedDataTypes': [{}], 'Extra': 1, 'NSPrivacyAccessedAPITypes': [
                        {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults',
                         'NSPrivacyAccessedAPITypeReasons': ['C617.1']},
                        {'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryDiskSpace',
                         'NSPrivacyAccessedAPITypeReasons': []},
                        {'NSPrivacyAccessedAPIType': 'Unknown'}]}
        problems = release.privacy_problems(manifest)
        self.assertEqual(len(problems), 7, problems)

    def test_maps_imports_and_selectors_to_categories(self):
        used = release.used_categories({'_stat', '_fstat', '_OBJC_CLASS_$_NSUserDefaults', '_malloc'},
                                       {'setEarliestBeginDate:', 'systemUptime'})
        self.assertEqual(used, {'NSPrivacyAccessedAPICategoryFileTimestamp': ['_fstat', '_stat'],
                                'NSPrivacyAccessedAPICategoryUserDefaults': ['_OBJC_CLASS_$_NSUserDefaults'],
                                'NSPrivacyAccessedAPICategorySystemBootTime': ['systemUptime']})
        self.assertEqual(release.used_categories({'_statfs'}, {'activeInputModes'}).keys(),
                         {'NSPrivacyAccessedAPICategoryDiskSpace', 'NSPrivacyAccessedAPICategoryActiveKeyboards'})


class SizeTableTests(unittest.TestCase):
    MAP = '''# Path: /x/DispatchMobile.app/DispatchMobile
# Arch: arm64
# Object files:
[  0] linker synthesized
[  1] /b/DispatchMobile.build/Objects-normal/arm64/MobileRoot.o
[  2] /b/Release-iphoneos/libdispatch_mobile_ssh.a(dispatch_mobile_ssh-1.cgu.0.rcgu.o)
[  3] /b/Release-iphoneos/Term.framework/Term(Surface.o)
# Sections:
# Address\tSize    \tSegment\tSection
0x100000000\t0x00001000\t__TEXT\t__text
# Symbols:
# Address\tSize    \tFile  Name
0x100000000\t0x00000100\t[  1] _main
0x100000100\t0x00000200\t[  2] _ssh_connect
0x100000300\t0x00000010\t[  2] _ssh_close
0x100000310\t0x00000040\t[  3] _surface
0x100000350\t0x00000008\t[  0] __mh_execute_header
# Dead Stripped Symbols:
#        \tSize    \tFile  Name
<<dead>> \t0x00009000\t[  2] _unused
'''

    def test_counts_live_symbols_per_object_and_leaves_dead_ones_out(self):
        sizes = release.parse_link_map(self.MAP)
        self.assertEqual(sizes['/b/Release-iphoneos/libdispatch_mobile_ssh.a(dispatch_mobile_ssh-1.cgu.0.rcgu.o)'], 0x210)
        self.assertEqual(sum(sizes.values()), 0x100 + 0x210 + 0x40 + 0x8)
        self.assertEqual({release.code_group(path) for path in sizes},
                         {'App code (Mobile/ and shared Dispatch/)', 'SSH engine (Rust russh, ring, tokio)',
                          'Term (emulator)', 'Linker and system stubs'})

    def test_rows_add_up_to_the_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = ReleaseBundleTests.bundle(None, directory)
            (app / 'DispatchMobile').write_bytes(bytes(1000))
            (app / 'TermFonts').mkdir()
            (app / 'TermFonts/a.ttf').write_bytes(bytes(300))
            (app / 'ThirdPartyLicenses').mkdir()
            (app / 'Info.plist').write_bytes(bytes(5))
            rows = release.size_rows(app, release.parse_link_map(self.MAP))
            total = rows[0][1]
            self.assertEqual(total, sum(size for label, size, indented in rows[1:] if not indented))
            self.assertEqual(dict((label, size) for label, size, _ in rows)['The rest (assets, themes, plists, icons)'], 5)
            self.assertIn('SSH engine', release.format_rows(rows))


if __name__ == '__main__':
    unittest.main()
