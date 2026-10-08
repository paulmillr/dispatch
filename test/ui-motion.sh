#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DISPATCH_SETUP_OFFLINE=1 bash scripts/setup.sh
python3 scripts/generate-project.py
xcodebuild -project Dispatch.xcodeproj -scheme Dispatch -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  -only-testing:DispatchTests/InterfaceMotionTests \
  -only-testing:DispatchTests/MainMockupPresentationTests \
  -only-testing:DispatchTests/TerminalIntegrationTests \
  -only-testing:DispatchTests/ChatEndToEndTests \
  -only-testing:DispatchTests/ChatPresentationTests \
  -only-testing:DispatchTests/ChatPerformanceTests \
  -only-testing:DispatchTests/ChatHistoryTests \
  -only-testing:DispatchTests/ChatToolGroupingTests test
