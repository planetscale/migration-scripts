#!/bin/bash
#
# Usage: ~/drop-replication-slots.sh [slot_name]
# Example: ~/drop-replication-slots.sh pgcopydb
#
# Cleans up pgcopydb replication artifacts: drops the replication slot on
# the source, the replication origin on the target, and the pgcopydb
# sentinel schema on the target. Defaults to slot/origin name "pgcopydb".
#
set -e

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

SLOT_NAME="${1:-pgcopydb}"
ORIGIN_NAME="${1:-pgcopydb}"

echo "=== Cleaning up replication artifacts for slot/origin: $SLOT_NAME ==="
echo ""

# --- SOURCE: drop replication slot ---
echo "--- Source: checking replication slot ---"
SLOT_EXISTS=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
  "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")

if [ "$SLOT_EXISTS" -gt 0 ]; then
  SLOT_ACTIVE=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT active FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")

  if [ "$SLOT_ACTIVE" = "t" ]; then
    echo "  Slot '$SLOT_NAME' is active, terminating consumer..."
    ACTIVE_PID=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
      "SELECT active_pid FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")
    psql "$PGCOPYDB_SOURCE_PGURI" -c "SELECT pg_terminate_backend($ACTIVE_PID);" > /dev/null
    sleep 2
  fi

  echo "  Dropping replication slot '$SLOT_NAME'..."
  psql "$PGCOPYDB_SOURCE_PGURI" -c "SELECT pg_drop_replication_slot('$SLOT_NAME');" > /dev/null
  echo "  Done."
else
  echo "  No replication slot '$SLOT_NAME' found (already clean)."
fi

echo ""

# --- TARGET: drop replication origin ---
echo "--- Target: checking replication origin ---"
ORIGIN_EXISTS=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c \
  "SELECT COUNT(*) FROM pg_replication_origin WHERE roname = '$ORIGIN_NAME';")

if [ "$ORIGIN_EXISTS" -gt 0 ]; then
  echo "  Dropping replication origin '$ORIGIN_NAME'..."
  psql "$PGCOPYDB_TARGET_PGURI" -c "SELECT pg_replication_origin_drop('$ORIGIN_NAME');" > /dev/null
  echo "  Done."
else
  echo "  No replication origin '$ORIGIN_NAME' found (already clean)."
fi

echo ""

# --- TARGET: drop pgcopydb sentinel schema ---
echo "--- Target: checking pgcopydb schema ---"
SCHEMA_EXISTS=$(psql "$PGCOPYDB_TARGET_PGURI" -t -A -c \
  "SELECT COUNT(*) FROM pg_namespace WHERE nspname = 'pgcopydb';")

if [ "$SCHEMA_EXISTS" -gt 0 ]; then
  echo "  Dropping schema 'pgcopydb' and its objects..."
  psql "$PGCOPYDB_TARGET_PGURI" -c "DROP SCHEMA pgcopydb CASCADE;" > /dev/null
  echo "  Done."
else
  echo "  No schema 'pgcopydb' found (already clean)."
fi

echo ""
echo "=== Cleanup complete ==="

