#!/bin/bash
#
# Usage: ~/drop-replication-slots.sh [slot_name]
# Example: ~/drop-replication-slots.sh pgcopydb
#
# Cleans up pgcopydb replication artifacts: drops the replication slot and
# the pgoutput publication on the source, the replication origin on the
# target, and the pgcopydb sentinel schema on the target. Defaults to the
# slot/origin/publication name "pgcopydb".
#
# pgcopydb creates the publication only when OUTPUT_PLUGIN is pgoutput. It
# names the publication after the replication slot.
#
set -e

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
# --- loaded ---

SLOT_NAME="${1:-pgcopydb}"
ORIGIN_NAME="${1:-pgcopydb}"
PUBLICATION_NAME="${1:-pgcopydb}"

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

# --- SOURCE: drop the pgoutput publication ---
# pgcopydb creates this publication only for the pgoutput plugin, and names it
# after the replication slot. Nothing exists to drop for wal2json.
echo "--- Source: checking publication ---"
PUB_EXISTS=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
  "SELECT COUNT(*) FROM pg_publication WHERE pubname = '$PUBLICATION_NAME';")

if [ "$PUB_EXISTS" -gt 0 ]; then
  echo "  Dropping publication '$PUBLICATION_NAME'..."
  DROP_PUB_SQL=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A -c \
    "SELECT 'DROP PUBLICATION ' || quote_ident(pubname) || ';'
     FROM pg_publication WHERE pubname = '$PUBLICATION_NAME';")
  if psql "$PGCOPYDB_SOURCE_PGURI" -v ON_ERROR_STOP=1 -c "$DROP_PUB_SQL" > /dev/null; then
    echo "  Done."
  else
    echo "  WARN: could not drop publication '$PUBLICATION_NAME'."
    echo "        The source user must own it. Drop it manually as the owner."
  fi
else
  echo "  No publication '$PUBLICATION_NAME' found (already clean)."
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

