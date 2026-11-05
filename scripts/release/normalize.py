#!/usr/bin/env python3
"""Removes what a release build takes from the machine that made it (docs/releasing.md, Two builders):

    python3 -I scripts/release/normalize.py APP

Xcode writes the build machine's macOS build, BuildMachineOSBuild, into every Info.plist it makes, and the ad hoc
signature seals each Info.plist: GitHub's runner and the signing machine, on different macOS builds, would make apps
that differ in those plists, the main executables' signatures and CodeResources, and in nothing else. This removes the
key from every Info.plist in APP (from an XML plist as text, keeping every other byte as Xcode wrote it), then signs
again, ad hoc, every signed bundle holding one of those plists, deepest first, keeping each one's identifier,
entitlements, requirements and flags. The release's own signature (scripts/release/notarize.sh) replaces these
anyway. Prints what it changed.
"""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

KEY = 'BuildMachineOSBuild'
XML_ENTRY = re.compile(rb'\n[ \t]*<key>' + KEY.encode() + rb'</key>\n[ \t]*<string>[^<]*</string>')


def strip(plist: Path) -> bool:
    data = plist.read_bytes()
    if KEY not in plistlib.loads(data):
        return False
    if data.startswith(b'bplist'):
        values = plistlib.loads(data)
        del values[KEY]
        plist.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY, sort_keys=False))
    else:
        data, count = XML_ENTRY.subn(b'', data)
        if count != 1 or KEY in plistlib.loads(data):
            sys.exit(f'error: cannot remove {KEY} from {plist}: not one <key> and <string> pair')
        plist.write_bytes(data)
    return True


def main():
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        sys.exit('usage: release/normalize.py APP')
    app = Path(sys.argv[1]).resolve()
    changed = [plist for plist in sorted(app.rglob('Info.plist')) if not plist.is_symlink() and strip(plist)]
    # The bundles whose seal covers a changed plist: every signed bundle above one, the app included.
    signed = {app} | {folder.parent.parent if folder.parent.name == 'Contents' else folder.parent
                      for folder in app.rglob('_CodeSignature')}
    resign = {bundle for bundle in signed for plist in changed if bundle in plist.parents}
    for bundle in sorted(resign, key=lambda path: len(path.parts), reverse=True):
        subprocess.run(['codesign', '--force', '--sign', '-', '--preserve-metadata=identifier,entitlements,requirements,flags,runtime',
                        str(bundle)], check=True, capture_output=True)
    for plist in changed:
        print(f'{KEY} removed: {plist.relative_to(app.parent)}')
    for bundle in sorted(resign):
        print(f'signed again, ad hoc: {bundle.relative_to(app.parent)}')


if __name__ == '__main__':
    main()
