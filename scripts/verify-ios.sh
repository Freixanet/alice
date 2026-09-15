#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODE=${1:-all}
case "$MODE" in unit|ui|all|build) ;; *) echo 'Usage: scripts/verify-ios.sh [unit|ui|all|build]' >&2; exit 2 ;; esac
command -v xcodegen >/dev/null || { echo 'Install XcodeGen before running iOS verification.' >&2; exit 1; }
(cd ios && xcodegen generate)

DERIVED=${ALICE_DERIVED_DATA_PATH:-"$PWD/ios/.build/DerivedData"}
ARGS=(-project ios/Alice.xcodeproj -scheme Alice -configuration Debug
  -sdk iphonesimulator
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO
  "CURRENT_PROJECT_VERSION=${GITHUB_RUN_NUMBER:-2}"
  "ALICE_SOURCE_REVISION=${GITHUB_SHA:-$(git rev-parse HEAD)}")

if [[ "$MODE" == build ]]; then
  xcodebuild "${ARGS[@]}" -destination 'generic/platform=iOS Simulator' build
  exit
fi

# Reuse only our dedicated simulator. A developer's ordinary simulator may
# contain real gateway credentials and must not be selected automatically.
SIMULATOR=${ALICE_SIMULATOR_ID:-}
if [[ -z "$SIMULATOR" ]]; then
  SIMULATOR=$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-26" in runtime:
        for device in devices:
            if device["name"] == "Alice Verification":
                print(device["udid"])
                raise SystemExit
')
fi
if [[ -z "$SIMULATOR" ]]; then
  RUNTIME=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
rows = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-26-")]
if not rows:
    raise SystemExit("Install an iOS 26 simulator runtime in Xcode.")
rows.sort(key=lambda r: tuple(int(p) for p in r["version"].split(".")))
print(rows[-1]["identifier"])
')
  SIMULATOR=$(xcrun simctl create 'Alice Verification' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$RUNTIME")
fi

xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR" -b
case "$MODE" in
  unit) ARGS+=(-only-testing:AliceTests) ;;
  ui) ARGS+=(-only-testing:AliceUITests) ;;
esac
xcodebuild "${ARGS[@]}" -destination "platform=iOS Simulator,id=$SIMULATOR" \
  -destination-timeout 180 \
  -parallel-testing-enabled NO test
