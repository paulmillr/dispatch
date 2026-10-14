#!/usr/bin/env python3
"""Moves the replay corpus (replays/) into its own repository, mounted back at replays/ as a git submodule.

One-time: it creates the corpus repository at --repo from the replays/ in the index (one commit), points its
origin at URL (pushing it with --push), and stages in this checkout the removal of replays/ and the submodule in
its place. Paths stay the same: recordings name /tmp/dt-journal/checkout/replays, so the corpus never moves.
Nothing is committed in this checkout.
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def git(*args, cwd=ROOT, capture=False):
    result = subprocess.run(['git', *args], cwd=cwd, check=True, text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('url', help="The corpus repository's remote (the submodule's URL in .gitmodules)")
    parser.add_argument('--repo', type=Path, default=ROOT.parent / 'dispatch-replays',
                        help='Where to create the corpus repository (default: %(default)s); must not exist')
    parser.add_argument('--push', action='store_true', help='Push the corpus repository to URL')
    args = parser.parse_args()
    repo = args.repo.resolve()

    if git('ls-files', '--stage', '--', 'replays', capture=True).startswith('160000'):
        sys.exit('replays/ is already a submodule')
    if not git('ls-files', '--', 'replays', capture=True):
        sys.exit('replays/ has no tracked files')
    if git('status', '--porcelain', '--', 'replays', capture=True):
        sys.exit('replays/ has unstaged or untracked changes: stage or drop them first')
    if repo.exists():
        sys.exit(str(repo) + ' exists')

    # The corpus as staged: the tree replays/ has in the index.
    tree = git('write-tree', '--prefix=replays/', capture=True)
    repo.mkdir(parents=True)
    git('init', '--quiet', '--initial-branch=main', cwd=repo)
    archive = subprocess.Popen(['git', 'archive', tree], cwd=ROOT, stdout=subprocess.PIPE)
    subprocess.run(['tar', '-x', '-C', str(repo)], stdin=archive.stdout, check=True)
    if archive.wait():
        sys.exit('git archive failed')
    git('add', '--all', cwd=repo)
    git('commit', '--quiet', '-m', 'Replay corpus', cwd=repo)
    if git('rev-parse', 'HEAD^{tree}', cwd=repo, capture=True) != tree:
        sys.exit('The corpus repository at ' + str(repo) + ' does not hold the staged replays/')
    git('remote', 'add', 'origin', args.url, cwd=repo)
    if args.push:
        git('push', '--quiet', '--set-upstream', 'origin', 'main', cwd=repo)

    # replays/ out of the index, the submodule in: cloned from the local repository (URL may not be pushed yet),
    # then recorded with URL. The old files wait aside until the submodule checks out the same tree.
    aside = Path(tempfile.mkdtemp(prefix='replays-', dir=ROOT / 'build' if (ROOT / 'build').is_dir() else None))
    git('rm', '-r', '--cached', '--quiet', '--', 'replays')
    (ROOT / 'replays').rename(aside / 'replays')
    git('-c', 'protocol.file.allow=always', 'submodule', 'add', '--quiet', '--name', 'replays', str(repo), 'replays')
    git('config', '--file', '.gitmodules', 'submodule.replays.url', args.url)
    git('add', '.gitmodules')
    git('submodule', 'sync', '--quiet', '--', 'replays')
    if git('rev-parse', 'HEAD^{tree}', cwd=ROOT / 'replays', capture=True) != tree:
        sys.exit('The submodule does not check out the old corpus; the old files are in ' + str(aside))
    shutil.rmtree(aside)
    print('Corpus repository: ' + str(repo) + (' (pushed)' if args.push else ' (not pushed: git -C ' + str(repo) + ' push -u origin main)'))
    print('Staged here: replays/ as a submodule of ' + args.url + '; review with git status and commit')


if __name__ == '__main__':
    main()
