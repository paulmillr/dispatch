#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/run.sh" \
  DispatchTests/ChatDiscoveryTests \
  DispatchTests/ChatRoutingIntegrationTests \
  DispatchTests/ChatEndToEndTests \
  DispatchTests/ChatPresentationTests "$@"
