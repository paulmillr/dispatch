# The second build of a release and its comparison with GitHub's attested one, shared by scripts/release-publish.sh
# and scripts/release/verify.sh --reproduce (docs/releasing.md, Two builders); sourced after release/ui.sh, defines
# functions only. The caller sets commit, number (the build number), variant, xcode (the Xcode build release/app.json
# pins) and xcode_version.
#
#   rebuild_checks USER            the Xcode whose build is $xcode in /Applications (sets developer), and the user the
#                                  build runs as: you when USER is empty, else one you can run commands as. Checklist
#                                  lines; bad on a problem. REBUILD_AS_YOU, when set, is said of building as you
#   rebuild SCRIPTS SOURCE OUT USER
#                                  builds SOURCE (the commit's tree) into OUT with SCRIPTS/release/builder.sh, as USER
#                                  (empty: you); skipped when OUT has a build.json from an earlier run; stops on failure
#   rebuild_compare GITHUB LOCAL COMPARE
#                                  the two build folders (unpacked to GITHUB.unpacked and LOCAL.unpacked): identical zips;
#                                  or the same app (COMPARE, release/compare.py) in zips that differ, a warning; or
#                                  different apps, which stops

rebuild_checks() {
  local user="$1" app
  pending "Xcode $xcode"
  developer=""
  for app in /Applications/Xcode*.app; do
    [[ ! -L "$app" ]] || continue
    [[ "$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version 2> /dev/null | sed -n 's/^Build version //p')" == "$xcode" ]] &&
      { developer="$app"; break; }
  done
  if [[ -n "$developer" ]]; then ok "Xcode $xcode" "$developer"
  else bad "no Xcode build $xcode in /Applications, the one release/app.json pins: brew install xcodes; xcodes install $xcode_version"; fi
  pending "build user"
  if [[ -z "$user" || "$user" == "$(id -un)" ]]; then
    ok "build user" "you ($(id -un))${REBUILD_AS_YOU:+: $REBUILD_AS_YOU}"
  elif ! id "$user" > /dev/null 2>&1 || ! sudo -n -u "$user" /usr/bin/true 2> /dev/null; then
    bad "cannot run commands as $user; run: scripts/release/signer-setup.sh builder $user"
  else
    ok "build user" "$user"
  fi
}

rebuild() {
  local scripts="$1" source="$2" out="$3" user="$4" begun=$SECONDS
  if [[ -f "$out/build.json" ]]; then
    skipped "local build" "done earlier"
    return 0
  fi
  rm -rf "$out"
  pending "local build${user:+ as $user}"
  logged "$out-build.log" bash "$scripts/release/builder.sh" "$source" "$out" --commit "$commit" --build-number "$number" \
    --xcode-build "$xcode" --variant "$variant" ${user:+--user "$user"}
  if [[ $status != 0 ]]; then
    bad "the local build failed"
    note "$(tail -15 "$out-build.log")"
    note "logs: $out-build.log, $out.log"
    exit 1
  fi
  ok "local build" "$(since "$begun")"
}

rebuild_compare() {
  local github="$1" local="$2" compare="$3" file dir app result
  file="$(plutil -extract mac.file raw "$github/build.json")"
  pending "the same build"
  [[ -f "$local/$file" ]] || { bad "the local build has no $file"; exit 1; }
  for dir in "$github" "$local"; do
    rm -rf "$dir.unpacked"
    mkdir -p "$dir.unpacked"
    ditto -x -k "$dir/$file" "$dir.unpacked"
  done
  app="$(cd "$github.unpacked" && ls -d -- *.app)"
  local github_sha local_sha
  github_sha="$(shasum -a 256 "$github/$file" | cut -d' ' -f1)"
  local_sha="$(shasum -a 256 "$local/$file" | cut -d' ' -f1)"
  if [[ "$github_sha" == "$local_sha" ]]; then
    ok "the same build" "identical $file, SHA-256 ${local_sha:0:16}…"
  elif result="$(python3 -I "$compare" "$github.unpacked/$app" "$local.unpacked/$app" 2>&1)"; then
    result="${result#*(}"
    warn "the same build, in zips that differ" "${result%)}"
    note "GitHub's ${github_sha:0:16}…, this one ${local_sha:0:16}…: a build step is not deterministic (docs/releasing.md, Two builders)"
  else
    bad "GitHub's app and the one built here differ"
    note "$result"
    exit 1
  fi
}
