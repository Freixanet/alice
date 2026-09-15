#!/usr/bin/env bash
#
# Run the Quality workflow locally with the installed prerequisites.
# Usage: scripts/ci-local.sh [all|verify|browser|ios]
# Local runs reuse dependencies; CI performs a clean npm install.
# Missing prerequisites fail explicitly.
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
  local hermes_python=${ALICE_HERMES_TEST_PYTHON:-"$HOME/.hermes/hermes-agent/venv/bin/python"}
  run "Hermes plugin tests" "$hermes_python" -m unittest discover -s hermes-plugin/tests
  run "Mac notifier tests" "$hermes_python" -m unittest discover -s mac/notifier
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
  run "iOS build and tests" bash scripts/verify-ios.sh all
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
