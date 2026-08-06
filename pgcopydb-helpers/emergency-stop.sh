#!/bin/bash
#
# Usage: ~/emergency-stop.sh
# Example: MIGRATION_DIR=~/migration_YYYYMMDD-HHMMSS ~/emergency-stop.sh
#
# EMERGENCY STOP: immediately terminates a running pgcopydb migration and 
# ALL of its subprocesses (clone/COPY/index/follow workers). Use when the source
# database is overloaded or the migration must be halted at once. Prompts for
# confirmation and spells out the consequences first, then sends SIGTERM to the
# whole process group and escalates to SIGKILL on its own if anything survives.
#
# Stop-only by design: it does NOT drop the replication slot, snapshot, or
# target data, so the migration stays resumable via resume-migration.sh /
# resume-cdc.sh.
#
set -eo pipefail

# List live pgcopydb PIDs by exact process name. Every pgcopydb process —
# supervisor and workers — is named "pgcopydb". 
# If none are found, returns an empty string (not an error).
pgcopydb_pids() { pgrep -x pgcopydb 2>/dev/null || true; }

# Wait up to $1 seconds for every pgcopydb process to disappear (lets the OS reap
# children after a kill). Returns 0 once none remain, non-zero on timeout.
wait_until_gone() {
    local secs="$1"
    while [ "$secs" -gt 0 ]; do
        [ -z "$(pgcopydb_pids)" ] && return 0
        sleep 1
        secs=$((secs - 1))
    done
    [ -z "$(pgcopydb_pids)" ]
}

# Find the most recent migration directory, or set MIGRATION_DIR explicitly
MIGRATION_DIR="${MIGRATION_DIR:-$(ls -dt ~/migration_*/ 2>/dev/null | head -1 || true)}"

# --- Locate the running pgcopydb supervisor ---
# pgcopydb writes its supervisor PID to <dir>/pgcopydb.pid at startup. Fall back
# to pgrep so the script still works if the pidfile is missing or stale.
MAIN_PID=""
PIDFILE="$MIGRATION_DIR/pgcopydb.pid"
if [ -n "$MIGRATION_DIR" ] && [ -f "$PIDFILE" ]; then
    MAIN_PID=$(head -1 "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
    # Drop a stale pid that no longer points at a live process
    if [ -n "$MAIN_PID" ] && ! kill -0 "$MAIN_PID" 2>/dev/null; then
        MAIN_PID=""
    fi
fi

PGCOPYDB_PIDS=$(pgcopydb_pids)

if [ -z "$MAIN_PID" ] && [ -z "$PGCOPYDB_PIDS" ]; then
    echo "No running pgcopydb migration found. Nothing to stop."
    exit 0
fi

PROC_COUNT=$(printf '%s\n' "$PGCOPYDB_PIDS" | grep -c '[0-9]' || true)
PGID=""
if [ -n "$MAIN_PID" ]; then
    PGID=$(ps -o pgid= -p "$MAIN_PID" 2>/dev/null | tr -d ' ' || true)
fi

# Safety net: only signal pgcopydb's process group when it is genuinely its own
# group (pgcopydb calls setpgrp at startup, so it always is in production). 
OWN_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)
USE_PGID=0
if [ -n "$PGID" ] && [ "$PGID" != "$OWN_PGID" ]; then
    USE_PGID=1
fi

# --- Report what will be stopped (query pgcopydb's catalog directly) ---
COPY_DONE=0
TABLES_DONE=""
TABLES_TOTAL=""
CDC_STARTED="no"
SOURCE_DB="$MIGRATION_DIR/schema/source.db"
if [ -n "$MIGRATION_DIR" ] && [ -f "$SOURCE_DB" ]; then
    TABLES_TOTAL=$(sqlite3 "$SOURCE_DB" "SELECT COUNT(*) FROM s_table;" 2>/dev/null || true)
    TABLES_DONE=$(sqlite3 "$SOURCE_DB" \
        "SELECT COUNT(*) FROM summary WHERE tableoid IS NOT NULL AND done_time_epoch IS NOT NULL;" 2>/dev/null || true)
    WRITE_LSN=$(sqlite3 "$SOURCE_DB" "SELECT write_lsn FROM sentinel LIMIT 1;" 2>/dev/null || true)
    if [ -n "$WRITE_LSN" ]; then CDC_STARTED="yes"; fi
    if [ -n "$TABLES_TOTAL" ] && [ "$TABLES_TOTAL" -gt 0 ] 2>/dev/null && [ "$TABLES_DONE" = "$TABLES_TOTAL" ]; then
        COPY_DONE=1
    fi
fi

echo "=========================================="
echo "EMERGENCY STOP: pgcopydb migration"
echo "=========================================="
echo "Migration dir:    ${MIGRATION_DIR:-(unknown)}"
echo "Supervisor PID:   ${MAIN_PID:-(no pidfile — using pgrep)}"
echo "Process group:    ${PGID:-(n/a)}"
echo "pgcopydb procs:   ${PROC_COUNT:-0}"
if [ -n "$TABLES_TOTAL" ]; then
    echo "Initial COPY:     ${TABLES_DONE:-0}/${TABLES_TOTAL} tables done"
fi
echo "CDC started:      $CDC_STARTED"
echo ""
echo "Consequences of stopping NOW:"
echo "  - pgcopydb and ALL its workers (COPY/index/follow) are terminated at once."
echo "  - If the initial copy is still running, target tables may be left"
echo "    PARTIALLY COPIED and are not consistent until the migration resumes."
echo "  - The source replication slot stays ACTIVE (kept on purpose so you can"
echo "    resume) — it holds WAL on the source until you resume or drop it."
echo "  - This is RECOVERABLE: the migration dir, SQLite catalog, and slot are"
echo "    preserved, so the migration can be resumed."
echo ""
read -r -p "Stop the migration NOW? [y/N] " CONFIRM || CONFIRM=""
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Stop: SIGTERM the whole process group, then escalate automatically ---
echo ""
echo "Sending SIGTERM..."
if [ "$USE_PGID" -eq 1 ]; then
    kill -TERM -- "-$PGID" 2>/dev/null || true
else
    pkill -TERM -x pgcopydb 2>/dev/null || true
fi

# Give pgcopydb up to ~10s to wind down cleanly. If it doesn't, escalate to
# SIGKILL automatically and keep trying — by process group AND
# by each surviving PID — for several rounds.
if ! wait_until_gone 10; then
    echo "Still running after SIGTERM — escalating to SIGKILL..."
    tries=5
    while [ "$tries" -gt 0 ] && [ -n "$(pgcopydb_pids)" ]; do
        [ "$USE_PGID" -eq 1 ] && kill -KILL -- "-$PGID" 2>/dev/null || true
        pkill -KILL -x pgcopydb 2>/dev/null || true
        for p in $(pgcopydb_pids); do kill -KILL "$p" 2>/dev/null || true; done
        wait_until_gone 2 && break
        tries=$((tries - 1))
    done
fi

# Tear down a lingering detached screen session from start-migration-screen.sh
screen -S migration -X quit >/dev/null 2>&1 || true

# --- Verify: only after SIGTERM + repeated SIGKILL do we ask the user to act ---
REMAINING="$(pgcopydb_pids | tr '\n' ' ')"
if [ -n "${REMAINING// /}" ]; then
    echo ""
    echo "############################################################"
    echo "WARNING: pgcopydb is STILL RUNNING after SIGTERM and repeated SIGKILL."
    echo "Surviving PIDs: $REMAINING"
    echo "Inspect and kill them manually, then re-run this script:"
    echo "    ps -o pid,stat,comm -p $REMAINING"
    echo "    sudo kill -9 $REMAINING"
    echo "    ~/emergency-stop.sh"
    echo "############################################################"
    exit 1
fi

echo ""
echo "All pgcopydb processes stopped."
echo ""
echo "=========================================="
echo "Next steps"
echo "=========================================="
echo "To RESUME where it stopped (slot + catalog are intact):"
if [ "$COPY_DONE" -eq 1 ]; then
    echo "  Initial COPY had finished — resume CDC only:"
    echo "    ~/resume-cdc.sh"
    echo "  (or, to re-run the full clone + CDC: ~/resume-migration.sh)"
else
    echo "  Initial COPY was not finished — resume the full clone + CDC:"
    echo "    ~/resume-migration.sh"
    echo "  (or, if the copy was actually complete: ~/resume-cdc.sh)"
fi
echo ""
echo "To ABANDON and start fresh:"
echo "    ~/drop-replication-slots.sh   # remove slot/origin"
echo "    ~/target-clean.sh             # wipe the target"
echo "    ~/start-migration-screen.sh   # start over"
echo ""
echo "If you will NOT resume soon and need to relieve the source, run"
echo "~/drop-replication-slots.sh to free the WAL the slot is holding."
echo "WARNING: dropping the slot makes resume impossible (full re-clone required)."
