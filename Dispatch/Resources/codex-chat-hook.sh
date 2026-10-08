#!/bin/sh
# Dispatch agent hook bridge. Never emit diagnostic text into model context.
[ -n "${DISPATCH_HELPER_EXECUTABLE:-}" ] || exit 0
"$DISPATCH_HELPER_EXECUTABLE" hook codex 2>/dev/null || exit 0
exit 0
