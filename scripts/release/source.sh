# The signing machine's first step, of scripts/release-publish.sh (and any other script of the signing machine's); sourced, defines
# functions only (docs/releasing.md, Signing machine). The script sets SELF, REPOSITORY, CONFIG, version and arguments,
# and sources release/ui.sh first. signed_commit is also scripts/release/verify.sh --reproduce's (with its own clone and
# key).
#
#   source_start FOLDER        the work folder, CONFIG/work/FOLDER; quiet in the clone's copy of the script
#   source_checks TOOL...      the tools; the commit key pinned in CONFIG; the version commit of X.Y.Z signed by that
#                              key alone (signed_commit). Sets commit and number (the build number); stops with every
#                              problem listed
#   signed_commit GNUPGHOME KEY URL MAIN_REF [COMMIT]
#                              fetches main from URL into MAIN_REF of $clone; finds the version commit of $version on it
#                              (scripts/release/config.py version-commit: the newest commit setting the app to $version;
#                              it must be COMMIT when given), signed by KEY (a primary key's fingerprint) from the keyring
#                              GNUPGHOME alone; a tag $version on URL, once published, must be it. One checklist line;
#                              sets commit and number (the build number), empty on a problem
#   source_hand_over           the clone's copy: exports the commit's tree to the work folder and runs the same script
#                              from there (what touches the keys comes from a commit you signed); the commit's copy:
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
  else bad "not on PATH:$missing"; note "over SSH, run it in a login shell: ssh -t signer zsh -lc '$(script_name) $version'"; fi

  if [[ -f "$CONFIG/release.env" && -d "$CONFIG/gnupg" ]]; then
    # RELEASE_COMMIT_KEY, and optionally RELEASE_TAP (the tap's clone).
    source "$CONFIG/release.env"
    key="${RELEASE_COMMIT_KEY:-}"
    [[ "$key" =~ ^[0-9A-F]{40}$ ]] || { bad "RELEASE_COMMIT_KEY in $CONFIG/release.env is not a 40-digit fingerprint"; key=""; }
  else
    bad "no commit key pinned; run: scripts/release/signer-setup.sh trust"
  fi

  commit="" number=""
  if [[ -z "$clone" ]] || ! [[ "$(git -C "$clone" config --get remote.origin.url)" =~ github\.com[:/]$REPOSITORY(\.git)?$ ]]; then
    bad "not run from a clone of $REPOSITORY"
  elif [[ -n "$key" ]]; then
    signed_commit "$CONFIG/gnupg" "$key" origin refs/remotes/origin/main
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
      die "the version commit of $version, ${commit:0:8}, predates scripts/release/: these scripts cannot release it"
    mkdir -p "$work"
    echo "$commit" > "$work/commit"
    rm -rf "$work/source"
    mkdir "$work/source"
    git -C "$clone" archive "$commit" | tar -x -C "$work/source"
    RELEASE_SOURCE_CLONE="$clone" exec bash "$work/source/scripts/$(basename "$0")" "${arguments[@]}"
  fi
  [[ "$(cat "$work/commit")" == "$commit" ]] || die "the version commit of $version changed to ${commit:0:8} while this ran; find out why"
}
