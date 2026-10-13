#!/bin/zsh
# Install the Alice plugin without modifying the live copy until staging succeeds.
# A previous installation is retained under HERMES_HOME/backups for recovery.
set -euo pipefail
umask 077

here=${0:A:h}
hermes_home=${HERMES_HOME:-$HOME/.hermes}
plugins_dir=$hermes_home/plugins
dest=$plugins_dir/alice
config=$hermes_home/config.yaml
transaction=''
backup=''
old_moved=0
old_swapped=0
swap_intent=0
fresh_intent=0
new_moved=0
config_started=0
had_config=0
services_started=0
gateway_restarted=0
complete=0
lock_owned=0
restore_failed=0
lock_dir=$plugins_dir/.alice-install.lock

# The macOS GUI service labels are global to the logged-in user, not scoped
# by HERMES_HOME. Never restart them when installing to a throwaway or another
# user's Hermes home. File-only installation remains supported in that case.
restart_services=0
# $HOME is caller-controlled; use the OS account record, not that variable,
# before touching fixed launchctl labels belonging to the logged-in user.
canonical_home=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
if [[ ${hermes_home:A} == ${canonical_home:A}/.hermes ]]; then
  restart_services=1
fi

if ! command -v hermes >/dev/null; then
  print -u2 'The hermes command was not found. Install Hermes first.'
  exit 1
fi
if [[ -L $hermes_home || -L $plugins_dir || -L $hermes_home/backups ]]; then
  print -u2 'Refusing a symlink in Hermes home, plugins or backup directory.'
  exit 1
fi
if [[ -L $dest || ( -e $dest && ! -d $dest ) ]]; then
  print -u2 "Refusing to replace a non-directory or symlink: $dest"
  exit 1
fi
if [[ -L $config || ( -e $config && ! -f $config ) ]]; then
  print -u2 "Refusing to replace a non-file or symlink config: $config"
  exit 1
fi

# Exchange two directories without a moment when plugins/alice disappears.
# Both live and staged directories are under plugins/, on the same filesystem.
swap_dirs() {
  "$python" - "$1" "$2" <<'PY'
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)
if sys.platform == 'darwin':
    rename = libc.renameatx_np
    at_fdcwd = -2
else:
    # Linux hosts with renameat2 also support a directory exchange.
    rename = libc.renameat2
    at_fdcwd = -100
rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int
result = rename(at_fdcwd, os.fsencode(sys.argv[1]), at_fdcwd, os.fsencode(sys.argv[2]), 2)
if result != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
PY
}

cleanup() {
  local exit_code=$1
  trap - EXIT HUP INT TERM
  set +e
  if (( ! complete && exit_code != 0 )); then
    if (( (swap_intent && ! old_swapped) || (fresh_intent && ! new_moved) )); then
      # The kernel exchange may have completed even if its userspace caller
      # was interrupted before acknowledging it. NEVER delete the recovery
      # copy in transaction/new when the result is uncertain.
      restore_failed=1
      print -u2 "RESTORE REQUIRED: atomic swap outcome uncertain; preserve $transaction and $lock_dir"
    elif (( old_swapped )); then
      if ! swap_dirs "$transaction/new" "$dest"; then
        restore_failed=1
        print -u2 "RESTORE REQUIRED: original plugin is at $transaction/new; recovery details: $lock_dir"
      fi
    elif (( new_moved )); then
      rm -rf -- "$dest" || {
        restore_failed=1
        print -u2 "Could not remove new installation: $dest"
      }
    fi
    if (( config_started )); then
      if (( had_config )); then
        local config_restore=$hermes_home/.alice-config-restore.$$
        if ! cp -p -- "$transaction/config.before" "$config_restore" || ! mv -f -- "$config_restore" "$config"; then
          restore_failed=1
          print -u2 "RESTORE REQUIRED: Hermes config could not be restored: $config"
        fi
        rm -f -- "$config_restore"
      else
        rm -f -- "$config" || {
          restore_failed=1
          print -u2 "RESTORE REQUIRED: remove $config created by the failed install"
        }
      fi
    fi
    # A restarted gateway must reload the restored plugin before the dashboard.
    if (( services_started )); then
      for name in ai.hermes.gateway ai.hermes.dashboard; do
        local service=gui/$(id -u)/$name
        if launchctl print "$service" >/dev/null 2>&1; then
          launchctl kickstart -k "$service" >/dev/null 2>&1 || print -u2 "Restart $name after restoring the plugin"
        fi
      done
    fi
    if (( old_moved || new_moved || config_started || services_started )); then
      print -u2 'Alice installation failed; the previous plugin and configuration were restored where possible.'
    fi
  fi
  if (( ! restore_failed )); then
    [[ -n $transaction && -d $transaction ]] && rm -rf -- "$transaction"
  fi
  [[ -n $backup && -d $backup && ! -e $backup/alice ]] && rmdir -- "$backup" 2>/dev/null
  if (( lock_owned && ! restore_failed )); then
    rm -f -- "$lock_dir/owner" "$lock_dir/recovery" "$lock_dir/swap-intent" "$lock_dir/fresh-intent"
    rmdir -- "$lock_dir" || print -u2 "Could not release installer lock: $lock_dir"
  fi
  return "$exit_code"
}
trap 'cleanup $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "$plugins_dir" "$hermes_home/backups"
if ! mkdir -- "$lock_dir" 2>/dev/null; then
  print -u2 "Another or interrupted Alice install has a lock at $lock_dir; inspect it before retrying."
  exit 1
fi
lock_owned=1
print -r -- "$$" > "$lock_dir/owner"
transaction=$(mktemp -d "$plugins_dir/.alice-install.XXXXXX")
stage=$transaction/new
mkdir -- "$stage"
cp -R -- "$here/." "$stage/"
if [[ -n $(find "$stage" -type l -print -quit) ]]; then
  print -u2 'Refusing symlinks in the Alice plugin distribution.'
  exit 1
fi

python=$hermes_home/hermes-agent/venv/bin/python
[[ -x $python ]] || python=$(command -v python3)

# Validate both Hermes manifests and all dashboard entrypoints before touching
# an enabled installation. The Hermes environment supplies its YAML reader.
"$python" - "$stage" <<'PY'
import json
from pathlib import Path
import sys

try:
    import hermes_yaml as yaml
except ImportError:
    import yaml

root = Path(sys.argv[1])
plugin = yaml.safe_load((root / 'plugin.yaml').read_text(encoding='utf-8'))
dashboard = json.loads((root / 'dashboard/manifest.json').read_text(encoding='utf-8'))
if not isinstance(plugin, dict) or not isinstance(dashboard, dict):
    raise SystemExit('Invalid Alice manifest structure')
if plugin.get('name') != 'alice' or dashboard.get('name') != 'alice':
    raise SystemExit('Unexpected Alice plugin name')
if not plugin.get('version') or plugin['version'] != dashboard.get('version'):
    raise SystemExit('Plugin and dashboard versions do not match')
if plugin.get('kind') != 'standalone':
    raise SystemExit('Expected a standalone Hermes plugin')
for key in ('provides_tools', 'provides_hooks'):
    declared = plugin.get(key)
    if not isinstance(declared, list) or not declared or any(not isinstance(item, str) or not item for item in declared):
        raise SystemExit(f'Invalid {key} declaration')
    if len(declared) != len(set(declared)):
        raise SystemExit(f'Duplicate {key} declarations')
for key in ('entry', 'api'):
    relative = dashboard.get(key)
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise SystemExit(f'Invalid dashboard {key}')
    if not (root / 'dashboard' / relative).is_file():
        raise SystemExit(f'Missing dashboard {key}: {relative}')
if not (root / '__init__.py').is_file() or not (root / 'skills/comprar/SKILL.md').is_file():
    raise SystemExit('Incomplete Alice plugin distribution')
PY

# Optional pypdf is installed only into the staged plugin, never into Hermes'
# runtime or the currently enabled Alice plugin. Retain the previous vendor
# folder on an update if this optional dependency cannot be refreshed.
if [[ -L $dest/vendor ]]; then
  print -u2 'Refusing a symlink at the existing plugin vendor directory.'
  exit 1
fi
if [[ -d $dest/vendor ]]; then
  cp -R -- "$dest/vendor" "$stage/vendor"
fi
if [[ -n $(find "$stage" -type l -print -quit) ]]; then
  print -u2 'Refusing symlinks in the staged plugin vendor directory.'
  exit 1
fi
mkdir -- "$transaction/pypdf"
if ! "$python" -m pip install --quiet --upgrade --target "$transaction/pypdf" 'pypdf==6.18.0'; then
  print -u2 'Could not install pypdf; PDF forms may need it. Keeping the previous vendor if present.'
else
  if [[ -n $(find "$transaction/pypdf" -type l -print -quit) ]]; then
    print -u2 'Refusing symlinks in the downloaded plugin dependency.'
    exit 1
  fi
  mkdir -p -- "$stage/vendor"
  cp -R -- "$transaction/pypdf/." "$stage/vendor/"
fi
chmod -R u+w "$stage/skills"
chmod a-w "$stage/skills"/*/SKILL.md

# Save configuration before enabling: Hermes may update it in both CLI calls.
if [[ -f $config ]]; then
  cp -p -- "$config" "$transaction/config.before"
  had_config=1
fi
current=$("$python" - "$config" <<'PY'
import sys
try:
    import hermes_yaml as yaml
except ImportError:
    import yaml
try:
    with open(sys.argv[1], encoding='utf-8') as source:
        cfg = yaml.safe_load(source) or {}
except FileNotFoundError:
    cfg = {}
if not isinstance(cfg, dict):
    raise SystemExit('Invalid Hermes config')
skills = cfg.get('skills') or {}
if not isinstance(skills, dict):
    raise SystemExit('Invalid Hermes skills config')
external_dirs = skills.get('external_dirs') or []
if not isinstance(external_dirs, list):
    raise SystemExit('Invalid Hermes external_dirs config')
print('\n'.join(str(directory) for directory in external_dirs))
PY
)

if [[ -d $dest ]]; then
  backup=$(mktemp -d "$hermes_home/backups/alice-$(date +%Y%m%d-%H%M%S).XXXXXX")
  print -r -- "$transaction/new" > "$lock_dir/recovery"
  print -r -- 'swap-started' > "$lock_dir/swap-intent"
  swap_intent=1
  if ! swap_dirs "$stage" "$dest"; then
    print -u2 'Atomic directory exchange not acknowledged; inspect recovery journal before retrying.'
    exit 1
  fi
  old_swapped=1
  new_moved=1
else
  print -r -- 'fresh-started' > "$lock_dir/fresh-intent"
  fresh_intent=1
  mv -- "$stage" "$dest"
  new_moved=1
fi

config_started=1
hermes plugins enable alice --no-allow-tool-override
if [[ -z $current ]]; then
  hermes config set skills.external_dirs "[\"$dest/skills\"]" >/dev/null
elif ! print -r -- "$current" | grep -qF 'plugins/alice/skills'; then
  print -u2 "Add $dest/skills to skills.external_dirs in Hermes' config to see Alice's skills in the list."
fi

# The gateway loads the Python plugin. Restart it before the dashboard so the
# latter does not expose an interface backed by stale plugin code.
if (( restart_services )); then
  for name in ai.hermes.gateway ai.hermes.dashboard; do
    service=gui/$(id -u)/$name
    if launchctl print "$service" >/dev/null 2>&1; then
      services_started=1
      launchctl kickstart -k "$service"
      if [[ $name == ai.hermes.gateway ]]; then
        gateway_restarted=1
        ready=0
        for attempt in {1..10}; do
          if launchctl print "$service" 2>/dev/null | grep -q 'state = running'; then
            ready=1
            break
          fi
          sleep 1
        done
        if (( ! ready )); then
          print -u2 'Hermes gateway did not reach the running state.'
          exit 1
        fi
        # launchctl running does not attest to API health/authentication.
      fi
    fi
  done
else
  print 'Hermes services NOT restarted: HERMES_HOME is not the current user default.'
fi

if (( old_swapped )); then
  # Copy, rather than cross-filesystem mv, so an interrupted backup cannot
  # consume the only rollback source in the same-filesystem transaction/new.
  cp -R -- "$stage" "$backup/alice"
  if ! diff -rq "$stage" "$backup/alice" >/dev/null; then
    print -u2 'Backup verification failed; restoring the old plugin.'
    exit 1
  fi
  old_moved=1
fi
complete=1
print 'Alice plugin files installed. R02 authenticated pairing/control plane remains NO-GO for real purchases and payments.'
if (( gateway_restarted )); then
  print 'launchctl reported a running gateway process; API health and authentication have not been verified.'
fi
if (( old_moved )); then
  print "Previous plugin backup: $backup/alice"
fi
