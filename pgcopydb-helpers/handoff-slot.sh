#!/bin/bash
#
# Usage: ~/handoff-slot.sh [publication_name] [subscription_name]
# Example: ~/handoff-slot.sh my_pub my_sub
#
# Orchestrates a zero-data-loss handoff from pgcopydb CDC to native
# PostgreSQL logical replication. After pgcopydb finishes the initial
# copy and prefetch, this script:
#
#   1. Verifies pgcopydb CDC is caught up
#   2. Creates a publication on the source for all replicated tables
#   3. Creates a pgoutput replication slot — its LSN is the cut-point
#   4. Sets that LSN as pgcopydb's endpos so it applies up to that point
#   5. Waits for pgcopydb to exit
#   6. Creates a subscription on the target (copy_data=false, create_slot=false)
#   7. Verifies the subscription is replicating
#
# The slot creation LSN is the handoff point: pgcopydb applies everything
# before it, the native subscription gets everything after it.
#
# Prerequisites:
#   - pgcopydb is running in CDC/follow mode and is caught up
#   - Tables have appropriate REPLICA IDENTITY on the source
#   - PGCOPYDB_SOURCE_PGURI and PGCOPYDB_TARGET_PGURI set in ~/.env
#
# Defaults: publication "pgcopydb_handoff", subscription "pgcopydb_handoff".
#
set -euo pipefail

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

PUB_NAME="${1:-pgcopydb_handoff}"
SUB_NAME="${2:-pgcopydb_handoff}"
PGCOPYDB_SLOT="${PGCOPYDB_SLOT_NAME:-pgcopydb}"

# Find the most recent migration directory
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"
if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Set MIGRATION_DIR or pass as env var."
    exit 1
fi

SOURCE_DB="$MIGRATION_DIR/schema/source.db"
if [ ! -f "$SOURCE_DB" ]; then
    echo "ERROR: source.db not found at $SOURCE_DB"
    exit 1
fi

echo ""
echo "======================================================================"
echo "  pgcopydb → Native Replication Handoff"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "======================================================================"
echo ""
echo "  Migration dir:     $MIGRATION_DIR"
echo "  pgcopydb slot:     $PGCOPYDB_SLOT"
echo "  Publication name:  $PUB_NAME"
echo "  Subscription name: $SUB_NAME"
echo ""

# =====================================================================
# Step 1: Verify pgcopydb is running and CDC is caught up
# =====================================================================
echo "--- Step 1: Verify pgcopydb CDC is caught up ---"
echo ""

PROCS=$(pgrep -a pgcopydb 2>/dev/null || true)
PROC_COUNT=$(echo "$PROCS" | grep -c pgcopydb 2>/dev/null || echo 0)

if [ "$PROC_COUNT" -eq 0 ]; then
    echo "  ERROR: pgcopydb is not running."
    echo "  pgcopydb must be running in CDC mode for a clean handoff."
    echo "  If it already exited, use resume-migration.sh to restart it first."
    echo ""
    exit 1
fi

echo "  pgcopydb processes: $PROC_COUNT (running)"

# Check the pgcopydb slot is active
SLOT_ACTIVE=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT active FROM pg_replication_slots WHERE slot_name = '$PGCOPYDB_SLOT';" 2>/dev/null || true)

if [ "$SLOT_ACTIVE" != "t" ]; then
    echo "  WARNING: Slot '$PGCOPYDB_SLOT' is not active."
    echo "  pgcopydb may not be in CDC streaming mode yet."
    echo ""
    read -r -p "  Continue anyway? [y/N] " CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        exit 1
    fi
fi

# Check apply lag
APPLY_LSN=""
SENTINEL_REPLAY_LSN=$(sqlite3 "$SOURCE_DB" \
    "SELECT replay_lsn FROM sentinel LIMIT 1;" 2>/dev/null || true)
if [ -n "$SENTINEL_REPLAY_LSN" ] && [ "$SENTINEL_REPLAY_LSN" != "0/0" ]; then
    APPLY_LSN="$SENTINEL_REPLAY_LSN"
fi

CURRENT_WAL_LSN=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT pg_current_wal_lsn();" 2>/dev/null || true)

if [ -n "$APPLY_LSN" ] && [ -n "$CURRENT_WAL_LSN" ]; then
    LAG_BYTES=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
        "SELECT pg_wal_lsn_diff('$CURRENT_WAL_LSN', '$APPLY_LSN');" 2>/dev/null || true)
    LAG_MB=$(( ${LAG_BYTES%.*} / 1048576 ))

    echo "  Apply LSN:          $APPLY_LSN"
    echo "  Source WAL LSN:     $CURRENT_WAL_LSN"
    echo "  Apply lag:          ${LAG_MB} MB"

    if [ "$LAG_MB" -gt 500 ]; then
        echo ""
        echo "  WARNING: Apply lag is ${LAG_MB} MB. pgcopydb should be caught up"
        echo "  (< 100 MB) before performing the handoff to minimize the window"
        echo "  where neither pgcopydb nor the subscription is applying."
        echo ""
        read -r -p "  Continue anyway? [y/N] " CONTINUE
        if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
            exit 1
        fi
    fi
else
    echo "  Could not determine apply lag (sentinel may not have replay_lsn yet)."
fi

echo ""

# =====================================================================
# Step 2: Create publication on source
# =====================================================================
echo "--- Step 2: Create publication on source ---"
echo ""

# Check if publication already exists
PUB_EXISTS=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT COUNT(*) FROM pg_publication WHERE pubname = '$PUB_NAME';" 2>/dev/null || true)

if [ "$PUB_EXISTS" -gt 0 ]; then
    echo "  Publication '$PUB_NAME' already exists, skipping creation."
else
    # Get the list of schemas pgcopydb is replicating from the filter config.
    # If include-only-schema is set in filters.ini, use those schemas.
    # Otherwise default to ALL TABLES.
    FILTER_FILE=~/filters.ini
    PUB_SCOPE="ALL TABLES"

    if [ -f "$FILTER_FILE" ]; then
        # Extract include-only-schema entries if present
        INCLUDE_SCHEMAS=$(awk '/^\[include-only-schema\]/{found=1; next} /^\[/{found=0} found && /^[^#]/ && NF{print}' "$FILTER_FILE" 2>/dev/null || true)

        if [ -n "$INCLUDE_SCHEMAS" ]; then
            # Build TABLES IN SCHEMA clause
            SCHEMA_LIST=""
            while IFS= read -r schema; do
                schema=$(echo "$schema" | xargs)  # trim whitespace
                if [ -n "$schema" ]; then
                    if [ -n "$SCHEMA_LIST" ]; then
                        SCHEMA_LIST="$SCHEMA_LIST, $schema"
                    else
                        SCHEMA_LIST="$schema"
                    fi
                fi
            done <<< "$INCLUDE_SCHEMAS"

            if [ -n "$SCHEMA_LIST" ]; then
                PUB_SCOPE="TABLES IN SCHEMA $SCHEMA_LIST"
            fi
        fi
    fi

    echo "  Creating publication '$PUB_NAME' FOR $PUB_SCOPE..."
    psql "$PGCOPYDB_SOURCE_PGURI" -c "CREATE PUBLICATION $PUB_NAME FOR $PUB_SCOPE;" 2>&1
fi

# Verify
PUB_TABLE_COUNT=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT COUNT(*) FROM pg_publication_tables WHERE pubname = '$PUB_NAME';" 2>/dev/null || true)
echo "  Publication '$PUB_NAME' covers $PUB_TABLE_COUNT table(s)."
echo ""

if [ "$PUB_TABLE_COUNT" -eq 0 ]; then
    echo "  ERROR: Publication has no tables. Check your filter configuration."
    echo "  You may need to create the publication manually with the correct scope."
    exit 1
fi

# =====================================================================
# Step 3: Create pgoutput slot — this LSN is the cut-point
# =====================================================================
echo "--- Step 3: Create pgoutput replication slot (cut-point) ---"
echo ""

# Check if slot already exists
NEW_SLOT_EXISTS=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$SUB_NAME';" 2>/dev/null || true)

if [ "$NEW_SLOT_EXISTS" -gt 0 ]; then
    echo "  Slot '$SUB_NAME' already exists."
    CUTOVER_LSN=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
        "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$SUB_NAME';" 2>/dev/null || true)
    echo "  Using existing slot LSN: $CUTOVER_LSN"
else
    CUTOVER_LSN=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
        "SELECT lsn FROM pg_create_logical_replication_slot('$SUB_NAME', 'pgoutput');" 2>/dev/null)

    if [ -z "$CUTOVER_LSN" ]; then
        echo "  ERROR: Failed to create replication slot."
        exit 1
    fi

    echo "  Created slot '$SUB_NAME' with pgoutput plugin."
    echo "  Cut-point LSN: $CUTOVER_LSN"
fi

echo ""
echo "  This is the handoff LSN. pgcopydb will apply up to this point,"
echo "  then the native subscription takes over from here."
echo ""

# =====================================================================
# Step 4: Set pgcopydb endpos to the cut-point LSN
# =====================================================================
echo "--- Step 4: Set pgcopydb endpos to cut-point LSN ---"
echo ""

sqlite3 "$SOURCE_DB" "UPDATE sentinel SET endpos = '$CUTOVER_LSN';"

VERIFIED_ENDPOS=$(sqlite3 "$SOURCE_DB" "SELECT endpos FROM sentinel;")
echo "  Sentinel endpos set to: $VERIFIED_ENDPOS"

if [ "$VERIFIED_ENDPOS" != "$CUTOVER_LSN" ]; then
    echo "  ERROR: Endpos verification failed."
    echo "  Expected: $CUTOVER_LSN"
    echo "  Got:      $VERIFIED_ENDPOS"
    exit 1
fi

echo "  pgcopydb will stop after applying changes up to this LSN."
echo ""

# =====================================================================
# Step 5: Wait for pgcopydb to exit
# =====================================================================
echo "--- Step 5: Waiting for pgcopydb to exit ---"
echo ""
echo "  pgcopydb is applying remaining changes up to $CUTOVER_LSN..."
echo "  This may take a moment. (Ctrl+C to abort)"
echo ""

while true; do
    STILL_RUNNING=$(pgrep -c pgcopydb 2>/dev/null || echo 0)
    if [ "$STILL_RUNNING" -eq 0 ]; then
        echo "  pgcopydb has exited."
        break
    fi

    # Show progress
    CURRENT_REPLAY=$(sqlite3 "$SOURCE_DB" \
        "SELECT replay_lsn FROM sentinel LIMIT 1;" 2>/dev/null || true)
    if [ -n "$CURRENT_REPLAY" ] && [ "$CURRENT_REPLAY" != "0/0" ]; then
        REMAINING=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
            "SELECT pg_size_pretty(pg_wal_lsn_diff('$CUTOVER_LSN', '$CURRENT_REPLAY'));" 2>/dev/null || true)
        echo "  Replay LSN: $CURRENT_REPLAY  Remaining: ${REMAINING:-unknown}"
    fi

    sleep 10
done

echo ""

# =====================================================================
# Step 6: Create subscription on target
# =====================================================================
echo "--- Step 6: Create subscription on target ---"
echo ""

# Check if subscription already exists
SUB_EXISTS=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c \
    "SELECT COUNT(*) FROM pg_subscription WHERE subname = '$SUB_NAME';" 2>/dev/null || true)

if [ "$SUB_EXISTS" -gt 0 ]; then
    echo "  Subscription '$SUB_NAME' already exists, skipping creation."
else
    # Extract source connection info for the subscription.
    # The subscription needs a direct conninfo string to the source.
    echo "  Creating subscription '$SUB_NAME' on target..."
    echo "  (copy_data=false — data already present from pgcopydb)"
    echo "  (create_slot=false — using slot created in step 3)"
    echo ""

    psql "$PGCOPYDB_TARGET_PGURI" -c \
        "CREATE SUBSCRIPTION $SUB_NAME
         CONNECTION '$PGCOPYDB_SOURCE_PGURI'
         PUBLICATION $PUB_NAME
         WITH (
             copy_data = false,
             create_slot = false,
             slot_name = '$SUB_NAME',
             enabled = true
         );" 2>&1

    if [ $? -ne 0 ]; then
        echo ""
        echo "  ERROR: Failed to create subscription."
        echo "  You may need to create it manually. The slot '$SUB_NAME' is"
        echo "  ready on the source at LSN $CUTOVER_LSN."
        exit 1
    fi
fi

echo ""

# =====================================================================
# Step 7: Verify subscription is replicating
# =====================================================================
echo "--- Step 7: Verify subscription is replicating ---"
echo ""

echo "  Waiting for subscription to become active..."

ATTEMPTS=0
MAX_ATTEMPTS=12

while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
    SUB_STATE=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c \
        "SELECT srsubstate FROM pg_subscription_rel
         WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = '$SUB_NAME')
         LIMIT 1;" 2>/dev/null || true)

    SLOT_NOW_ACTIVE=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
        "SELECT active FROM pg_replication_slots WHERE slot_name = '$SUB_NAME';" 2>/dev/null || true)

    if [ "$SLOT_NOW_ACTIVE" = "t" ]; then
        echo "  Slot '$SUB_NAME' is ACTIVE — subscription is consuming."
        echo ""

        CONSUMER_LAG=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
            "SELECT pg_size_pretty(pg_current_wal_lsn() - confirmed_flush_lsn)
             FROM pg_replication_slots
             WHERE slot_name = '$SUB_NAME';" 2>/dev/null || true)

        echo "  Current lag: ${CONSUMER_LAG:-unknown}"
        break
    fi

    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "  WARNING: Subscription slot did not become active within 60 seconds."
    echo "  Check subscription status manually:"
    echo "    psql \"\$PGCOPYDB_TARGET_PGURI\" -c \"SELECT * FROM pg_stat_subscription;\""
    echo "    psql \"\$PGCOPYDB_SOURCE_PGURI\" -c \"SELECT * FROM pg_replication_slots WHERE slot_name = '$SUB_NAME';\""
fi

echo ""

# =====================================================================
# Cleanup guidance
# =====================================================================
echo "======================================================================"
echo "  Handoff Summary"
echo "======================================================================"
echo ""
echo "  Cut-point LSN:     $CUTOVER_LSN"
echo "  Publication:       $PUB_NAME (source)"
echo "  Subscription:      $SUB_NAME (target)"
echo "  Subscription slot: $SUB_NAME (source, pgoutput)"
echo ""
echo "  pgcopydb applied all changes up to $CUTOVER_LSN."
echo "  The native subscription is replicating changes from that point forward."
echo ""
echo "  --- Cleanup (safe to run now) ---"
echo ""
echo "  Drop the old pgcopydb wal2json slot on source:"
echo "    psql \"\$PGCOPYDB_SOURCE_PGURI\" -c \"SELECT pg_drop_replication_slot('$PGCOPYDB_SLOT');\""
echo ""
echo "  Drop pgcopydb replication origin on target:"
echo "    psql \"\$PGCOPYDB_TARGET_PGURI\" -c \"SELECT pg_replication_origin_drop('$PGCOPYDB_SLOT');\""
echo ""
echo "  Do NOT drop the '$SUB_NAME' slot — the subscription is using it."
echo ""
echo "======================================================================"
echo ""
