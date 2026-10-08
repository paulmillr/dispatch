#!/usr/bin/env python3
"""Sign and notarize an existing Release app without modifying the build product."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
MACHO = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca',
    'cafebabf', 'bfbafeca')}


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True,
                          capture_output=True, text=True).stdout


def identity_hash(identity):
    """Require one valid Developer ID identity, never silently select a team."""
    identities = re.findall(r'([0-9A-Fa-f]{40}) "([^"]+)"',
                            run('security', 'find-identity', '-v', '-p', 'codesigning'))
    matches = [digest for digest, name in identities
               if name.startswith('Developer ID Application:') and
               (identity.lower() == digest.lower() or identity == name)]
    if len(matches) != 1:
        raise ValueError('Select one valid Developer ID Application identity by its full name or SHA-1. '
                         'Apple Development and ad-hoc identities cannot notarize a download.')
    return matches[0]


def signing_targets(app):
    """Sign every Mach-O (including resource helpers), then enclosing bundles."""
    binaries, bundles = [], []
    for path in app.rglob('*'):
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open('rb') as source:
                if source.read(4) in MACHO:
                    binaries.append(path)
        elif path.suffix in ('.app', '.framework', '.xpc', '.appex', '.bundle'):
            bundles.append(path)
    # Deepest paths first puts nested code before its enclosing resource seal.
    return sorted(binaries + bundles, key=lambda p: (-len(p.parts), str(p))) + [app]


def package(app, archive):
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)


def finish(app, output, submission_id, status):
    if status != 'Accepted':
        raise ValueError(f'Notarization status: {status}. Submission: {submission_id}. '
                         f'Inspect with xcrun notarytool log {submission_id} --keychain-profile PROFILE; '
                         'do not resubmit an in-progress upload.')
    run('xcrun', 'stapler', 'staple', app)
    run('xcrun', 'stapler', 'validate', app)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    archive = output / 'Dispatch.zip'
    package(app, archive)  # ZIP must contain the stapled app, not the submitted copy.
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    print(f'Notarized and verified: {archive}\nSHA-256: {digest}')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/Build/Products/Release/Dispatch.app')
    parser.add_argument('--output', type=Path, required=True,
                        help='new output directory; refuses to overwrite existing artifacts')
    parser.add_argument('--identity', help='full Developer ID Application name or SHA-1')
    parser.add_argument('--keychain-profile', required=True, help='existing notarytool credential profile')
    parser.add_argument('--resume', action='store_true',
                        help='finish an existing submission from this output directory without uploading again')
    args = parser.parse_args(argv)
    output = args.output.expanduser().resolve()
    staged = output / 'Dispatch.app'
    receipt = output / 'notarization.json'
    if args.resume:
        result = json.loads(receipt.read_text())
        submission_id = result['id']
        result = json.loads(run('xcrun', 'notarytool', 'info', submission_id,
                                '--keychain-profile', args.keychain_profile, '--output-format', 'json'))
        receipt.write_text(json.dumps(result, indent=2) + '\n')
        finish(staged, output, submission_id, result['status'])
        return
    if not args.identity:
        parser.error('--identity is required unless --resume is used')
    identity = identity_hash(args.identity)
    source = args.app.expanduser().resolve()
    with (source / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if info.get('CFBundlePackageType') != 'APPL' or not (source / 'Contents/MacOS' / info['CFBundleExecutable']).is_file():
        raise ValueError('Expected a built macOS application bundle')
    if source == output or source in output.parents:
        raise ValueError('Output must be outside the source app')
    # Check profile access before staging/signing. No passwords or keys in arguments.
    run('xcrun', 'notarytool', 'history', '--keychain-profile', args.keychain_profile,
        '--output-format', 'json')
    output.mkdir(parents=True, exist_ok=False)
    run('ditto', source, staged)
    for target in signing_targets(staged):
        run('codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', target)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', staged)
    archive = output / 'submission.zip'
    package(staged, archive)
    # Submit only once. Record the ID before waiting, so interruptions can resume.
    # If submit itself is interrupted, reconcile with notarytool history first.
    result = json.loads(run('xcrun', 'notarytool', 'submit', archive,
                            '--keychain-profile', args.keychain_profile, '--output-format', 'json'))
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    submission_id = result['id']
    print(f'Submitted: {submission_id}; receipt: {receipt}', flush=True)
    result = json.loads(run('xcrun', 'notarytool', 'wait', submission_id,
                            '--keychain-profile', args.keychain_profile, '--output-format', 'json'))
    receipt.write_text(json.dumps(result, indent=2) + '\n')
    finish(staged, output, submission_id, result['status'])


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        raise SystemExit(error.returncode)
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
