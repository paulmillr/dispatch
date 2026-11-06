# The release scripts' checklist (scripts/release.sh, scripts/release-publish.sh); sourced, defines functions only.
# A gray pending line, rewritten in place with ✓ or ✗ once the step resolves; plain lines when stdout is not a terminal.
# bad sets failed=1: a preflight runs every check, then stops if any failed; warn does not. With quiet set, only
# failures print.
# logged and step run a command with its output in a log (step: one checklist line, stopping on failure).
if [[ -t 1 ]]; then
  bold=$'\033[1m' red=$'\033[31m' green=$'\033[32m' yellow=$'\033[33m' gray=$'\033[38;5;8m' reset=$'\033[0m' tty=1
else
  bold="" red="" green="" yellow="" gray="" reset="" tty=""
fi
failed=""

pending() { [[ -z "$tty" || -n "${quiet:-}" ]] || printf '  %s· %s…%s' "$gray" "$1" "$reset"; }
ok() {
  [[ -z "${quiet:-}" ]] || return 0
  if [[ -n "$tty" ]]; then printf '\r\033[2K  %s✓%s %s' "$green" "$reset" "$1"; else printf '  ok   %s' "$1"; fi
  [[ -z "${2:-}" ]] || printf '  %s%s%s' "$gray" "$2" "$reset"
  printf '\n'
}
bad() {
  if [[ -n "$tty" ]]; then printf '\r\033[2K  %s✗ %s%s\n' "$red" "$1" "$reset"; else printf '  FAIL %s\n' "$1"; fi
  failed=1
}
warn() {
  if [[ -n "$tty" ]]; then printf '\r\033[2K  %s!%s %s' "$yellow" "$reset" "$1"; else printf '  WARN %s' "$1"; fi
  [[ -z "${2:-}" ]] || printf '  %s%s%s' "$gray" "$2" "$reset"
  printf '\n'
}
skipped() {
  [[ -z "${quiet:-}" ]] || return 0
  [[ -z "$tty" ]] || printf '\r\033[2K'
  printf '  %s· %s  %s%s\n' "$gray" "$1" "$2" "$reset"
}
note() { while IFS= read -r line; do printf '    %s%s%s\n' "$gray" "$line" "$reset"; done <<< "$1"; }
resume() { printf '    %sresume:%s %s\n' "$gray" "$reset" "$1"; }
block() {
  printf '\n  %s%s%s\n' "$gray" "$1" "$reset"
  while IFS= read -r line; do printf '  %s│%s %s\n' "$gray" "$reset" "$line"; done <<< "$2"
}
title() { printf '\n  %s%s%s%s\n\n' "$bold" "$1" "$reset" "${2:+  $gray$2$reset}"; }
# y/N, the prompt printed by hand: read -p prints it only when stdin is a terminal.
ask() {
  local answer
  printf '\n  %s %s%s%s? [y/N] ' "$1" "$bold" "$2" "$reset"
  read -r answer || answer=""
  printf '\n'
  [[ "$answer" == y || "$answer" == Y ]]
}
# The running script as typed from the repository's root: scripts/release.sh, scripts/release/verify.sh.
script_name() { local path; path="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"; printf 'scripts/%s' "${path##*/scripts/}"; }
die() { printf '%s\n' "$(basename "$0"): $*" >&2; exit 1; }
since() {
  local elapsed=$((SECONDS - $1))
  if ((elapsed < 60)); then echo "${elapsed}s"; else echo "$((elapsed / 60))m $((elapsed % 60))s"; fi
}

# Runs a command with its output in a log, status in $status. Never call it from an if, && or ||: set -e would be off in
# the command itself (bash ignores it there), and a failing check inside it would pass.
logged() {
  local log="$1"
  shift
  set +e
  ( set -e; "$@" ) > "$log" 2>&1
  status=$?
  set -e
}

# progress TEXT: a stage of the step running (its pending line again, with TEXT), for the scripts a step runs: step
# exports it, writing to file descriptor 3, the terminal. A plain line when that is not a terminal.
progress() {
  if [[ -n "${RELEASE_PROGRESS_TTY:-}" ]]; then
    printf '\r\033[2K  \033[38;5;8m· %s…  %s\033[0m' "$RELEASE_PROGRESS_LABEL" "$1" >&3
  else
    printf '    %s\n' "$1" >&3
  fi
}

# step LABEL LOG COMMAND...: one line with its time; a failure stops the script with the log's tail, the log and how
# to go on (the same command again: finished steps are skipped).
step() {
  local label="$1" log="$2" begun=$SECONDS
  shift 2
  pending "$label"
  export RELEASE_PROGRESS_LABEL="$label" RELEASE_PROGRESS_TTY="$tty"
  export -f progress
  logged "$log" "$@" 3>&1
  export -n -f progress
  unset RELEASE_PROGRESS_LABEL RELEASE_PROGRESS_TTY
  if [[ $status != 0 ]]; then
    bad "$label failed"
    note "$(tail -15 "$log")"
    note "log: $log"
    resume "$(script_name) ${arguments[*]}  (finished steps are skipped)"
    exit 1
  fi
  ok "$label" "$(since "$begun")"
}
