#!/usr/bin/env bash
# Alice Doctor — system health diagnostic
#
# Answers: "Is Alice healthy right now? If not, which layer is failing?"
#
# Usage:
#   bash scripts/alice-doctor.sh
#
# Safe to share: never prints keys, tokens, credentials, or private content.
# Exit code: 0 = healthy or degraded, 1 = broken (at least one critical check failed).
#
# This script checks infrastructure availability (ports listening, services
# loaded, files present). It does NOT authenticate to the gateway or dashboard
# because those require credentials that must not be printed or probed.

set -uo pipefail

PASS=0
WARN=0
FAIL=0

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
ALICE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()      { echo "[OK]        $1  $2"; PASS=$((PASS + 1)); }
degraded(){ echo "[DEGRADED]  $1  $2"; WARN=$((WARN + 1)); }
fail()    { echo "[FAIL]      $1  $2"; FAIL=$((FAIL + 1)); }
skip()    { echo "[SKIP]      $1  $2"; }

echo "=== Alice Doctor ==="
echo "Root: $ALICE_ROOT"
echo "Hermes home: $HERMES_HOME"
echo ""

# --- Node.js ---
if command -v node >/dev/null 2>&1; then
  NODE_VER=$(node --version 2>/dev/null)
  NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v//' | cut -d. -f1)
  if [ "$NODE_MAJOR" -ge 22 ]; then
    ok "node" "$NODE_VER"
  else
    fail "node" "Node.js 22.13+ required, found $NODE_VER"
  fi
else
  fail "node" "Node.js not found"
fi

# --- npm ---
if command -v npm >/dev/null 2>&1; then
  NPM_VER=$(npm --version 2>/dev/null)
  NPM_MAJOR=$(echo "$NPM_VER" | cut -d. -f1)
  if [ "$NPM_MAJOR" -ge 11 ]; then
    ok "npm" "$NPM_VER"
  else
    fail "npm" "npm 11+ required, found $NPM_VER"
  fi
else
  fail "npm" "npm not found"
fi

# --- XcodeGen (for iOS builds) ---
if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen" "found"
else
  degraded "xcodegen" "not installed (needed for iOS builds)"
fi

# --- Hermes CLI ---
if command -v hermes >/dev/null 2>&1; then
  ok "hermes" "Hermes CLI found"
else
  fail "hermes" "Hermes command not found. Install Hermes 0.21.x first."
fi

# --- Gateway port ---
# The gateway requires Bearer auth, so we check if the port is listening
# rather than probing an API endpoint. Main profile uses ports 8643+;
# bot gateways use 8642.
GATEWAY_PORT=""
if command -v lsof >/dev/null 2>&1; then
  for port in $(seq 8642 8670); do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      GATEWAY_PORT=$port
      break
    fi
  done
  if [ -n "$GATEWAY_PORT" ]; then
    ok "gateway" "port $GATEWAY_PORT is listening"
  else
    fail "gateway" "no gateway port listening (checked 8642-8670)"
  fi
elif command -v nc >/dev/null 2>&1; then
  for port in $(seq 8642 8670); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      GATEWAY_PORT=$port
      break
    fi
  done
  if [ -n "$GATEWAY_PORT" ]; then
    ok "gateway" "port $GATEWAY_PORT is listening"
  else
    fail "gateway" "no gateway port listening (checked 8642-8670)"
  fi
else
  skip "gateway" "cannot check ports (lsof and nc not available)"
fi

# --- Dashboard ---
# The dashboard requires username+password session auth, so we check if
# port 9119 is listening rather than probing an API endpoint.
DASHBOARD_PORT=9119
DASHBOARD_LISTENING=""
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$DASHBOARD_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    DASHBOARD_LISTENING=1
  fi
elif command -v nc >/dev/null 2>&1; then
  if nc -z 127.0.0.1 "$DASHBOARD_PORT" 2>/dev/null; then
    DASHBOARD_LISTENING=1
  fi
fi
if [ -n "$DASHBOARD_LISTENING" ]; then
  ok "dashboard" "port $DASHBOARD_PORT is listening"
else
  # Check launchd service
  SERVICE="gui/$(id -u)/ai.hermes.dashboard"
  if launchctl print "$SERVICE" >/dev/null 2>&1; then
    degraded "dashboard" "service loaded but port $DASHBOARD_PORT not listening"
  else
    fail "dashboard" "not running (launchd service not found, port $DASHBOARD_PORT not listening)"
  fi
fi

# --- Alice plugin ---
PLUGIN_DIR="$HERMES_HOME/plugins/alice"
if [ -d "$PLUGIN_DIR" ] && [ -f "$PLUGIN_DIR/dashboard/plugin_api.py" ]; then
  ok "plugin" "installed at $PLUGIN_DIR"
  # Check if enabled
  if command -v hermes >/dev/null 2>&1; then
    if hermes plugins list 2>/dev/null | grep -q "alice"; then
      ok "plugin" "enabled in Hermes"
    else
      degraded "plugin" "installed but not enabled (run: hermes plugins enable alice)"
    fi
  fi
else
  fail "plugin" "not installed (run: hermes-plugin/install.sh)"
fi

# --- Notifier ---
NOTIFIER_LABEL="com.freixanet.alice.notifier"
if launchctl print "gui/$(id -u)/$NOTIFIER_LABEL" >/dev/null 2>&1; then
  ok "notifier" "LaunchAgent loaded"
else
  degraded "notifier" "not loaded (optional, run: mac/notifier/install.sh)"
fi

# --- Web dependencies ---
if [ -d "$ALICE_ROOT/node_modules" ]; then
  ok "web-deps" "node_modules present"
else
  degraded "web-deps" "node_modules missing (run: npm ci)"
fi

# --- Migrations ---
MIGRATIONS_DIR="$ALICE_ROOT/migrations"
if [ -d "$MIGRATIONS_DIR" ]; then
  MIGRATION_COUNT=$(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | wc -l)
  if [ "$MIGRATION_COUNT" -gt 0 ]; then
    ok "migrations" "$MIGRATION_COUNT migration file(s) present"
  else
    degraded "migrations" "no migration files found"
  fi
else
  degraded "migrations" "migrations directory not found"
fi

# --- Tailscale (if expected) ---
if command -v tailscale >/dev/null 2>&1; then
  TS_STATUS=$(tailscale status 2>&1 || true)
  if echo "$TS_STATUS" | grep -q "stopped"; then
    degraded "tailscale" "installed but stopped"
  else
    ok "tailscale" "running"
  fi
else
  skip "tailscale" "not installed (skip if not using Tailscale)"
fi

# --- Disk space ---
DISK_AVAIL=$(df -k "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')
if [ -n "$DISK_AVAIL" ]; then
  DISK_GB=$((DISK_AVAIL / 1048576))
  if [ "$DISK_GB" -ge 5 ]; then
    ok "disk-space" "${DISK_GB} GB available"
  else
    degraded "disk-space" "only ${DISK_GB} GB free (recommend 5+ GB)"
  fi
else
  skip "disk-space" "cannot determine"
fi

# --- CDP port (should not be in use by tests) ---
if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:9222 -sTCP:LISTEN >/dev/null 2>&1; then
    degraded "cdp-port" "port 9222 in use (do not test in shared agent browser)"
  else
    ok "cdp-port" "port 9222 free"
  fi
fi

# --- Production env checks (only if NODE_ENV=production) ---
if [ "${NODE_ENV:-}" = "production" ] || [ -n "${VERCEL:-}" ]; then
  if [ -z "${BETTER_AUTH_SECRET:-}" ] || [ ${#BETTER_AUTH_SECRET} -lt 32 ]; then
    fail "env-config" "BETTER_AUTH_SECRET missing or too short (production)"
  else
    ok "env-config" "BETTER_AUTH_SECRET set"
  fi
  if [ -z "${DATABASE_URL:-}" ]; then
    fail "env-config" "DATABASE_URL missing (production requires it)"
  else
    ok "env-config" "DATABASE_URL set"
  fi
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  OK:        $PASS"
echo "  DEGRADED:  $WARN"
echo "  FAIL:      $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "Status: BROKEN"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "Status: DEGRADED"
  exit 0
else
  echo "Status: HEALTHY"
  exit 0
fi
