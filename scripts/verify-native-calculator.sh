#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work_dir=$(mktemp -d /private/tmp/alice-native-tests.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT
xcrun swiftc -swift-version 6 -module-cache-path "$work_dir/cache" \
  ios/Alice/Features/Chat/GenerativeUI/NativeCalculator.swift \
  ios/Alice/Features/Chat/GenerativeUI/UIComponent.swift \
  tests/native-calculator/main.swift -o "$work_dir/probe"
"$work_dir/probe" "$PWD/ios/Alice/Resources/OpenIntelligentUI/native-calculator-demos.json" "$PWD/hermes-plugin/skills/openintelligentui/SKILL.md"
