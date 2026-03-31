#!/bin/bash
#
# Usage: ~/resume-migration.sh [migration_dir]
# Example: ~/resume-migration.sh ~/migration_YYYYMMDD-HHMMSS
#
# Resumes a previously interrupted pgcopydb clone --follow migration.
# If no directory is given, uses the most recent ~/migration_* directory.
# Backs up the SQLite catalog before resuming.
#
# IMPORTANT: --split-tables-larger-than and --resume
# If the original migration used --split-tables-larger-than, you MUST pass
# the same value here -- pgcopydb validates catalog consistency and will
# refuse to resume without it. This is SAFE if the COPY phase already
# completed (indexes, CDC, etc.). If COPY was still in progress when the
# failure occurred, use --restart instead -- pgcopydb truncates split tables
# before re-queuing parts on resume, which loses already-copied partitions.
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
if [ -n "${1:-}" ]; then
    MIGRATION_DIR="$1"
else
    MIGRATION_DIR=$(ls -dt ~/migration_* 2>/dev/null | head -1)
fi

if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Pass the path as an argument:"
    echo "  $0 ~/migration_YYYYMMDD-HHMMSS"
    exit 1
fi

echo "Resuming migration in: $MIGRATION_DIR"

LOGFILE=$MIGRATION_DIR/migration.log
FILTER_FILE=~/filters.ini
TABLE_JOBS=16
INDEX_JOBS=12

cd "$MIGRATION_DIR"
ulimit -c unlimited
echo "$MIGRATION_DIR/core.%e.%p" | sudo tee /proc/sys/kernel/core_pattern

# Back up SQLite catalog before resume
cp "$MIGRATION_DIR/schema/source.db" "$MIGRATION_DIR/schema/source.db.bak.$(date +%Y%m%d-%H%M%S)"

{
    echo ""
    echo "=========================================="
    echo "Resuming clone --follow at $(date)"
    echo "Migration dir: $MIGRATION_DIR"
    echo "=========================================="

    # If the original migration used --split-tables-larger-than, pass the
    # same value here. This is safe when COPY is already complete (the COPY
    # supervisor won't run, so no truncation occurs). If COPY failed
    # mid-flight, use --restart instead of --resume.
    /usr/lib/postgresql/17/bin/pgcopydb clone \
        --follow \
        --plugin wal2json \
        --resume \
        --not-consistent \
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
    echo "Resume completed at $(date) - Exit code: $EXIT_CODE"
    exit "$EXIT_CODE"
} 2>&1 | tee -a "$LOGFILE"
