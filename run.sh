#!/bin/bash
# The old name of ./build.sh, kept for now and behaving as it did: it launches what it builds, unless --just-build.
set -eo pipefail
here="$(dirname "$0")"
[[ "${1:-}" != --test ]] || exec bash "$here/build.sh" "$@"
run=--run
args=()
for arg in "$@"; do
  case "$arg" in
    --just-build) run= ;;
    --archive | --archive=*) run=; args+=("$arg") ;;
    *) args+=("$arg") ;;
  esac
done
exec bash "$here/build.sh" "${args[@]}" $run
