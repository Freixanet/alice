#!/bin/bash
# Portable contract checks + isolated macOS WebKit (no simulator, Hermes or models).
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir=$(mktemp -d /private/tmp/alice-openui-tests.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -module-cache-path "$work_dir/cache" \
  ios/Alice/Features/Chat/OpenIntelligentUI/InteractiveArtifact.swift \
  ios/Alice/Features/Chat/OpenIntelligentUI/InteractiveDocument.swift \
  tests/open-intelligent-ui/main.swift -o "$work_dir/probe"
"$work_dir/probe" "$PWD/ios/Alice/Resources/OpenIntelligentUI"
