#!/bin/bash

# Usage: ~/stop-cdc.sh
# Example: MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/stop-cdc.sh
#
# Fetches the current WAL LSN from the source, asks for confirmation,
# then sets the CDC endpos sentinel so pgcopydb stops streaming after
# reaching that LSN. Uses MIGRATION_DIR env var if set,
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

echo "Fetching current WAL LSN from source..."
ENDPOS_LSN=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c "SELECT pg_current_wal_lsn();" 2>&1)
if [ $? -ne 0 ] || [ -z "$ENDPOS_LSN" ]; then
    echo "ERROR: Failed to fetch LSN from source database:"
    echo "  $ENDPOS_LSN"
    exit 1
fi

echo ""
echo "Current source LSN: $ENDPOS_LSN"
echo ""
read -r -p "Stop CDC at this LSN? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Find the most recent migration directory
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"

if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Set MIGRATION_DIR explicitly:"
    echo "  MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS $0"
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
