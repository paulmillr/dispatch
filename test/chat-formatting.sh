#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/run.sh" \
  DispatchTests/ChatFormattingTests \
  DispatchTests/ChatToolGroupingTests \
  DispatchTests/ChatPerformanceTests \
  DispatchTests/ChatEndToEndTests "$@"
