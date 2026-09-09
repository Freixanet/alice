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
# It mirrors the workflow's checks while reusing the dependencies already
# installed in this checkout so the pre-push gate stays fast. GitHub remains
# the clean-install authority (`npm ci` + fresh Playwright browsers). Where a
# local prerequisite is missing, this fails rather than pretending it ran.
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

node_supported() {
  local version major minor
  version=$(node -p 'process.versions.node' 2>/dev/null) || return 1
  IFS=. read -r major minor _ <<<"$version"
  (( major >= 24 || (major == 22 && minor >= 13) ))
}

# The shell used to push Alice currently exposes Node 23, which the project
# explicitly does not support. Prefer an already-installed NVM Node when the
# ambient one is outside package.json's engine range; never download from a
# hook or silently bless an unsupported runtime.
prepare_node() {
  if ! node_supported; then
    local nvm_dir=${NVM_DIR:-"$HOME/.nvm"}
    if [[ -s "$nvm_dir/nvm.sh" ]]; then
      export NVM_DIR="$nvm_dir"
      # `--no-use` avoids NVM's default (which may itself be unsupported).
      # shellcheck disable=SC1090
      . "$NVM_DIR/nvm.sh" --no-use
      local candidate resolved
      for candidate in 24 22; do
        resolved=$(nvm version "$candidate" 2>/dev/null || true)
        if [[ -n $resolved && $resolved != N/A ]]; then
          nvm use --silent "$resolved" >/dev/null 2>&1 || true
          node_supported && break
        fi
      done
    fi
  fi

  if ! node_supported; then
    local have; have=$(node --version 2>/dev/null || echo "none")
    printf "%s  ✗ Unsupported Node %s. Alice requires ^22.13.0 or >=24.0.0.%s\n" \
      "$RED" "$have" "$OFF"
    FAILED+=("supported Node runtime")
    return 1
  fi

  local have; have=$(node --version)
  if [[ $have == v24* ]]; then
    printf "  Node %s (matches CI)\n" "$have"
  else
    printf "%s  Node %s (supported locally; CI still verifies Node 24).%s\n" \
      "$YELLOW" "$have" "$OFF"
  fi
}

job_verify() {
  prepare_node || return
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
  prepare_node || return
  if [[ ! -x node_modules/.bin/playwright ]]; then
    printf "%s  ✗ Playwright package is not installed — run: npm ci%s\n" "$RED" "$OFF"
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
