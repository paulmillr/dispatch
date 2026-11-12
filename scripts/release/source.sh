# The signing machine's first step, of scripts/release-publish.sh and scripts/release/iphone.sh; sourced, defines
# functions only (docs/releasing.md, Signing machine). The script sets SELF (the scripts folder), REPOSITORY, CONFIG,
# version (or, for signed_ref, ref) and arguments, and sources release/ui.sh first. signed_commit is also
# scripts/release/verify.sh --reproduce's (with its own clone and key).
#
#   source_start FOLDER        the work folder, CONFIG/work/FOLDER; quiet in the clone's copy of the script
#   source_checks TOOL...      the tools; the commit key pinned in CONFIG; the version commit of X.Y.Z signed by that
#                              key alone (signed_commit), or, with version empty, the commit ref names (signed_ref;
#                              no key need be pinned).
#                              Sets commit and number (the build number); stops with every problem listed
#   signed_commit GNUPGHOME KEY URL MAIN_REF [COMMIT]
#                              fetches main from URL into MAIN_REF of $clone; finds the version commit of $version on it
#                              (scripts/release/config.py version-commit: the newest commit setting the app to $version;
#                              it must be COMMIT when given), signed by KEY (a primary key's fingerprint) from the keyring
#                              GNUPGHOME alone; a tag $version on URL, once published, must be it. One checklist line;
#                              sets commit and number (the build number), empty on a problem
#   signed_ref GNUPGHOME KEY REF
#                              fetches origin's branches; REF is HEAD (the commit checked out in $clone), a branch of
#                              origin, or any commit $clone has. Not signed by KEY (as above; or no KEY), not pushed,
#                              behind origin's branch or with uncommitted changes in $clone: only warnings, for now (the
#                              iPhone's Ad Hoc builds are internal). Sets commit, number and version (the version files'
#                              there), empty on a problem
#   source_hand_over           the clone's copy: exports the commit's tree to the work folder and runs the same script
#                              (the same path under scripts/) from there (what touches the keys comes from a commit you signed); the commit's copy:
#                              returns

source_start() {
  mkdir -p "$CONFIG/work"
  # Physical, as $SELF is: that is how the commit's copy of a script tells itself from the clone's.
  work="$(cd "$CONFIG/work" && pwd -P)/$1"
  clone="${RELEASE_SOURCE_CLONE:-$(git -C "$SELF/.." rev-parse --show-toplevel 2> /dev/null || true)}"
  # The clone's copy only checks and hands over: quietly, failures aside.
  quiet=""
  [[ "$SELF" == "$work/source/scripts" ]] || quiet=1
}

source_checks() {
  local missing="" tool key="" apps
  for tool in "$@"; do command -v "$tool" > /dev/null || missing+=" $tool"; done
  if [[ -z "$missing" ]]; then ok "$(printf '%s, ' "$@" | sed 's/, $//')"
  else bad "not on PATH:$missing"; note "over SSH, run it in a login shell: ssh -t signer zsh -lc '$(script_name) ${version:-$ref}'"; fi

  if [[ -f "$CONFIG/release.env" && -d "$CONFIG/gnupg" ]]; then
    # RELEASE_COMMIT_KEY, and optionally RELEASE_TAP (the tap's clone).
    source "$CONFIG/release.env"
    key="${RELEASE_COMMIT_KEY:-}"
    [[ "$key" =~ ^[0-9A-F]{40}$ ]] || { bad "RELEASE_COMMIT_KEY in $CONFIG/release.env is not a 40-digit fingerprint"; key=""; }
  elif [[ -n "$version" ]]; then
    bad "no commit key pinned; run: scripts/release/signer-setup.sh trust"
  fi

  commit="" number=""
  if [[ -z "$clone" ]] || ! [[ "$(git -C "$clone" config --get remote.origin.url)" =~ github\.com[:/]$REPOSITORY(\.git)?$ ]]; then
    bad "not run from a clone of $REPOSITORY"
  elif [[ -n "$key" && -n "$version" ]]; then
    signed_commit "$CONFIG/gnupg" "$key" origin refs/remotes/origin/main
  elif [[ -z "$version" ]]; then
    signed_ref "$CONFIG/gnupg" "$key" "$ref"
  fi
  [[ -z "$failed" ]] || die "stopped; nothing was built or signed"
}

signed_commit() {
  local home="$1" key="$2" url="$3" main_ref="$4" expected="${5:-}" found tagged
  commit="" number=""
  pending "version commit of $version"
  if ! git -C "$clone" fetch --quiet --no-tags "$url" "+refs/heads/main:$main_ref" 2> /dev/null; then
    bad "cannot fetch main from $url"
  elif ! found="$(cd "$clone" && python3 -I "$SELF/release/config.py" version-commit "$version" "$main_ref")"; then
    bad "no version commit of $version on main (scripts/release.sh on the commit machine makes it)"
  elif [[ -n "$expected" && "$found" != "$expected" ]]; then
    bad "tag $version is ${expected:0:8}, but the version commit of $version on main is ${found:0:8}"
  elif ! grep -qw "$key" <<< "$(signer_of "$home" commit "$found")"; then
    bad "commit ${found:0:8}, the version commit of $version, is not signed by the commit key $key"
  elif tagged="$(git -C "$clone" ls-remote --tags "$url" "refs/tags/$version" "refs/tags/$version^{}" 2> /dev/null | awk '{ print $1 }' | tail -1)";
       [[ -n "$tagged" && "$tagged" != "$found" ]]; then
    # Published already: the release's tag must be this commit.
    bad "tag $version exists at ${tagged:0:8}, not the version commit ${found:0:8}"
  else
    commit="$found"
    number="$(TZ=UTC git -C "$clone" show -s --format=%cd --date=format-local:%Y%m%d.%H%M "$commit")"
    ok "version commit signed" "${commit:0:8} on main, $version, key …${key: -16}"
  fi
}

signed_ref() {
  local home="$1" key="$2" name="$3" found="" signed="" fetched="" here branch="" upstream changes
  commit="" number=""
  pending "commit $name"
  git -C "$clone" fetch --quiet --no-tags origin '+refs/heads/*:refs/remotes/origin/*' 2> /dev/null && fetched=1
  here="$(git -C "$clone" rev-parse --quiet --verify 'HEAD^{commit}' || true)"
  # HEAD first: refs/remotes/origin/HEAD is origin's default branch, not what is checked out here.
  if [[ "$name" == HEAD ]]; then
    found="$here"
  elif git -C "$clone" rev-parse --quiet --verify "refs/remotes/origin/$name^{commit}" > /dev/null; then
    found="$(git -C "$clone" rev-parse "refs/remotes/origin/$name^{commit}")"
  elif git -C "$clone" rev-parse --quiet --verify "$name^{commit}" > /dev/null; then
    found="$(git -C "$clone" rev-parse "$name^{commit}")"
  fi
  [[ -z "$found" || -z "$key" ]] || ! grep -qw "$key" <<< "$(signer_of "$home" commit "$found")" || signed=1
  if [[ -z "$found" ]]; then
    bad "$name is no commit of $clone, nor a branch of origin"
  elif ! version="$(cd "$clone" && python3 -I "$SELF/release/config.py" version-at "$found" 2>&1)"; then
    bad "commit ${found:0:8}: $version"
    version=""
  else
    commit="$found"
    number="$(TZ=UTC git -C "$clone" show -s --format=%cd --date=format-local:%Y%m%d.%H%M "$commit")"
    # The commit's copy gets the commit itself, so it names the branch only when that commit is the one checked out.
    if [[ "$commit" == "$here" ]]; then branch="$(git -C "$clone" symbolic-ref --quiet --short HEAD || true)"; fi
    if [[ "$name" =~ ^[0-9a-f]{7,40}$ || "$name" == HEAD ]]; then name="${branch:+ ($branch)}"; else name=" ($name)"; fi
    if [[ -n "$signed" ]]; then ok "commit signed" "${commit:0:8}$name, version $version, key …${key: -16}"
    elif [[ -z "${quiet:-}" ]]; then
      warn "commit not signed" "${commit:0:8}$name, version $version: not by the commit key; its scripts run here, with your keys"
    fi
    # Internal builds: none of these stops one, but each means the build is not what origin or the clone shows.
    [[ -z "${quiet:-}" ]] || return 0
    [[ -n "$fetched" ]] || warn "origin not fetched" "what it has is as of the last fetch"
    [[ -n "$(git -C "$clone" for-each-ref --contains "$commit" refs/remotes/origin/)" ]] ||
      warn "commit not pushed" "${commit:0:8} is on no branch of origin: only this clone has it"
    if [[ -n "$branch" ]] && upstream="$(git -C "$clone" rev-parse --quiet --verify "refs/remotes/origin/$branch^{commit}")" &&
       ! git -C "$clone" merge-base --is-ancestor "$upstream" "$commit"; then
      warn "behind origin" "origin's $branch is at ${upstream:0:8}; git pull to build that"
    fi
    if [[ "$commit" == "$here" ]] && changes="$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')" && [[ "$changes" != 0 ]]; then
      warn "uncommitted changes" "$changes file$([[ $changes == 1 ]] || echo s) in $clone: the build has ${commit:0:8}'s code only"
    fi
  fi
}

# gpg's status lines: VALIDSIG <signing key> … <primary key>. Only the pinned key, from its own keyring, counts.
signer_of() {
  GNUPGHOME="$1" git -C "$clone" "verify-$2" --raw "$3" 2>&1 > /dev/null |
    awk '$2 == "GOODSIG" { good = 1 } $2 == "VALIDSIG" { keys = keys " " $3 " " $NF } END { if (good) print keys }'
}

source_hand_over() {
  if [[ -n "$quiet" ]]; then
    # A version commit never changes: a work folder made for another commit stops it.
    if [[ -f "$work/commit" && "$(cat "$work/commit")" != "$commit" ]]; then
      die "the version commit of $version is now ${commit:0:8}, but $work was made for $(cut -c1-8 "$work/commit"). Find out why; move that folder away to start over."
    fi
    # Its own scripts take over: a commit from before these (no scripts/release/) has others, which this cannot run.
    git -C "$clone" cat-file -e "$commit:scripts/release/source.sh" 2> /dev/null ||
      die "commit ${commit:0:8} predates scripts/release/: these scripts cannot release it"
    git -C "$clone" cat-file -e "$commit:$(script_name)" 2> /dev/null ||
      die "commit ${commit:0:8} has no $(script_name): it cannot release this way"
    mkdir -p "$work"
    echo "$commit" > "$work/commit"
    rm -rf "$work/source"
    mkdir "$work/source"
    git -C "$clone" archive "$commit" | tar -x -C "$work/source"
    RELEASE_SOURCE_CLONE="$clone" exec bash "$work/source/$(script_name)" "${arguments[@]}"
  fi
  [[ "$(cat "$work/commit")" == "$commit" ]] || die "the version commit of $version changed to ${commit:0:8} while this ran; find out why"
}
