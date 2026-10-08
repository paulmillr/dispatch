#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/mockup-review
swiftc -framework AppKit -framework WebKit scripts/render-mockups.swift -o build/mockup-review/render-mockups
build/mockup-review/render-mockups
