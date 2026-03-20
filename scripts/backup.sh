#!/usr/bin/env bash
# Backup Taguette PostgreSQL database from production VPS
# Usage: ./scripts/backup.sh [output_dir]
#
# Creates: backups/YYYY-MM-DD_HHMMSS_taguette.dump
# Format: pg_dump custom format (compressed, supports partial restore)
set -euo pipefail

REMOTE_HOST="vps"
REMOTE_DIR="~/repos/taguette"
BACKUP_DIR="${1:-./backups}"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
FILENAME="${TIMESTAMP}_taguette.dump"

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

step() { echo -e "\n${BOLD}==> $1${RESET}"; }
ok()   { echo -e "${GREEN}    ✓ $1${RESET}"; }
warn() { echo -e "${YELLOW}    ! $1${RESET}"; }

mkdir -p "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# 1. Dump on remote via Docker exec, stream to local
# ---------------------------------------------------------------------------
step "Dumping PostgreSQL on ${REMOTE_HOST}"

ssh "$REMOTE_HOST" bash <<EOF | gzip > "${BACKUP_DIR}/${FILENAME}.gz"
set -euo pipefail
cd ${REMOTE_DIR}
PGPASSWORD=\$(cat secrets/postgres_password.txt) \
docker compose exec -T postgres \
    pg_dump -U taguette -d taguette --format=plain --no-privileges --no-owner
EOF

SIZE=$(du -sh "${BACKUP_DIR}/${FILENAME}.gz" | cut -f1)
ok "Saved: ${BACKUP_DIR}/${FILENAME}.gz (${SIZE})"

# ---------------------------------------------------------------------------
# 2. Prune backups older than 30 days
# ---------------------------------------------------------------------------
step "Pruning backups older than 30 days"
DELETED=$(find "$BACKUP_DIR" -name "*.dump.gz" -mtime +30 -print -delete | wc -l)
if [ "$DELETED" -gt 0 ]; then
    warn "Deleted ${DELETED} old backup(s)"
else
    ok "Nothing to prune"
fi

echo -e "\n${GREEN}${BOLD}Backup complete: ${BACKUP_DIR}/${FILENAME}.gz${RESET}"
