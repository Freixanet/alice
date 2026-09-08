#!/usr/bin/env bash
#
# The Quality workflow, run here.
#
# GitHub bills private repositories for hosted runners, so while the account's
# payments are unsettled no job on .github/workflows/quality.yml starts at all
# — every push since has been red for that reason and not for anything in the
# code. This runs the same checks locally so pushing is still gated by
# something.
#
# It mirrors the workflow job for job. Where it cannot check something it says
# so and fails, rather than passing quietly: a gate that skips in silence is
# worse than no gate, because it is trusted.
#
#   scripts/ci-local.sh            verify + browser + ios   (everything)
#   scripts/ci-local.sh verify     the job that was failing (fast)
#   scripts/ci-local.sh ios        build + simulator tests
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
FAILED=()
STARTED=$(date +%s)

step() { printf "\n%s▸ %s%s\n" "$BOLD" "$1" "$OFF"; }

run() { # run <name> <command...>
  local name=$1; shift
  step "$name"
  if "$@"; then
    printf "%s  ✓ %s%s\n" "$GREEN" "$name" "$OFF"
  else
    printf "%s  ✗ %s%s\n" "$RED" "$name" "$OFF"
    FAILED+=("$name")
  fi
}

# The workflow pins Node 24. A pass on a different major is weaker evidence,
# so say which one this was.
node_note() {
  local have; have=$(node --version 2>/dev/null || echo "none")
  if [[ $have != v24* ]]; then
    printf "%s  ! Node %s here, the workflow pins 24 — a pass here is not a pass there.%s\n" \
      "$YELLOW" "$have" "$OFF"
  fi
}

job_verify() {
  node_note
  # gitleaks: native binary first, then the image the workflow uses. Neither
  # available is a failure, not a skip — this is the secret scan.
  step "gitleaks (secret scan)"
  if command -v gitleaks >/dev/null 2>&1; then
    if gitleaks detect --source=. --no-banner --redact; then
      printf "%s  ✓ gitleaks%s\n" "$GREEN" "$OFF"
    else
      printf "%s  ✗ gitleaks%s\n" "$RED" "$OFF"; FAILED+=("gitleaks")
    fi
  elif docker info >/dev/null 2>&1; then
    if docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:v8.28.0 \
         detect --source=/repo --no-banner --redact; then
      printf "%s  ✓ gitleaks (docker)%s\n" "$GREEN" "$OFF"
    else
      printf "%s  ✗ gitleaks (docker)%s\n" "$RED" "$OFF"; FAILED+=("gitleaks")
    fi
  else
    printf "%s  ✗ gitleaks unavailable — install it (brew install gitleaks) or start Docker.%s\n" \
      "$RED" "$OFF"
    FAILED+=("gitleaks (not run)")
  fi

  run "check:static" npm run --silent check:static
  run "security:check" npm run --silent security:check
  run "deps:check" npm run --silent deps:check
}

job_browser() {
  if [[ ! -d node_modules/@playwright ]] && ! npx --no playwright --version >/dev/null 2>&1; then
    printf "%s  ✗ Playwright is not installed — run: npx playwright install%s\n" "$RED" "$OFF"
    FAILED+=("test:e2e (not run)")
    return
  fi
  run "test:e2e" npm run --silent test:e2e
}

job_ios() {
  run "xcodegen" bash -c 'cd ios && xcodegen generate'

  # The workflow picks the first available iOS 26 iPhone; same choice here so a
  # simulator difference cannot explain a difference in result.
  local device
  device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, rows in json.load(sys.stdin)["devices"].items():
    if "iOS-26" not in runtime:
        continue
    for row in rows:
        if row.get("isAvailable") and row.get("name", "").startswith("iPhone"):
            print(row["udid"]); raise SystemExit
' 2>/dev/null)

  if [[ -z $device ]]; then
    printf "%s  ✗ No available iOS 26 iPhone simulator.%s\n" "$RED" "$OFF"
    FAILED+=("ios (no simulator)")
    return
  fi

  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device" -b >/dev/null 2>&1 || true

  run "iOS build" xcodebuild -project ios/Alice.xcodeproj -scheme Alice \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
  run "iOS tests" xcodebuild -project ios/Alice.xcodeproj -scheme Alice \
    -configuration Debug -destination "platform=iOS Simulator,id=$device" \
    CODE_SIGNING_ALLOWED=NO test
}

case "${1:-all}" in
  verify)  job_verify ;;
  browser) job_browser ;;
  ios)     job_ios ;;
  all)     job_verify; job_browser; job_ios ;;
  *) echo "usage: $0 [all|verify|browser|ios]" >&2; exit 2 ;;
esac

ELAPSED=$(( $(date +%s) - STARTED ))
printf "\n%s── %dm%02ds ──%s\n" "$BOLD" $((ELAPSED / 60)) $((ELAPSED % 60)) "$OFF"
if (( ${#FAILED[@]} )); then
  printf "%sFAILED: %s%s\n" "$RED" "${FAILED[*]}" "$OFF"
  exit 1
fi
printf "%sAll checks passed.%s\n" "$GREEN" "$OFF"
