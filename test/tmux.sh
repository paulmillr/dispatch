#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/run.sh" \
  DispatchTests/TmuxProtocolTests \
  DispatchTests/TmuxOutputFilterTests \
  DispatchTests/TmuxSessionTests \
  DispatchTests/TmuxEdgeCaseTests \
  DispatchTests/TmuxChatIntegrationTests \
  DispatchTests/TmuxIntegrationTests "$@"
