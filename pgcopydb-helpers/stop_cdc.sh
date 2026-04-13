#!/bin/bash

# Usage: ~/stop_cdc.sh <LSN>
# Example: ~/stop_cdc.sh 41EBA/7C7A1AD8
# Example: MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/stop_cdc.sh 41EBA/7C7A1AD8
#
# Sets the CDC endpos sentinel so pgcopydb stops streaming
# after reaching the given LSN. Uses MIGRATION_DIR env var if set,
# otherwise the most recent ~/migration_*/ directory.
# Use the sqlite3 method (more reliable than the pgcopydb CLI sentinel command).


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

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <LSN>"
    echo "Example: $0 41EBA/7C7A1AD8"
    echo ""
    echo "Get current source LSN with:"
    echo "  psql \"\$PGCOPYDB_SOURCE_PGURI\" -t -A -c \"SELECT pg_current_wal_lsn();\""
    exit 1
fi

ENDPOS_LSN="$1"

# Find the most recent migration directory
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"

if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Pass the path as second argument:"
    echo "  $0 <LSN> ~/migration_YYYYMMDD-HHMMSS"
    exit 1
fi

SOURCE_DB="$MIGRATION_DIR/schema/source.db"

if [ ! -f "$SOURCE_DB" ]; then
    echo "ERROR: source.db not found at $SOURCE_DB"
    exit 1
fi

echo "Setting CDC endpos to: $ENDPOS_LSN"
echo "Migration directory:   $MIGRATION_DIR"
echo ""

# Set endpos via sqlite3 (more reliable than pgcopydb CLI)
sqlite3 "$SOURCE_DB" "UPDATE sentinel SET endpos = '$ENDPOS_LSN';"

# Verify
CURRENT=$(sqlite3 "$SOURCE_DB" "SELECT endpos FROM sentinel;")
echo "Verified sentinel endpos: $CURRENT"
echo ""
echo "pgcopydb will stop streaming after reaching this LSN."
echo "Monitor with: ~/check-migration-status.sh"
