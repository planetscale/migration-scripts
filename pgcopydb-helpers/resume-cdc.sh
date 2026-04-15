#!/bin/bash
#
# Usage: ~/resume-cdc.sh
# Example: MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/resume-cdc.sh
#
# Resumes only the CDC (change data capture) phase of a previously
# interrupted migration. Unlike resume-migration.sh, this does NOT
# re-attempt the clone — it runs pgcopydb follow directly.
#
# Use this when the initial COPY completed successfully but CDC was
# interrupted (crash, reboot, connection drop). Uses MIGRATION_DIR
# env var if set, otherwise the most recent ~/migration_*/ directory.
# Backs up the SQLite catalog before resuming.
#
set -eo pipefail

# --- Load environment ---
set +u
set -a
source ~/.env
set +a
set -u

if [ -z "${PGCOPYDB_SOURCE_PGURI:-}" ] || [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
    echo "ERROR: PGCOPYDB_SOURCE_PGURI and PGCOPYDB_TARGET_PGURI must be set in ~/.env"
    exit 1
fi
# --- loaded ---

# Find the most recent migration directory, or set explicitly
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"

if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Set the path explicitly:"
    echo "  MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS $0"
    exit 1
fi

echo "Resuming CDC in: $MIGRATION_DIR"

LOGFILE=$MIGRATION_DIR/resume-cdc-$(date +%Y%m%d-%H%M%S).log
FILTER_FILE=~/filters.ini

cd "$MIGRATION_DIR"
ulimit -c unlimited
echo "$MIGRATION_DIR/core.%e.%p" | sudo tee /proc/sys/kernel/core_pattern

PGCOPYDB_BIN=$(command -v pgcopydb 2>/dev/null || true)
if [ -z "$PGCOPYDB_BIN" ]; then
    echo "ERROR: pgcopydb not found on PATH"
    exit 1
fi

# Back up SQLite catalog before resume
cp "$MIGRATION_DIR/schema/source.db" "$MIGRATION_DIR/schema/source.db.bak.$(date +%Y%m%d-%H%M%S)"

{
    echo ""
    echo "=========================================="
    echo "Resuming CDC (follow only) at $(date)"
    echo "Migration dir: $MIGRATION_DIR"
    echo "=========================================="

    "$PGCOPYDB_BIN" follow \
        --plugin wal2json \
        --resume \
        --not-consistent \
        --verbose \
        --source "$PGCOPYDB_SOURCE_PGURI" \
        --target "$PGCOPYDB_TARGET_PGURI" \
        --filter "$FILTER_FILE" \
        --dir "$MIGRATION_DIR"

    EXIT_CODE=$?
    echo "CDC resume completed at $(date) - Exit code: $EXIT_CODE"
    exit "$EXIT_CODE"
} 2>&1 | tee -a "$LOGFILE"
