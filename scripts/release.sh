#!/bin/bash
# Release, on the machine that signs commits (docs/releasing.md, Commit machine):
#
#   scripts/release.sh X.Y.Z [-m NOTES]
#
# Checks everything first and lists every problem at once: tools and gh's login, X.Y.Z newer than the apps' version
# and not released yet, the version files unchanged, main fast-forwarding to HEAD, the commits to push signed,
# GitHub's checks on HEAD green (a rehearsal of the release build counts), git signing commits (it may ask for the
# key) and with which key. Then it shows what it is about to do and asks.
# Then: MARKETING_VERSION set to X.Y.Z in the version files scripts/release/app.json lists, a signed commit "X.Y.Z" of
# those files only (the version commit, dated in UTC; -m NOTES, the release notes' summary, is its body: signed with
# it, and put at the top of the GitHub release), pushed to main. That starts GitHub's release build
# (.github/workflows/release.yml). No tag: publishing the release on the signing machine creates it, so a version that
# fails before then leaves no tag behind.
#
# Next, on the signing machine, by hand: scripts/release-publish.sh X.Y.Z (it waits for GitHub's build). This machine
# has no way into that one. Run again with the same version after a failure: a version commit made earlier is pushed,
# not made again; one already on main is only named, with the command to run there.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/release/ui.sh"
config() { python3 -I "$ROOT/scripts/release/config.py" "$@"; }
NAME="$(config get name)"
REPOSITORY="$(config get repository)"
FILES=()
while IFS= read -r file; do FILES+=("$file"); done < <(config get version_files)

# Commits dated now, in UTC: the build number is the version commit's UTC time.
utc() {
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%S+0000)"
  GIT_AUTHOR_DATE="$now" GIT_COMMITTER_DATE="$now" TZ=UTC "$@"
}

usage="usage: scripts/release.sh X.Y.Z [-m NOTES] (three numbers, no v; NOTES: the release's summary)"
[[ $# -ge 1 && "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$usage"
version="$1" notes=""
shift
if [[ $# -gt 0 ]]; then
  [[ $# == 2 && "$1" == -m && -n "$2" ]] || die "$usage"
  notes="$2"
fi
cd "$ROOT"
title "$NAME $version"

# Preflight: every check runs and every failure is listed, so one rerun fixes them all.
missing=""
for tool in git gh gpg python3; do command -v "$tool" > /dev/null || missing+=" $tool"; done
if [[ -z "$missing" ]]; then ok "git, gh, gpg"; else bad "not installed:$missing"; fi

pending "gh logged in"
if command -v gh > /dev/null && gh auth status > /dev/null 2>&1; then ok "gh logged in"; else bad "gh is not logged in; run: gh auth login"; fi

pending "origin is $REPOSITORY"
if [[ "$(git config --get remote.origin.url)" =~ github\.com[:/]$REPOSITORY(\.git)?$ ]]; then
  ok "origin is $REPOSITORY"
else
  bad "origin is $(git config --get remote.origin.url || echo none), not $REPOSITORY"
fi

# What exists already: nothing (make the version commit), the version commit here only (push it), or on main (nothing
# to do here: publish on the signing machine).
pending "main"
git fetch --quiet origin main 2> /dev/null || bad "could not fetch main from origin"
pushed="$(config version-commit "$version" origin/main 2> /dev/null || true)"
# Only main's own version: an older version commit belongs to an older release.
main_version="$(config version-at origin/main 2> /dev/null || true)"
old_version=""
if [[ -n "$pushed" && "$main_version" != "$version" ]]; then
  bad "$version is an older version than main's $main_version: nothing to release"
  pushed="" old_version=1
fi
local_commit=""
if [[ -z "$pushed" && -z "$old_version" && "$(config version 2> /dev/null || true)" == "$version" ]]; then
  local_commit="$(config version-commit "$version" HEAD 2> /dev/null || true)"
fi
if [[ -n "$pushed" ]]; then
  stage=published
  ok "version commit on main" "${pushed:0:8}: pushed earlier; publish it on the signing machine"
elif [[ -n "$local_commit" ]]; then
  stage=push
  ok "version commit here" "${local_commit:0:8}: made earlier, not pushed yet"
elif [[ -n "$old_version" ]]; then
  stage=old
else
  stage=new
fi

pending "release $version"
status=0
git ls-remote --exit-code --tags origin "refs/tags/$version" > /dev/null 2>&1 || status=$?
case "$status" in
  0) if [[ "$stage" == published ]]; then ok "release $version" "tagged already: the signing machine finishes or checks it"
     elif [[ "$stage" != old ]]; then bad "tag $version already exists on GitHub: $version is released"; fi ;;
  2) ok "release $version" "not released yet" ;;
  *) bad "could not reach origin to check its tags" ;;
esac

old="" counts=""
if [[ "$stage" == new ]]; then
  if ! git diff --quiet HEAD -- "${FILES[@]}"; then
    bad "uncommitted changes in the version files (${FILES[*]}); commit or revert them first"
  elif result="$(config version --check "$version" 2>&1)"; then
    old="${result%% *}" counts="${result#* }"
    ok "version $old → $version" "$counts"
  else
    bad "$result"
  fi
fi

head="$(git rev-parse HEAD)"
ahead=0
if [[ "$stage" != published ]]; then
  pending "main fast-forwards to HEAD"
  if ! git merge-base --is-ancestor origin/main HEAD 2> /dev/null; then
    bad "HEAD is not ahead of origin/main: pull or rebase first"
  else
    ahead="$(git rev-list --count origin/main..HEAD)"
    ok "main fast-forwards to HEAD" "$([[ $ahead == 0 ]] && echo "HEAD is main" || echo "$ahead commit$([[ $ahead == 1 ]] || echo s) to push")"
    # main accepts only signed commits; the version commit itself is signed below.
    pending "commits to push are signed"
    unsigned="$(git log --format='%G? %h %s' origin/main..HEAD | grep -vE '^[GU] ' || true)"
    if [[ -z "$unsigned" ]]; then
      ok "commits to push are signed"
    else
      bad "commits to push without a good signature"
      note "$unsigned"
    fi
  fi
fi

if [[ "$stage" == new ]]; then
  pending "GitHub checks on HEAD"
  if checks="$(gh api "repos/$REPOSITORY/commits/$head/check-runs?per_page=100" 2> /dev/null)"; then
    result="$(python3 -I -c '
import json, sys
runs = json.load(sys.stdin)["check_runs"]
failed = [r for r in runs if r["status"] == "completed" and r["conclusion"] not in ("success", "neutral", "skipped")]
running = [r for r in runs if r["status"] != "completed"]
for r in failed: print("failed", r["conclusion"], r["name"], r.get("html_url") or "")
for r in running: print("running", r["status"], r["name"], r.get("html_url") or "")
if not failed and not running: print("green", len(runs))
' <<< "$checks")"
    case "$result" in
      green\ 0) ok "GitHub checks on HEAD" "none ran on ${head:0:8}" ;;
      green\ *) ok "GitHub checks on HEAD" "${result#green } green on ${head:0:8}" ;;
      *) bad "GitHub checks on ${head:0:8} failed or are still running"; note "$result" ;;
    esac
  elif git merge-base --is-ancestor HEAD origin/main 2> /dev/null; then
    bad "could not read GitHub's checks on ${head:0:8}"
  else
    skipped "GitHub checks on HEAD" "${head:0:8} is not on GitHub yet, none to check"
  fi
fi

# The one check with a visible side effect (the key may ask for its passphrase): only when the rest passed. A signed
# commit object nothing points to, left for git's garbage collection.
if [[ "$stage" == new ]]; then
  if [[ -n "$failed" ]]; then
    skipped "signing probe" "skipped: earlier checks failed"
  else
    pending "git signs commits"
    if probe="$(git commit-tree -S -p HEAD -m probe "HEAD^{tree}" 2> /dev/null)"; then
      key="$(git verify-commit --raw "$probe" 2>&1 > /dev/null | awk '$2 == "VALIDSIG" { print $NF }' | head -1)"
      # The signing machine accepts only its pinned key: compare this with release.env's RELEASE_COMMIT_KEY.
      ok "git signs commits" "key ${key:-unknown}"
    else
      bad "git cannot sign a commit; check user.signingkey and gpg-agent"
    fi
  fi
fi

if [[ -n "$failed" ]]; then
  printf '\n'
  die "preflight failed; nothing was changed"
fi

publish="scripts/release-publish.sh $version"
if [[ "$stage" != published ]]; then
  if [[ "$stage" == new ]]; then
    plan="MARKETING_VERSION $old → $version ($counts)
commit $version, the version commit (the version files only, signed)${notes:+, notes: $notes}
push it to main: that starts GitHub's release build"
  else
    plan="push the version commit ${local_commit:0:8} to main: that starts GitHub's release build"
  fi
  [[ $ahead == 0 ]] || plan+="
with the $ahead commit$([[ $ahead == 1 ]] || echo s) before it: $(git log --format=%h origin/main..HEAD | tr '\n' ' ')"
  plan+="
then, on the signing machine: $publish (it asks before signing)"
  plan+="
no tag yet: publishing the release creates it"
  block "plan" "$plan"
  # The version files are unchanged (checked above): every tracked change listed is someone else's, left alone.
  others="$(git status --short --untracked-files=no)"
  [[ -z "$others" ]] || block "uncommitted, not part of the release" "$others"
  ask push "$version" || die "aborted; nothing was changed"
fi
start=$SECONDS

if [[ "$stage" == new ]]; then
  pending "version"
  config version --set "$version" > /dev/null
  ok "version  $old → $version"
  pending "commit"
  if ! output="$(utc git commit -S -q -m "$version" ${notes:+-m "$notes"} -- "${FILES[@]}" 2>&1)"; then
    bad "commit failed; the version files are changed, nothing is committed"
    note "$output"
    resume "git commit -S -m '$version'${notes:+ -m $(printf %q "$notes")} -- ${FILES[*]}, then scripts/release.sh $version"
    exit 1
  fi
  ok "commit   $version" "$(git rev-parse --short HEAD)"
fi
if [[ "$stage" != published ]]; then
  pending "push main"
  if ! output="$(git push --quiet origin HEAD:refs/heads/main 2>&1)"; then
    bad "push failed; the version commit exists here, GitHub is unchanged"
    note "$output"
    resume "scripts/release.sh $version"
    exit 1
  fi
  ok "push     main → origin" "$(git rev-parse --short HEAD)"
  pushed="$(git rev-parse HEAD)"

  # The run the push started; GitHub may take a few seconds to list it.
  pending "release build"
  run=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run="$(gh run list -R "$REPOSITORY" --workflow release.yml --commit "$pushed" --event push --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty' 2> /dev/null || true)"
    [[ -z "$run" ]] || break
    sleep 3
  done
  if [[ -n "$run" ]]; then
    ok "build    https://github.com/$REPOSITORY/actions/runs/$run" "gh run watch $run -R $REPOSITORY"
  else
    skipped "release build" "not listed yet: https://github.com/$REPOSITORY/actions/workflows/release.yml"
  fi
fi

printf '\n  %sdone in %s%s\n' "$gray" "$(since "$start")" "$reset"
printf '  next, on the signing machine (it waits for GitHub'"'"'s build): %s%s%s\n\n' "$bold" "$publish" "$reset"
