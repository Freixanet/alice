#!/usr/bin/env bash
# Controlled teardown of ONE explicitly recorded test project, never global.
set -euo pipefail
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: bash scripts/h021_host_b_stop.sh /path/to/operator-session.env" >&2; exit 2
fi
session="$(python3 - "$1" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]).resolve()
if p.name != "operator-session.env" or p.parent.name == "":
    raise SystemExit("not a known H021 session manifest")
d={}
for line in p.read_text().splitlines():
    k,sep,v=line.partition("=")
    if sep != "=" or k not in {"H02_FIXTURE_DIR","H02_COMPOSE_PROJECT","H02_PUBLIC_BIND","COMPOSE_PROJECT_NAME"}:
        raise SystemExit("unexpected session data")
    d[k]=v
if set(d)!={"H02_FIXTURE_DIR","H02_COMPOSE_PROJECT","H02_PUBLIC_BIND","COMPOSE_PROJECT_NAME"}:
    raise SystemExit("incomplete session")
if p.parent != pathlib.Path(d["H02_FIXTURE_DIR"]).resolve() or not d["H02_COMPOSE_PROJECT"].startswith("alice-h021-"):
    raise SystemExit("session/project mismatch")
print("\n".join(f"{k}={v}" for k,v in d.items()))
PY
)"
while IFS='=' read -r key value; do
  case "$key" in
    H02_FIXTURE_DIR|H02_COMPOSE_PROJECT|H02_PUBLIC_BIND|COMPOSE_PROJECT_NAME) export "$key=$value" ;;
    *) echo "invalid session key" >&2; exit 2;;
  esac
done <<< "$session"
cd "$(dirname "$0")/.."
docker compose -f deploy/h021/compose.yaml --profile attack down --volumes --remove-orphans
if docker compose -f deploy/h021/compose.yaml ps -q | grep -q .; then
  echo "H021 containers remain; keep private files for recovery" >&2; exit 1
fi
# Only images tagged with this uniquely recorded disposable Compose project.
for image in runner gateway hostile; do
  docker image rm "${H02_COMPOSE_PROJECT}-${image}:fixture" >/dev/null 2>&1 || true
done
python3 - "$H02_FIXTURE_DIR" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1]).resolve()
if not p.name.startswith("alice-h021-fictional.") or p.is_symlink():
    raise SystemExit("refuse arbitrary fixture deletion")
shutil.rmtree(p)
PY
echo "H021 test containers, volumes and fixture directory removed (cloud VM deletion must be verified separately)"
