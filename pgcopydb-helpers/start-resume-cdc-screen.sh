#!/bin/bash
set -eo pipefail

if [ ! -f ~/.env ]; then
    echo "ERROR: ~/.env not found. Create it from the template:" >&2
    echo "  cp ~/env-template ~/.env && chmod 600 ~/.env" >&2
    exit 1
fi
set -a
source ~/.env
set +a

if [ -z "${PGCOPYDB_SOURCE_PGURI:-}" ] || [ -z "${PGCOPYDB_TARGET_PGURI:-}" ]; then
    echo "ERROR: PGCOPYDB_SOURCE_PGURI and PGCOPYDB_TARGET_PGURI must be set in ~/.env" >&2
    exit 1
fi

MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"
if [ -z "$MIGRATION_DIR" ] || [ ! -d "$MIGRATION_DIR" ]; then
    echo "ERROR: No migration directory found. Set the path explicitly:" >&2
    echo "  MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS $0" >&2
    exit 1
fi

RUNNING=$(pgrep -af "pgcopydb (clone|follow)" || true)
if [ -n "$RUNNING" ]; then
    echo "ERROR: pgcopydb is already running:" >&2
    echo "$RUNNING" >&2
    echo "Stop it with ~/emergency-stop.sh before you resume CDC." >&2
    exit 1
fi

if ! SLOT_PID=$(psql "$PGCOPYDB_SOURCE_PGURI" -t -A \
    -c "SELECT active_pid FROM pg_replication_slots WHERE slot_name = 'pgcopydb' AND active;"); then
    echo "ERROR: Failed to query replication slots on the source" >&2
    exit 1
fi
if [ -n "$SLOT_PID" ]; then
    echo "ERROR: Replication slot 'pgcopydb' is in use by source backend PID $SLOT_PID." >&2
    echo "Stop the process that uses the slot before you resume CDC." >&2
    exit 1
fi

screen -S resume-cdc -X quit > /dev/null 2>&1 || true

MIGRATION_DIR="$MIGRATION_DIR" screen -dmS resume-cdc bash -c '~/resume-cdc.sh; echo "Press enter to exit."; read'

sleep 10
if ! pgrep -f "pgcopydb follow" > /dev/null; then
    echo "ERROR: pgcopydb follow is not running 10 seconds after the start." >&2
    echo "Last lines of $MIGRATION_DIR/migration.log:" >&2
    tail -n 20 "$MIGRATION_DIR/migration.log" >&2 2>/dev/null || true
    echo "Attach with: screen -r resume-cdc" >&2
    exit 1
fi

echo "CDC resume started in screen session 'resume-cdc'"
echo "Migration directory: $MIGRATION_DIR"
echo ""
echo "To watch:        screen -r resume-cdc"
echo "To detach:       Ctrl-A then D"
echo "To check status: ~/check-migration-status.sh"
echo "────────────────────────────────────────────────────────"
