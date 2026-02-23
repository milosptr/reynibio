#!/usr/bin/env bash
set -euo pipefail

# === ReyniBio Media Server — Hot Backup ===
# Backs up ./config/ and .env with SQLite-safe database dumps.
# Keeps the 5 most recent backups, prunes older ones.
#
# Usage:
#   bash backup.sh          # run manually
#   make backup             # via Makefile
#
# Cron example (daily at 3 AM):
#   0 3 * * * cd /path/to/reynibio-fresh-start && bash backup.sh >> backups/backup.log 2>&1

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
CONFIG_DIR="${SCRIPT_DIR}/config"
KEEP=5

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="reynibio-config-${TIMESTAMP}.tar.gz"

echo ""
echo -e "${GREEN}ReyniBio Backup${NC} — $(date)"
echo "─────────────────────────────────────"

# --- Validate source ---
if [[ ! -d "$CONFIG_DIR" ]]; then
    echo -e "${RED}Error: Config directory not found at ${CONFIG_DIR}${NC}"
    exit 1
fi

# --- Create backup directory ---
mkdir -p "$BACKUP_DIR"

# --- SQLite-safe database dumps ---
if command -v sqlite3 &>/dev/null; then
    echo "Creating SQLite-safe database dumps..."
    SQLITE_DUMPED=0
    while IFS= read -r db; do
        if sqlite3 "$db" ".backup '${db}.backup'" 2>/dev/null; then
            SQLITE_DUMPED=$((SQLITE_DUMPED + 1))
        fi
    done < <(find "$CONFIG_DIR" -name "*.db" -type f 2>/dev/null)
    echo -e "${GREEN}Dumped ${SQLITE_DUMPED} SQLite database(s) safely.${NC}"
else
    echo -e "${YELLOW}Warning: sqlite3 not found — backing up raw database files.${NC}"
    echo "Install sqlite3 for corruption-safe backups: apt-get install sqlite3"
fi

# --- Include .env in backup ---
ENV_INCLUDED=false
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    cp "${SCRIPT_DIR}/.env" "${CONFIG_DIR}/.env.backup"
    ENV_INCLUDED=true
fi

# --- Create backup ---
echo "Backing up config/ → backups/${BACKUP_FILE} ..."

if tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" -C "$SCRIPT_DIR" config/; then
    SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
    echo -e "${GREEN}Backup complete:${NC} ${BACKUP_FILE} (${SIZE})"
else
    echo -e "${RED}Error: Backup failed.${NC}"
    rm -f "${CONFIG_DIR}/.env.backup"
    find "$CONFIG_DIR" -name "*.db.backup" -delete 2>/dev/null
    exit 1
fi

# --- Cleanup temp files ---
if [[ "$ENV_INCLUDED" == true ]]; then
    rm -f "${CONFIG_DIR}/.env.backup"
    echo ".env included in backup."
fi
find "$CONFIG_DIR" -name "*.db.backup" -delete 2>/dev/null

# --- Verify backup integrity ---
echo "Verifying backup integrity..."
if tar -tzf "${BACKUP_DIR}/${BACKUP_FILE}" > /dev/null 2>&1; then
    echo -e "${GREEN}Integrity check: passed.${NC}"
else
    echo -e "${RED}Error: Backup archive is corrupt! Deleting bad file.${NC}"
    rm -f "${BACKUP_DIR}/${BACKUP_FILE}"
    exit 1
fi

# --- Prune old backups ---
BACKUP_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name 'reynibio-config-*.tar.gz' | wc -l)

if [[ "$BACKUP_COUNT" -gt "$KEEP" ]]; then
    PRUNE_COUNT=$((BACKUP_COUNT - KEEP))
    echo -e "${YELLOW}Pruning ${PRUNE_COUNT} old backup(s) (keeping ${KEEP})...${NC}"
    find "$BACKUP_DIR" -maxdepth 1 -name 'reynibio-config-*.tar.gz' -printf '%T+ %p\n' \
        | sort \
        | head -n "$PRUNE_COUNT" \
        | awk '{print $2}' \
        | xargs rm -f
    echo -e "${GREEN}Pruned.${NC}"
else
    echo "Backups on disk: ${BACKUP_COUNT}/${KEEP} (no pruning needed)."
fi

echo "─────────────────────────────────────"
echo -e "${GREEN}Done.${NC}"
echo ""
