#!/usr/bin/env python3
"""The app's release settings, scripts/release/app.json, for the release scripts (docs/releasing.md, Another app).

    release/config.py get KEY                 a setting (dots for nesting, a list one item per line)
    release/config.py variant [NAME]          NAME if it is one of the variants, else the default (the first)
    release/config.py publishes VARIANT       exits 0 if the variant is published (the default unless "publish": false)
    release/config.py entitlements            the app's entitlements, a property list
    release/config.py brew                    the cask's install name, OWNER/TAP/CASK
    release/config.py version                 the apps' version, MARKETING_VERSION in every version file (they must agree)
    release/config.py version --check X.Y.Z   "OLD COUNTS" if X.Y.Z is newer, else why not
    release/config.py version --set X.Y.Z     sets it in every version file
    release/config.py version-commit X.Y.Z REF
                                              the version commit of X.Y.Z on REF: the newest commit there that sets the
                                              version files to X.Y.Z (its parent has another version); exits 1 if none
    release/config.py version-at REF          the version the version files set at REF; exits 1 if they disagree
    release/config.py --commit SHA changes-version
                                              the version SHA sets, if it is a version commit; else exits 1

--commit SHA, before the command, reads release/app.json and the version files from that commit of the repository in the
current directory instead of from this checkout. A release is made from a version commit (docs/releasing.md).
"""
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
# project.yml, project-mobile.yml (XcodeGen): `MARKETING_VERSION: "0.1.3"`; project.pbxproj: `MARKETING_VERSION = 0.1.3;`.
VERSION = re.compile(r'(MARKETING_VERSION(?::\s*"|\s*=\s*))([0-9]+(?:\.[0-9]+)*)("|;)')


def git(*args):
    return subprocess.run(['git', *args], check=True, capture_output=True, text=True).stdout


def version_key(version):
    return tuple(int(part) for part in version.split('.'))


def version_at(commit, files):
    """The one version the files set at commit, or None (none of them there, unreadable or disagreeing). A file the
    commit does not have is skipped: a version file added later (project-mobile.yml, from the projects' split) must
    not make its first commit look like a version change."""
    found = set()
    for path in files:
        try:
            found |= {match.group(2) for match in VERSION.finditer(git('show', f'{commit}:{path}'))}
        except subprocess.CalledProcessError:
            continue
    return found.pop() if len(found) == 1 else None


def main():
    args = sys.argv[1:]
    commit = None
    if args[:1] == ['--commit']:
        commit, args = args[1], args[2:]

    def read(path):
        if commit:
            return subprocess.run(['git', 'show', f'{commit}:{path}'], check=True, capture_output=True, text=True).stdout
        return (ROOT / path).read_text()

    config = json.loads(read('scripts/release/app.json'))
    variants = config['variants']
    command = args[0] if args else ''
    if command == 'get' and len(args) == 2:
        value = config
        for key in args[1].split('.'):
            value = value[key]
        print('\n'.join(value) if isinstance(value, list) else value if isinstance(value, str) else json.dumps(value))
    elif command == 'variant' and len(args) <= 2:
        name = args[1] if len(args) == 2 and args[1] else next(iter(variants))
        if name not in variants:
            sys.exit(f'no variant {name}; release/app.json has {", ".join(variants)}')
        print(name)
    elif command == 'publishes' and len(args) == 2:
        sys.exit(0 if variants[args[1]].get('publish', True) else 1)
    elif command == 'entitlements' and len(args) == 1:
        sys.stdout.buffer.write(plistlib.dumps(config.get('entitlements', {})))
    elif command == 'brew' and len(args) == 1:
        owner, tap = config['tap'].split('/')
        print(f'{owner}/{tap.removeprefix("homebrew-")}/{config["cask"]}')
    elif command == 'version-commit' and len(args) == 3:
        version, ref, files = args[1], args[2], config['version_files']
        for sha in git('log', '--format=%H', ref, '--', *files).split():
            here = version_at(sha, files)
            if here == version and version_at(f'{sha}^', files) != version:
                print(sha)
                return
            if here and re.fullmatch(r'[0-9]+(\.[0-9]+)*', here) and version_key(here) < version_key(version):
                break
        sys.exit(1)
    elif command == 'version-at' and len(args) == 2:
        version = version_at(args[1], config['version_files'])
        if not version:
            sys.exit(f'no one version at {args[1]}')
        print(version)
    elif command == 'changes-version' and len(args) == 1 and commit:
        files = config['version_files']
        version = version_at(commit, files)
        if not version or version_at(f'{commit}^', files) == version:
            sys.exit(1)
        print(version)
    elif command == 'version' and len(args) in (1, 3) and (len(args) == 1 or args[1] in ('--check', '--set')):
        texts = {path: read(path) for path in config['version_files']}
        found = {path: {match.group(2) for match in VERSION.finditer(text)} for path, text in texts.items()}
        for path, versions in found.items():
            if not versions:
                sys.exit(f'no MARKETING_VERSION in {path}')
        current = set().union(*found.values())
        if len(current) != 1:
            sys.exit(f'the version files disagree on MARKETING_VERSION ({", ".join(sorted(current))})')
        old = current.pop()
        if len(args) == 1:
            print(old)
            return
        version = args[2]
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or version_key(version) <= version_key(old):
            sys.exit(f'{version} is not newer than the current {old}')
        counts = []
        for path, text in texts.items():
            updated, count = VERSION.subn(lambda match: match.group(1) + version + match.group(3), text)
            counts.append(f'{count} in {Path(path).name}')
            if args[1] == '--set':
                if commit:
                    sys.exit('--set changes this checkout, not a commit')
                (ROOT / path).write_text(updated)
        print(old, ', '.join(counts))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    try:
        main()
    except (KeyError, StopIteration) as error:
        sys.exit(f'release/app.json has no {error}')
    except subprocess.CalledProcessError as error:
        sys.exit(error.stderr.strip())
