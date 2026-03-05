#!/bin/bash
#
# Usage: ~/run-migration.sh
#
# Starts a pgcopydb clone --follow migration in a new timestamped directory.
# Creates ~/migration_YYYYMMDD-HHMMSS/, enables core dumps, and logs all
# output to migration.log. Intended to be run via start-migration-screen.sh.
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

MIGRATION_DIR=~/migration_$(date +%Y%m%d-%H%M%S)
LOGFILE=$MIGRATION_DIR/migration.log
FILTER_FILE=~/filters.ini
TABLE_JOBS=16
INDEX_JOBS=12

mkdir -p "$MIGRATION_DIR"
cd "$MIGRATION_DIR"
ulimit -c unlimited
echo "$MIGRATION_DIR/core.%e.%p" | sudo tee /proc/sys/kernel/core_pattern

{
    echo ""
    echo "=========================================="
    echo "Starting clone --follow at $(date)"
    echo "=========================================="

    /usr/lib/postgresql/17/bin/pgcopydb clone \
        --follow \
        --plugin wal2json \
        --verbose \
        --source "$PGCOPYDB_SOURCE_PGURI" \
        --target "$PGCOPYDB_TARGET_PGURI" \
        --filter "$FILTER_FILE" \
        --no-owner \
        --no-acl \
        --skip-db-properties \
        --table-jobs "$TABLE_JOBS" \
        --index-jobs "$INDEX_JOBS" \
        --split-tables-larger-than 50GB \
        --split-max-parts "$TABLE_JOBS" \
        --dir "$MIGRATION_DIR"

    EXIT_CODE=$?
    echo "Clone completed at $(date) - Exit code: $EXIT_CODE"
    exit "$EXIT_CODE"
} 2>&1 | tee -a "$LOGFILE"
