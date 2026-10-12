#!/usr/bin/env bash
# Hosted Isolation Proof — ephemeral local Docker/CI lab, never production.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v docker >/dev/null || { echo 'H01 NOT VERIFIED: no docker binary' >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo 'H01 NOT VERIFIED: Docker daemon unavailable' >&2; exit 2; }
command -v openssl >/dev/null || { echo 'H01 NOT VERIFIED: openssl unavailable' >&2; exit 2; }

H01_FIXTURE_DIR="$(mktemp -d -t alice-h01-fictional.XXXXXX)"
export H01_FIXTURE_DIR
chmod 700 "$H01_FIXTURE_DIR"
cleanup() {
  docker compose -f deploy/h01/compose.yaml --profile attack down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$H01_FIXTURE_DIR"
}
trap cleanup EXIT INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$H01_FIXTURE_DIR/asr.key" -out "$H01_FIXTURE_DIR/asr.pem" \
  -subj '/CN=asr' -addext 'subjectAltName=DNS:asr,DNS:localhost,IP:127.0.0.1' \
  >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$H01_FIXTURE_DIR/gateway.key" -out "$H01_FIXTURE_DIR/gateway.pem" \
  -subj '/CN=gateway' -addext 'subjectAltName=DNS:gateway,DNS:localhost,IP:127.0.0.1' \
  >/dev/null 2>&1

python3 - "$H01_FIXTURE_DIR" <<'PY'
import pathlib, secrets, sys
p = pathlib.Path(sys.argv[1])
for name in ('backend_coordinator_a','backend_coordinator_b',
             'backend_human_a','backend_human_b',
             'owner_a','owner_b','proposal_a','proposal_b','human_a','human_b'):
    (p / name).write_text(secrets.token_urlsafe(48))
(p / 'device_hmac_hex').write_text(secrets.token_hex(32))
PY
# Root-managed bind mounts inside disposable containers need the nonroot
# service UID to READ its own synthetic fixture files. Fixture dir is mode 0700
# and is deleted after the test; real hosted secrets use a managed secret store.
chmod 644 "$H01_FIXTURE_DIR"/*

docker compose -f deploy/h01/compose.yaml config --quiet
docker compose -f deploy/h01/compose.yaml --profile attack build --pull
docker compose -f deploy/h01/compose.yaml up -d --no-deps asr gateway
python3 scripts/h01_operator.py e2e
echo 'H01 SYNTHETIC CONTAINER BOUNDARY: test operator completed; teardown follows'
