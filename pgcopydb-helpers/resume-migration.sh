#!/bin/bash
#
# Usage: ~/resume-migration.sh
# Example: MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/resume-migration.sh
#
# Resumes a previously interrupted pgcopydb clone --follow migration.
# Uses MIGRATION_DIR env var if set, otherwise the most recent ~/migration_*/ directory.
# Backs up the SQLite catalog before resuming.
#
# Uses --split-tables-larger-than to match run-migration.sh. pgcopydb
# requires catalog consistency — if the original run used split tables,
# the resume must pass the same value.
#
set -eo pipefail

# --- Load environment ---
if [ ! -f ~/.env ]; then
    echo "ERROR: ~/.env not found. Create it from the template:" >&2
    echo "  cp ~/env-template ~/.env && chmod 600 ~/.env" >&2
    exit 1
fi
set +u
set -a
source ~/.env
set +a
set -u

if [ -z "${PGCOPYDB_SOURCE_PGURI:-}" ] || [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
    echo "ERROR: PGCOPYDB_SOURCE_PGURI and PGCOPYDB_TARGET_PGURI must be set in ~/.env"
    exit 1
fi

if [ -z "${PUBLICATION_NAME:-}" ]; then
    echo "ERROR: PUBLICATION_NAME must be set in ~/.env"
    echo "  Add: export PUBLICATION_NAME=migration_pub"
    exit 1
fi
# --- loaded ---

# --- Locate pgcopydb: prefer PATH, else highest-versioned PG install ---
find_pgcopydb() {
    local bin
    if bin=$(command -v pgcopydb 2>/dev/null); then
        echo "$bin"; return 0
    fi
    bin=$(ls -d /usr/lib/postgresql/*/bin/pgcopydb 2>/dev/null | sort -rV | head -n1 || true)
    if [ -n "$bin" ] && [ -x "$bin" ]; then
        echo "$bin"; return 0
    fi
    return 1
}
PGCOPYDB_BIN=$(find_pgcopydb) || { echo "ERROR: pgcopydb not found on PATH or under /usr/lib/postgresql/*/bin" >&2; exit 1; }
# --- located ---

# Find the most recent migration directory, or set explicitly
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"

if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Pass the path as an argument:"
    echo "  $0 ~/migration_YYYYMMDD-HHMMSS"
    exit 1
fi

echo "Resuming migration in: $MIGRATION_DIR"

LOGFILE=$MIGRATION_DIR/migration.log

# Tunables come from ~/.env. See env-template for the full list.
# Keep these in sync with run-migration.sh — a resume must use the same values.
FILTER_FILE="${FILTER_FILE:-$HOME/filters.ini}"
TABLE_JOBS="${TABLE_JOBS:-8}"
INDEX_JOBS="${INDEX_JOBS:-6}"
SPLIT_TABLES_LARGER_THAN="${SPLIT_TABLES_LARGER_THAN:-50GB}"
OUTPUT_PLUGIN="${OUTPUT_PLUGIN:-pgoutput}"


cd "$MIGRATION_DIR"
# Core dumps help debug rare native crashes; not required for a successful migrate.
# SSM sessions often cannot raise the core ulimit — do not abort if this fails.
if ! ulimit -c unlimited 2>/dev/null; then
    echo "WARN: could not raise core ulimit (common under SSM); continuing without core dumps" >&2
fi
if ! echo "$MIGRATION_DIR/core.%e.%p" | sudo tee /proc/sys/kernel/core_pattern; then
    echo "WARN: could not set kernel.core_pattern; continuing without core dumps" >&2
fi

# Back up SQLite catalog before resume
cp "$MIGRATION_DIR/schema/source.db" "$MIGRATION_DIR/schema/source.db.bak.$(date +%Y%m%d-%H%M%S)"

{
    echo ""
    echo "=========================================="
    echo "Resuming clone --follow at $(date)"
    echo "Migration dir: $MIGRATION_DIR"
    echo "Plugin: $OUTPUT_PLUGIN | table-jobs: $TABLE_JOBS | index-jobs: $INDEX_JOBS"
    echo "Publication: $PUBLICATION_NAME"
    echo "Split tables larger than: $SPLIT_TABLES_LARGER_THAN | filter: $FILTER_FILE"
    echo "=========================================="

    "$PGCOPYDB_BIN" clone \
        --follow \
        --plugin "$OUTPUT_PLUGIN" \
        --publication "$PUBLICATION_NAME" \
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
        --split-tables-larger-than "$SPLIT_TABLES_LARGER_THAN" \
        --split-max-parts "$TABLE_JOBS" \
        --dir "$MIGRATION_DIR"

    EXIT_CODE=$?
    echo "Resume completed at $(date) - Exit code: $EXIT_CODE"
    exit "$EXIT_CODE"
} 2>&1 | tee -a "$LOGFILE"
