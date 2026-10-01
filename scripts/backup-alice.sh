#!/usr/bin/env bash
# Alice backup — creates a timestamped tarball of critical Alice/Hermes data.
#
# Usage:
#   bash scripts/backup-alice.sh
#
# Stores backups in ~/.hermes/backups/. Retains the last 7 backups.
# Safe: does not include logs, caches, or temporary files.

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
BACKUP_DIR="$HERMES_HOME/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/alice-backup-$TIMESTAMP.tar.gz"
ALICE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$BACKUP_DIR"

echo "Backing up Alice/Hermes data to $BACKUP_FILE"

# Create a list of paths to back up
INCLUDE=()

# Hermes home (profiles, sessions, memory, vault, config)
if [ -d "$HERMES_HOME" ]; then
  INCLUDE+=("$HERMES_HOME")
  echo "  Including: $HERMES_HOME"
else
  echo "  WARNING: $HERMES_HOME does not exist"
fi

# Alice plugin (if not already in hermes home)
PLUGIN_DIR="$HERMES_HOME/plugins/alice"
if [ -d "$PLUGIN_DIR" ]; then
  echo "  Plugin: included in hermes home"
fi

# Alice repo uncommitted changes (git stash list and diff)
if command -v git >/dev/null 2>&1 && [ -d "$ALICE_ROOT/.git" ]; then
  GIT_DIFF=$(cd "$ALICE_ROOT" && git diff 2>/dev/null || true)
  if [ -n "$GIT_DIFF" ]; then
    echo "$GIT_DIFF" > "$BACKUP_DIR/alice-uncommitted-$TIMESTAMP.diff"
    echo "  Saved uncommitted changes to alice-uncommitted-$TIMESTAMP.diff"
  fi
  # Save git stash list
  (cd "$ALICE_ROOT" && git stash list 2>/dev/null || true) > "$BACKUP_DIR/alice-stashes-$TIMESTAMP.txt"
fi

# Create the tarball
if [ ${#INCLUDE[@]} -gt 0 ]; then
  tar --exclude='*.log' \
      --exclude='*.cache' \
      --exclude='__pycache__' \
      --exclude='.git' \
      --exclude='node_modules' \
      --exclude='.build' \
      --exclude='DerivedData' \
      -czf "$BACKUP_FILE" \
      "${INCLUDE[@]}" 2>/dev/null || true

  SIZE=$(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1)
  echo "  Backup created: $BACKUP_FILE ($SIZE)"
else
  echo "  Nothing to back up."
  exit 0
fi

# Retention: keep the last 7 backups
cd "$BACKUP_DIR"
ls -t alice-backup-*.tar.gz 2>/dev/null | tail -n +8 | while read -r old; do
  rm -f "$old"
  echo "  Removed old backup: $old"
done

# Also clean up old diff/stash files
ls -t alice-uncommitted-*.diff 2>/dev/null | tail -n +8 | while read -r old; do
  rm -f "$old"
done
ls -t alice-stashes-*.txt 2>/dev/null | tail -n +8 | while read -r old; do
  rm -f "$old"
done

echo ""
echo "Backup complete. $BACKUP_FILE"
echo ""
echo "To restore: tar -xzf $BACKUP_FILE -C /"
