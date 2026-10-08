#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/run.sh" \
  DispatchTests/ChatHistoryTests \
  DispatchTests/ChatPerformanceTests \
  DispatchTests/ChatToolGroupingTests \
  DispatchTests/ChatDiscoveryTests \
  DispatchTests/ChatEndToEndTests "$@"
