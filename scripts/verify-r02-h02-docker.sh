#!/usr/bin/env bash
# H02 synthetic SAME-HOST integration only. For independent hosts, see docs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v docker >/dev/null || { echo "H02 NOT RUN: Docker unavailable" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "H02 NOT RUN: Docker daemon unavailable" >&2; exit 2; }
command -v openssl >/dev/null || { echo "H02 NOT RUN: OpenSSL unavailable" >&2; exit 2; }

export H02_FIXTURE_DIR="$(mktemp -d -t alice-h02-fictional.XXXXXX)"
export H02_COMPOSE_PROJECT="alice-h02-$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
export H02_PUBLIC_BIND=127.0.0.1
export COMPOSE_PROJECT_NAME="$H02_COMPOSE_PROJECT"
chmod 700 "$H02_FIXTURE_DIR"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    docker compose -f deploy/h02/compose.yaml ps -a >&2 || true
    docker compose -f deploy/h02/compose.yaml logs --no-color --tail=50 asr gateway >&2 || true
  fi
  docker compose -f deploy/h02/compose.yaml --profile attack down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$H02_FIXTURE_DIR"
}
trap cleanup EXIT INT TERM
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$H02_FIXTURE_DIR/asr.key" -out "$H02_FIXTURE_DIR/asr.pem" \
  -subj "/CN=asr" -addext "subjectAltName=DNS:asr,IP:127.0.0.1" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$H02_FIXTURE_DIR/gateway.key" -out "$H02_FIXTURE_DIR/gateway.pem" \
  -subj "/CN=gateway" -addext "subjectAltName=DNS:gateway,IP:127.0.0.1" >/dev/null 2>&1
python3 - "$H02_FIXTURE_DIR" <<'PY'
import json, pathlib, secrets, sys
p = pathlib.Path(sys.argv[1])
for name in ("backend_coordinator_a", "backend_coordinator_b", "backend_human_a", "backend_human_b"):
    (p / name).write_text(secrets.token_urlsafe(48))
(p / "device_hmac_hex").write_text(secrets.token_hex(32))
(p / "keyring.json").write_text(json.dumps({
    "active": "oct26", "keys": {"oct26": secrets.token_hex(32), "retired": secrets.token_hex(32)}}))
(p / "subjects.json").write_text(json.dumps({"test-user-a": {
    "actor": "a", "tenant": "fixture-tenant-a", "session": "fixture-session-a"}}))
PY
# Only random synthetic credentials, on disposable test host.
chmod 644 "$H02_FIXTURE_DIR"/*
python3 -m unittest discover -s tests -p 'test_h02_identity.py' -v
docker compose -f deploy/h02/compose.yaml config --quiet
docker compose -f deploy/h02/compose.yaml --profile attack build --pull
docker compose -f deploy/h02/compose.yaml up -d --no-deps asr gateway
python3 scripts/h02_operator.py e2e
echo "H02 SYNTHETIC SAME-HOST PASS (INDEPENDENT ADMIN HOST NOT ATTESTED)"
