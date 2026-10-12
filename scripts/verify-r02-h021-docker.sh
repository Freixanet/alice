#!/usr/bin/env bash
# Synthetic SAME-HOST CI only. This does NOT prove independent administration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
EXTERNAL="${H021_EXTERNAL_APPROVED:-no}"
if [ "$EXTERNAL" = yes ]; then
  # This opt-in entry point is exclusively for an independently provisioned,
  # disposable Alice-administered Host B. Never invoke from CI/personal Hermes.
  test "${H021_INDEPENDENT_ADMIN_CONFIRMED:-}" = yes
  test "${H021_FIREWALL_REVIEWED:-}" = yes
  test -n "${H021_B_BIND_IP:-}"
  test -n "${H021_B_PUBLIC_IP:-}"
  python3 - "${H021_B_BIND_IP}" "${H021_B_PUBLIC_IP}" <<'PY'
import ipaddress,sys
for item in sys.argv[1:]:
    value=ipaddress.ip_address(item)
    if value.version != 4 or value.is_loopback or value.is_unspecified:
        raise SystemExit("two-host fixture requires approved non-loopback IPv4 addresses")
PY
elif [ "$EXTERNAL" != no ]; then
  echo "invalid H021_EXTERNAL_APPROVED; only yes/no" >&2; exit 2
fi
docker info >/dev/null 2>&1 || { echo "H021 Docker daemon unavailable" >&2; exit 2; }
command -v openssl >/dev/null
export H02_FIXTURE_DIR="$(mktemp -d -t alice-h021-fictional.XXXXXX)"
export H02_COMPOSE_PROJECT="alice-h021-$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
export H02_PUBLIC_BIND="${H021_B_BIND_IP:-127.0.0.1}"
export COMPOSE_PROJECT_NAME="$H02_COMPOSE_PROJECT"
chmod 700 "$H02_FIXTURE_DIR"
cleanup() {
  local status=$?
  if [ "$EXTERNAL" = yes ] && [ "$status" -eq 0 ]; then return; fi
  if [ "$status" -ne 0 ]; then
    docker compose -f deploy/h021/compose.yaml ps -a >&2 || true
    docker compose -f deploy/h021/compose.yaml logs --no-color --tail=30 asr gateway >&2 || true
  fi
  docker compose -f deploy/h021/compose.yaml --profile attack down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$H02_FIXTURE_DIR"
}
trap cleanup EXIT INT TERM
GATEWAY_SANS="DNS:gateway,IP:127.0.0.1"
if [ "$EXTERNAL" = yes ]; then
  GATEWAY_SANS="$GATEWAY_SANS,IP:$H021_B_BIND_IP,IP:$H021_B_PUBLIC_IP"
fi
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$H02_FIXTURE_DIR/asr.key" -out "$H02_FIXTURE_DIR/asr.pem" \
  -subj "/CN=asr" -addext "subjectAltName=DNS:asr,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$H02_FIXTURE_DIR/gateway.key" -out "$H02_FIXTURE_DIR/gateway.pem" \
  -subj "/CN=gateway" -addext "subjectAltName=$GATEWAY_SANS" >/dev/null 2>&1
mkdir -m 755 "$H02_FIXTURE_DIR/public"
openssl genpkey -algorithm Ed25519 -out "$H02_FIXTURE_DIR/issuer-private.pem" >/dev/null 2>&1
openssl pkey -in "$H02_FIXTURE_DIR/issuer-private.pem" -pubout \
  -out "$H02_FIXTURE_DIR/public/issuer.pub.pem" >/dev/null 2>&1
python3 - "$H02_FIXTURE_DIR" <<'PY'
import json,pathlib,secrets,sys
p=pathlib.Path(sys.argv[1])
for label in ("backend_coordinator_a","backend_coordinator_b","backend_human_a","backend_human_b"):
    (p/label).write_text(secrets.token_urlsafe(48))
(p/"device_hmac_hex").write_text(secrets.token_hex(32))
(p/"subjects.json").write_text(json.dumps({"test-user-a":{"actor":"a","tenant":"fixture-tenant-a","session":"fixture-session-a"}}))
(p/"public/public.json").write_text(json.dumps({"keys":{"h021-k1":"issuer.pub.pem"}}))
(p/"public/subjects.json").write_text((p/"subjects.json").read_text())
PY
chmod 600 "$H02_FIXTURE_DIR/issuer-private.pem"
# Test TLS keys are confined to a 0700 host fixture directory; container
# processes have distinct nonroot UIDs and need read access to their mounts.
chmod 644 "$H02_FIXTURE_DIR"/*.key
chmod 644 "$H02_FIXTURE_DIR/public/"*
python3 -m unittest discover -s tests -p 'test_h021_*.py' -v
docker compose -f deploy/h021/compose.yaml config --quiet
docker compose -f deploy/h021/compose.yaml --profile attack build --pull
docker compose -f deploy/h021/compose.yaml up -d --no-deps asr gateway
if [ "$EXTERNAL" = yes ]; then
  python3 -m scripts.h021_operator --prepare-remote
  cat > "$H02_FIXTURE_DIR/operator-session.env" <<EOF
H02_FIXTURE_DIR=$H02_FIXTURE_DIR
H02_COMPOSE_PROJECT=$H02_COMPOSE_PROJECT
H02_PUBLIC_BIND=$H02_PUBLIC_BIND
COMPOSE_PROJECT_NAME=$H02_COMPOSE_PROJECT
EOF
  chmod 600 "$H02_FIXTURE_DIR/operator-session.env"
  echo "H021 HOST B PREPARED (NOT VERIFIED TWO-HOST). PRIVATE fixture directory: $H02_FIXTURE_DIR"
  echo "Transfer ONLY gateway.pem, untrusted_one_use_proposal and remote_manifest.json to approved Host A."
  echo "Run scripts/h021_host_b_stop.sh with operator-session.env after the test."
else
  python3 -m scripts.h021_operator
  echo "H021 SAME-DOCKER-HOST SIGNED-BOUNDARY FIXTURE PASS; ADMINISTRATIVE SEPARATION PENDING"
fi
