#!/usr/bin/env python3
"""Whether two app bundles are the same build (docs/releasing.md, Two builders).

    release-compare.py A.app B.app            two builders' unsigned builds of one commit
    release-compare.py --signed BUILD.app SIGNED.app   a build and the signing machine's signed copy of it

Every file and link must exist in both, with the same executable bits, and the same contents, with these exceptions:
- Signatures: `_CodeSignature/` folders, the stapled ticket (`Contents/CodeResources`) and, with --signed, profiles
  (`embedded.mobileprovision`) are skipped; Mach-O files are compared without their signatures (`codesign
  --remove-signature`, then the `__LINKEDIT` segment's vmsize zeroed: a Developer ID signature can grow it by a page,
  and removing it leaves the size grown).
- Info.plist files are compared as property lists without BuildMachineOSBuild, the builder's macOS, which differs
  between GitHub's runner image and the VM. Everything else in them (the Xcode and SDK builds) must match.
- Compiled asset catalogs (`.car`) of the same size are compared by what `assetutil --info` lists: every rendition with
  its metadata and SHA-1, without the Timestamp it reports. actool stores the same renditions in a varying order (the
  iPhone app's, from one commit, on one Mac), so their bytes may differ.
Without --signed, every Mach-O's entitlements (from its ad hoc signature) must match too: the signing machine's iPhone
export keeps them.

Prints each difference and exits 1 if there is any.
"""
import argparse
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

IGNORED_PLIST_KEYS = {'BuildMachineOSBuild'}
MACHO = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
         b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def skipped(relative, signed):
    parts = relative.parts
    return ('_CodeSignature' in parts or relative == Path('Contents/CodeResources') or
            signed and parts[-1] == 'embedded.mobileprovision')


def entries(root, signed):
    """{relative path: 'dir' | 'file' | ('link', target)} under root, skipped paths left out."""
    found = {}
    for directory, names, files in os.walk(root):
        for name in names + files:
            path = Path(directory) / name
            relative = path.relative_to(root)
            if skipped(relative, signed):
                continue
            if path.is_symlink():
                found[relative] = ('link', os.readlink(path))
            elif path.is_dir():
                found[relative] = 'dir'
            else:
                found[relative] = 'file'
    return found


def is_macho(path):
    with path.open('rb') as stream:
        return stream.read(4) in MACHO


def without_linkedit_size(data):
    """Zeroes the __LINKEDIT segment's vmsize in each 64-bit slice (thin or universal)."""
    data = bytearray(data)
    magic = struct.unpack_from('>I', data)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # universal: big-endian fat_arch (20 bytes) or fat_arch_64 (32 bytes)
        wide = magic == 0xCAFEBABF
        starts = [struct.unpack_from('>Q' if wide else '>I', data, 8 + index * (32 if wide else 20) + 8)[0]
                  for index in range(struct.unpack_from('>I', data, 4)[0])]
    else:
        starts = [0]
    for start in starts:
        if struct.unpack_from('<I', data, start)[0] != 0xFEEDFACF:  # only 64-bit little-endian slices
            continue
        command = start + 32
        for _ in range(struct.unpack_from('<I', data, start + 16)[0]):
            kind, size = struct.unpack_from('<II', data, command)
            if kind == 0x19 and data[command + 8:command + 24].rstrip(b'\0') == b'__LINKEDIT':  # LC_SEGMENT_64
                struct.pack_into('<Q', data, command + 32, 0)
            command += size
    return bytes(data)


def unsigned(path, scratch):
    copy = Path(scratch) / 'binary'
    shutil.copyfile(path, copy)
    # A file without a signature stays as it is ("not signed at all").
    subprocess.run(['codesign', '--remove-signature', str(copy)], capture_output=True)
    return without_linkedit_size(copy.read_bytes())


def entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(path)], capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    return plistlib.loads(result.stdout)


def catalog(path):
    listed = json.loads(subprocess.run(['xcrun', 'assetutil', '--info', str(path)], check=True, capture_output=True).stdout)
    for entry in listed:
        entry.pop('Timestamp', None)
    return listed


def plist(path):
    value = plistlib.loads(path.read_bytes())
    if isinstance(value, dict):
        value = {key: item for key, item in value.items() if key not in IGNORED_PLIST_KEYS}
    return value


def compare(first, second, signed):
    differences = []
    left, right = entries(first, signed), entries(second, signed)
    for relative in sorted(left.keys() - right.keys()):
        differences.append(f'only in {first}: {relative}')
    for relative in sorted(right.keys() - left.keys()):
        differences.append(f'only in {second}: {relative}')
    machos = 0
    with tempfile.TemporaryDirectory() as scratch:
        for relative in sorted(left.keys() & right.keys()):
            a, b = left[relative], right[relative]
            if a != b:
                differences.append(f'differs ({a} vs {b}): {relative}')
                continue
            if a != 'file':
                continue
            one, other = first / relative, second / relative
            if (one.stat().st_mode & 0o111) != (other.stat().st_mode & 0o111):
                differences.append(f'executable bits differ: {relative}')
            if relative.name == 'Info.plist':
                try:
                    if plist(one) != plist(other):
                        differences.append(f'Info.plist differs: {relative}')
                except Exception as error:
                    differences.append(f'unreadable Info.plist ({error}): {relative}')
                continue
            if is_macho(one):
                machos += 1
                if not is_macho(other):
                    differences.append(f'Mach-O in one only: {relative}')
                    continue
                if not signed and entitlements(one) != entitlements(other):
                    differences.append(f'entitlements differ: {relative}')
                if one.read_bytes() != other.read_bytes() and unsigned(one, scratch) != unsigned(other, scratch):
                    differences.append(f'executable differs beyond its signature: {relative}')
                continue
            if one.read_bytes() != other.read_bytes():
                if relative.suffix == '.car' and one.stat().st_size == other.stat().st_size:
                    try:
                        if catalog(one) == catalog(other):
                            continue
                    except (subprocess.CalledProcessError, ValueError) as error:
                        differences.append(f'unreadable asset catalog ({error}): {relative}')
                        continue
                differences.append(f'differs: {relative}')
    return differences, len(left), machos


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--signed', action='store_true', help='the second app is the signed copy of the first')
    parser.add_argument('first', type=Path)
    parser.add_argument('second', type=Path)
    args = parser.parse_args()
    for app in (args.first, args.second):
        if not app.is_dir():
            sys.exit(f'error: no app bundle at {app}')
    differences, count, machos = compare(args.first, args.second, args.signed)
    for line in differences:
        print(line)
    if differences:
        print(f'{args.first.name}: {len(differences)} differences', file=sys.stderr)
        return 1
    print(f'{args.first.name}: the same build ({count} entries, {machos} Mach-O files'
          f'{", signatures aside" if args.signed else ""})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
