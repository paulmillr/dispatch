#!/usr/bin/env python3
"""A byte-reproducible zip of one folder, for the release builds (docs/releasing.md, Two builders):

    python3 -I scripts/release/zip.py FOLDER OUT.zip --time YYYYMMDD.HHMM

The zip holds FOLDER itself (as `ditto -c -k --keepParent` would), and depends only on the folder's names, contents,
links and permissions: entries sorted by name, every date the given time (the build number, the commit's UTC time),
no owners, extended attributes, resource forks or extra fields, and stored, not compressed, so no compressor version
can change a byte. The same build makes the same
zip on any Mac, so its SHA-256 is the whole comparison. `ditto -x -k` unpacks it, links included.
"""
import os
import stat
import sys
import zipfile
from datetime import datetime
from pathlib import Path


def entries(root: Path):
    """(name in the zip, path) for root and everything under it, sorted by name; refuses anything not a folder, file or
    link."""
    found = []
    for folder, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(folder) / name
            found.append(path)
    found.append(root)
    named = []
    for path in found:
        name = (root.name / path.relative_to(root)).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            named.append((name, path, 'link'))
        elif stat.S_ISDIR(mode):
            named.append((name + '/', path, 'folder'))
        elif stat.S_ISREG(mode):
            named.append((name, path, 'file'))
        else:
            sys.exit(f'error: {path} is neither a folder, a file nor a link')
    return sorted(named, key=lambda entry: entry[0].encode())


def main():
    args = sys.argv[1:]
    if len(args) != 4 or args[2] != '--time':
        sys.exit('usage: release/zip.py FOLDER OUT.zip --time YYYYMMDD.HHMM')
    root, out = Path(args[0]), Path(args[1])
    time = datetime.strptime(args[3], '%Y%m%d.%H%M')
    if not root.is_dir() or root.is_symlink():
        sys.exit(f'error: {root} is not a folder')
    if out.exists():
        sys.exit(f'error: {out} exists')
    date = (time.year, time.month, time.day, time.hour, time.minute, 0)
    with zipfile.ZipFile(out, 'x', compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for name, path, kind in entries(root):
            info = zipfile.ZipInfo(name, date)
            info.create_system = 3  # Unix: the modes below are read.
            info.compress_type = zipfile.ZIP_STORED
            permissions = stat.S_IMODE(path.lstat().st_mode)
            if kind == 'folder':
                info.external_attr = (stat.S_IFDIR | permissions) << 16 | 0x10
                archive.writestr(info, b'')
            elif kind == 'link':
                info.external_attr = (stat.S_IFLNK | permissions) << 16
                archive.writestr(info, os.readlink(path).encode())
            else:
                info.external_attr = (stat.S_IFREG | permissions) << 16
                archive.writestr(info, path.read_bytes())


if __name__ == '__main__':
    main()
